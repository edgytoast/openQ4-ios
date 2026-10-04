//
//  OpenQ4VisionApp.swift — SwiftUI app entry for the visionOS target. D-090/D-100.
//
//  This file is SCENE PLUMBING ONLY. It exists because visionOS requires a
//  SwiftUI `App` to declare an `ImmersiveSpace`, and D-089 settled that the
//  visionOS app is SwiftUI-entry from its FIRST build rather than flipping entry
//  style once Phase 6 needs the space — vkQuake D-028 found that flipping it
//  over a bundle id that has already launched makes UIKit restore a persisted
//  scene session naming SDL's scene delegate, which then calls through a NULL
//  forward_main and dies at PC=0 with no usable crash report, on the tester's
//  device only.
//
//  Phase 6 round 2 lands the space here, exactly as that comment promised, with
//  no change to the entry style. Everything it does lives in C/ObjC:
//  OpenQ4Immersive.m owns the CompositorServices loop, OpenQ4Vision3D.m owns the
//  ordering around it.
//
//  Deliberately NOT set on the WindowGroup, per the brief's inherited findings:
//    - no `defaultSize`      — the engine sizes itself from whatever the scene
//                              gives it, and a requested size races the boot.
//    - no `windowResizability` — the aspect lock is requested from UIKit in
//                              OpenQ4HostViewController (uniform resizing), which
//                              is the API that actually constrains a visionOS
//                              window's shape.
//

import SwiftUI
import CompositorServices
import AVFAudio

/// D-107 defect 2 — the game's audio came from the parked 2D card, not the panel.
///
/// That is what visionOS does by default: an app's audio is spatialised at its
/// SCENE, and in 3D the app's only regular scene is the 480 pt card parked
/// wherever the player left it. Nothing in this tree ever said otherwise — STATUS
/// carried "spatial audio" as not-done since round 2.
///
/// Copied, not designed: vkQuake `ios/shell-visionos/VKQVisionApp.swift:66-82`
/// (`vkqSetAudioFrontStage`, called at :256 after `openImmersiveSpace` succeeds
/// and at :261 after `dismissImmersiveSpace`) and quake3e
/// `ios/shell-visionos/Q3EVisionApp.swift:20-38` (`Q3E_SetSpatialAudioMode`).
/// `.headTracked(..., anchoringStrategy: .front)` puts the sound stage in front
/// of the player — where the panel is — and `.automatic` hands it back to the
/// window on exit. Sound-stage size is quake3e's `.large`: the panel is a 5.5 m
/// screen at 3.6 m, which is quake3e's geometry rather than vkQuake's.
///
/// The session category is NOT touched here (openq4_ios_audio.m owns it, and SDL
/// rewrites it behind us — IOS-AUDIO-SESSION-GUIDE); the intended spatial
/// experience is a separate property of the same session.
@_cdecl("OpenQ4_SetSpatialAudioFront")
func OpenQ4_SetSpatialAudioFront(_ front: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        if front {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .large, anchoringStrategy: .front))
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        NSLog("[openq4] xr3d: spatial audio -> \(front ? "front (the panel)" : "automatic (the window)")")
        OpenQ4_Vision3D_NoteSpatialAudio(front ? 1 : 0)
    } catch {
        NSLog("[openq4] xr3d: setIntendedSpatialExperience failed: \(error)")
        OpenQ4_Vision3D_NoteSpatialAudio(-1)
    }
}

/// The one piece of state the ObjC side pokes: whether the immersive space is
/// open. `OpenQ4Vision3D.m` owns the ordering; this only carries the answer into
/// SwiftUI, which is the only place the space can actually be opened.
final class OpenQ4AppModel: ObservableObject {
    static let shared = OpenQ4AppModel()
    @Published var immersive = false
    /// False until engine init completes. The ornament is hidden until then:
    /// on the first-run onboarding screen there is no engine to enter 3D with,
    /// and the settings sheet edits cvars of an engine that does not exist yet.
    @Published var engineRunning = false
}

@_cdecl("OpenQ4_SetEngineRunning")
func OpenQ4_SetEngineRunning(_ running: Bool) {
    DispatchQueue.main.async { OpenQ4AppModel.shared.engineRunning = running }
}

@_cdecl("OpenQ4_SetImmersiveMode")
func OpenQ4_SetImmersiveMode(_ on: Bool) {
    DispatchQueue.main.async { OpenQ4AppModel.shared.immersive = on }
}

/// CompositorServices layer configuration for the 3D panel.
///
/// Capabilities are QUERIED, never assumed: requesting a combination the device
/// does not support makes `openImmersiveSpace` fail with a generic `.error` and
/// nothing to debug from.
struct OpenQ4CompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        // ROUND 4 (D-105): eye-tracked foveation, the de-blur fix.
        //
        // The layout set MUST be queried with the options the layer will
        // actually be configured with. D-100 queried `options: []` and the
        // headset answered `.layered` only, which was read as "the device
        // refuses .dedicated"; the empty-options set simply is not the set that
        // exists once foveation is requested. `.foveationEnabled` is therefore
        // the query, and the answer decides the rate-map path the render loop
        // takes (OpenQ4Immersive.m handles BOTH — see its layered-pass note).
        //
        // D-106: the `vp3dFoveation` kill switch is GONE. It existed so the maintainer
        // could A/B the blur on hardware; he did, the verdict was "just leave
        // on", and the foveation guide's directive was always to ship it
        // unconditional once validated. Foveation is now simply asked for
        // whenever the device offers it — `isFoveationEnabled = supportsFoveation`
        // — and one fewer row can be left in the wrong state.
        let wantFoveation = true
        let fov = capabilities.supportsFoveation
        let layouts = capabilities.supportedLayouts(options: fov ? [.foveationEnabled] : [])
        configuration.isFoveationEnabled = fov
        // `.dedicated` whenever it is offered: a texture AND a rate map per
        // view, which is what the texture-map-driven loop targets, and the only
        // layout where a pass-per-eye rasterizes with its own map. With
        // `.layered` the drawable carries ONE multi-layer map and a pass per
        // slice would rasterize every eye with layer 0's — the right-eye
        // fisheye (guide trap 1). The loop answers that with a single layered
        // pass that writes `render_target_array_index`, so `.layered` is a
        // supported path here rather than a reason to drop foveation.
        configuration.layout = layouts.contains(.dedicated)
            ? .dedicated
            : (layouts.contains(.layered) ? .layered : .dedicated)
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        // Do NOT raise maxRenderQuality: it aborts the compositor at entry on
        // the simulator AND on device (vkQuake, hard-won).
        NSLog("[openq4] xr3d: compositor configured (dedicated=\(layouts.contains(.dedicated)) "
              + "layered=\(layouts.contains(.layered)) supportsFoveation=\(capabilities.supportsFoveation) "
              + "want=\(wantFoveation) foveation=\(fov))")
        // Same facts into the blackbox and into !xr3diag's caps= field: NSLog is
        // not retrievable from a headset over the tailnet bridge, and 0.1.0.58
        // reported layout=layered on device with no way to tell whether
        // .dedicated had been refused or never offered.
        OpenQ4_Vision3D_NoteLayoutCaps(layouts.contains(.dedicated) ? 1 : 0,
                                       layouts.contains(.layered) ? 1 : 0,
                                       layouts.contains(.shared) ? 1 : 0,
                                       capabilities.supportsFoveation ? 1 : 0,
                                       wantFoveation ? 1 : 0,
                                       fov ? 1 : 0)
    }
}

/// Hosts the UIKit/SDL engine bootstrap inside SwiftUI.
struct OpenQ4WindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> OpenQ4HostViewController {
        return OpenQ4HostViewController()
    }
    func updateUIViewController(_ vc: OpenQ4HostViewController, context: Context) {}
}

/// The window's root view. It owns the immersive open/close environment actions,
/// which are only valid inside a `View` — not in the `App` struct.
struct OpenQ4RootView: View {
    @ObservedObject private var model = OpenQ4AppModel.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        OpenQ4WindowView()
            .ignoresSafeArea()
            // openq4:// deep links (D-096). visionOS is SwiftUI-entry, so this is
            // the delivery point; iOS is SDL-entry and intercepts SDL's app
            // delegate instead. Both call the same C handler, and the command it
            // produces waits on a queue until the engine is past init.
            .onOpenURL { url in
                OpenQ4_iOS_HandleURL(url.absoluteString)
            }
            // A BOTTOM ornament, pushed fully below the window: contentAlignment
            // .top anchors the pill's top edge to the window's bottom edge, and
            // the padding gives it a clear gap. The default centre alignment
            // straddles the boundary and covers game content.
            //
            // D-106 — copied from the siblings rather than designed. vkQuake
            // (ios/shell-visionos/VKQVisionApp.swift:196-219) and quake3e
            // (ios/shell-visionos/Q3EVisionApp.swift:153-177) both carry ONE
            // ornament that is always present, in 2D and while immersive; the
            // mode button's own label flips to "Exit" while its mode is on, and
            // the gear is an icon-only `Image(systemName: "gearshape.fill")`
            // that never carries text. D-102 had invented a LABELLED "3D
            // Settings" button that appeared only in 3D, and the 2D window had
            // no gear at all — the maintainer's 0.1.0.61 verdict ("just the gear icon,
            // not with 3D Settings … look at what we did with other ports").
            //
            // "Exit", not vkQuake's-with-a-suffix "Exit 3D": the maintainer's word on
            // top of the siblings' shape, and it is also exactly what vkQuake's
            // 3D button says (:202).
            //
            // Hidden until the engine is up (OpenQ4_SetEngineRunning): the
            // 3D button used to be live on the onboarding screen.
            .ornament(visibility: model.engineRunning ? .visible : .hidden,
                      attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                HStack(spacing: 16) {
                    // Explicit LocalizedStringKey: a ternary of two literals
                    // type-checks as String, and Button(String) never localises
                    // (D-112).
                    Button(model.immersive ? LocalizedStringKey("Exit") : LocalizedStringKey("3D")) {
                        OpenQ4_Vision3D_Set(model.immersive ? 0 : 1)
                    }
                    // The gear is the ONLY way into the 3D settings while the
                    // space is open — the window under it is curtained and the
                    // in-game menu is display-only in 3D (charter Phase 6,
                    // Q-034) — and in 2D it is a second way into the same sheet
                    // the in-game chrome opens. The sheet is presented on the
                    // GAME window, which under .mixed immersion stays in the
                    // room in front of the panel.
                    //
                    // It opens at the TOP, in 2D and in 3D alike (D-109). It
                    // used to jump to the 3D section while immersive; the maintainer
                    // disliked the jump, and neither sibling does it — both
                    // gears just raise the sheet (vkQuake
                    // VKQVisionApp.swift:207-209, quake3e
                    // Q3EVisionApp.swift:165-167).
                    Button {
                        OpenQ4_iOS_ShowSettingsSection("")
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                }
                .font(.title3)
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassBackgroundEffect()
                .opacity(0.85)
                .padding(.top, 14)
            }
            .onChange(of: model.immersive) { _, on in
                NSLog("[openq4] xr3d: immersive onChange -> \(on)")
                Task {
                    if on {
                        let r = await openImmersiveSpace(id: "OpenQ43D")
                        NSLog("[openq4] xr3d: openImmersiveSpace -> \(String(describing: r))")
                        if case .opened = r, OpenQ4_Vision3D_IsOn() == 0 {
                            // The user left 3D while the open was in flight:
                            // the exit's own dismiss may have run before there
                            // was a space to dismiss, so this one is the only
                            // one that can close it. Finalize runs once per
                            // exit whichever caller gets there first.
                            NSLog("[openq4] xr3d: space opened after the exit — dismissing it")
                            await dismissImmersiveSpace()
                            OpenQ4_SetSpatialAudioFront(false)
                            OpenQ4_Vision3D_Finalize()
                        } else if case .opened = r {
                            // vkQuake VKQVisionApp.swift:256 — only once the
                            // space is really open.
                            OpenQ4_SetSpatialAudioFront(true)
                            OpenQ4_Vision3D_SpaceOpened()
                        } else {
                            // .error, .userCancelled, or anything a later SDK
                            // adds: no space exists, so take the failed-open
                            // path (review fold-in, D-107). Never leave the
                            // engine rendering offscreen, the curtain up and
                            // audio front-anchored with the window the only
                            // thing on screen. Vision3D_Set(0) runs the normal
                            // exit: curtain down, Metal view shown, audio back
                            // to automatic, r_stereo3d 0.
                            OpenQ4_Vision3D_Set(0)
                        }
                    } else {
                        await dismissImmersiveSpace()
                        NSLog("[openq4] xr3d: dismissed immersive space")
                        // vkQuake VKQVisionApp.swift:261.
                        OpenQ4_SetSpatialAudioFront(false)
                        // Under .mixed the 2D window never deactivates, so there
                        // is no lifecycle event to hang this on: this call is the
                        // authoritative back-to-2D trigger.
                        OpenQ4_Vision3D_Finalize()
                    }
                }
            }
    }
}

@main
struct OpenQ4VisionApp: App {
    init() {
        NSLog("[openq4] OpenQ4VisionApp.init — Swift entry running (SwiftUI @main, D-089)")
    }

    var body: some Scene {
        WindowGroup {
            OpenQ4RootView()
        }
        ImmersiveSpace(id: "OpenQ43D") {
            CompositorLayer(configuration: OpenQ4CompositorConfiguration()) { layerRenderer in
                // This closure runs on the MAIN thread. The frame loop must not:
                // blocking main here would block the engine's display link, i.e.
                // freeze the whole app.
                NSLog("[openq4] xr3d: CompositorLayer ready — spawning the render thread")
                let renderThread = Thread { OpenQ4_Immersive_Run(layerRenderer) }
                renderThread.name = "OpenQ4-Immersive"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        // Mixed = the panel floats in the real room over passthrough. NOTE:
        // merely ALLOWING .progressive changes the drawable contract (portal
        // rendering) and cp_drawable_encode_present then aborts
        // __BUG_IN_CLIENT__ — Crown dimming needs real portal support first.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

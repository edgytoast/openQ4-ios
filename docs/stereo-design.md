# Phase 6 — 3D stereo mode on Vision Pro: design (round 1, no code)

**Date:** 2026-09-17 · **Decision records:** D-098 (design), D-100 (round 2),
**D-101 (round 3 — corrections below are marked)** · **Inputs:** vkQuake D-026/
D-030/D-039 + `ios/shell-visionos/VKQImmersive.m`, quake3e D-019/D-022/D-023/
D-027/D-028, `~/dev/VISIONOS-FOVEATION-GUIDE.md`, `~/dev/q2repro-ios/
SETTINGS-SPEC-FROM-VKQUAKE.md`, our D-089–D-092 and D-097, upstream at pin
227ee810 with overlay 0001–0026 applied.

## 0. The shape in one paragraph

The engine never sees CompositorServices. In 3D it renders the **complete
composite** (scene + HUD + menus + console) **twice per host frame**, left then
right, at the same game time, into two offscreen per-eye **present images**
instead of the window swapchain. A native-Metal **compositor thread** in the
visionOS shell copies both images (mip-mapped) on its own queue and draws one
**world-locked screen quad** per `cp_view` into the `cp_drawable`, using
`cp_drawable_compute_projection` and the view's rasterization-rate map. The
head pose places the panel, never the camera. This is vkQuake's proven stack
(D-026 → D-030 → D-039) on a MoltenVK VkImage that *is* a MTLTexture; the only
engine-side novelty is that openQ4's front end has real view/projection
matrices, so the eye enters honestly, not through a folded camera basis.

Rejected alternative: importing the `cp_drawable` colour/depth textures into
Vulkan and rendering the scene with the headset's own per-view projection. That
is a head-driven camera (charter: never), forces the engine onto the `cp_frame`
cadence and off the main thread (SDL's Darwin event pump asserts main), and
re-imports VkImages per frame. Nothing about it is cheaper than the panel.

## 1. Where the eye enters (front end, engine-side, game module untouched)

The game module (`openQ4-game/src/mpgame/PlayerView.cpp:628`) calls
`gameRenderWorld->RenderScene( view, … )` once per `game->Draw`. It is a
separate dylib and stays unmodified; the eye lives entirely in the engine.

- **Per-frame doubling — `idSessionLocal::UpdateScreen`** (`framework/
  Session.cpp:6558`): today `BeginFrame → Draw() → EndFrame`. In 3D:
  `for eye in {L, R}: tr.stereoEye = eye; BeginFrame; Draw(); EndFrame`. The
  game does not tick between the two (`Frame()` ran before), so both eyes carry
  the same game time; `Draw()` is a pure re-emission (guis redraw against
  `presentationTime`). Watch items for round 3: `tr.deltaTime` (computed from
  `lastRenderTimeMsec` in `RenderScene`, ~0 on the second eye — find its
  consumers), `frameCount` advancing twice per host frame (metrics only), and
  any game-side effect that `Draw` spawns per call (Doom 3 lineage says none).
  The 2D-only paths (`insideExecuteMapChange`, load screens) are rendered once,
  mono, and the compositor shows the live image in both eyes.
- **View matrix — `R_SetViewMatrix`** (`renderer/tr_main.cpp:823`): after
  `myGlMultMatrix( viewerMatrix, s_flipMatrix, world->modelViewMatrix )`, apply
  the eye as a **post-translation along view-space X**:
  `modelViewMatrix[12] -= e`, with `e = (eye == R ? +1 : -1) · sep/2`. Columns
  0–2 are untouched; `renderView.vieworg/viewaxis` are untouched, so
  `R_SetupViewFrustum`, portal visibility and light culling keep the centre
  camera. The offset (default 2.5 units ≈ IPD at Quake scale) is far below
  portal tolerances.
- **Projection — `R_SetupProjection`** (`tr_main.cpp:880`): the off-axis skew
  `projectionMatrix[8] = -projectionMatrix[0] · e / conv` (zero parallax at
  `conv` game units, i.e. objects at `conv` sit exactly on the panel). The
  function already carries an asymmetric-frustum mechanism
  (`tr_levelshotProjectionShiftX/Y`, lines 914 and the three siblings at 966,
  993, 1044). **Round 3 correction (D-101): the stereo skew goes in exactly ONE
  of those places, `R_SetupProjection`.** The other sites are
  `R_GetViewFrustumExtents` and `R_SetupViewFrustum`, i.e. the CULL frustum,
  which the very next sentence says must keep the centre camera — applying the
  skew there would have contradicted it. Known approximation, accepted as in
  vkQuake: the cull frustum is the symmetric centre one; the skew is
  `e/conv` ≈ 0.5 % of width at defaults, so at worst a sliver at one edge.
- **Subviews** (`tr_subview.cpp`: mirrors, remote cameras, portal sky with
  `RF_PORTAL_SKY`) inherit the current eye because they run through the same
  two functions; the sky is at infinity so its offset is invisible. GUI 3D
  surfaces on in-world panels are subviews too — correct by construction.
- **2D views** (`guiModel->EmitFullScreen`, `GuiModel.cpp:329`: a `viewDef`
  with `viewEntitys == NULL`, drawn by `VK_GuiExecutor_Draw2DView`) get no
  offset: HUD, crosshair, menus and console render at **zero parallax = the
  panel plane**, which is exactly the quake3e "HUD at panel depth" rule, for
  free.
- **Weapon depth hack — `VK_BuildSurfMVP`** (`renderer/Vulkan/
  vk_GuiExecutor.cpp:4197`) is the single MVP home in the VK backend; it
  squashes depth with `proj[14] *= 0.25` for `space->weaponDepthHack`. quake3e
  D-028 (v1 rejected on device, v2 shipped) says the weapon's stereo must be
  re-derived, not shifted: for weapon surfaces the skew is recomputed with the
  weapon's own convergence (`convWeapon`, default `r_znear`-class = weapon on
  the panel; slider blends toward `conv` for pop-out). Interaction passes in
  `vk_Interactions.cpp` (`wantWeaponRange` at 1443/1620/2433/2601) must be
  checked in round 3 to confirm they take their MVP from the same function.
- **State + cvars.** **Shipped names (D-101), which differ from this
  paragraph's first draft:** `tr_stereoEye` / `tr_stereoEyeOffset` (0/1/2,
  latched in `UpdateScreen`, never mid-frame) and `R_Stereo_SetEye` /
  `R_Stereo_Enabled` in overlay patch **0027** (`renderer/tr_main.cpp`);
  `r_stereo3d` (0/1, shell-driven), `r_stereo3dSeparation` (units, 2.5),
  `r_stereo3dConvergence` (units, 240 ≈ 20 ft — the spec's "Crosshair
  Distance"), `r_stereo3dGunDepth` (−1…+1, 0 = on the panel),
  `r_stereo3dGunConvergence` (units, 24), `r_stereo3dWidth`/`Height`
  (per-eye render extent, 1920×1080) and the debug `r_stereo3dLateRetire`, all
  in patch 0019. One `r_stereo3d*` family, so `grep` finds the whole feature.
  All `CVAR_RENDERER`, none archived (the shell persists the settings and
  re-applies on entry; renderer cvars do not stick from the sim's pre-boot
  config anyway — STATUS open question).
  The doubling in `UpdateScreen` rides in patch **0009**, which already owns
  `Session.cpp`; the pairs, the eye extent and the weapon skew ride in **0019**,
  which already owns `vk_GuiExecutor.cpp` and `vk_Backend.cpp`. A file belongs
  to exactly one patch.

## 2. What replaces the SDL swapchain (VK backend)

Nothing is imported; the swapchain is **bypassed**. The window's SDL/Metal
layer stays alive and its swapchain untouched, so exit needs no recreate.

- **Acquire seam — `VK_GuiExecutor_BeginFrame`** (`vk_GuiExecutor.cpp:2390`):
  in 3D, skip `vkAcquireNextImageKHR`; point `vkExec.activeColorEntry` /
  `activeExtent` / `activePipelineTarget` at the eye's present image (created
  `vkCtx.swapchainFormat` = `B8G8R8A8_UNORM`, usage `COLOR_ATTACHMENT |
  SAMPLED | TRANSFER_SRC`, own depth image at the same extent — the per-slot
  `vkCtx.depthImages` are swapchain-sized and cannot be reused once the eye
  extent decouples). `acquireWaitPending = false`. Everything downstream
  (`VK_Exec_BeginMainRendering`, the 2D/3D draw walks, D-094's resolve
  scratch, SMAA's `_forwardRenderAlbedo` route) reads the active target and is
  unchanged.
- **Present seam — `VK_GuiExecutor_SubmitFrame( present )`** (`:3696`): the
  `present=false` path already exists (screenshot resume). 3D submits with
  `present=false`, transitions the eye image to `SHADER_READ_ONLY` (the
  existing `VK_Exec_TransitionActiveTargetToSampled`), and bumps a per-eye
  completed-render counter. `GLimp_SwapBuffers` under `RC_SWAP_BUFFERS`
  (`vk_Backend.cpp:472`) is what calls this; it becomes a no-op present.
  The per-slot fence (`VK_FRAMES_IN_FLIGHT = 2`, `VulkanDevice.h:33`) still
  bounds the producer at two frames in flight — the foveation guide's trap 3
  (unbounded producer) is structurally closed.
- **Extent** = the 3D render size, owned by the 3D settings, not by the
  window (vkQuake D-033). Patches 0019/0021's live-extent and recreate
  accounting are swapchain-only and keep working for 2D; in 3D the swapchain
  extent is simply not consulted (`glConfig.vidWidth/Height` follow the eye
  extent while `r_stereo3d` is on — `vk_Backend.cpp:103/265` are the two
  writers). Changing the 3D size = destroy + recreate the two eye images and
  depth under `vkDeviceWaitIdle`, with the shell's per-eye accessor returning
  NULL until each eye has been rendered again (vkQuake D-032's undefined-image
  gate). D-065's "one owner for the drawable size" is untouched: the layer's
  size is irrelevant while the swapchain is bypassed.
- **Handing the image to Metal:** `vkGetMTLTextureMVK` — exported `T` from
  the vendored `xros-arm64` and `ios-arm64` MoltenVK slices (checked with
  `nm`). Called as a direct extern from the shell (quake3e's lesson: it is not
  resolvable through `vkGetInstanceProcAddr`, so not through volk); compiled
  only in the visionOS lanes. `vkExportMetalObjectsEXT` is also exported and is
  the non-deprecated route if MoltenVK drops the MVK call at a future pin bump;
  the accessor is one function, so the swap is local. Zero copy on the engine
  side; the compositor thread copies into its own mip-mapped per-eye textures
  on its own queue (vkQuake D-030), which is what makes the second eye unable
  to overwrite the first before it is sampled.
- **Colour:** present images are UNORM holding display-ready values; the
  drawable is `bgra8Unorm_srgb` (whatever `capabilities.supportedColorFormats`
  vends first). The quad shader linearises (`srgbDecode`) — vkQuake's
  washed-out-panel fix. "Gamma in panel" (quake3e): whatever brightness the
  engine bakes into the frame is what the panel shows; round 2 verifies that
  openQ4's brightness path under Vulkan is a shader op, not a hardware ramp
  request that the panel would silently drop.
- **NULL drawable / withheld frame:** the compositor thread abandons the
  frame — no `cp_frame_end_submission`, no engine involvement (vkQuake R4.1:
  ending an invalidated frame is `__BUG_IN_CLIENT__`). The engine keeps
  rendering; the next drawable samples the newest pair.

## 3. Frame model and threads

- **Engine stays on the main thread**, driven by the port's own CADisplayLink
  (`OpenQ4_iOS_StartFrameLoop`, `ios/shell/openq4_ios_bridge.m:1441`; tick body
  in overlay patch 0002). SDL's Darwin event pump asserts main; D-092 recorded
  that the visionOS engine runs inside serial main-queue blocks. Both eyes
  render inside one tick.
- **Compositor thread** (`OpenQ4Immersive.m`, spawned from the
  `CompositorLayer` closure in `OpenQ4VisionApp.swift`): `query_next_frame →
  predict_timing → start/end_update → cp_time_wait_until(optimal input time)
  → start_submission → query_drawable → device anchor at presentation time →
  copy both eye images → one pass per view → encode_present → commit →
  end_submission`. It never blocks the engine and the engine never waits for
  it. The compositor shows the newest **complete pair** (pair counter advances
  after the right eye's submit), so a slow engine shows a repeated pair, not a
  torn one.
- **Rate is a measurement, not an assumption.** D-097 established that a
  *window* is granted 120/60 Hz on frame cost; whether the parked window's
  display link keeps ticking at full rate while an ImmersiveSpace is open, and
  what `cp_frame` paces at (nominally 90), are round-2's first two numbers.
  `OpenQ4_iOS_MaxFramesPerSecond()` (compat header, hardcoded 90 on visionOS)
  is left alone until then.
- **Enter/exit sequencing** (vkQuake D-029/D-031/D-033 for the shape, D-101 for
  the ordering): enter = `r_stereo3d 1` + eye images at the 3D size → wait for
  the engine to confirm the bypass → curtain → **park the window to a 480 pt
  card at the panel's aspect FIRST** → let the resize settle → open the space.
  Exit is the mirror: stop the compositor thread → `dismissImmersiveSpace` →
  restore the window → let its animation finish → `r_stereo3d 0` → curtain down.
  **Park BEFORE the space opens, never after.** The siblings both park ~1.5 s
  after; do not copy that. A window geometry change is a scene reconfiguration
  and a live `CompositorLayer` does not survive one — two runs in five silently
  fell back to 2D about ten seconds in, `withheld=1 invalidated=1`. Parking
  first is free, because the engine is already rendering into the offscreen
  pair and the eye extent is decoupled from the window, so the resize touches
  only a swapchain nothing reads.
  **Round 3b (D-102) changed the card's CONTENT, not its size.** It briefly
  removed the park entirely, reading the maintainer's "a black window that says playing
  in 3d like the other ports do" as "do not shrink it"; that is not what the
  other ports do, and a full-size window covers the panel's centre — including
  the crosshair — which is the complaint the park exists to fix. The card
  carries the siblings' exact string `Playing in 3D` and nothing else; the
  round-3 "drag this card out of the way" lines crowded it off a 480 pt surface
  and that advice now belongs to the Screen Position Height row, which is the
  control that acts on it. Exit 3D and 3D Settings are labelled, bordered
  buttons on the ornament.
  Restoring the window on exit grows the swapchain while 3D still owns
  `glConfig`, so the extents already agree by the time ownership is released:
  putting `glConfig` back is entirely down to the one-shot reconcile armed on
  that release (§below, D-102 defect 2). That is the letterbox, and the exit
  path is the only thing that exercises it.
  Spatial audio `.headTracked(.front)` is **not yet wired** — deferred with
  round 4's device pass, since the panel's position is the user's and the
  verdict is audible, not visible.
  Crown/system dismissal reconciles through the layer-invalidated path.
- **The 2D layer is laid out for whatever the composite's target is.** D-101
  decoupled `glConfig.vidWidth/Height` from the window; D-102 finished the job,
  because `glConfig.uiViewport*` / `engineWindowState.uiViewport*` — the
  rectangle `idGuiModel::EmitFullScreen` derives the whole fullscreen 2D
  viewport from — were still the WINDOW's safe area in the WINDOW's pixels.
  Applied to a 1920x1080 panel that put the entire HUD, crosshair, menu and
  console layer in a sub-rect of the panel. In 3D the UI viewport is the whole
  frame, in both copies, restored on exit.

## 4. Budget and the render-scale knob

D-097: one eye-equivalent at 2560×1440, MSAA 0, costs 5.3 ms; the 120 Hz grant
needs ≲6 ms and 60 Hz arrives at ≳8 ms — so **two eyes at that size start at
~10.6 ms**, over every budget that matters. The **3D render size is the knob**
and it is per eye, decoupled from the window: a new visionOS-only settings row
"Panel Resolution" (persisted as `vp3dRenderPercent`, applied through the eye
image extent, *not* the 2D knob's layer-drawable path), starting at
**1920×1080 per eye** (≈3.0 ms by area) and tuned by round-4 measurement
against the granted rate. Aspect follows the panel's width:height on slider
release (D-032). The 2D "Render Resolution" setting stays 2D-only.

## 5. FPS stereo fixes carried, and who owns them

| Fix | Owner | Where |
|---|---|---|
| Both eyes per host frame, same game time | engine | `UpdateScreen` loop, patch 0009 |
| HUD/menus/crosshair at panel depth | engine (free) | 2D views have no eye offset |
| Convergence ("Crosshair Distance") | engine | `r_stereo3dConvergence` in `R_SetupProjection` |
| Weapon disparity re-derived, "Gun depth" | engine | `VK_BuildSurfMVP`: eye offset scaled by `r_stereo3dGunDepth` AND the skew recomputed against `r_stereo3dGunConvergence` — two numbers, because one cannot say both "how much" and "where" (D-101) |
| Panel alpha forced to 1, real depth written | compositor | quad fragment `float4(rgb, 1)`, depth write on |
| sRGB decode, mipmapped + 16× aniso sampling | compositor | quad pipeline |
| Surroundings dimming (`1-(1-d)^2.2`) | compositor | fullscreen layer under the panel |
| Spatial audio at the panel | shell | `setIntendedSpatialExperience` on enter/exit |
| Parked 2D card + curtain, ornament "3D"/"Exit" + gear | shell | `OpenQ4HostViewController.m`, `OpenQ4VisionApp.swift` |
| FPS on panel = engine counter, 3D-only | engine + shell | `r_showFPS`-class cvar gated on `r_stereo3d` |

## 6. Foveation

**Landed round 4, D-105.** Compositor-pass only, per the guide and D-039 (the
"foveation off" line was a MoltenVK-era myth that a native Metal panel pass
never had). The engine's Vulkan side needs nothing: MoltenVK exposes no
`VK_EXT_fragment_density_map`, the eyes render uniform density into the present
pair, and the foveation acts where the blur was — in the panel hop.

- **The layout set is queried WITH the options the layer will use**:
  `capabilities.supportedLayouts(options: [.foveationEnabled])`. D-100 queried
  empty options, got `.layered` on hardware and read it as a refusal of
  `.dedicated`; the empty-options set is not the set that exists under
  foveation.
- **`.dedicated` when offered**: per-view pass, per-view rate map from
  `cp_drawable_get_rasterization_rate_map(drawable, texIdx)`, targeting from
  `cp_view_get_view_texture_map`, `[enc setViewport:vp]` before every draw.
- **`.layered` otherwise, and it is a supported path, not a reason to drop
  foveation**: ONE pass over the array texture with
  `renderTargetArrayLength = views`, each draw naming its layer through
  `render_target_array_index`, so each eye rasterizes with its own layer of the
  single multi-layer map. A pass per slice would use layer 0's for both — the
  right-eye fisheye (guide trap 1). Those pipelines MUST set
  `inputPrimitiveTopology = .triangle` or Metal refuses them.
- The loop picks the path from the DRAWABLE (do the views share a texture
  index?), not from what was requested — the two have disagreed on this
  hardware before.
- **Never touch `maxRenderQuality`** (aborts at entry, sim and device).
- Kill switch `vp3dFoveation` (persisted, default on, a **Foveation** row in
  the 3D section), read at layer-config time so it applies at the next entry
  into 3D. Removed once validated on hardware (quake3e D-028 directive: always
  on where supported).
- **Fidelity log** `Documents/oq4-3d-fidelity.log` — vkQuake's supersample
  report plus the granted rate map's screen/physical sizes. It says whether the
  sharpening knob is the toggle or Panel Resolution: below 1.0x the engine's
  per-eye image is the limit and foveation cannot invent detail it never drew.
  The simulator reads 0.60x at 1920x1080 against its 3840x2160 drawable; the
  headset's drawable is 2048x1984 at a wider FOV, i.e. about half the pixels
  per degree, so the device log is the number that decides whether
  `r_stereo3dWidth/Height` defaults rise (D-097's ~6 ms budget applies; no
  default was changed on the simulator's number).
- `!xr3diag` gained `fovWhy=on|off|unsupported|refused|unknown`,
  `fovLayout=dedicated|layered|none` and `rmap=<screenW>x<screenH>/
  <physW>x<physH>`; `fov=` and `rmaps=` are now real.
- The simulator reports `supportsFoveation == false`, so the sim only proves
  the guarded path enters/exits cleanly, the toggle round-trips into the layer
  config, the layered pipelines build and the log is written; the de-blur
  verdict is the maintainer's.

## 7. Menus, settings, telemetry, verification

- **Menus in 3D are display-only** (charter). They render onto the panel and
  the pad drives them (visionOS converts nothing while `GCEventInteraction`
  claims the pad, D-090); there is no touch/pinch overlay on the panel. "Exit"
  to 2D for anything that needs a tap. The 3D settings live in a **SwiftUI
  sheet over the space** hosting the UIKit table (the D-092 `OpenQ4SubPageVC`
  header already gives it Back/Done), opened by the ornament gear or
  `!settings`. The **ornament** (D-106) is the siblings' one bar, present in
  2D and in 3D alike: a mode button reading `3D` out of the space and `Exit`
  inside it, and an **icon-only** `gearshape.fill`, borderless, `.title3`,
  over `glassBackgroundEffect()`.
- **Settings rows (visionOS-only section, spec order) — D-106 is current:**
  Screen Distance 1.0-8.0 m (3.6), Screen Width 1.2-8.0 m (5.5), Screen Height
  1.0-6.0 m (3.1), Screen Position Height -1.5...+10 m (0), **Stereo Depth
  0-300 % (default 125 %**, 100 % = 2.5 u), Crosshair Distance 32-512 u (240),
  **Panel Resolution 1920x1080 ... 2880x1620 per eye, default 2560x1440 with
  1920x1080 the hard floor** (the floor is in `r_stereo3dWidth/Height`'s own
  cvar range, not only in the row's list), Surroundings Dimming 0-100 % (80),
  FPS on Panel, Units m|ft (ft, a segmented control), Recenter Screen.
  **No row has description text under it** — the siblings have none anywhere,
  and a row is named so that it needs none.
  **Reset is not a row**: it is a tinted pill on the section's own header,
  which a plain-style table pins at the top of the viewport while you scroll
  inside the 3D section and swaps out on the way past.
  **Gun Depth and Foveation are no longer rows at all.** Gun depth is
  hardcoded at +0.39 in `r_stereo3dGunDepth`'s default and the sheet does not
  push it; foveation is asked for whenever the device supports it. Both are
  the maintainer's 0.1.0.61 hardware verdicts (Q-032, Q-037).
  A **settings schema stamp** (`openq4.settingsSchema`, currently 2) clears the
  stored `vp3d*` keys once per install, because a changed DEFAULT never moves
  an install that already has a stored value.
  All live while dragging; lengths stored in metres; strings through
  `OpenQ4_L()` (D-088).
- **Bridge commands:** `!xr3d 0|1` (enter/exit), `!xr3dtune <sep> <conv>
  [dist halfW halfH height dim]`, and **`!xr3diag`**, one line: `imm=<on>
  frames=<n> withheld=<n> invalidated=<n> anchor=<ok|pending> views=<n>
  layout=<dedicated|layered> fov=<0|1> rmaps=<n> drawable=<w>x<h>
  eye=<w>x<h> pairs=<n> eyeL=<n> eyeR=<n> consumed=<n> engineTick=<p50/p95 ms>
  compTick=<p50/p95 ms> gpuEye=<ms> link=<hz> dim=<f> sep=<f> conv=<f>
  engineFrames=<n> bypass=<0|1> notReady=<n> stalls=<n> overruns=<n>
  halfPairs=<n> gui=<w>x<h>@<x>,<y>`.
  `!settings <Section>#<key>` (D-105) scrolls that ROW to the top of the
  sheet — a section is not fine-grained enough to photograph the 3D section's
  lower rows on a simulator nobody can scroll.
  `!xrwin <w> <h>` (D-102) requests a 2D window size in points — a TEST LEVER,
  not a feature: the lane simulator's persisted window is already the park's
  480 pt card, so the park resizes nothing there and the exit path's real
  swapchain-extent change is unreachable without growing the window first.
  `gui=` (D-102) is the 2D composite's own extent, which is a DIFFERENT
  rectangle from `eye=` whenever the UI viewport is still the window's: in 3D
  it must read the full eye size at 0,0, and defect 1 — the HUD at mid-height
  on the left of the panel with no crosshair — is exactly what it looks like
  when it does not.
  The last three are the D-100-addendum sync gate made observable: `notReady`
  counts submits held back a frame because their fence had not signalled,
  `stalls` engine frames that waited for the compositor to release an image,
  and `overruns` must stay 0.
  `!framelink`, `r_vkSpeeds` and the heartbeat keep reporting underneath.
- **Verification per round:** ~~the visionOS simulator cannot screenshot
  immersive content (the layer parks in `paused`, no drawable is vended)~~ and
  reports mono (`views=1`, `.dedicated`).
  **Round 2 corrected the struck-through half (D-100): the simulator DOES run
  the compositor, vend drawables and capture immersive content** —
  `artifacts/sim/visionos-3d-r2/02-3d-on-curtain.png` is the live game on the
  world-locked panel. What it does not do is report two views, so stereo
  disparity still needs the headset. The sim is a real visual gate from round 3
  on, not merely a liveness check. Each round's sim gate is: builds
  green on `visionos` and `visionos-sim`; `!xr3d 1/0/1/0` with the app alive,
  `pairs` advancing, no `crashes/*.log`, no compositor abort; a screenshot of
  the curtained window and the live panel as the visible artifact;
  **and, from D-102 on, a screenshot that actually shows the 2D layer on the
  panel** — a map where the player is armed, so the HUD and the crosshair are
  drawn. `game/mcc_1` past the continue prompt is still the gate's map, but its
  opening sequence hides both, which is why round 3 could not have caught
  defect 1 from its own artifacts; `map game/tram1` + `give all` shows them in
  about twenty seconds; `!xr3diag` transcripts
  under `artifacts/sim/visionos-3d-<round>/`. The visual verdict per round is
  **device via OTA** (`--visionos`), read back over the console bridge
  (port 8774 on the headset's private-network address) while the maintainer is in-game (Q-027 precedent), with the
  fidelity log (`Documents/vp3d-fidelity.log`, vkQuake's supersample report)
  as the number beside his verdict.

## 8. Round plan

| Round | Builds | Done when | Artifacts |
|---|---|---|---|
| **2 — space + mono panel** | `ImmersiveSpace` + `CompositorLayer` config + `OpenQ4Immersive.m` thread; patch 0027 part 1: `r_stereo3d`, one present image, no-acquire/no-present submit, `vkGetMTLTextureMVK` accessor; enter/exit/Crown paths; park/curtain; `!xr3d`, `!xr3diag` | sim: enter/exit/re-enter clean, `frames` and `pairs` advancing, 2D returns live after exit; device: the maintainer sees the live game on a world-locked panel over passthrough, and the two rates (engine tick, `cp_frame`) are recorded | sim transcripts + curtain PNG; MEASUREMENTS row "3D mono: rates" |
| **3 — both eyes** ✅ **done, D-101** | patches 0009 + 0019 + new 0027: `UpdateScreen` double render, eye matrices, weapon skew, present PAIRS published atomically, per-eye render extent decoupled from the window; compositor samples per eye; settings sheet + all rows; dimming; the park; `!xr3dtune` | sim: `eyeL`/`eyeR` equal to the frame, `engineFrames == 2 × pairs`, 99.9 % published, `stalls`/`overruns`/`superseded` 0, no layer invalidation over two cycles — **all met**; device: depth reads correctly (crosshair on panel, weapon not doubled), "buttery" per D-030 — **the maintainer's, still open** | `artifacts/sim/visionos-3d-r3/`; MEASUREMENTS "3D both eyes: GPU per eye vs size" (CPU only — the simulator's GPU timestamps are inert); the maintainer's comfort verdict + chosen defaults |
| **4 — foveation + fidelity** ✅ **done, D-105** | `.dedicated` + rate map + texture-map targeting + viewport; fidelity log; Panel Resolution sweep vs granted rate; kill switch removed after verdict | device: de-blur verdict, both eyes stable under head motion, no periphery warp; a size/rate table with a recommended default | fidelity log; MEASUREMENTS table; D-0xx closing the knob default |

Round 2 is the only one with a compile-time decision (`OPENQ4_VISIONOS_3D`
build define on the visionOS lanes; the iOS target stays byte-for-byte
untouched, charter Phase 5). Each round is an implementation pass with a
diff review; the milestone acceptance is the maintainer in the headset from this doc's
§7 checklist alone.

## 9. Open questions for the maintainer (each with the default that will be taken)

- **Q-031 Panel/stereo defaults.** Default: vkQuake's shipped values above
  (3.6 m / 5.5 × 3.1 m / depth 100 % / crosshair 240 u / dim 80 %) until he
  tunes them in round 3.
- **Q-032 Gun depth.** Default: weapon converged on the panel (quake3e's
  upstream-default plane), slider available; he picks after round 3.
- **Q-033 Per-eye resolution.** Default: 1920×1080 per eye until round 4's
  table exists; then whichever size holds the higher granted rate.
- **Q-034 Menus in 3D.** Default: display-only + pad, exit to 2D for touch
  (charter). If he wants pinch-driven menus on the panel, that is a later
  round (gaze→panel-UV mapping through the existing `!touchtap` handler).
- **Q-035 Does the parked window's display link keep full rate while the space
  is open?** Not his to answer — measured in round 2; recorded here because the
  fallback (a link not tied to the window scene) changes the shell.

# overlay/patches-sdl — local changes to vendored SDL3

`vendor/SDL` is a pristine `release-3.4.10` checkout and stays one (charter
ground rule 1). Anything this port needs changed in SDL lives here as a
reviewable patch, applied by `scripts/build-ios-deps.sh` into a checksum-synced
copy under `build/sdl-src-<set>` with `patch --fuzz=0`, failing loudly. The set
is chosen per build lane by `SDL_PATCHES` in that script's lane table; the
concatenated patch text is stamped beside the built prefix, so editing a patch
rebuilds SDL instead of silently re-using yesterday's archive.

## Why this directory exists (D-089)

It did not, until the visionOS lanes needed an SDL change. `vendor/SDL` was
cloned from `~/dev/vkQuake-ios/vendor/SDL`, which vkQuake patches **in place** —
so our "pristine" checkout arrived with two of vkQuake's SDL patches already
applied to the working tree and recorded nowhere. Every iOS build this port has
shipped was built from that tree. This round restored `vendor/SDL` with
`git checkout --`, captured the exact working-tree diff as the two patches
below, and verified the reconstructed `build/sdl-src-apple` is identical to a
snapshot of the old dirty tree. The iOS SDL sources are byte-identical before
and after; the difference is that they are now visible and reviewable.

## Set `apple` — all four lanes (`device`, `sim`, `visionos`, `visionos-sim`)

### 0001-ios-softkeyboard-backspace.patch

`SDL_uikitviewcontroller.m`: drop the `!SDL_HasKeyboard()` condition guarding
synthesized backspace key events, so deletions from the on-screen keyboard reach
the app on a device that also reports a hardware keyboard.

### 0002-swiftui-scene-delegate-coexist.patch

Mandatory for the SwiftUI-entry visionOS app, harmless on iOS (which is why it
has been in the iOS build all along without anyone noticing).

Under a SwiftUI `@main` the engine never calls `SDL_RunApp`, so SDL's
`forward_main` function pointer stays NULL — but UIKit can still resolve
`SDLUIKitSceneDelegate` **by name** as the scene delegate of a persisted scene
session and call `postFinishLaunch`, which jumps through that NULL pointer
(PC=0, instant SIGKILL at launch, no usable crash report). The patch renames the
class to `SDLUIKitSceneShim` so it cannot be resolved by the old name, keeps its
protocol conformances, and NULL-guards both `postFinishLaunch` implementations.

Adopted from `~/dev/vkQuake-ios/patches/sdl/` (vkQuake D-028).

### 0003-visionos-window-geometry-from-the-scene.patch

**visionOS only** (every hunk is inside `#ifdef SDL_PLATFORM_VISIONOS`), applied
on all four lanes because the set is; the iOS SDL sources are byte-identical
before and after. D-091.

SDL3's visionOS backend reports ONE fake display of the compile-time constants
`SDL_XR_SCREENWIDTH x SDL_XR_SCREENHEIGHT` (1280x720) at a hardcoded scale of
2.0, and `UIKit_ComputeViewFrame` places the SDL view at
`CGRectMake(window->x, window->y, window->w, window->h)` — SDL window
coordinates taken against that fiction. In a real 1920x1200 pt volume that
produced two visible bugs: the Metal view landed at `(-320,-240)`, and the
engine's UI viewport — which intersects the SDL window rect with the SDL
DISPLAY bounds — was clipped to the 1280x720 overlap, i.e. the top-left two
thirds of the drawable, which is exactly what D-090 photographed.

The patch makes every one of those numbers come from the live `UIWindowScene`:

- New `UIKit_GetVisionSceneGeometry(window, &size, &scale)` — the scene from
  the window's `UIWindow`, else `UIKit_GetActiveWindowScene()`;
  `effectiveGeometry.coordinateSpace.bounds` (falling back to
  `coordinateSpace.bounds`), and `traitCollection.displayScale`. It returns
  false when no scene is connected yet, which is the only case where the
  `SDL_XR_SCREEN*` constants are still used.
- `UIKit_ComputeViewFrame` returns `(0,0 sceneW x sceneH)`.
- `UIKit_AddDisplay` sizes the fake display from the scene and sets
  `pixel_density` to its displayScale; `UIKit_GetDisplayUsableBounds` follows.
- `UIKit_Metal_CreateView` and `UIKit_GetWindowSizeInPixels` take the scale
  from the scene instead of the constant 2.0.
- New `UIKit_UpdateVisionDisplayGeometry()`, called from
  `-viewDidLayoutSubviews`, re-reads the scene into the display after a resize
  and pins the window origin to 0,0; that path then sends
  `SDL_EVENT_WINDOW_RESIZED` as before plus an explicit
  `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED`, so a displayScale-only change reaches
  the app too.

**Not an upstreaming candidate, unlike the other two.** SDL's own
contribution policy (in `vendor/SDL`) forbids AI-generated code in
contributions to SDL. The fix is real
and upstream's `// TODO: Consider making this configurable or determining it
dynamically` invites it, but a human has to write the patch that goes there.

### 0004-mfi-rumble-restarts-a-stopped-haptics-engine.patch

`SDL_mfijoystick.m`, iOS and visionOS. D-111.

SDL drives controller rumble through one `CHHapticEngine` per motor, made from
`GCController.haptics`. The system STOPS those engines whenever the app is
suspended (and on an audio-session interruption); SDL's `stoppedHandler` sets
the engine to nil, and nothing ever made a new one — every later
`SDL_RumbleGamepad` failed with "Haptics engine was stopped" until the pad was
re-paired. So rumble died after the first trip to the home screen. The motor
now remembers its controller (weakly) and locality, and rebuilds and restarts
its engine on the next non-zero intensity; a stop request on a stopped motor
succeeds. A rebuild that fails still returns an error, which the engine's
`rumbleStatus` reports.

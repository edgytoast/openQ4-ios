/*
 * OpenQ4Vision3D.h — shell orchestration for the visionOS 3D panel mode.
 * Phase 6 round 2, D-100.
 *
 * The compositor loop lives in OpenQ4Immersive.m; this is everything around it:
 * entering and leaving the mode in the right order, the curtain over the parked
 * 2D window, the engine-tick sampler behind Q-035, and the one-line `!xr3diag`
 * report (docs/stereo-design.md §7).
 */

#ifndef OPENQ4_VISION3D_H
#define OPENQ4_VISION3D_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// `!xr3d 0|1`, the ornament button, and a Crown dismissal all land here.
// Callable from any thread; the work is marshalled to the main queue.
void OpenQ4_Vision3D_Set(int on);
int	 OpenQ4_Vision3D_IsOn(void);

// D-114. Engine thread, before a game-module swap / engine reload: returns 1
// while 3D is on or still leaving (and starts the exit the first time), 0 once
// the renderer can be torn down safely. Common.cpp re-asks every frame.
int  OpenQ4_Vision3D_HoldRendererTeardown(void);

// Called by the compositor loop when the LAYER was invalidated, i.e. the Crown
// or the system dismissed the space behind our back: flips the SwiftUI state so
// the dismissal path runs exactly as the button's would.
void OpenQ4_Vision3D_ImmersiveEnded(void);

// Called from Swift once dismissImmersiveSpace() has completed. Under .mixed
// immersion the 2D window never deactivates, so there is no lifecycle event to
// hang this on — this call IS the authoritative back-to-2D trigger.
void OpenQ4_Vision3D_Finalize(void);

// One sample per display-link tick, from the shared frame driver. visionOS only.
void OpenQ4_Vision3D_NoteEngineTick(void);

// `!xr3dtune <sep> <conv> [dist halfW halfH height dim]` and the settings rows
// that drive the same values. Pointers are optional tail arguments: NULL leaves
// that knob alone. Main thread (the sheet) or the bridge's socket thread.
void OpenQ4_Vision3D_Tune(float separation, float convergence,
						  const float *dist, const float *halfW, const float *halfH,
						  const float *height, const float *dim);
// The weapon's depth, -1..+1, 0 = flat on the panel (Q-032's default).
void OpenQ4_Vision3D_SetGunDepth(float gunDepth);
// Panel Resolution: the PER-EYE render extent, decoupled from the window and
// applied at the next frame boundary — no vid_restart (D-101).
void OpenQ4_Vision3D_SetEyeSize(int width, int height);

// `!xrwin <w> <h>` — request a 2D window size in POINTS, the one API visionOS
// gives for window geometry and the same call the park makes.
//
// A TEST LEVER, not a feature (D-102): the park shrinks the window to a 480 pt
// card, and the simulator's persisted window size IS 480x271 pt, so on the sim
// the park changes nothing and the exit path's swapchain-extent change — the
// case the one-shot reconcile in vk_Backend.cpp exists for — is unreachable.
// Growing the window first makes it reachable, and keeps it reachable for
// every round after this one. Same shape as r_stereo3dFailPair (D-101): the
// lever that makes a path a simulator never takes into one it does.
void OpenQ4_Vision3D_RequestWindowSizePt(double widthPt, double heightPt);

// D-107. Swift calls SpaceOpened once openImmersiveSpace() returned .opened
// (curtain re-asserted then and at +1.5 s / +3 s, card state to the blackbox),
// and NoteSpatialAudio with 1 (front, the panel), 0 (the window) or -1 (the
// session refused) so !xr3diag can report audio=.
void OpenQ4_Vision3D_SpaceOpened(void);
void OpenQ4_Vision3D_NoteSpatialAudio(int state);

// The `!xr3diag` line, without a trailing newline.
void OpenQ4_Vision3D_DiagLine(char *buf, size_t size);

// Recorded from the Swift CompositorLayer configuration, and reported in
// !xr3diag as caps=dedN/layN/shrN/fovN. The shell asks for .dedicated; what it
// GETS depends on this capability set, and on hardware 0.1.0.58 it got
// .layered with nothing in the diag line to say why.
// Round 4 (D-105) adds the two foveation answers: what the shell WANTED and
// what the layer was actually configured with, so `!xr3diag` can say why fov=
// reads 0. D-106 retired the `vp3dFoveation` row, so "wanted" is now simply
// "the device supports it" — the guide's directive once validated.
void OpenQ4_Vision3D_NoteLayoutCaps(int dedicated, int layered, int shared, int foveation,
									int wanted, int enabled);
const char *OpenQ4_Vision3D_LayoutCaps(void);

// One word for !xr3diag's fovWhy= field: on|off|unsupported|refused|unknown.
const char *OpenQ4_Vision3D_FoveationWhy(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_VISION3D_H */

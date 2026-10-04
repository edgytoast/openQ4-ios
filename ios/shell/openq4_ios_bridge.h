/*
 * openq4_ios_bridge.h — remote console bridge and frame loop for the iOS build.
 *
 * The bridge is a TCP console on the device/simulator, reachable from the Mac.
 * It is the single highest-value debugging asset in a port like this: without it
 * every question ("does this map load?", "what is r_actualRenderApi?") needs
 * hands on a screen, and with it they are all scriptable.
 *
 * Port 8774 (see DECISIONS): 8765-8769 are HarbourMasters, 8771 realrtcw,
 * 8772 dhewm3, 8773 GoldenEye, and the Quake-family 27999 is shared and
 * collides across concurrent sessions.
 */

#ifndef OPENQ4_IOS_BRIDGE_H
#define OPENQ4_IOS_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Start the listener. Opt-in via the OPENQ4_CONSOLE_BRIDGE=1 environment
 * variable so a release build cannot accidentally expose a console; call once,
 * after common->Init() (the command system must exist before commands arrive).
 */
void OpenQ4_iOS_BridgeStart(void);

/*
 * Is the console channel allowed in THIS build? OTA builds yes (unless
 * OPENQ4_CONSOLE_BRIDGE=0), public builds only with OPENQ4_CONSOLE_BRIDGE=1 —
 * the charter's split. Exposed because the `openq4://console/` deep link has to
 * be gated by exactly the same rule and there must be only one copy of it.
 */
bool OpenQ4_iOS_BridgeEnabled(void);

/*
 * Hand the engine a console command from UIKit code.
 *
 * Goes onto the same locked queue the socket listener uses and is executed on
 * the engine thread by OpenQ4_iOS_BridgeDrain — idCmdSystem is not thread-safe,
 * so this is the only legal way for the settings sheet (or any other UIKit
 * code) to run a command. Works whether or not the bridge listener is running.
 */
void OpenQ4_iOS_QueueConsoleCommand(const char *cmd);

/*
 * Feed any queued commands to the engine. MUST be called from the frame thread:
 * commands arrive on a socket thread, but idCmdSystem is not thread-safe, so
 * the queue is the handoff point.
 */
void OpenQ4_iOS_BridgeDrain(void);

/*
 * Start the frame loop.
 *
 * Frames are driven by a CADisplayLink that WE own, not by
 * SDL_SetiOSAnimationCallback. SDL's callback assumes a main() that never
 * returns: SDL_uikitappdelegate's postFinishLaunch calls
 * SDL_SetiOSEventPump(false) the moment the user main returns
 * (SDL_uikitappdelegate.m:496) — and on iOS main MUST return to the run loop.
 * Driving frames through SDL's callback there yields roughly one frame and then
 * silence, which is exactly what this port hit.
 *
 * Ours is also registered in NSRunLoopCommonModes so frames continue during
 * touch tracking; SDL registers its link in NSDefaultRunLoopMode only
 * (SDL_uikitviewcontroller.m:178), which would stop the game while a finger is
 * down.
 *
 * Call once, after common->Init(), then return from main.
 * OpenQ4_iOS_EngineFrame() is implemented engine-side and runs one frame.
 */
void OpenQ4_iOS_StartFrameLoop(void);

/*
 * Print display-link health: tick count, re-entrancy drops, and whether the
 * link object is alive/paused. Registered as the `iosframelink` console command
 * so it can be asked over the bridge at any moment.
 */
void OpenQ4_iOS_ReportFrameLoop(void);

/*
 * Pause the display link across a blocking load. An armed link that keeps
 * requesting callbacks the app never answers is a standing request to the
 * render server, and a starved one is what arms the scene-update watchdog.
 */
void OpenQ4_iOS_SetFrameLoopPaused(int paused);

/*
 * Tell the main thread that the engine has finished initialising and it is safe
 * to pump SDL events. SDL is not thread-safe and the engine thread owns SDL
 * exclusively during common->Init.
 */
void OpenQ4_iOS_EngineReady(void);

/*
 * Frame pacing mode: 0 = one engine frame per display-link tick (a tick that
 * lands on a running frame is dropped), 1 = catch up, running one extra frame
 * immediately for a tick that was missed. Default 1; see the comment on
 * g_paceMode for the measurement that motivates it.
 */
void OpenQ4_iOS_SetPaceMode(int mode);

/*
 * Read-and-reset the pacing counters for the heartbeat. Any pointer may be
 * NULL; paceMode is read, not reset.
 */
void OpenQ4_iOS_TakeFramePacingCounters(int *missed, int *catchUp, int *paceMode);

/*
 * Render resolution, as a fraction of the native drawable (0.5 - 1.0).
 *
 * Read by the SDL3 backend when it reports the window's pixel size, which is
 * what the Vulkan swapchain extent — and therefore CAMetalLayer.drawableSize —
 * follows. The engine's own r_screenFraction cannot do this job: the Vulkan
 * renderer never implements the scaled scene target it describes.
 *
 * Called from the engine thread every frame, so it is a plain atomic read.
 */
float OpenQ4_iOS_RenderScale(void);

/* Percent form, 50-100, clamped. Setting it applies on the next frame. */
int OpenQ4_iOS_RenderScalePercent(void);
void OpenQ4_iOS_SetRenderScalePercent(int percent);

/*
 * The pixel size the SDL Metal layer will actually present, in exact integers.
 *
 * This is the size the engine must request for its swapchain. MoltenVK judges a
 * swapchain optimal by comparing its extent to the layer's natural drawable
 * size (bounds x contentsScale, its own rounding), so a size computed any other
 * way — even one pixel out — makes every present return VK_SUBOPTIMAL_KHR and
 * costs a full swapchain recreate per frame. There is exactly one number and
 * this is where it lives.
 *
 * Returns false when the Metal layer has not been found (before the renderer
 * creates its window, or when layer scaling is disabled for an A/B); the caller
 * then falls back to its own arithmetic and should say so.
 *
 * Safe from the engine thread: reads cached atomics, touches no UIKit.
 */
bool OpenQ4_iOS_RenderPixelSize(int *width, int *height);

/* Re-derive the layer's contentsScale and cached pixel size (async on main). */
void OpenQ4_iOS_RenderScaleRefreshLayer(void);

/*
 * Run fn(ctx) on the main thread and wait for it.
 *
 * UIKit view-hierarchy work is main-thread-only and asserts loudly when it is
 * not: SDL's Vulkan surface creation builds the CAMetalLayer view, and calling
 * it from the engine thread throws an NSInternalInconsistencyException out of
 * -[UIView _didMoveFromWindow:toWindow:], which unwinds into our C++ terminate
 * handler as a bare SIGABRT. That only happens on a MID-SESSION renderer
 * rebuild — the game-module swap an Arena match performs (D-078); at first boot
 * common->Init() is already on the main thread and this is a direct call.
 *
 * Safe to call from the engine thread: the display link's tick: signals the
 * engine thread and returns without waiting for the frame, so the main thread
 * is on its run loop and this cannot deadlock against it. Not for per-frame
 * use — it is a lifecycle helper, called once per renderer bring-up.
 */
void OpenQ4_iOS_RunOnMainSync(void (*fn)(void *), void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_BRIDGE_H */

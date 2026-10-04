/*
 * openq4_ios_blackbox.h — crash-surviving startup trace.
 *
 * When the app dies during startup the engine log cannot say whether the
 * process was killed or the main thread wedged: both look like output stopping.
 * The black box answers that, because a watchdog thread keeps writing after the
 * main thread has stopped responding, and every line is fsync'd so a SIGKILL
 * cannot take the tail with it.
 *
 * Read Documents/blackbox.log after a failure:
 *   ticks stop entirely               -> process killed (Jetsam or watchdog)
 *   ticks continue, main-alive frozen -> main thread blocked, app hung
 */

#ifndef OPENQ4_IOS_BLACKBOX_H
#define OPENQ4_IOS_BLACKBOX_H

#ifdef __cplusplus
extern "C" {
#endif

void OpenQ4_iOS_BlackBox(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* Name the startup stage; every subsequent watchdog tick carries it. */
void OpenQ4_iOS_BlackBoxPhase(const char *phase);

/* Bumped from the main thread so a stall is visible as a frozen counter. */
void OpenQ4_iOS_NoteMainAlive(void);

/*
 * Hand the run loop back to UIKit briefly, from inside the engine's long
 * single-threaded startup. Without this the main thread never returns to its
 * run loop for ~22 seconds and iOS kills the app for being unresponsive —
 * silently, with SIGKILL, showing a black screen the whole way.
 *
 * Called from the engine's print path (frequent and well distributed through
 * init) and rate-limited internally. A no-op once init has finished.
 */
void OpenQ4_iOS_ServiceRunLoopDuringInit(void);
void OpenQ4_iOS_InitComplete(void);

/*
 * Has common->Init() finished? Read by the deep-link queue, which must not hand
 * a console command to an engine that has no command system yet — and, on iOS,
 * must not run one while onboarding is still up (OpenQ4_iOS_EnsureGameData runs
 * before Init and blocks, so "init complete" implies "past onboarding").
 */
int OpenQ4_iOS_InitCompleted(void);

/*
 * Engine output written straight to a file descriptor from the calling thread.
 * The ordinary log reaches disk through a pipe and a pump thread, and whatever
 * is still in that pipe when the process is killed is lost — always the tail,
 * always the part that names what was happening.
 */
void OpenQ4_iOS_TraceLine(const char *line);

/* Remaining Jetsam headroom in MB, or -1 where the OS does not report one. */
int OpenQ4_iOS_AvailableMemoryMB(void);

/*
 * What the main thread is working on right now. Writes a fixed-size buffer and
 * nothing else, so it is cheap enough to call per image or per model; the
 * watchdog samples it once a second. That makes the tick log a 1 Hz profile of
 * work that prints nothing of its own — which is exactly the work that has been
 * impossible to attribute.
 */
void OpenQ4_iOS_SetActivity(const char *what);

/* Point the backtrace sampler at the calling thread (the engine thread). */
void OpenQ4_iOS_SetSampleTargetToSelf(void);

/*
 * Loading overlay for map changes. The engine's own loading screen cannot be
 * drawn on iOS: rendering it acquires a swapchain drawable from inside a
 * blocked run loop, which hangs permanently once the drawable pool empties.
 */
void OpenQ4_iOS_BeginBlockingLoad(void);
void OpenQ4_iOS_LoadProgress(void);
void OpenQ4_iOS_LoadProgressDone(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_BLACKBOX_H */

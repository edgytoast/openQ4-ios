/*
 * openq4_ios_shell.m — the iOS app shell.
 *
 * The engine supplies main() (src/sys/osx/macosx_sdl3_main.cpp, reached through
 * SDL_RunApp), so this file does not own the app lifecycle. It exists for the
 * things that must happen around the engine rather than inside it.
 *
 * It is also load-bearing in a duller way: an Xcode application target with no
 * sources at all links nothing, produces a bundle containing only Info.plist,
 * and still reports BUILD SUCCEEDED. This translation unit guarantees a link
 * step happens.
 */

#import <Foundation/Foundation.h>
#include <exception>
#include <typeinfo>
#include <stdlib.h>
#import <UIKit/UIKit.h>
#import "../compat/openq4_ios_compat.h"
#include <stdio.h>
#include <dlfcn.h>
#include <signal.h>
#include <execinfo.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <fcntl.h>
#include <errno.h>
#include <os/proc.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <mach/thread_act.h>
#include <mach-o/dyld.h>
#include <pthread.h>

// Included so the C entry points below keep C linkage: this translation unit is
// Objective-C++ (it needs std::set_terminate and typeid), and without the
// declarations the definitions would be C++-mangled and the engine could not
// link against them.
#include "openq4_ios_blackbox.h"
#include "openq4_ios_onboarding.h"
#include "openq4_ios_settings.h"
#include "openq4_ios_bridge.h"
#include <stdarg.h>
#include <time.h>

/*
 * Launch beacon.
 *
 * A constructor runs before main(), so this records that the process started at
 * all. That matters because the failures most likely on a fresh port — a
 * MoltenVK load failure, a missing pak, a dyld problem — happen before any
 * engine logging exists, and on an OTA-installed build there is no console to
 * watch. A beacon file in Documents is often the only evidence that survives.
 */
/*
 * Persistent log + crash capture.
 *
 * On an OTA-installed build there is no console, no debugger and no bridge
 * unless it was explicitly enabled — so when the app dies the only evidence
 * that can reach us is a file in Documents, which the Files app exposes.
 *
 * stdout and stderr are tee'd: the original fds still receive everything (so
 * `simctl --console` and the bridge keep working) and a copy lands in
 * Documents/openq4-log.txt, line-buffered so a crash cannot swallow the tail.
 */
static int  g_logFileFd  = -1;
static int  g_realStdoutFd = -1;
static char g_beaconPath[1024];

/*
 * Black box.
 *
 * The engine log cannot answer the question that matters when the app dies
 * during startup: was the process killed, or is the main thread wedged? Both
 * look identical — output simply stops.
 *
 * So a watchdog thread ticks once a second, writing a line that carries a
 * counter the MAIN thread bumps. Read the tail afterwards:
 *
 *   ticks stop entirely            -> the process was killed (Jetsam/watchdog)
 *   ticks continue, main-alive frozen -> the main thread is blocked, app is hung
 *
 * Every line is write() + fsync(), so a SIGKILL cannot swallow the tail the way
 * it can with the pipe-and-pump used for the engine log. The previous run is
 * kept alongside, because the evidence is usually collected after a relaunch
 * has already truncated the current one.
 *
 * This instrument is inherited from quake3e-ios, where three successive
 * on-device wedges were each caught by it and by nothing else.
 */
static int              g_blackBoxFd = -1;
static int              g_traceFd    = -1;
static double           g_launchTime = 0.0;
static volatile uint64_t g_mainAlive = 0;
// Bumped by a 1 Hz CFRunLoopTimer on the main run loop in the default mode.
// g_mainAlive measures ENGINE progress — it is raised from the pacifier, deep
// inside a blocking load — which is not what iOS polices, and reading it as
// "the app is healthy" is what kept the investigation pointed at resource
// exhaustion for three builds. This one measures whether the main run loop is
// actually turning. During a deliberate blocking load it freezes BY DESIGN;
// freezing at any other time is a real hang.
static volatile uint64_t g_runLoopTurns = 0;
static char             g_phase[128] = "pre-main";
// Sampled by the watchdog, never written to disk by the setter. Updating it is
// a bounded strlcpy, so it is cheap enough to call per image / per model — and
// that turns the watchdog tick into a 1 Hz sampled profile of whatever the main
// thread is grinding through, which plain logging cannot give when the slow
// work prints nothing at all.
static char             g_activity[192] = "";
static pthread_t        g_mainPThread;

static int OpenQ4_FootprintMB(void);
// Set for the duration of a map load; defined with the load prologue below.
extern volatile int g_loadOverlayUp;

static double OpenQ4_NowSeconds(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

void OpenQ4_iOS_BlackBox(const char *fmt, ...) {
	if (g_blackBoxFd < 0) {
		return;
	}
	char line[512];
	const int head = snprintf(line, sizeof(line), "[+%7.3fs] ", OpenQ4_NowSeconds() - g_launchTime);
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line + head, sizeof(line) - (size_t)head - 2, fmt, ap);
	va_end(ap);
	strlcat(line, "\n", sizeof(line));
	(void)write(g_blackBoxFd, line, strlen(line));
	// fsync per line is expensive and entirely the point: an unsynced tail is
	// exactly what a SIGKILL takes with it.
	(void)fsync(g_blackBoxFd);
}

/*
 * Engine output, written straight from the engine's own thread.
 *
 * Documents/openq4-log.txt reaches the disk through a pipe and a pump thread,
 * which is fine until the process is killed: whatever is still sitting in the
 * pipe dies with it, and that is always the tail — the lines naming what the
 * engine was doing at the end. This path has no pipe. write() hands the bytes
 * to the kernel, which keeps them whether or not the process ever runs again.
 */
/*
 * Ring of the most recent engine output.
 *
 * The engine log and the black box are separate files, and diagnosis has
 * repeatedly stalled on having one without the other — the black box says
 * "responsive, memory fine, then dead" and only the engine log can say what it
 * was doing. Keeping the last lines in memory and dumping them into the black
 * box whenever something is sampled makes that one file self-contained.
 *
 * Fixed-size and overwritten in place: no allocation on the engine's hot print
 * path, and nothing to free from a signal handler.
 */
#define OPENQ4_TRACE_RING 24
#define OPENQ4_TRACE_LINE 160
static char g_traceRing[OPENQ4_TRACE_RING][OPENQ4_TRACE_LINE];
static int  g_traceRingNext = 0;

static void OpenQ4_DumpTraceRing(void) {
	OpenQ4_iOS_BlackBox("--- last %d engine lines ---", OPENQ4_TRACE_RING);
	for (int i = 0; i < OPENQ4_TRACE_RING; i++) {
		const char *line = g_traceRing[(g_traceRingNext + i) % OPENQ4_TRACE_RING];
		if (line[0] != '\0') {
			OpenQ4_iOS_BlackBox("  | %s", line);
		}
	}
}

void OpenQ4_iOS_TraceLine(const char *line) {
	if (line == NULL) {
		return;
	}
	// Ring first, so it is populated even before the trace fd exists.
	if (line[0] != '\n' && line[0] != '\0') {
		char *slot = g_traceRing[g_traceRingNext];
		strlcpy(slot, line, OPENQ4_TRACE_LINE);
		const size_t n = strlen(slot);
		if (n > 0 && slot[n - 1] == '\n') {
			slot[n - 1] = '\0';
		}
		g_traceRingNext = (g_traceRingNext + 1) % OPENQ4_TRACE_RING;
	}
	if (g_traceFd < 0) {
		return;
	}
	char stamp[24];
	const int n = snprintf(stamp, sizeof(stamp), "[%8.3f] ", OpenQ4_NowSeconds() - g_launchTime);
	(void)write(g_traceFd, stamp, (size_t)n);
	(void)write(g_traceFd, line, strlen(line));
}

/*
 * Ring of recent activity values.
 *
 * The 1 Hz watchdog sample is far too coarse to name the asset that kills a
 * load: thousands go past between two ticks. This keeps the last 48 DISTINCT
 * ones, so the dump names the handful immediately before death — which is what
 * matters now that the evidence says the load dies at the same deterministic
 * point every run (same memory consumed, same progress count, across builds).
 */
#define OPENQ4_ACT_RING 48
static char g_actRing[OPENQ4_ACT_RING][sizeof(g_activity)];
static int  g_actRingNext = 0;

static void OpenQ4_DumpActivityRing(void) {
	OpenQ4_iOS_BlackBox("--- last %d assets touched ---", OPENQ4_ACT_RING);
	for (int i = 0; i < OPENQ4_ACT_RING; i++) {
		const char *a = g_actRing[(g_actRingNext + i) % OPENQ4_ACT_RING];
		if (a[0] != '\0') {
			OpenQ4_iOS_BlackBox("  > %s", a);
		}
	}
}

void OpenQ4_iOS_SetActivity(const char *what) {
	if (what == NULL) {
		g_activity[0] = '\0';
		return;
	}
	if (strcmp(g_activity, what) != 0) {
		strlcpy(g_actRing[g_actRingNext], what, sizeof(g_actRing[0]));
		g_actRingNext = (g_actRingNext + 1) % OPENQ4_ACT_RING;
	}
	strlcpy(g_activity, what, sizeof(g_activity));
}

void OpenQ4_iOS_BlackBoxPhase(const char *phase) {
	if (phase == NULL) {
		return;
	}
	snprintf(g_phase, sizeof(g_phase), "%s", phase);
	OpenQ4_iOS_BlackBox("phase: %s", phase);
}

void OpenQ4_iOS_NoteMainAlive(void) {
	g_mainAlive++;
}

/*
 * Main-thread backtrace sampler.
 *
 * When the watchdog sees the main thread stalled, it suspends it, walks the
 * frame-pointer chain, and writes raw return addresses plus the image slide.
 * Symbolicate offline: `atos -o openQ4 -l <slide> <addr...>`.
 *
 * This is what converts "the app went silent for 109 seconds and died" into the
 * name of the function it was inside. Every previous silent stall on this port
 * cost a publish-and-test round to guess at; this answers it from the first one.
 *
 * arm64 frame layout: x29 (fp) points at [saved fp, saved lr]. Walking that is
 * enough for the ordinary compiled frames we care about — leaf frames without a
 * frame pointer are skipped, which is acceptable for naming a stall.
 */
// Set once the frame loop moves to the engine thread: that is the thread doing
// the work, and sampling main after the move only ever shows an idle run loop.
static pthread_t        g_sampleTarget;
static volatile int     g_sampleTargetSet = 0;

void OpenQ4_iOS_SetSampleTargetToSelf(void) {
	g_sampleTarget = pthread_self();
	g_sampleTargetSet = 1;
}

static void OpenQ4_SampleMainThreadStack(void) {
	const mach_port_t mainThread =
		pthread_mach_thread_np(g_sampleTargetSet ? g_sampleTarget : g_mainPThread);
	if (mainThread == MACH_PORT_NULL) {
		return;
	}

	if (thread_suspend(mainThread) != KERN_SUCCESS) {
		return;
	}

	arm_thread_state64_t state;
	mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
	const kern_return_t kr =
		thread_get_state(mainThread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);

	uintptr_t pcs[24];
	int depth = 0;
	if (kr == KERN_SUCCESS) {
		pcs[depth++] = (uintptr_t)arm_thread_state64_get_pc(state);
		uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
		// Bounded, and each frame must be above the last: a corrupt or
		// mid-prologue chain must not walk this thread off into the weeds while
		// the main thread is suspended.
		while (depth < (int)(sizeof(pcs) / sizeof(pcs[0])) && fp != 0 && (fp & 0x7) == 0) {
			const uintptr_t nextFp = *(uintptr_t *)fp;
			const uintptr_t lr = *(uintptr_t *)(fp + sizeof(uintptr_t));
			if (lr == 0 || nextFp <= fp) {
				break;
			}
			pcs[depth++] = lr;
			fp = nextFp;
		}
	}

	thread_resume(mainThread);

	if (depth == 0) {
		return;
	}
	const intptr_t slide = _dyld_get_image_vmaddr_slide(0);
	OpenQ4_iOS_BlackBox("STALL BACKTRACE (slide 0x%lx; symbolicate: atos -o openQ4 -l <load-addr>)",
						(unsigned long)slide);
	char line[512];
	int n = 0;
	line[0] = '\0';
	for (int i = 0; i < depth; i++) {
		n += snprintf(line + n, sizeof(line) - (size_t)n, "0x%llx ", (unsigned long long)pcs[i]);
		if (n > (int)sizeof(line) - 24) {
			break;
		}
	}
	OpenQ4_iOS_BlackBox("    %s", line);
}

static void *OpenQ4_WatchdogThread(void *arg) {
	(void)arg;
	pthread_setname_np("openq4-blackbox");
	uint64_t lastSeen = 0;
	int stalledTicks = 0;
	for (;;) {
		struct timespec req = { 1, 0 };
		nanosleep(&req, NULL);

		const uint64_t alive = g_mainAlive;
		const size_t avail = os_proc_available_memory();
		const int headroomMB = (avail == 0) ? -1 : (int)(avail / (1024 * 1024));

		if (alive == lastSeen) {
			stalledTicks++;
		} else {
			stalledTicks = 0;
		}
		lastSeen = alive;

		// Sample on entering the stall and then sparsely, so a genuinely long
		// load leaves a few datapoints rather than one line a second.
		if (stalledTicks == 3 || (stalledTicks > 3 && (stalledTicks % 15) == 0)) {
			OpenQ4_SampleMainThreadStack();
		}

		// A responsive app can still be making no progress. A map load services
		// the run loop constantly through the pacifier, so main-alive races
		// ahead while nothing actually advances — and the stall trigger above
		// never fires, which is exactly what happened on the run that took 102
		// seconds and died. Treat "the activity string has not changed in a
		// long time" as its own kind of stuck.
		static char lastActivity[sizeof(g_activity)] = "";
		static int  sameActivityTicks = 0;
		if (strcmp(lastActivity, g_activity) == 0) {
			sameActivityTicks++;
		} else {
			strlcpy(lastActivity, g_activity, sizeof(lastActivity));
			sameActivityTicks = 0;
		}
		// During a map load, sample unconditionally at 1 Hz.
		//
		// Both existing triggers key off progress *stopping*, and during the
		// fatal block progress never stops — load-progress advances at ~1000/s
		// right up to the kill. So the one window that matters produced no
		// backtrace at all, and three rounds were spent reasoning from a
		// correlation table instead of a stack. If the work is progressing and
		// the app dies anyway, the last sample before death is still the answer.
		if (g_loadOverlayUp) {
			OpenQ4_SampleMainThreadStack();
		}

		if (sameActivityTicks == 6 || (sameActivityTicks > 6 && (sameActivityTicks % 10) == 0)) {
			OpenQ4_iOS_BlackBox("NO PROGRESS for %ds (main thread responsive) — sampling",
								sameActivityTicks);
			OpenQ4_SampleMainThreadStack();
			OpenQ4_DumpTraceRing();
			OpenQ4_DumpActivityRing();
		}

		if (g_traceFd >= 0) { (void)fsync(g_traceFd); }
		char headroom[24];
		if (headroomMB >= 0) {
			snprintf(headroom, sizeof(headroom), "%dMB", headroomMB);
		} else {
			snprintf(headroom, sizeof(headroom), "n/a");
		}
		OpenQ4_iOS_BlackBox("tick load-progress=%llu%s runloop=%llu headroom=%s footprint=%dMB phase=%s | %s",
							(unsigned long long)alive,
							stalledTicks >= 3 ? " STALLED" : "",
							(unsigned long long)g_runLoopTurns,
							headroom, OpenQ4_FootprintMB(), g_phase,
							g_activity[0] ? g_activity : "-");
	}
	return NULL;
}

static void OpenQ4_InstallMemoryPressureSource(void) {
	// Jetsam warns before it kills, often with enough notice to land in the log.
	// Without this the kill is the first and only evidence that memory was ever
	// the problem.
	dispatch_queue_t q = dispatch_queue_create("openq4.mempressure", DISPATCH_QUEUE_SERIAL);
	dispatch_source_t src = dispatch_source_create(
		DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
		DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, q);
	if (src == NULL) {
		return;
	}
	dispatch_source_set_event_handler(src, ^{
		const unsigned long flags = dispatch_source_get_data(src);
		OpenQ4_iOS_BlackBox("MEMORY PRESSURE: %s (phase %s)",
							(flags & DISPATCH_MEMORYPRESSURE_CRITICAL) ? "CRITICAL" : "warning",
							g_phase);
	});
	dispatch_resume(src);
	// Intentionally never cancelled: it must outlive everything it reports on.
	CFRetain((CFTypeRef)src);
}

static void OpenQ4_AppendBeacon(const char *text) {
	if (g_beaconPath[0] == '\0' || text == NULL) {
		return;
	}
	// Signal-handler safe: open/write/close only, no malloc, no Foundation.
	const int fd = open(g_beaconPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
	if (fd >= 0) {
		write(fd, text, strlen(text));
		close(fd);
	}
}

/*
 * Crash handler. Records which signal killed us and a raw backtrace into the
 * beacon. Deliberately minimal — anything more than write() from a signal
 * handler risks deadlocking instead of reporting.
 */
/*
 * C++ terminate handler.
 *
 * SIGABRT with no message means abort(), and by far the most common route there
 * is an uncaught C++ exception: std::terminate runs, then abort. The engine's
 * own handler reports the signal, which tells us nothing about what threw.
 *
 * This runs BEFORE abort, while the exception is still in flight, so rethrowing
 * it gives the type and message. That is the difference between "the process
 * aborted" and knowing which call failed.
 *
 * Deliberately not a signal handler, so std::* and backtrace_symbols_fd are
 * legal here.
 */
static void OpenQ4_TerminateHandler(void) {
	OpenQ4_iOS_BlackBox("*** std::terminate in phase %s ***", g_phase);
	try {
		const std::exception_ptr cur = std::current_exception();
		if (cur) {
			std::rethrow_exception(cur);
		} else {
			OpenQ4_iOS_BlackBox("    terminate called with no exception in flight "
								"(a direct abort(), or a throw during unwinding)");
		}
	} catch (const std::exception &e) {
		OpenQ4_iOS_BlackBox("    C++ exception: %s: %s", typeid(e).name(), e.what());
	} catch (...) {
		OpenQ4_iOS_BlackBox("    C++ exception of a non-std type");
	}

	void *frames[64];
	const int n = backtrace(frames, 64);
	char **syms = backtrace_symbols(frames, n);
	if (syms != NULL) {
		for (int i = 0; i < n; i++) {
			OpenQ4_iOS_BlackBox("    %s", syms[i]);
		}
		free(syms);
	}
	if (g_traceFd >= 0) { (void)fsync(g_traceFd); }

	abort();
}

// Defined here rather than beside OpenQ4_ReArmCrashHandlers because the crash
// handler below needs it, and the crash handler must come first.
static void (*g_engineAbrtHandler)(int) = SIG_DFL;

static void OpenQ4_UncaughtExceptionHandler(NSException *ex) {
	// Metal and MoltenVK report some failures as ObjC exceptions, which abort
	// the process. By the time SIGABRT arrives the reason is gone, so record it
	// here where it is still readable.
	OpenQ4_iOS_BlackBox("*** uncaught exception: %s: %s ***",
						ex.name.UTF8String ?: "?", ex.reason.UTF8String ?: "?");
	for (NSString *frame in ex.callStackSymbols) {
		OpenQ4_iOS_BlackBox("    %s", frame.UTF8String);
	}
}

static void OpenQ4_CrashHandler(int sig) {
	OpenQ4_AppendBeacon("\n*** CRASH ***\n  signal: ");
	switch (sig) {
		case SIGSEGV: OpenQ4_AppendBeacon("SIGSEGV (bad memory access)\n"); break;
		case SIGBUS:  OpenQ4_AppendBeacon("SIGBUS\n"); break;
		case SIGILL:  OpenQ4_AppendBeacon("SIGILL\n"); break;
		case SIGABRT: OpenQ4_AppendBeacon("SIGABRT (engine fatal or assertion)\n"); break;
		case SIGFPE:  OpenQ4_AppendBeacon("SIGFPE\n"); break;
		default:      OpenQ4_AppendBeacon("other\n"); break;
	}

	void *frames[64];
	const int n = backtrace(frames, 64);
	if (g_blackBoxFd >= 0) {
		backtrace_symbols_fd(frames, n, g_blackBoxFd);
		(void)fsync(g_blackBoxFd);
	}
	if (g_beaconPath[0] != '\0') {
		const int fd = open(g_beaconPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
		if (fd >= 0) {
			backtrace_symbols_fd(frames, n, fd);
			close(fd);
		}
	}
	// Flush whatever the engine had buffered, then die normally so the OS still
	// files its own report.
	if (g_logFileFd >= 0) {
		fsync(g_logFileFd);
	}
	OpenQ4_iOS_BlackBox("*** fatal signal %d in phase %s ***", sig, g_phase);
	OpenQ4_DumpTraceRing();
	// Hand back to the engine's handler if it had one, so its own phase
	// reporting still reaches the log.
	if (sig == SIGABRT && g_engineAbrtHandler != SIG_DFL && g_engineAbrtHandler != SIG_ERR) {
		signal(sig, g_engineAbrtHandler);
		raise(sig);
		return;
	}
	signal(sig, SIG_DFL);
	raise(sig);
}

static void *OpenQ4_LogPumpThread(void *arg) {
	const int readFd = (int)(intptr_t)arg;
	char buf[4096];
	for (;;) {
		const ssize_t n = read(readFd, buf, sizeof(buf));
		if (n <= 0) {
			if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
			break;
		}
		if (g_realStdoutFd >= 0) { (void)write(g_realStdoutFd, buf, (size_t)n); }
		if (g_logFileFd  >= 0)  {
			(void)write(g_logFileFd, buf, (size_t)n);
			// The engine log is the record of what the app was doing when it
			// died, and a SIGKILL takes any unsynced tail with it — which is
			// precisely the tail that matters. Sync cost is irrelevant next to
			// losing the evidence.
			(void)fsync(g_logFileFd);
		}
	}
	return NULL;
}

__attribute__((constructor))
static void OpenQ4_iOS_LaunchBeacon(void) {
	@autoreleasepool {
		NSArray<NSString *> *paths =
			NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		if (paths.count == 0) {
			return;
		}
		NSString *beacon = [paths.firstObject stringByAppendingPathComponent:@"launch-beacon.txt"];
		NSMutableString *stamp =
			[NSMutableString stringWithFormat:@"openQ4 launched %@\n", [NSDate date]];

		/*
		 * AMFI probe (D-014).
		 *
		 * The game modules are dylibs inside the bundle, signed with the app,
		 * loaded with dlopen. The simulator does NOT enforce code signing, so
		 * simulator success proves nothing about whether AMFI will honour the
		 * signature chain for a dlopen'd (rather than launch-linked) dylib on a
		 * sideloaded device install. This records the answer where it survives:
		 * a beacon file readable over the bridge or via the container.
		 *
		 * It also doubles as a load-path breadcrumb when the modules cannot be
		 * found at all.
		 */
		NSString *fw = [NSBundle.mainBundle.privateFrameworksPath
							stringByAppendingPathComponent:@"game-sp_arm64.dylib"];
		void *handle = dlopen(fw.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
		if (handle != NULL) {
			const BOOL hasEntry = (dlsym(handle, "GetGameAPI") != NULL);
			[stamp appendFormat:@"  dlopen probe: OK (GetGameAPI %@)\n",
								hasEntry ? @"present" : @"MISSING"];
			dlclose(handle);
		} else {
			const char *err = dlerror();
			[stamp appendFormat:@"  dlopen probe: FAILED (%s)\n", err ? err : "unknown"];
		}

		snprintf(g_beaconPath, sizeof(g_beaconPath), "%s", beacon.fileSystemRepresentation);

		// Persistent engine log, truncated per launch so it always describes the
		// run that is being reported rather than growing without bound.
		NSString *logPath = [paths.firstObject stringByAppendingPathComponent:@"openq4-log.txt"];
		g_logFileFd = open(logPath.fileSystemRepresentation,
						   O_WRONLY | O_CREAT | O_TRUNC, 0644);
		// Two ways to capture stdout/stderr, and the choice matters for
		// diagnosis.
		//
		// The pipe-and-pump route can tee to the real stdout as well as the
		// file, which is what the console bridge and `simctl --console` need.
		// But anything still sitting in the pipe when the process is killed
		// dies with it — and third-party output we cannot reroute, MoltenVK's
		// [mvk-error] lines above all, only exists on that path.
		//
		// So when there is no console to tee to (every OTA build on a device),
		// point the descriptors straight at the file instead. write() then
		// hands the bytes to the kernel, which keeps them regardless of what
		// happens to the process.
#if !defined(OPENQ4_PUBLIC_BUILD)
		const char *bridge = getenv("OPENQ4_CONSOLE_BRIDGE");
		const BOOL wantTee = (bridge != NULL && strcmp(bridge, "1") == 0);
#else
		// Public builds (D-113) have no bridge and no console to tee to.
		const BOOL wantTee = NO;
#endif
		int fds[2];
		if (g_logFileFd >= 0 && wantTee && pipe(fds) == 0) {
			g_realStdoutFd = dup(STDOUT_FILENO);
			setvbuf(stdout, NULL, _IOLBF, 0);
			dup2(fds[1], STDOUT_FILENO);
			dup2(fds[1], STDERR_FILENO);
			close(fds[1]);
			pthread_t tid;
			if (pthread_create(&tid, NULL, OpenQ4_LogPumpThread,
							   (void *)(intptr_t)fds[0]) == 0) {
				pthread_detach(tid);
			}
		} else if (g_logFileFd >= 0) {
			setvbuf(stdout, NULL, _IONBF, 0);
			setvbuf(stderr, NULL, _IONBF, 0);
			dup2(g_logFileFd, STDOUT_FILENO);
			dup2(g_logFileFd, STDERR_FILENO);
		}

		// Black box: keep the previous run before truncating, because the
		// evidence is normally collected after a relaunch has already
		// overwritten the log of the death being investigated.
		g_launchTime = OpenQ4_NowSeconds();
		// Captured in the constructor, which runs on the main thread before
		// main(), so the watchdog has a handle to sample later.
		g_mainPThread = pthread_self();
		NSString *bbPath = [paths.firstObject stringByAppendingPathComponent:@"blackbox.log"];
		NSString *bbPrev = [paths.firstObject stringByAppendingPathComponent:@"blackbox-prev.log"];
		[NSFileManager.defaultManager removeItemAtPath:bbPrev error:NULL];
		[NSFileManager.defaultManager moveItemAtPath:bbPath toPath:bbPrev error:NULL];
		g_blackBoxFd = open(bbPath.fileSystemRepresentation,
							O_WRONLY | O_CREAT | O_TRUNC, 0644);
		// Identify the build from the bundle, not from the engine's compiled-in
		// banner: that header is generated by the overlay sync, so it goes stale
		// the moment the engine is rebuilt without one — and a log that names
		// the wrong build sends the next diagnosis in the wrong direction.
		NSDictionary *info = NSBundle.mainBundle.infoDictionary;
		NSString *ident = [NSString stringWithFormat:@"openQ4 %@ (build %@) %@",
						   info[@"CFBundleShortVersionString"] ?: @"?",
						   info[@"CFBundleVersion"] ?: @"?",
#if TARGET_OS_SIMULATOR
						   @"ios-simulator"
#else
						   @"ios-device"
#endif
						   ];
		NSString *tracePath = [paths.firstObject stringByAppendingPathComponent:@"openq4-trace.log"];
		NSString *tracePrev = [paths.firstObject stringByAppendingPathComponent:@"openq4-trace-prev.log"];
		[NSFileManager.defaultManager removeItemAtPath:tracePrev error:NULL];
		[NSFileManager.defaultManager moveItemAtPath:tracePath toPath:tracePrev error:NULL];
		g_traceFd = open(tracePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);

		OpenQ4_iOS_BlackBox("launch %s", [NSDate date].description.UTF8String);
		OpenQ4_iOS_BlackBox("%s", ident.UTF8String);
		[stamp appendFormat:@"  %@\n", ident];
		{
			pthread_t wd;
			if (pthread_create(&wd, NULL, OpenQ4_WatchdogThread, NULL) == 0) {
				pthread_detach(wd);
			}
		}
		OpenQ4_InstallMemoryPressureSource();

		// Where the drawable size comes from. The device renders 2736x1260
		// while the simulator of the same model renders the native 2868x1320 —
		// 91% of the pixels — and 912x420 points is suspiciously the screen
		// minus a 44pt and a 20pt inset. Log the actual numbers so the next
		// device run says which of bounds / nativeBounds / safe area is
		// responsible, instead of it being inferred from a ratio.
		dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_VISION
			// No UIScreen on visionOS — there is no panel to describe. The scene
			// and window lines below carry every number that matters here, and
			// they are the ones the drawable is actually sized from.
			OpenQ4_iOS_BlackBox("screen: (visionOS — no UIScreen; see the scene/window lines)");
#else
			UIScreen *screen = UIScreen.mainScreen;
			OpenQ4_iOS_BlackBox("screen: bounds %.0fx%.0f  nativeBounds %.0fx%.0f  scale %.2f nativeScale %.2f",
								screen.bounds.size.width, screen.bounds.size.height,
								screen.nativeBounds.size.width, screen.nativeBounds.size.height,
								screen.scale, screen.nativeScale);
#endif
			for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
				if (![sc isKindOfClass:UIWindowScene.class]) { continue; }
				UIWindowScene *ws = (UIWindowScene *)sc;
				OpenQ4_iOS_BlackBox("scene: coordinateSpace %.0fx%.0f",
									ws.coordinateSpace.bounds.size.width,
									ws.coordinateSpace.bounds.size.height);
				for (UIWindow *w in ws.windows) {
					const UIEdgeInsets si = w.safeAreaInsets;
					OpenQ4_iOS_BlackBox("window: %.0fx%.0f safeArea t=%.0f l=%.0f b=%.0f r=%.0f key=%d",
										w.bounds.size.width, w.bounds.size.height,
										si.top, si.left, si.bottom, si.right, (int)w.isKeyWindow);
				}
			}
		});

		// Run-loop-turn counter. Scheduled on the main run loop in the default
		// mode, i.e. the mode the system's own work uses.
		CFRunLoopTimerRef turnTimer = CFRunLoopTimerCreateWithHandler(
			kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1.0, 1.0, 0, 0,
			^(CFRunLoopTimerRef t) { (void)t; g_runLoopTurns++; } );
		if (turnTimer != NULL) {
			CFRunLoopAddTimer(CFRunLoopGetMain(), turnTimer, kCFRunLoopDefaultMode);
		}

		NSSetUncaughtExceptionHandler(&OpenQ4_UncaughtExceptionHandler);
		std::set_terminate(&OpenQ4_TerminateHandler);

		// Installed after the log exists so a crash report has somewhere to go.
		signal(SIGSEGV, OpenQ4_CrashHandler);
		signal(SIGBUS,  OpenQ4_CrashHandler);
		signal(SIGILL,  OpenQ4_CrashHandler);
		signal(SIGABRT, OpenQ4_CrashHandler);
		signal(SIGFPE,  OpenQ4_CrashHandler);

		FILE *f = fopen(beacon.fileSystemRepresentation, "a");
		if (f != NULL) {
			fputs(stamp.UTF8String, f);
			fclose(f);
		}
		fputs(stamp.UTF8String, stdout);
	}
}

/*
 * Documents directory lives in openq4_ios_onboarding.m, which also owns the
 * import flow that populates it.
 */


/*
 * Remaining Jetsam headroom in MB.
 *
 * iOS kills on memory pressure with SIGKILL, which cannot be caught and files no
 * crash report — so an OOM death looks exactly like any other sudden exit. This
 * makes the approach to that cliff visible in the log.
 */
static int OpenQ4_FootprintMB(void) {
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return -1;
	}
	// phys_footprint is the number Jetsam actually meters, which is why it is
	// worth logging next to os_proc_available_memory's headroom rather than
	// trusting either alone.
	return (int)(info.phys_footprint / (1024 * 1024));
}

int OpenQ4_iOS_AvailableMemoryMB(void) {
	// Returns 0 on the simulator, which has no Jetsam limit to report. Pass that
	// through as -1 so callers print "n/a" rather than an alarming "0 MB".
	const size_t avail = os_proc_available_memory();
	if (avail == 0) {
		return -1;
	}
	return (int)(avail / (1024 * 1024));
}


/*
 * Keeping the app alive through common->Init().
 *
 * Init blocks the calling thread for ~22 seconds on this content — 22 retail
 * paks, the decl system, media, and a full image load. The black box measured
 * it: main-alive frozen from +0.088s to +21.8s.
 *
 * Deferring init off the launch path (so main() returns and the app "finishes
 * launching") is necessary but not sufficient: iOS also requires the app to
 * become *responsive*, and a main thread that never returns to its run loop for
 * 22 seconds is killed with SIGKILL — no crash report, no signal our handler
 * can catch, and a black screen the whole way. Which is exactly the reported
 * symptom.
 *
 * So the engine's own print path calls this, and it hands the run loop back to
 * UIKit for a couple of milliseconds. That is the same thing a modal progress
 * sheet does. SDL's event queue is pumped explicitly elsewhere and is not
 * touched here; a re-entrant display-link tick is dropped by the g_inFrame
 * guard in the bridge.
 */
static volatile int g_initComplete = 0;

/*
 * Loading overlay during a map change.
 *
 * The engine's own loading screen cannot be drawn on iOS — rendering it means
 * acquiring a swapchain drawable from inside a blocked run loop, which is what
 * hung the campaign load forever. So the shell shows the progress instead,
 * reusing the activity string the watchdog already maintains.
 */
volatile int g_loadOverlayUp = 0;

/*
 * Load prologue: put the app into a state where blocking is SAFE.
 *
 * The evidence that shapes this: a fully-blocked main thread with no run-loop
 * servicing at all survived 109 seconds, while a main thread serviced in 2 ms
 * slices at 20 Hz was killed at 10-11 seconds, every time. More servicing, nine
 * times faster death — which rules out "unresponsiveness" as the mechanism.
 *
 * A fully blocked app arms nothing: events queue and no round trip ever starts.
 * The slices were exactly enough for the system to START scene-level
 * transactions and nowhere near enough to FINISH them, and FrontBoard's
 * scene-update watchdog kills at 10.00 seconds of wall clock for precisely that.
 *
 * So the load becomes an honest block between two clean edges: everything the UI
 * needs is done and COMMITTED before the block starts, nothing is pending during
 * it, and nothing is asked of the system until it ends. The spinner keeps
 * spinning because UIActivityIndicatorView animates in the render server, with
 * no app-side commits at all — and if it freezes, that is a real hang.
 */
void OpenQ4_iOS_BeginBlockingLoad(void) {
	if (g_loadOverlayUp) {
		return;
	}
	g_loadOverlayUp = 1;
	OpenQ4_iOS_BlackBox("load prologue: pausing frame loop, committing overlay");

	/*
	 * The frame loop is NOT paused here any more, and pausing it is now a hang.
	 *
	 * This pause was correct when the engine ran on the main thread inside the
	 * display-link callback: the load blocked in place, and stopping the link
	 * kept the system from asking for work that could not be delivered.
	 *
	 * The engine has since moved to its own thread, and the display link became
	 * the thing that SIGNALS it. Pausing the link therefore starves the engine
	 * the moment its current frame returns: the engine parks on g_frameSem and
	 * nothing ever signals it again. It survived at all only by accident —
	 * a single-player map load ends in the "press any key" gate, and that gate
	 * calls LoadProgressDone from inside the engine's own frame, resuming the
	 * link before the frame returns.
	 *
	 * Any map change WITHOUT that gate had no such rescue and hung permanently:
	 * disconnecting to the main menu, and by the same route loading a savegame
	 * or returning to the menu after dying. Confirmed under lldb — main thread
	 * healthy in mach_msg2_trap, engine thread parked in semaphore_wait_trap
	 * inside OpenQ4_EngineThread, load-progress frozen while the run loop kept
	 * turning.
	 *
	 * The watchdog kill this pause was originally defending against came from
	 * the MAIN thread blocking, which it no longer does. A link ticking against
	 * a responsive main thread is the healthy state, and g_frameInFlight already
	 * stops ticks piling up behind a long frame.
	 */

	/*
	 * The overlay is OFF by default during a map load, and that is the
	 * experiment this build exists to run.
	 *
	 * Every regime that dies at ~10 s has a visible, key UIWindow up while the
	 * main thread stops turning its run loop. The one regime that survived —
	 * 109 seconds, build 0.1.0.10 — had no overlay at all, because the feature
	 * did not exist yet. 0.1.0.19 removed the two armers a second-opinion review identified (the
	 * display link and the run-loop servicing) and kept the window; it died on
	 * schedule. The window is the only surviving difference.
	 *
	 * So: skip it, restoring exactly the regime that lived. If the load
	 * completes, the window was the armer and the loading screen has to be
	 * rebuilt some other way. If it still dies, the window is exonerated and
	 * the problem is blocking the main thread at all.
	 *
	 * Set openq4.loadOverlay = 1 in NSUserDefaults to put it back.
	 */
	// Back on by default: the window theory is dead. A review falsified it from two
	// rows of my own table — builds .12 and .13 had no overlay and died at ~10 s
	// anyway — and every build including the 109-second survivor has a visible
	// key UIWindow on screen throughout (the SDL game window). Suppressing this
	// buys nothing and costs the player a black screen.
	if (OpenQ4_iOS_SettingFloat("loadOverlay", 1.0f) > 0.5f) {
		OpenQ4_iOS_ShowBootOverlay();
		OpenQ4_iOS_SetBootStatus("Loading map…");
	} else {
		OpenQ4_iOS_BlackBox("load prologue: overlay SUPPRESSED (testing the 0.1.0.10 regime)");
	}

	// Wait for the overlay's transaction to actually commit before blocking.
	// Spinning the run loop NORMALLY here is the opposite of the 2 ms slices:
	// the main thread is still free, so the round trip completes instead of
	// being left half-open.
	__block volatile int committed = 0;
	dispatch_async(dispatch_get_main_queue(), ^{
		[CATransaction begin];
		[CATransaction setCompletionBlock:^{ committed = 1; }];
		[CATransaction commit];
	});

	const double deadline = OpenQ4_NowSeconds() + 2.0;
	while (!committed && OpenQ4_NowSeconds() < deadline) {
		@autoreleasepool {
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
		}
	}
	OpenQ4_iOS_BlackBox("load prologue: overlay %s; entering blocking load",
						committed ? "committed" : "commit TIMED OUT after 2s");
}

void OpenQ4_iOS_LoadProgress(void) {
	// Deliberately does NOT touch UIKit. The caption is fixed for the whole
	// load: a per-100 ms label update queues a commit that only drains inside a
	// nested slice, which is a perpetual pending-commit treadmill and exactly
	// the half-open contract that gets the app killed. The asset name still
	// reaches the black box through the activity string.
	if (!g_loadOverlayUp) {
		OpenQ4_iOS_BeginBlockingLoad();
	}
}

/* Called from the frame loop: the load is over once normal frames resume. */
void OpenQ4_iOS_LoadProgressDone(void) {
	if (!g_loadOverlayUp) {
		return;
	}
	g_loadOverlayUp = 0;
	// Harmless belt-and-braces: the link is no longer paused on entry, but a
	// resume must stay unconditional so no future pause can strand the engine.
	OpenQ4_iOS_SetFrameLoopPaused(0);
	OpenQ4_iOS_SetBootStatus(NULL);   // hides the window; never releases it
	OpenQ4_iOS_BlackBox("load epilogue: frame loop resumed, overlay hidden");
}

int OpenQ4_iOS_InitCompleted(void) {
	return g_initComplete;
}

#if TARGET_OS_VISION
// OpenQ4VisionApp.swift: the window ornament (3D / gear) stays hidden until the
// engine exists — on the onboarding screen there is nothing to enter 3D with.
extern "C" void OpenQ4_SetEngineRunning(bool running);
#endif

void OpenQ4_iOS_InitComplete(void) {
	g_initComplete = 1;
	OpenQ4_iOS_BlackBox("init complete; run-loop servicing stays on for map loads");
#if TARGET_OS_VISION
	OpenQ4_SetEngineRunning(true);
#endif
}

/*
 * The engine installs its own POSIX signal handlers partway through Init, which
 * displaces ours — which is exactly why the SIGABRT that ended startup was
 * reported by the engine's three-line handler and not by our backtrace. Re-arm
 * ours, remembering the engine's so it still runs afterwards and keeps its own
 * phase reporting.
 */
static void OpenQ4_ReArmCrashHandlers(void) {
	void (*prev)(int) = signal(SIGABRT, OpenQ4_CrashHandler);
	if (prev != OpenQ4_CrashHandler && prev != SIG_ERR && prev != SIG_DFL) {
		g_engineAbrtHandler = prev;
	}
}

void OpenQ4_iOS_ServiceRunLoopDuringInit(void) {
	if (!pthread_main_np()) {
		return;
	}
	// Deliberately NOT gated on init being finished. Loading a map blocks the
	// main thread for a minute or more — the same unresponsiveness that iOS
	// kills for during startup, just triggered later. During gameplay the
	// engine barely prints, so this costs nothing there.
	if (!g_initComplete) {
		OpenQ4_ReArmCrashHandlers();
	}
	// Rate-limited: the engine prints thousands of lines during init and
	// re-entering the run loop on every one of them would dominate the cost of
	// the work being reported.
	static double lastService = 0.0;
	const double now = OpenQ4_NowSeconds();
	if (now - lastService < 0.05) {
		return;
	}
	lastService = now;

	@autoreleasepool {
		// Show what is loading while we are here. Startup is ~20 s on a
		// simulator and a minute on device, and a caption that never changes
		// reads as a hang — which is what it was reported as. The activity
		// string is already being maintained for the watchdog, so this costs
		// one label assignment per service tick.
		if (!g_initComplete && g_activity[0] != '\0') {
			char caption[256];
			snprintf(caption, sizeof(caption), "Loading Quake 4 data…\n%s", g_activity);
			OpenQ4_iOS_SetBootStatus(caption);
		}
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false);
#if !TARGET_OS_VISION
		// D-104 / Q-036. The renderer creates its SDL window inside this same
		// blocked init, and UIKit has been observed handing it a portrait
		// geometry a moment after creating it landscape. Whatever the engine
		// reads at THAT moment becomes glConfig for the life of the process —
		// nothing re-sizes the front end afterwards, only the swapchain. So the
		// re-pin has to run here, during init, not merely once init is over.
		// No-op until the metal view exists, and no-op once it already matches.
		if (!g_initComplete) {
			OpenQ4_iOS_RenderScaleRefreshLayer();
		}
#endif
	}
	OpenQ4_iOS_NoteMainAlive();
}

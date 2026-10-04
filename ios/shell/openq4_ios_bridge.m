/*
 * openq4_ios_bridge.m — remote console bridge (TCP :8774).
 *
 * Shape, and why:
 *
 *   listener thread   accepts one client at a time, reads newline-terminated
 *                     commands, pushes them onto a locked queue
 *   frame thread      OpenQ4_iOS_BridgeDrain() pops the queue and hands each
 *                     command to idCmdSystem
 *   output tee        stdout/stderr are dup2'd through a pipe so everything the
 *                     engine prints reaches BOTH the real fd (so
 *                     `simctl launch --console` still works) and the connected
 *                     client
 *
 * The queue exists because commands arrive on a socket thread while
 * idCmdSystem is not thread-safe. Handing a command straight to the engine from
 * the socket thread is the obvious mistake and produces rare, unreproducible
 * corruption.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import "../compat/openq4_ios_compat.h"
#include <arpa/inet.h>
#include <math.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <unistd.h>

#include "openq4_ios_bridge.h"
#include "openq4_ios_blackbox.h"
#include "openq4_ios_audiotest.h"
#include "openq4_ios_audio.h"
#include "openq4_ios_touch.h"
#include "openq4_ios_settings.h"
#include "openq4_ios_mods.h"
#include "openq4_ios_fontcheck.h"
#include "openq4_ios_mvkenv.h"

#if TARGET_OS_VISION
// Phase 6 stereo (D-100). visionOS only, and every use below is inside the same
// guard, so the iOS translation unit is textually what it always was.
#include "../shell-visionos/OpenQ4Vision3D.h"
#endif
#include "openq4_ios_url.h"

/*
 * OPENQ4_PUBLIC_BUILD (D-113): the public GitHub/SideStore build. The TCP
 * listener, the output tee and every `!` shell command below are NOT COMPILED
 * into it — not disabled, absent — so nothing in a public binary can open a
 * port or execute console text from outside the app. What stays is the locked
 * command queue and the frame loop, which the settings sheet and the deep-link
 * handler need in every build. OTA dev builds define OPENQ4_OTA_BUILD instead;
 * a build that claims to be both is a script bug, so refuse it.
 */
#if defined(OPENQ4_PUBLIC_BUILD) && defined(OPENQ4_OTA_BUILD)
#error "OPENQ4_PUBLIC_BUILD and OPENQ4_OTA_BUILD are mutually exclusive"
#endif

/*
 * Engine entry points reached from the bridge but living on the other side of
 * the shell/engine line (overlay patch 0005, src/sys/sdl3/sdl3_backend.cpp).
 */
extern int OpenQ4_iOS_SynthesizeMenuTap(float nx, float ny);
extern int OpenQ4_iOS_InjectPadState(float lookX, float lookY, float moveX, float moveY,
                                     float rightTrigger, int active);
extern void OpenQ4_iOS_PrintPadMenuState(void);

#define OPENQ4_BRIDGE_PORT 8774
#define OPENQ4_BRIDGE_MAX_QUEUE 64
#define OPENQ4_BRIDGE_MAX_CMD 1024

// Implemented on the engine side (overlay patch); keeps this file free of C++
// engine headers, which do not coexist happily with an ObjC translation unit.
extern void OpenQ4_iOS_BridgeExecuteCommand(const char *text);

static pthread_mutex_t g_queueLock = PTHREAD_MUTEX_INITIALIZER;
static char           *g_queue[OPENQ4_BRIDGE_MAX_QUEUE];
static int             g_queueCount = 0;
static int             g_clientFd = -1;
static volatile int    g_started = 0;

#if !defined(OPENQ4_PUBLIC_BUILD)
// Answered on the SOCKET thread, never queued. Any command that must work when
// the frame loop is dead has to bypass the engine entirely — otherwise the only
// tool for diagnosing a stalled frame loop is itself stalled.
static int BridgeHandleLocalCommand(const char *cmd);
#endif

// Engine-side (macosx_sdl3_main.cpp): the "press any key to continue" gate and
// the synthetic key that clears it.
extern int  OpenQ4_iOS_AwaitingContinue(void);
extern void OpenQ4_iOS_InjectContinueKey(void);

// Render-scale layer plumbing; defined with the rest of it further down.
static void OpenQ4_ApplyRenderScaleToLayer(void);
#if !defined(OPENQ4_PUBLIC_BUILD)
static void OpenQ4_SetRenderScaleLayerEnabled(bool enabled);
static bool OpenQ4_RenderScaleLayerEnabled(void);
#endif

static void BridgeQueuePush(const char *cmd) {
	pthread_mutex_lock(&g_queueLock);
	if (g_queueCount < OPENQ4_BRIDGE_MAX_QUEUE) {
		g_queue[g_queueCount++] = strdup(cmd);
	}
	pthread_mutex_unlock(&g_queueLock);
}

/*
 * The same queue, for UIKit code that has a console command to run.
 *
 * The settings sheet's "Connect" row is the first such caller: idCmdSystem is
 * not thread-safe and the sheet runs on the main thread, so a command from the
 * UI has to cross to the engine thread exactly the way a bridge command does.
 * Named for the queue rather than the bridge because the socket listener is
 * opt-in and this path must work in a build that never opens it.
 */
void OpenQ4_iOS_QueueConsoleCommand(const char *cmd) {
	if (cmd == NULL || cmd[0] == '\0') {
		return;
	}
	BridgeQueuePush(cmd);
}

#if !defined(OPENQ4_PUBLIC_BUILD)
/*
 * Mirror engine output to the connected client. Best-effort and non-fatal: a
 * disconnected client must never wedge the engine, so a failed write simply
 * drops the client.
 */
static void BridgeWriteToClient(const char *buf, ssize_t len) {
	const int fd = g_clientFd;
	if (fd < 0 || len <= 0) {
		return;
	}
	ssize_t off = 0;
	while (off < len) {
		const ssize_t n = send(fd, buf + off, (size_t)(len - off), 0);
		if (n <= 0) {
			return;
		}
		off += n;
	}
}

/*
 * stdout/stderr tee. Both fds are redirected into a pipe; this thread reads the
 * pipe and writes to the ORIGINAL fd as well as the client, so console output
 * is not stolen from `simctl launch --console`.
 */
static int g_realStdout = -1;

static void *BridgeOutputThread(void *arg) {
	int readFd = (int)(intptr_t)arg;
	char buf[2048];
	for (;;) {
		const ssize_t n = read(readFd, buf, sizeof(buf));
		if (n <= 0) {
			if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
				continue;
			}
			break;
		}
		if (g_realStdout >= 0) {
			ssize_t off = 0;
			while (off < n) {
				const ssize_t w = write(g_realStdout, buf + off, (size_t)(n - off));
				if (w <= 0) break;
				off += w;
			}
		}
		BridgeWriteToClient(buf, n);
	}
	return NULL;
}

static void BridgeInstallOutputTee(void) {
	int fds[2];
	if (pipe(fds) != 0) {
		return;
	}
	g_realStdout = dup(STDOUT_FILENO);
	setvbuf(stdout, NULL, _IOLBF, 0);   // line-buffered: a crash must not eat the tail
	dup2(fds[1], STDOUT_FILENO);
	dup2(fds[1], STDERR_FILENO);
	close(fds[1]);

	pthread_t tid;
	if (pthread_create(&tid, NULL, BridgeOutputThread, (void *)(intptr_t)fds[0]) == 0) {
		pthread_detach(tid);
	}
}

static void *BridgeListenThread(void *unused) {
	(void)unused;

	int listenFd = socket(AF_INET, SOCK_STREAM, 0);
	if (listenFd < 0) {
		fprintf(stderr, "openQ4 bridge: socket() failed: %s\n", strerror(errno));
		return NULL;
	}
	int yes = 1;
	setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

	/*
	 * The port is :8774 (the program's allocation for this port), but it can be
	 * moved with OPENQ4_BRIDGE_PORT — every simulator on this Mac shares the
	 * host's loopback, so two concurrent sessions testing an iOS and a visionOS
	 * build at the same time otherwise fight over one socket: the second app
	 * silently loses the bind and the first one answers the second session's
	 * commands. scripts/ios-console.sh already reads the same variable.
	 */
	int bridgePort = OPENQ4_BRIDGE_PORT;
	{
		const char *portEnv = getenv("OPENQ4_BRIDGE_PORT");
		if (portEnv != NULL && *portEnv != '\0') {
			const long parsed = strtol(portEnv, NULL, 10);
			if (parsed > 0 && parsed < 65536) {
				bridgePort = (int)parsed;
			} else {
				fprintf(stderr, "openQ4 bridge: ignoring OPENQ4_BRIDGE_PORT='%s' (not a port)\n", portEnv);
			}
		}
	}

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	addr.sin_port = htons(bridgePort);

	// A previous instance that has just been killed can still hold the port for
	// a few seconds. Retry rather than losing the bridge for the whole session —
	// this is exactly the case where the bridge is most wanted.
	int bound = 0;
	for (int attempt = 0; attempt < 60; attempt++) {
		if (bind(listenFd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
			bound = 1;
			break;
		}
		usleep(500 * 1000);
	}
	if (!bound) {
		fprintf(stderr, "openQ4 bridge: bind(:%d) failed: %s\n", bridgePort, strerror(errno));
		close(listenFd);
		return NULL;
	}
	if (listen(listenFd, 1) != 0) {
		fprintf(stderr, "openQ4 bridge: listen() failed: %s\n", strerror(errno));
		close(listenFd);
		return NULL;
	}

	fprintf(stdout, "openQ4 bridge: listening on :%d\n", bridgePort);

	for (;;) {
		const int fd = accept(listenFd, NULL, NULL);
		if (fd < 0) {
			if (errno == EINTR) continue;
			break;
		}
		g_clientFd = fd;
		const char *hello = "openQ4 console bridge ready\n";
		send(fd, hello, strlen(hello), 0);

		char line[OPENQ4_BRIDGE_MAX_CMD];
		int used = 0;
		for (;;) {
			char c;
			const ssize_t n = recv(fd, &c, 1, 0);
			if (n <= 0) {
				break;
			}
			if (c == '\n' || c == '\r') {
				if (used > 0) {
					line[used] = '\0';
					if (!BridgeHandleLocalCommand(line)) {
						BridgeQueuePush(line);
					}
					used = 0;
				}
				continue;
			}
			if (used < (int)sizeof(line) - 1) {
				line[used++] = c;
			}
		}
		g_clientFd = -1;
		close(fd);
	}

	close(listenFd);
	return NULL;
}

/*
 * On in OTA builds, off in public ones — the charter's split, which was never
 * actually implemented: the env-var gate meant no device build ever started the
 * bridge, so every diagnosis has gone through log files the maintainer had to fetch by
 * hand. OPENQ4_OTA_BUILD is defined by publish-ota.sh.
 *
 * OPENQ4_CONSOLE_BRIDGE=0 still turns it off explicitly.
 *
 * Factored out of BridgeStart because `openq4://console/` (D-096) must be gated
 * by the same rule, and two copies of a security gate is one too many.
 */
bool OpenQ4_iOS_BridgeEnabled(void) {
	const char *enabled = getenv("OPENQ4_CONSOLE_BRIDGE");
#if defined(OPENQ4_OTA_BUILD)
	return !(enabled != NULL && strcmp(enabled, "0") == 0);
#else
	return (enabled != NULL && strcmp(enabled, "1") == 0);
#endif
}

void OpenQ4_iOS_BridgeStart(void) {
	if (g_started) {
		return;
	}
	if (!OpenQ4_iOS_BridgeEnabled()) {
		return;
	}
	g_started = 1;

	BridgeInstallOutputTee();

	pthread_t tid;
	if (pthread_create(&tid, NULL, BridgeListenThread, NULL) == 0) {
		pthread_detach(tid);
	} else {
		fprintf(stderr, "openQ4 bridge: failed to start listener thread\n");
	}
}
#else /* OPENQ4_PUBLIC_BUILD */
/* No listener exists in this build; no environment variable can conjure one. */
bool OpenQ4_iOS_BridgeEnabled(void) {
	return false;
}

void OpenQ4_iOS_BridgeStart(void) {
	(void)g_started;
	(void)g_clientFd;
}
#endif /* !OPENQ4_PUBLIC_BUILD */

#if !defined(OPENQ4_PUBLIC_BUILD)

/*
 * !views — the window's view hierarchy, as a logged fact.
 *
 * The touch overlay is UIKit, and UIKit placement is invisible to an engine
 * screenshot: a control that is present, unhidden and correctly laid out but
 * BURIED under a later sibling photographs exactly like one that was never
 * created (D-082). Subview order is the whole answer there, so print it —
 * class, index among its siblings, frame, hidden/alpha, hit-testability — and
 * flag the two views that matter: the touch overlay and whichever view owns
 * the CAMetalLayer the engine draws into.
 */
static void OpenQ4_DumpViewTree(UIView *v, int depth, int index, int siblings) {
	char indent[64];
	int pad = depth * 2;
	if (pad > 62) { pad = 62; }
	memset(indent, ' ', (size_t)pad);
	indent[pad] = '\0';

	const char *mark = "";
	if ([v isKindOfClass:NSClassFromString(@"OpenQ4TouchView")]) {
		mark = "   <== TOUCH OVERLAY";
	} else if (v.tag == OPENQ4_CURTAIN_TAG) {
		mark = "   <== 3D CURTAIN";
	} else if ([v.layer isKindOfClass:CAMetalLayer.class]) {
		mark = "   <== ENGINE METAL VIEW";
	}

	fprintf(stdout, "  %s[%d/%d] %s frame=(%.0f,%.0f %.0fx%.0f) hidden=%d alpha=%.2f opaque=%d ui=%d layer=%s%s\n",
			indent, index, siblings, NSStringFromClass(v.class).UTF8String,
			v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height,
			v.hidden ? 1 : 0, v.alpha, v.isOpaque ? 1 : 0, v.userInteractionEnabled ? 1 : 0,
			NSStringFromClass(v.layer.class).UTF8String, mark);

	int n = (int)v.subviews.count;
	for (int i = 0; i < n; i++) {
		OpenQ4_DumpViewTree(v.subviews[i], depth + 1, i, n);
	}
}

static void OpenQ4_PrintViewHierarchy(void) {
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			fprintf(stdout, "openQ4 views: window %p key=%d level=%.0f rootVC=%s\n",
					(void *)(__bridge void *)w, w.isKeyWindow ? 1 : 0, (double)w.windowLevel,
					w.rootViewController != nil
						? NSStringFromClass(w.rootViewController.class).UTF8String : "(nil)");
			int n = (int)w.subviews.count;
			for (int i = 0; i < n; i++) {
				OpenQ4_DumpViewTree(w.subviews[i], 1, i, n);
			}
			// The one-line verdict, so a run does not have to be read by eye:
			// the overlay has to be the LAST direct subview of the window, or
			// something drawn later is sitting on top of it.
			UIView *overlay = nil;
			int overlayIndex = -1;
			for (int i = 0; i < n; i++) {
				if ([w.subviews[i] isKindOfClass:NSClassFromString(@"OpenQ4TouchView")]) {
					overlay = w.subviews[i];
					overlayIndex = i;
				}
			}
			if (overlay != nil) {
				fprintf(stdout, "openQ4 views: overlay is direct subview %d of %d — topmost=%s\n",
						overlayIndex, n, (overlayIndex == n - 1) ? "YES" : "NO (BURIED)");
			} else {
				fprintf(stdout, "openQ4 views: overlay is NOT a direct subview of this window\n");
			}
			/*
			 * The curtain's verdict, in the same one-line form (D-106).
			 *
			 * This is the ONLY artifact the simulator can produce for the
			 * frozen-frame defect: the sim's 2D window keeps presenting
			 * whatever it last held, so a black card and a card showing the
			 * frozen game photograph identically there. What DOES distinguish
			 * them is whether the curtain is on this window at all, whether it
			 * is the last subview, and whether it is actually opaque — which
			 * is exactly what was wrong on device (the curtain landed on the
			 * ornament's hosting window, which is not this one).
			 */
			UIView *curtain = nil;
			int curtainIndex = -1;
			for (int i = 0; i < n; i++) {
				if (w.subviews[i].tag == OPENQ4_CURTAIN_TAG) {
					curtain = w.subviews[i];
					curtainIndex = i;
				}
			}
			if (curtain != nil) {
				const BOOL solid = !curtain.hidden && curtain.alpha >= 0.999
					&& curtain.isOpaque && curtainIndex == n - 1;
				fprintf(stdout, "openQ4 views: 3D curtain is direct subview %d of %d — "
						"hidden=%d alpha=%.2f opaque=%d topmost=%s — VERDICT %s\n",
						curtainIndex, n, curtain.hidden ? 1 : 0, curtain.alpha,
						curtain.isOpaque ? 1 : 0,
						(curtainIndex == n - 1) ? "YES" : "NO (BURIED)",
						solid ? "OPAQUE AND ON TOP" : "NOT PROVEN OPAQUE");
			} else {
				fprintf(stdout, "openQ4 views: no 3D curtain on this window "
						"(expected unless 3D is on)\n");
			}
		}
	}
	fflush(stdout);
}

/*
 * Shell-local commands, prefixed '!' so they can never collide with an engine
 * command. Handled on the socket thread, so they still answer when the frame
 * loop is dead — which is exactly when they are needed.
 *
 *   !framelink   display-link health
 *   !ping        liveness of the bridge itself
 *   !touch       force the control overlay visible/hidden/auto
 *   !settings    open the iOS settings sheet
 *   !settingsback  press a pushed sub-page's "< Back", through its own action
 *   !settingsdone  press "Done" and dismiss the sheet
 *   !set k v     move one setting through the same path its slider uses
 *   !fonttest    report per-glyph ink from the UIKit font, for the missing letters
 *   !audiotest   play a raw-AL tone, bypassing the engine mixer
 *   !audiosession  the live AVAudioSession: mode, category, decoded options,
 *                whether they match the mode, whether anyone is being ducked,
 *                activation, isOtherAudioPlaying, and the game-side gain
 *   !layout      print the touch layout, for pasting back as the default
 *   !views       print the touch overlay's visibility state (pad detection,
 *                in-game verdict, always-show) and the window's view hierarchy
 *                in subview order, with the
 *                touch overlay and the engine's Metal view flagged; the last
 *                line says whether the overlay is still topmost (D-082)
 *   !layoutedit  enter the drag-to-move layout editor
 *   !pace        frame-pacing mode and its counters; !pace 0/1 switches live
 *   !renderscale render resolution percent; `!renderscale 75` applies live
 *   !renderscalelayer  0 disables the CAMetalLayer half of the render scale, for
 *                      A/Bing the swapchain-recreate counters against the
 *                      pre-0.1.0.40 behaviour; 1 restores it
 *   !touchtap    tap at a normalised view point: `!touchtap 0.5 0.5` is the
 *                centre of the screen, i.e. exactly where the crosshair points.
 *                Runs the overlay's real publish-and-click path (D-071).
 *   !menutap     tap a MENU at a normalised view point. Runs the engine's own
 *                SDL finger handler, i.e. the absolute-cursor + K_MOUSE1 path a
 *                real finger takes when the overlay declines the touch (D-086).
 *   !pad         drive a SYNTHETIC gamepad, for a simulator that has none:
 *                `!pad <x> <y> [rt] [left]` holds the stick at x,y (-1..1, +y
 *                DOWN) with the right trigger optionally pulled; `left` drives
 *                the LEFT stick instead of the right. `!pad off` releases it,
 *                `!pad` alone prints the pad and menu-cursor state. Goes through
 *                the shipping SDL3_ApplyGamepadAxisState, so the menu cursor,
 *                the trigger click and upstream's own menu navigation are all
 *                the real path with made-up numbers (D-103).
 *   !chrome      press a chrome button through its real target/action:
 *                `!chrome pause` is the hamburger, `objectives`, `settings`.
 *   !gyro        inject ONE synthetic device-motion sample, in the engine's own
 *                view degrees: `!gyro 30 0` should move getviewpos's yaw by 30
 *                at gyro sensitivity 100%%. Runs the real gate, gravity
 *                projection, deadzone, sensitivity and invert (D-083) — the
 *                simulator has no gyro, so this is the only way to verify it
 *                before hardware. Prints what it produced, or why it refused.
 *   !rumble      controller rumble in one step (D-111): `!rumble` prints the
 *                pad, whether SDL says it can rumble, the request/send counters
 *                and SDL's last answer; `!rumble pulse [low high ms]` buzzes
 *                the pad once (default full for 500 ms) and prints the result;
 *                `!rumble virtual` / `!rumble novirtual` attach/detach an SDL
 *                virtual pad that counts driver calls (iOS simulator proof);
 *                `!rumble reset` zeroes the counters (D-112: the "sound
 *                shape" line — runs, longest run, peak — reads one scene).
 *   !xr3d       visionOS: enter/leave the world-locked 3D panel.
 *                `!xr3d 1` opens the ImmersiveSpace and points the engine at
 *                its offscreen present image; `!xr3d 0` returns to the window.
 *   !settings    open the settings sheet, optionally at a section;
 *                `!settings off` closes it again
 *   !xr3dtune    visionOS: live stereo + panel tuning,
 *                `!xr3dtune <sep> <conv> [dist halfW halfH height dim]`
 *   !xr3diag     visionOS: one line of compositor + engine 3D state
 *   !continue    clear the post-load "press any key to continue" gate
 *   !xrwin       visionOS: request a 2D window size in points,
 *                `!xrwin <w> <h>`. A test lever — the lane simulator's
 *                persisted window is already the park's 480 pt card, so
 *                without this the park resizes nothing there.
 *   !mvkenv      MoltenVK / OpenAL env overrides applied before main():
 *                list, `!mvkenv KEY VALUE`, `!mvkenv clear`. Keys must start
 *                with MVK_CONFIG_ or ALSOFT_ (e.g. ALSOFT_LOGLEVEL 3).
 *                A written key takes effect on the NEXT launch.
 */
static int BridgeHandleLocalCommand(const char *cmd) {
	if (cmd == NULL || cmd[0] != '!') {
		return 0;
	}
	if (strcmp(cmd, "!framelink") == 0) {
		OpenQ4_iOS_ReportFrameLoop();
		return 1;
	}
	if (strcmp(cmd, "!urlinfo") == 0) {
		OpenQ4_iOS_ReportURLHandler();
		return 1;
	}
	if (strncmp(cmd, "!url ", 5) == 0) {
		// Exercise the deep-link parser without the OS in the way — the system
		// "Open in openQ4?" confirmation makes simctl openurl a two-step
		// gesture, and this proves the routing half on its own.
		OpenQ4_iOS_HandleURL(cmd + 5);
		return 1;
	}
	if (strcmp(cmd, "!ping") == 0) {
		fprintf(stdout, "openQ4 bridge: pong (socket thread)\n");
		fflush(stdout);
		return 1;
	}
#if TARGET_OS_VISION
	/*
	 * `!xr3d 0|1` — enter/leave the 3D panel mode, and `!xr3diag` — one line of
	 * everything the compositor and the engine know about it
	 * (docs/stereo-design.md §7). The field list of the diag line is the spec
	 * even where this round cannot fill it: what is not measured yet reports
	 * n/a rather than being left out, so the shape never changes under a reader.
	 */
	/*
	 * `!xr3dtune <sep> <conv> [dist halfW halfH height dim]` — every live stereo
	 * and panel knob in one command, so a hardware session can sweep them over
	 * the tailnet bridge without a rebuild and without operating a settings
	 * sheet from inside a headset. Same path the sheet takes.
	 */
	/*
	 * `!xrwin <w> <h>` — resize the 2D window, in points. A test lever (D-102):
	 * the simulator's persisted window is already the park's 480 pt card, so
	 * without this the park is a no-op there and the exit path's real
	 * swapchain-extent change cannot be exercised on the lane at all.
	 */
	if (strncmp(cmd, "!xrwin", 6) == 0) {
		double w = 0.0, h = 0.0;
		if (sscanf(cmd + 6, "%lf %lf", &w, &h) == 2 && w >= 200.0 && h >= 120.0
				&& w <= 4000.0 && h <= 4000.0) {
			OpenQ4_Vision3D_RequestWindowSizePt(w, h);
			fprintf(stdout, "openQ4 xrwin: requested %.0fx%.0f pt\n", w, h);
		} else {
			fprintf(stdout, "openQ4 xrwin: usage !xrwin <width-pt> <height-pt> "
					"(200..4000)\n");
		}
		fflush(stdout);
		return 1;
	}
	if (strncmp(cmd, "!xr3dtune", 9) == 0) {
		float v[7] = { 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };
		const int n = sscanf(cmd + 9, "%f %f %f %f %f %f %f",
							 &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6]);
		if (n < 2) {
			fprintf(stdout, "openQ4 bridge: usage: !xr3dtune <sep> <conv> "
							"[dist halfW halfH height dim]\n");
			fflush(stdout);
			return 1;
		}
		OpenQ4_Vision3D_Tune(v[0], v[1],
							 (n >= 5) ? &v[2] : NULL,
							 (n >= 5) ? &v[3] : NULL,
							 (n >= 5) ? &v[4] : NULL,
							 (n >= 6) ? &v[5] : NULL,
							 (n >= 7) ? &v[6] : NULL);
		fprintf(stdout, "openQ4 xr3dtune: %d value(s) applied\n", n);
		fflush(stdout);
		return 1;
	}
	if (strncmp(cmd, "!xr3diag", 8) == 0) {
		char line[1024];
		OpenQ4_Vision3D_DiagLine(line, sizeof(line));
		fprintf(stdout, "openQ4 xr3diag: %s\n", line);
		fflush(stdout);
		return 1;
	}
	if (strncmp(cmd, "!xr3d", 5) == 0) {
		const char *arg = cmd + 5;
		while (*arg == ' ') { arg++; }
		if (*arg == '0' || *arg == '1') {
			OpenQ4_Vision3D_Set(*arg - '0');
		} else if (*arg != '\0') {
			fprintf(stdout, "openQ4 bridge: usage: !xr3d [0|1]\n");
			fflush(stdout);
			return 1;
		} else {
			OpenQ4_Vision3D_Set(OpenQ4_Vision3D_IsOn() ? 0 : 1);
		}
		// What was ASKED for. The state itself flips on the main queue, so
		// reading it back here would report the state this command is about to
		// change away from — which is exactly backwards, and read that way in
		// the round-2 transcripts before it was fixed.
		fprintf(stdout, "openQ4 xr3d: %s requested\n",
				(*arg == '0') ? "2D" : (*arg == '1') ? "3D"
					: (OpenQ4_Vision3D_IsOn() ? "2D" : "3D"));
		fflush(stdout);
		return 1;
	}
#endif
	/*
	 * `!touchtap <nx> <ny>` — a tap at a normalised view point, origin top-left,
	 * 0.5 0.5 being the centre of the screen (and therefore the crosshair).
	 *
	 * It runs the overlay's own publish-and-click path, not a copy of it: a
	 * harness that re-implements the behaviour it tests passes while the product
	 * is broken (dhewm3-ios D-014). The only thing it cannot do is manufacture a
	 * UITouch, so UIKit's delivery is the one step not exercised.
	 */
	/*
	 * `!menutap <nx> <ny>` — a tap on a MENU, at the same normalised point.
	 *
	 * Different path from `!touchtap` and deliberately so. The overlay declines
	 * bare touches while the playing controls are down (hitTest returns nil),
	 * UIKit hands them to SDL's view, and SDL posts a finger event; this calls
	 * the engine's own finger handler with that event, so everything from
	 * SDL3_HandleFingerEvent inwards — menu routing, the absolute cursor, the
	 * K_MOUSE1 pair — is the shipping code. Only SDL's delivery is skipped.
	 */
	/*
	 * `!pad <x> <y> [rt] [left]` — a synthetic gamepad (D-103).
	 *
	 * The lane simulators cannot be given a controller, so the pad menu cursor
	 * and its right-trigger click would otherwise be device-only. The state is
	 * HELD until changed: `!pad 0.9 0` pushes the stick and leaves it there,
	 * `!pad 0 0 rt` centres it and pulls the trigger, `!pad off` lets go. A real
	 * controller wins — the engine refuses to inject while one is attached.
	 */
	if (strncmp(cmd, "!pad", 4) == 0 && (cmd[4] == '\0' || cmd[4] == ' ')) {
		const char *arg = cmd + 4;
		while (*arg == ' ') { arg++; }
		if (*arg == '\0') {
			OpenQ4_iOS_PrintPadMenuState();
			return 1;
		}
		if (strncmp(arg, "off", 3) == 0) {
			OpenQ4_iOS_InjectPadState(0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0);
			fprintf(stdout, "openQ4 pad: synthetic pad released\n");
			fflush(stdout);
			return 1;
		}
		double x = 0.0, y = 0.0;
		int consumed = 0;
		if (sscanf(arg, "%lf %lf%n", &x, &y, &consumed) != 2) {
			fprintf(stdout, "openQ4 bridge: usage: !pad <x> <y> [rt] [left] | !pad off | !pad\n");
			fflush(stdout);
			return 1;
		}
		const char *flags = arg + consumed;
		const int wantTrigger = (strstr(flags, "rt") != NULL) ? 1 : 0;
		const int wantLeft = (strstr(flags, "left") != NULL) ? 1 : 0;
		const float fx = (float)x;
		const float fy = (float)y;
		const int ok = OpenQ4_iOS_InjectPadState(wantLeft ? 0.0f : fx, wantLeft ? 0.0f : fy,
												 wantLeft ? fx : 0.0f, wantLeft ? fy : 0.0f,
												 wantTrigger ? 1.0f : 0.0f, 1);
		fprintf(stdout, "openQ4 pad: %s stick %.2f,%.2f trigger=%d%s\n",
				wantLeft ? "left" : "right", x, y, wantTrigger,
				ok ? "" : "  (REFUSED: a real controller is attached)");
		fflush(stdout);
		OpenQ4_iOS_PrintPadMenuState();
		return 1;
	}
	/*
	 * !rumble — routed to the engine's own rumbleStatus / rumbleTest commands
	 * through the frame-thread queue, because SDL's joystick calls belong on the
	 * thread that pumps SDL events, not on this socket thread.
	 */
	if (strncmp(cmd, "!rumble", 7) == 0 && (cmd[7] == '\0' || cmd[7] == ' ')) {
		const char *arg = cmd + 7;
		while (*arg == ' ') { arg++; }
		char line[256];
		if (*arg == '\0') {
			snprintf(line, sizeof(line), "rumbleStatus");
		} else if (strncmp(arg, "pulse", 5) == 0) {
			snprintf(line, sizeof(line), "rumbleTest%s", arg + 5);
		} else if (strcmp(arg, "virtual") == 0 || strcmp(arg, "novirtual") == 0) {
			snprintf(line, sizeof(line), "rumbleTest %s", arg);
		} else if (strcmp(arg, "reset") == 0) {
			// D-112: zero the counters so one scene's rumble shape reads alone.
			snprintf(line, sizeof(line), "rumbleStatus reset");
		} else {
			fprintf(stdout, "openQ4 bridge: usage: !rumble | !rumble reset | !rumble pulse [low high ms] | !rumble virtual | !rumble novirtual\n");
			fflush(stdout);
			return 1;
		}
		BridgeQueuePush(line);
		return 1;
	}
	if (strncmp(cmd, "!menutap", 8) == 0) {
		double nx = 0.5, ny = 0.5;
		const char *arg = cmd + 8;
		while (*arg == ' ') { arg++; }
		if (sscanf(arg, "%lf %lf", &nx, &ny) != 2 || nx < 0.0 || nx > 1.0 || ny < 0.0 || ny > 1.0) {
			fprintf(stdout, "openQ4 bridge: usage: !menutap <nx> <ny>  (0..1, origin top-left)\n");
			fflush(stdout);
			return 1;
		}
		OpenQ4_iOS_SynthesizeMenuTap((float)nx, (float)ny);
		return 1;
	}
	// Ahead of `!touch` deliberately: that one is a strncmp on six characters,
	// so it matches "!touchtap" too and silently swallowed every tap — the
	// command appeared to work (the bridge answered) and did nothing.
	if (strncmp(cmd, "!touchtap", 9) == 0) {
		double nx = 0.5, ny = 0.5;
		const char *arg = cmd + 9;
		while (*arg == ' ') { arg++; }
		if (*arg != '\0' && sscanf(arg, "%lf %lf", &nx, &ny) != 2) {
			fprintf(stdout, "openQ4 bridge: usage: !touchtap [<nx> <ny>]  (0..1, origin top-left)\n");
			fflush(stdout);
			return 1;
		}
		if (nx < 0.0 || nx > 1.0 || ny < 0.0 || ny > 1.0) {
			fprintf(stdout, "openQ4 bridge: touchtap out of range: %g %g\n", nx, ny);
			fflush(stdout);
			return 1;
		}
		OpenQ4_iOS_TouchSynthesizeTap((float)nx, (float)ny);
		return 1;
	}
	// The simulator cannot reach gameplay (no BC textures, no layered
	// attachments), so overlay visibility would otherwise never follow
	// OpenQ4_iOS_InGame() there and its layout could never be screenshotted.
	if (strncmp(cmd, "!touch", 6) == 0) {
		const char *arg = cmd + 6;
		while (*arg == ' ') { arg++; }
		int mode = -1;
		if (strcmp(arg, "on") == 0) { mode = 1; }
		else if (strcmp(arg, "off") == 0) { mode = 0; }
		OpenQ4_iOS_TouchSetVisible(mode);
		fprintf(stdout, "openQ4 bridge: touch overlay %s\n",
				mode == 1 ? "forced visible" : (mode == 0 ? "forced hidden" : "following engine state"));
		fflush(stdout);
		return 1;
	}
	if (strncmp(cmd, "!chrome", 7) == 0) {
		const char *arg = cmd + 7;
		while (*arg == ' ') { arg++; }
		if (*arg == '\0') {
			fprintf(stdout, "openQ4 bridge: usage: !chrome pause|objectives|settings\n");
			fflush(stdout);
			return 1;
		}
		OpenQ4_iOS_TouchPressChrome(arg);
		return 1;
	}
	if (strcmp(cmd, "!layoutedit") == 0) {
		OpenQ4_iOS_TouchBeginLayoutEdit();
		return 1;
	}
	if (strncmp(cmd, "!pace", 5) == 0) {
		const char *arg = cmd + 5;
		while (*arg == ' ') { arg++; }
		if (*arg == '0' || *arg == '1') {
			OpenQ4_iOS_SetPaceMode(*arg - '0');
		} else if (*arg != '\0') {
			fprintf(stdout, "openQ4 bridge: usage: !pace [0|1]\n");
			fflush(stdout);
			return 1;
		}
		OpenQ4_iOS_ReportFrameLoop();
		return 1;
	}
	// Before !renderscale: the prefix test below would swallow this one.
	if (strncmp(cmd, "!renderscalelayer", 17) == 0) {
		const char *arg = cmd + 17;
		while (*arg == ' ') { arg++; }
		if (*arg == '0' || *arg == '1') {
			OpenQ4_SetRenderScaleLayerEnabled(*arg == '1');
		} else if (*arg != '\0') {
			fprintf(stdout, "openQ4 bridge: usage: !renderscalelayer [0|1]\n");
			fflush(stdout);
			return 1;
		}
		fprintf(stdout, "openQ4 render scale: layer scaling %s\n",
				OpenQ4_RenderScaleLayerEnabled() ? "on" : "off (engine computes its own size)");
		fflush(stdout);
		return 1;
	}
	if (strncmp(cmd, "!renderscale", 12) == 0) {
		const char *arg = cmd + 12;
		while (*arg == ' ') { arg++; }
		if (*arg != '\0') {
			const int requested = atoi(arg);
			if (requested < 50 || requested > 100) {
				fprintf(stdout, "openQ4 bridge: usage: !renderscale [50..100]\n");
				fflush(stdout);
				return 1;
			}
			// Through the settings path, so the bridge and the Display row are
			// the same switch and a value set here survives a relaunch.
			OpenQ4_iOS_SetRenderScaleSettingPercent(requested);
		}
		fprintf(stdout, "openQ4 render scale: %d%%\n", OpenQ4_iOS_RenderScalePercent());
		fflush(stdout);
		return 1;
	}
	if (strncmp(cmd, "!mvkenv", 7) == 0) {
		const char *arg = cmd + 7;
		while (*arg == ' ') { arg++; }
		if (*arg == '\0') {
			OpenQ4_iOS_MvkEnvReport();
			return 1;
		}
		if (strcmp(arg, "clear") == 0) {
			OpenQ4_iOS_MvkEnvClear();
			fprintf(stdout, "openQ4 mvkenv: cleared; takes effect on next launch\n");
			fflush(stdout);
			return 1;
		}
		char key[128] = {0};
		char value[128] = {0};
		if (sscanf(arg, "%127s %127s", key, value) == 2) {
			if (OpenQ4_iOS_MvkEnvSet(key, value) == 0) {
				fprintf(stdout, "openQ4 mvkenv: %s=%s written; takes effect on next launch\n", key, value);
			} else {
				fprintf(stdout, "openQ4 mvkenv: refused '%s' (keys must start with MVK_CONFIG_ or ALSOFT_)\n", key);
			}
		} else {
			fprintf(stdout, "openQ4 bridge: usage: !mvkenv | !mvkenv KEY VALUE | !mvkenv clear\n");
			fprintf(stdout, "openQ4 bridge:   KEY must start with MVK_CONFIG_ or ALSOFT_ (e.g. ALSOFT_LOGLEVEL 3)\n");
		}
		fflush(stdout);
		return 1;
	}
	if (strcmp(cmd, "!layout") == 0) {
		OpenQ4_iOS_TouchPrintLayout();
		return 1;
	}
	/*
	 * `!gyro <dyaw> <dpitch>` — one synthetic motion sample (D-083).
	 *
	 * Arguments are in the ENGINE's view degrees, the same convention
	 * OpenQ4_iOS_InjectLook takes, so a run can read `getviewpos` before and
	 * after and compare against the number it asked for. They are turned back
	 * into a (rotationRate, gravity, dt) triple and pushed through the real
	 * sample path — mode gate included, which is why `!gyro` in a menu, with the
	 * mode Off, or with "While Aiming" and no finger down, correctly does
	 * nothing and says so.
	 */
	if (strncmp(cmd, "!gyro", 5) == 0) {
		const char *arg = cmd + 5;
		while (*arg == ' ') { arg++; }
		if (*arg == '\0') {
			OpenQ4_iOS_TouchPrintGyroState();
			fprintf(stdout, "openQ4 bridge: usage: !gyro <dyaw> <dpitch>  (engine view degrees)\n");
			fflush(stdout);
			return 1;
		}
		double dyaw = 0.0, dpitch = 0.0;
		if (sscanf(arg, "%lf %lf", &dyaw, &dpitch) != 2) {
			fprintf(stdout, "openQ4 bridge: usage: !gyro <dyaw> <dpitch>  (engine view degrees)\n");
			fflush(stdout);
			return 1;
		}
		// A sample this large is not a wrist; it is a typo, and it would arrive
		// as one instant spin that reads like a bug in the mapping.
		if (fabs(dyaw) > 180.0 || fabs(dpitch) > 180.0) {
			fprintf(stdout, "openQ4 bridge: gyro sample out of range: %g %g (max 180 per axis)\n",
					dyaw, dpitch);
			fflush(stdout);
			return 1;
		}
		const int applied = OpenQ4_iOS_TouchInjectGyro((float)dyaw, (float)dpitch);
		fprintf(stdout, "openQ4 bridge: gyro sample %s\n", applied ? "applied" : "refused by the gate");
		fflush(stdout);
		return 1;
	}
	/*
	 * `!forcepad 0|1|off` — a synthetic "a pad is driving the game" for the
	 * Touch Controls row's Auto mode (D-106). A TEST LEVER, like `!xrwin`: no
	 * controller can be paired to a simulator, so Auto's whole behaviour would
	 * otherwise be unphotographable. `!pad` (D-103) drives the engine's input,
	 * not GameController, so it cannot answer this question.
	 */
	if (strncmp(cmd, "!forcepad", 9) == 0 && (cmd[9] == '\0' || cmd[9] == ' ')) {
		const char *arg = (cmd[9] == ' ') ? cmd + 10 : "";
		while (*arg == ' ') { arg++; }
		int state;
		if (strncmp(arg, "off", 3) == 0 || arg[0] == '\0') {
			state = -1;
		} else {
			state = (atoi(arg) != 0) ? 1 : 0;
		}
		OpenQ4_iOS_TouchForcePad(state);
		fprintf(stdout, "openQ4 bridge: forcepad %s\n",
				state < 0 ? "released (real controllers again)"
						  : (state ? "held (pretending a pad is connected)"
								   : "held (pretending no pad is connected)"));
		fflush(stdout);
		return 1;
	}
	if (strcmp(cmd, "!views") == 0) {
		// Both halves of the same question: where the overlay sits, and whether
		// it believes it should be showing anything at all.
		OpenQ4_iOS_TouchPrintState();
		dispatch_async(dispatch_get_main_queue(), ^{ OpenQ4_PrintViewHierarchy(); });
		return 1;
	}
	/*
	 * !audiosession — the AVAudioSession as it actually is, not as the settings
	 * row claims. D-087 was two lines of readback away the whole time: the
	 * options carried DuckOthers in modes that exist to leave other audio alone.
	 * The simulator runs a real AVAudioSession, so category and options are
	 * verifiable there even though ducking a real podcast is not.
	 */
	if (strcmp(cmd, "!audiosession") == 0) {
		OpenQ4_iOS_PrintAudioSessionState();
		return 1;
	}
	if (strcmp(cmd, "!audiotest") == 0) {
		OpenQ4_iOS_AudioSelfTest();
		return 1;
	}
	if (strcmp(cmd, "!settings") == 0 || strncmp(cmd, "!settings ", 10) == 0) {
		// Optional section name, so a run can photograph a section that is
		// below the fold on a device nobody can scroll. `Section#key` goes
		// further and puts THAT ROW at the top (D-105: the 3D section is longer
		// than a screen, so `!settings 3D` cannot photograph its lower rows).
		const char *section = (cmd[9] == ' ') ? cmd + 10 : NULL;
		while (section != NULL && *section == ' ') { section++; }
		// ...and `off` to close it again. Without this a scripted run could
		// open the sheet and never shut it, so every later screenshot in the
		// round carried a sheet floating over whatever it was meant to show.
		if (section != NULL && strcmp(section, "off") == 0) {
			OpenQ4_iOS_HideSettings();
			fprintf(stdout, "openQ4 bridge: settings sheet dismissed\n");
			fflush(stdout);
			return 1;
		}
		OpenQ4_iOS_ShowSettingsSection(section);
		fprintf(stdout, "openQ4 bridge: settings sheet requested%s%s\n",
				(section != NULL && *section != '\0') ? " at section " : "",
				(section != NULL && *section != '\0') ? section : "");
		fflush(stdout);
		return 1;
	}
	/*
	 * !set <key> <value> — move a setting exactly as its slider or switch does.
	 *
	 * Not the same thing as setting the cvar behind it over the console, which
	 * is what every previous check of "does the Brightness slider work" actually
	 * tested. This goes through OpenQ4_iOS_SettingSetFloat, so it exercises
	 * NSUserDefaults, the shell's own consumers, and the queued push onto the
	 * engine thread — the whole chain, including the parts that were broken.
	 */
	/*
	 * !continue — get past the "press any key to continue" gate.
	 *
	 * That gate is a blocking loop inside ExecuteMapChange: the engine thread
	 * sits in it, so a queued console command is buffered and never executed,
	 * and everything after a map load (autosave included) waits behind it. On a
	 * phone a tap clears it; over the bridge there was nothing, which made the
	 * whole post-load half of the game unreachable from a script — including
	 * the savegame chain this exists to verify (D-066).
	 *
	 * Dispatched to the main queue because that is the thread the touch overlay
	 * injects from; Posix_QueEvent has no lock of its own.
	 */
	if (strcmp(cmd, "!continue") == 0) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (OpenQ4_iOS_AwaitingContinue()) {
				OpenQ4_iOS_InjectContinueKey();
				fprintf(stdout, "openQ4 bridge: continue key injected\n");
			} else {
				fprintf(stdout, "openQ4 bridge: not awaiting continue; nothing injected\n");
			}
			fflush(stdout);
		});
		return 1;
	}
	if (strcmp(cmd, "!fonttest") == 0) {
		OpenQ4_iOS_FontCheck("on demand");
		return 1;
	}
	/*
	 * !mods — what the shell's mod picker can see, and which mod the next
	 * launch will use. The picker itself is a table row, and the simulator
	 * cannot tap one; this reads the same scan the row builds itself from
	 * rather than a second implementation of it.
	 */
	if (strcmp(cmd, "!mods") == 0) {
		OpenQ4_iOS_PrintMods();
		return 1;
	}
	if (strcmp(cmd, "!modpicker") == 0) {
		OpenQ4_iOS_ShowModPicker();
		return 1;
	}
	if (strcmp(cmd, "!settingsback") == 0) {
		OpenQ4_iOS_SettingsBack();
		return 1;
	}
	if (strcmp(cmd, "!settingsdone") == 0) {
		OpenQ4_iOS_SettingsDone();
		return 1;
	}
	/*
	 * !button <name> <0|1> — hold or release one of the touch overlay's
	 * buttons through the same OpenQ4_iOS_InjectButton the overlay uses. The
	 * objectives screen is a HELD display (BUTTON_SCORES down opens it, up
	 * closes it), so without this there is no way to photograph it on a device
	 * that cannot be touched.
	 */
	if (strncmp(cmd, "!button ", 8) == 0) {
		char name[64] = {0};
		int down = 0;
		if (sscanf(cmd + 8, "%63s %d", name, &down) == 2) {
			OpenQ4_iOS_InjectButton(name, down ? 1 : 0);
			fprintf(stdout, "openQ4 bridge: button '%s' %s\n", name, down ? "down" : "up");
		} else {
			fprintf(stdout, "openQ4 bridge: usage: !button <name> <0|1>\n");
		}
		fflush(stdout);
		return 1;
	}
	if (strncmp(cmd, "!set ", 5) == 0) {
		char key[64] = {0};
		double value = 0.0;
		if (sscanf(cmd + 5, "%63s %lf", key, &value) == 2) {
			OpenQ4_iOS_SettingSetFloat(key, (float)value);
			fprintf(stdout, "openQ4 bridge: setting '%s' = %g (now %g)\n",
					key, value, OpenQ4_iOS_SettingFloat(key, -1.0f));
		} else {
			fprintf(stdout, "openQ4 bridge: usage: !set <key> <value>\n");
		}
		fflush(stdout);
		return 1;
	}
	/*
	 * !setstr <key> <value> — the text-row equivalent of !set.
	 *
	 * Same reason !set exists: it goes through OpenQ4_iOS_SettingSetString, so
	 * it exercises NSUserDefaults, the trim and the cvar push, which is what
	 * "does the Master Server row work" actually means. Everything after the
	 * key is the value, spaces included.
	 */
	if (strncmp(cmd, "!setstr ", 8) == 0) {
		const char *rest = cmd + 8;
		while (*rest == ' ') { rest++; }
		const char *space = strchr(rest, ' ');
		char key[64] = {0};
		const char *value = "";
		if (space != NULL) {
			size_t n = (size_t)(space - rest);
			if (n >= sizeof(key)) { n = sizeof(key) - 1; }
			memcpy(key, rest, n);
			value = space + 1;
			while (*value == ' ') { value++; }
		} else {
			snprintf(key, sizeof(key), "%s", rest);
		}
		if (key[0] == '\0') {
			fprintf(stdout, "openQ4 bridge: usage: !setstr <key> <value>\n");
		} else {
			OpenQ4_iOS_SettingSetString(key, value);
			fprintf(stdout, "openQ4 bridge: setting '%s' = '%s' (now '%s')\n",
					key, value, OpenQ4_iOS_SettingString(key).UTF8String);
		}
		fflush(stdout);
		return 1;
	}
	if (strcmp(cmd, "!connect") == 0 || strncmp(cmd, "!connect ", 9) == 0) {
		// Drives the settings sheet's Connect row without a finger on it: sets
		// the address row when one is given, then runs the same code the button
		// runs.
		if (cmd[8] == ' ') {
			const char *addr = cmd + 9;
			while (*addr == ' ') { addr++; }
			OpenQ4_iOS_SettingSetString("directAddr", addr);
		}
		OpenQ4_iOS_SettingsDirectConnect();
		return 1;
	}
	fprintf(stdout, "openQ4 bridge: unknown local command '%s'\n", cmd);
	fflush(stdout);
	return 1;
}
#endif /* !OPENQ4_PUBLIC_BUILD — the `!` shell commands */

void OpenQ4_iOS_BridgeDrain(void) {
	/*
	 * Deliberately NOT gated on g_started any more. The listener is opt-in via
	 * OPENQ4_CONSOLE_BRIDGE, but the queue is now also the settings sheet's
	 * route to the engine (OpenQ4_iOS_QueueConsoleCommand), and gating the
	 * drain on the socket would make "Connect" silently do nothing in exactly
	 * the builds a player runs. Draining an empty queue is one uncontended
	 * lock.
	 */
	// Deep links feed the same queue, but only once the engine is past init
	// (D-096) — so they are moved across here, on the frame thread, rather than
	// at the moment the URL arrives.
	OpenQ4_iOS_DrainPendingURLs();

	char *pending[OPENQ4_BRIDGE_MAX_QUEUE];
	int count = 0;

	pthread_mutex_lock(&g_queueLock);
	for (int i = 0; i < g_queueCount; i++) {
		pending[count++] = g_queue[i];
	}
	g_queueCount = 0;
	pthread_mutex_unlock(&g_queueLock);

	for (int i = 0; i < count; i++) {
		fprintf(stdout, "] %s\n", pending[i]);
		OpenQ4_iOS_BridgeExecuteCommand(pending[i]);
		free(pending[i]);
	}
}

/* ------------------------------------------------------------------ frames */

#import <UIKit/UIKit.h>
#include <pthread.h>
#include <signal.h>
#include <errno.h>

// Implemented engine-side: drains the bridge and runs one common->Frame().
extern void OpenQ4_iOS_EngineFrame(void);
extern void OpenQ4_iOS_PumpSDLEvents(void);

/*
 * The engine runs on its own thread, and the reason is a hard limit rather than
 * a preference: iOS gives the main thread a 1 MB stack, where macOS gives 8 MB.
 * idMD5Mesh::ParseMesh needs more than what is left of 1 MB, so loading a map
 * overflowed the main thread's stack and the process died with
 * EXC_BAD_ACCESS / "Thread stack size exceeded" — in ___chkstk_darwin, the
 * stack probe itself. Four crash reports, identical.
 *
 * It was silent for the same reason it crashed: a SIGSEGV handler cannot run
 * when there is no stack left to run it on. Hence sigaltstack below, so a
 * future overflow reports itself instead of vanishing.
 *
 * 16 MB, i.e. twice the desktop main thread, because this engine was written
 * against desktop stack budgets and the load path is the deep part.
 */
#define OPENQ4_ENGINE_STACK_BYTES (16 * 1024 * 1024)

static dispatch_semaphore_t g_frameSem = nil;
static volatile int         g_engineReady = 0;
static pthread_t            g_engineThread;

static volatile int g_frameInFlight = 0;

/*
 * Frame pacing mode.
 *
 *   0  tick-gated  — one engine frame per display-link tick, and a tick that
 *                    arrives while a frame is running is dropped.
 *   1  catch-up    — a dropped tick is remembered, and the engine thread runs
 *                    one extra frame immediately instead of idling to the next.
 *
 * Why catch-up is the default. The link runs at 120 Hz (8.33 ms) and a device
 * frame costs ~10.5 ms of work. Under tick-gating that frame always misses the
 * next tick and waits for the one after, so every 10 ms of work costs 16.7 ms
 * of wall clock: measured on an A19 Pro as ~67 fps with a 3.8 ms gap and a
 * 16 ms present p50. The work was never the problem; the gate was.
 *
 * Running the engine thread completely free instead was the alternative, and it
 * is not needed: FIFO presentation is already the backpressure, because
 * vkAcquireNextImageKHR blocks once the swapchain is full. Catching up at most
 * ONE frame per wait keeps that property while never letting a runaway loop
 * starve the semaphore pump, and a frame cheaper than 8.3 ms still paces to the
 * link exactly as it did before.
 */
static atomic_int g_paceMode       = 1;
static atomic_int g_missedTick     = 0;
static atomic_int g_missedTickCount = 0;
static atomic_int g_catchUpFrames  = 0;

/*
 * The frame runs on this thread SYNCHRONOUSLY: the main thread signals it and
 * then waits for it to finish. Nothing runs concurrently — the ordering is
 * exactly what it was when the frame ran on the main thread directly.
 *
 * The only thing that changes is which stack the frame executes on, and that is
 * the entire point. iOS gives the main thread 1 MB; macOS gives 8 MB. Loading a
 * map overflowed it — four crash reports, all EXC_BAD_ACCESS with "Thread stack
 * size exceeded", all faulting in ___chkstk_darwin under idMD5Mesh::ParseMesh.
 *
 * A fully asynchronous engine thread is the better end state (Q-009/Q-010), and
 * it is what I tried first: it dies in SDL's video init, which is main-thread-
 * only on Darwin and wants far more than one call marshalled. That work is
 * worth doing properly rather than rushed on top of a live bug. This gets the
 * stack — the actual defect — with no concurrency introduced at all.
 */
static void *OpenQ4_EngineThread(void *arg) {
	(void)arg;
	pthread_setname_np("openq4-engine");
	OpenQ4_iOS_SetSampleTargetToSelf();
	for (;;) {
		dispatch_semaphore_wait(g_frameSem, DISPATCH_TIME_FOREVER);
		OpenQ4_iOS_EngineFrame();

		// One catch-up frame at most, and only for a tick that actually
		// arrived while this frame was running. g_frameInFlight stays set
		// across it, so tick: cannot signal the semaphore underneath us.
		// Always consume the flag, even when catch-up is off: a tick that
		// landed during a tick-gated frame must not be banked and cashed as a
		// phantom catch-up the moment !pace 1 is issued.
		const int missed = atomic_exchange(&g_missedTick, 0) != 0;
		if (atomic_load(&g_paceMode) != 0 && missed) {
			atomic_fetch_add(&g_catchUpFrames, 1);
			OpenQ4_iOS_EngineFrame();
			// Whatever arrived during the catch-up frame is left for the
			// next tick: falling back to the wait unconditionally is what
			// bounds this at one extra frame per wait.
			atomic_store(&g_missedTick, 0);
		}

		g_frameInFlight = 0;
	}
	return NULL;
}

/*
 * Why init stays on the main thread while frames move off it.
 *
 * SDL's video initialisation and window creation build UIKit objects and are
 * main-thread-only on Darwin; running common->Init() on the engine thread died
 * at VK_InitRenderDevice every time, and marshalling one call was not enough
 * because the whole subsystem wants main.
 *
 * Init does not need the bigger stack — the overflow is in map loading, which
 * happens in common->Frame(). So the split is: init on main exactly as before,
 * then every frame after it on the 16 MB engine thread. That is the smallest
 * change that fixes the actual crash, and it leaves SDL's init path untouched.
 */
static void OpenQ4_StartEngineThreadOnce(void) {
	static int started = 0;
	if (started) {
		return;
	}
	started = 1;

	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setstacksize(&attr, OPENQ4_ENGINE_STACK_BYTES);
	if (pthread_create(&g_engineThread, &attr, OpenQ4_EngineThread, NULL) != 0) {
		fprintf(stderr, "openQ4: FATAL: could not start the engine thread\n");
	}
	pthread_attr_destroy(&attr);
	fprintf(stdout, "openQ4: frame loop moved to the engine thread (%d MB stack; "
					"the main thread's 1 MB is what ParseMesh overflows)\n",
			OPENQ4_ENGINE_STACK_BYTES / (1024 * 1024));
	fflush(stdout);
}

static void OpenQ4_InstallSigAltStack(void) {
	// A stack overflow raises SIGSEGV with no usable stack, so the handler needs
	// its own. Without this the crash that took six rounds to find could not
	// have reported itself even in principle.
	static char altStack[SIGSTKSZ * 4];
	stack_t ss;
	ss.ss_sp = altStack;
	ss.ss_size = sizeof(altStack);
	ss.ss_flags = 0;
	if (sigaltstack(&ss, NULL) != 0) {
		fprintf(stderr, "openQ4: sigaltstack failed: %s\n", strerror(errno));
	}
}

@interface OpenQ4FrameDriver : NSObject
- (void)tick:(CADisplayLink *)link;
@end

static OpenQ4FrameDriver *g_frameDriver = nil;
static CADisplayLink     *g_frameLink   = nil;

static volatile int32_t g_tickCount   = 0;   // ticks the link has delivered
static volatile int32_t g_reentryCount = 0;   // ticks dropped because one was in flight
static volatile int32_t g_inFrame      = 0;

/*
 * Two independent reasons the link can be paused, kept apart on purpose
 * (D-068). The engine pauses it across a blocking map load; the app lifecycle
 * pauses it while backgrounded. Folding them into one boolean meant the
 * engine's "load finished, resume" would happily restart frames on an app that
 * is in the background — which is exactly the window in which drawing costs a
 * GPU-restricted-while-backgrounded kill.
 */
static atomic_int g_loadPaused = 0;
static atomic_int g_bgPaused   = 0;
static volatile int32_t g_bgSkippedTicks = 0;  // ticks that arrived while backgrounded

// Must be called on the main queue.
static void OpenQ4_ApplyFrameLoopPaused(void) {
	if (g_frameLink == nil) {
		return;
	}
	const BOOL paused = (atomic_load(&g_loadPaused) != 0 || atomic_load(&g_bgPaused) != 0);
	g_frameLink.paused = paused;
}

@implementation OpenQ4FrameDriver
- (void)tick:(CADisplayLink *)link {
	(void)link;
	g_tickCount++;
#if TARGET_OS_VISION
	// Q-035: the only place that sees every tick, so the only place that can
	// answer whether the window's link keeps its rate while an ImmersiveSpace
	// is open. Two stores and a subtraction.
	OpenQ4_Vision3D_NoteEngineTick();
#endif

	// Re-entrancy guard. A long map load runs inside this callback and pumps
	// events, which can spin the run loop and deliver another tick on top of
	// the first. common->Frame() is not re-entrant, so a nested call is
	// corruption. Counting the drops also tells us whether it ever happens.
	if (g_inFrame) {
		g_reentryCount++;
		return;
	}
	g_inFrame = 1;
	// The engine no longer runs here — see OpenQ4_EngineThread. This tick only
	// paces it and pumps SDL, both of which must happen on the main thread.
	//
	// The pump is gated until the engine has finished initialising. SDL is not
	// thread-safe, and during common->Init the engine thread is inside SDL's own
	// video init and window creation; pumping concurrently from here crashed the
	// app at VK_InitRenderDevice. After init the engine only drains the
	// mutex-protected event queue this fills, so the two no longer overlap.
	if (!g_engineReady) {
		// Initialisation runs here, on the main thread, exactly as it always
		// has. OpenQ4_iOS_EngineReady() is called at the end of it.
		OpenQ4_iOS_EngineFrame();
		if (g_engineReady) {
			OpenQ4_StartEngineThreadOnce();
		}
		// Clear the guard before returning. Leaving it latched drops every
		// subsequent tick, which parks the engine thread on its semaphore
		// forever — the app reaches the menu and then simply stops.
		g_inFrame = 0;
		return;
	}

	// Steady state: pump SDL here (main-thread-only) and let the frame run on
	// the big-stack thread WITHOUT waiting for it.
	//
	// Waiting was the obvious-looking choice — it keeps ordering identical to
	// the old main-thread loop — and it broke input completely. The engine has
	// blocking loops inside common->Frame() that spin until an event arrives:
	// the "press any key to continue" screen after a map load is one. With the
	// main thread parked on g_frameDone, the display link never ticks, SDL is
	// never pumped, and the event that loop is waiting for can never be
	// delivered. Deadlock by construction, and it presents as a screen that
	// ignores every tap and every controller button.
	//
	// So main stays free: it pumps SDL into the mutex-protected engine queue and
	// keeps the run loop turning. g_frameInFlight stops ticks from queueing up
	// behind a long frame.
	OpenQ4_iOS_PumpSDLEvents();
	// Backgrounded: pump SDL (so the lifecycle events the engine reacts to are
	// still delivered) but start no new engine frame. A frame already in flight
	// is left alone to finish — it is drawing into a drawable it already holds,
	// and killing it mid-command-buffer is worse than letting it complete. The
	// pause on the link means this path is normally not even reached; the guard
	// covers the tick already queued when the notification arrived.
	if (atomic_load(&g_bgPaused) != 0) {
		g_bgSkippedTicks++;
		g_inFrame = 0;
		return;
	}
	if (!g_frameInFlight) {
		g_frameInFlight = 1;
		dispatch_semaphore_signal(g_frameSem);
	} else {
		// A tick landed on top of a running frame. Under tick-gating this was
		// silently dropped and the engine idled until the tick after; now it is
		// remembered so the engine thread can start the next frame at once.
		atomic_store(&g_missedTick, 1);
		atomic_fetch_add(&g_missedTickCount, 1);
	}
	g_inFrame = 0;
}
@end

/*
 * Link health report, callable from the engine over the bridge. Distinguishes
 * the three ways "no frames" can happen: the link stopped being delivered
 * (tick count frozen), ticks arrive but are dropped (re-entrancy), or ticks run
 * but the engine does nothing.
 */
void OpenQ4_iOS_EngineReady(void) {
	g_engineReady = 1;
	// The overlay lays out long before the engine's cvars exist, so the insets
	// published then were dropped on the floor. Publish once more here, where
	// there is definitely something to publish them to (D-085).
	dispatch_async(dispatch_get_main_queue(), ^{ OpenQ4_iOS_PublishSafeArea(); });
}

void OpenQ4_iOS_SetFrameLoopPaused(int paused) {
	// Pausing across a blocking load is the point: an armed display link that
	// keeps requesting callbacks while the app never completes a frame is a
	// standing, unanswerable request to the render server. During a map load
	// every tick fires inside a nested run-loop slice, hits the re-entrancy
	// guard, and returns having presented nothing — the system starts round
	// trips the app cannot finish, and the scene-update watchdog terminates at
	// 10.00 seconds. A paused link asks for nothing.
	atomic_store(&g_loadPaused, paused ? 1 : 0);
	dispatch_async(dispatch_get_main_queue(), ^{
		OpenQ4_ApplyFrameLoopPaused();
	});
}

/*
 * App-lifecycle pause (D-068). Until this existed nothing stopped the display
 * link when the app went to the background: the device log showed engine
 * heartbeats printed AFTER "SDL3: application entering background", i.e. the
 * engine kept simulating, rendering and presenting against a scene the system
 * had already taken away.
 *
 * DidEnterBackground rather than WillResignActive: resign-active also fires for
 * the Control Centre pull-down and the app-switcher peek, where the app is
 * still on screen and stopping frames would freeze a visible game. Background
 * is the point at which drawing is both pointless and dangerous.
 *
 * Ordering with SDL: SDL3's own uikit lifecycle handler posts the engine's
 * background event from the same notifications. We do not replace it — the
 * engine still gets its event, still writes its config — we only stop asking
 * for new frames. The observers are registered after SDL's, so on foreground
 * the engine's focus restore has already been queued when frames resume.
 */
static void OpenQ4_SetFrameLoopBackgrounded(int backgrounded) {
	atomic_store(&g_bgPaused, backgrounded ? 1 : 0);
	OpenQ4_ApplyFrameLoopPaused();
	fprintf(stdout, "openQ4 framelink: %s (ticks=%d bgSkipped=%d)\n",
			backgrounded ? "paused, app entered background"
						 : "resumed, app returned to foreground",
			(int)g_tickCount, (int)g_bgSkippedTicks);
	fflush(stdout);
}

void OpenQ4_iOS_ReportFrameLoop(void) {
	fprintf(stdout,
			"openQ4 framelink: ticks=%d reentryDrops=%d inFrame=%d link=%s paused=%d duration=%.4f "
			"pace=%d missed=%d catchup=%d loadPaused=%d bgPaused=%d bgSkipped=%d\n",
			(int)g_tickCount, (int)g_reentryCount, (int)g_inFrame,
			(g_frameLink != nil) ? "alive" : "NIL",
			(g_frameLink != nil) ? (int)g_frameLink.isPaused : -1,
			(g_frameLink != nil) ? (double)g_frameLink.duration : -1.0,
			atomic_load(&g_paceMode),
			atomic_load(&g_missedTickCount),
			atomic_load(&g_catchUpFrames),
			atomic_load(&g_loadPaused),
			atomic_load(&g_bgPaused),
			(int)g_bgSkippedTicks);
	fflush(stdout);
}

void OpenQ4_iOS_SetPaceMode(int mode) {
	atomic_store(&g_paceMode, (mode != 0) ? 1 : 0);
	fprintf(stdout, "openQ4 pacing: mode %d (%s)\n", atomic_load(&g_paceMode),
			(mode != 0) ? "catch-up on a missed tick"
						: "tick-gated, one frame per display-link tick");
	fflush(stdout);
}

/*
 * Render resolution.
 *
 * Held here rather than read from NSUserDefaults on demand because the engine
 * thread asks for it inside the renderer's per-frame window poll, and a
 * defaults read on that path is neither cheap nor thread-safe by contract.
 * The settings layer and the bridge both push into it; nothing else reads the
 * stored value at frame time.
 */
static atomic_int g_renderScalePct = 100;

/*
 * The layer half of the render-scale knob, and the reason 0.1.0.39's knob cost
 * more than it saved.
 *
 * MoltenVK decides whether a swapchain is still optimal by comparing its extent
 * against the layer's NATURAL drawable size — bounds x contentsScale, not the
 * drawableSize property, which it sets itself. Ask for a smaller extent while
 * contentsScale stays at the screen's nativeScale and every acquire and present
 * answers VK_SUBOPTIMAL_KHR forever: the engine recreates the swapchain (a
 * vkDeviceWaitIdle plus a full rebuild) once per frame, and the ~10 ms that
 * costs hides inside the frame rather than in any measured stage. SDL is the
 * other owner of the same property — its updateDrawableSize recomputes
 * bounds x contentsScale on every layout — so nothing is stable until all
 * three agree.
 *
 * So: WE own contentsScale. Set it to nativeScale x scale and the natural size
 * IS the size we want; SDL's layout then computes the same number, and MoltenVK
 * sees an optimal surface. The pixel size handed to the engine is computed with
 * MoltenVK's own rounding (trunc(x + 0.5)) from the same two inputs, so the
 * requested extent, the natural size and the drawableSize cannot disagree by a
 * pixel. Two ways of computing one number is what the loop was made of.
 *
 * Cached in atomics rather than fetched on demand: UIKit is main-thread-only
 * and the engine asks for this inside its per-frame window poll, so a
 * dispatch_sync from the frame thread would be a deadlock waiting for a main
 * thread that is itself waiting on the frame.
 */
static atomic_int  g_layerPixelWidth = 0;
static atomic_int  g_layerPixelHeight = 0;
static atomic_bool g_layerPixelValid = false;
// Diagnostic-only escape hatch (!renderscalelayer 0): reproduces the pre-0.1.0.40
// behaviour on demand, which is the only way to A/B the thrash counters.
static atomic_bool g_layerScaleEnabled = true;

// Main thread. The SDL Metal view is the one view in the hierarchy whose layer
// is a CAMetalLayer; matching on that rather than on the class name keeps this
// working if SDL renames the view.
static UIView *OpenQ4_FindMetalView(UIView *root) {
	if (root == nil) { return nil; }
	if ([root.layer isKindOfClass:CAMetalLayer.class]) { return root; }
	for (UIView *child in root.subviews) {
		UIView *found = OpenQ4_FindMetalView(child);
		if (found != nil) { return found; }
	}
	return nil;
}

/*
 * Everything the SHELL owns that a rebuilt SDL view invalidates.
 *
 * The trampoline's one caller re-creates the Vulkan surface, and SDL builds
 * that surface by making a fresh Metal view and handing it to
 * -[SDL_uikitview setSDLWindow:], which re-assigns the window's
 * rootViewController. UIKit appends the new root view ABOVE every earlier
 * sibling, so the touch overlay — added to the window at boot — ends up buried
 * under it for the rest of the process, and the new layer comes back at its
 * default contentsScale. Neither belongs to the engine, so nothing else puts
 * them back. Both calls are idempotent, and at first boot the overlay does not
 * exist yet, which is why boot behaviour is unchanged (D-082).
 */
static void OpenQ4_AfterViewHierarchyRebuild(void) {
	OpenQ4_iOS_TouchReassertFront();
	OpenQ4_ApplyRenderScaleToLayer();
	// The 2D UI viewport is inset by the safe area (D-085), and a rebuilt
	// hierarchy is exactly the moment those insets can have gone stale — the
	// overlay is re-rooted and may be laid out against a different window.
	// Deferred as well as immediate: this runs INSIDE the rebuild, before UIKit
	// has re-attached and laid anything out, so the settled pass is the one that
	// carries the real numbers.
	OpenQ4_iOS_PublishSafeArea();
	dispatch_async(dispatch_get_main_queue(), ^{ OpenQ4_iOS_PublishSafeArea(); });
}

/*
 * Lifecycle-only main-thread trampoline. See the header for why this exists
 * and why it cannot deadlock against tick:.
 */
void OpenQ4_iOS_RunOnMainSync(void (*fn)(void *), void *ctx) {
	if (fn == NULL) {
		return;
	}
	if (NSThread.isMainThread) {
		fn(ctx);
		OpenQ4_AfterViewHierarchyRebuild();
		return;
	}
	dispatch_sync(dispatch_get_main_queue(), ^{
		fn(ctx);
		OpenQ4_AfterViewHierarchyRebuild();
	});
}

static void OpenQ4_ApplyRenderScaleToLayer(void) {
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ OpenQ4_ApplyRenderScaleToLayer(); });
		return;
	}
	// The layer is ours to keep: anything that can replace the view or reset
	// its contentsScale (a foreground return, a scene re-attach) has to be
	// followed by a re-apply, or the engine keeps requesting a size the layer
	// no longer agrees with — which is the thrash this whole path exists to end.
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		[NSNotificationCenter.defaultCenter
				addObserverForName:UIApplicationDidBecomeActiveNotification
							object:nil
							 queue:NSOperationQueue.mainQueue
						usingBlock:^(NSNotification *note) {
			(void)note;
			OpenQ4_ApplyRenderScaleToLayer();
			OpenQ4_iOS_PublishSafeArea();
		}];
	});

	UIWindow *win = nil;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (w.isKeyWindow) { win = w; break; }
		}
		if (win == nil) { win = ((UIWindowScene *)scene).windows.firstObject; }
		if (win != nil) { break; }
	}
	UIView *view = OpenQ4_FindMetalView(win);
	if (view == nil) {
		// Before the renderer has created its window there is nothing to scale;
		// the engine falls back to its own rounding and the poll adopts the
		// layer size on the frame after this lands.
		atomic_store(&g_layerPixelValid, false);
		return;
	}

#if !TARGET_OS_VISION
	/*
	 * Q-036 / D-104 — pin the metal view to its host before measuring it.
	 *
	 * SDL's metal view is the SDL window's root view controller's view, created
	 * with `data.uiwindow.bounds` at whatever instant the engine asked for a
	 * Vulkan surface, and it carries NO autoresizing mask. On iOS that instant
	 * lands inside the launch geometry negotiation: the scene hands out a
	 * placeholder size first (480x271 in the Q-036 run), then the device's
	 * natural portrait (440x956), then the landscape this app actually
	 * supports (956x440) — and UIKit does not reliably re-lay-out a root view
	 * that was swapped in mid-flight. A landscape window holding a portrait
	 * metal view is exactly what Q-036 photographed: the engine's image drawn
	 * into a 440x956 rectangle in the left third of a 956x440 screen, while the
	 * UIKit chrome around it sat correctly in landscape.
	 *
	 * Warm runs never saw it because the simulator was already in landscape
	 * when the app launched, so the first size handed out was already right.
	 *
	 * Fix both halves: correct the frame now, and give the view the mask it
	 * should have had so the next geometry change carries it for free.
	 */
	UIView *host = view.superview != nil ? view.superview : (UIView *)win;
	if (host != nil && !CGRectIsEmpty(host.bounds) &&
			!CGSizeEqualToSize(view.bounds.size, host.bounds.size)) {
		fprintf(stdout, "openQ4 render scale: metal view %.0fx%.0f did not follow its host"
						" %.0fx%.0f — re-pinning (D-104)\n",
				view.bounds.size.width, view.bounds.size.height,
				host.bounds.size.width, host.bounds.size.height);
		fflush(stdout);
		view.frame = host.bounds;
		[view layoutIfNeeded];
	}
	view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
#endif

	const CGSize bounds = view.bounds.size;
	if (!(bounds.width > 0.0 && bounds.height > 0.0)) {
		atomic_store(&g_layerPixelValid, false);
		return;
	}
	// UIScreen does not exist on visionOS; ../compat answers with the scene's
	// displayScale there and with this exact expression on iOS (D-090).
	CGFloat nativeScale = OpenQ4_iOS_NativeScaleForView(view);
	if (!(nativeScale > 0.0)) { nativeScale = view.layer.contentsScale; }
	if (!(nativeScale > 0.0)) { nativeScale = 1.0; }

	const int percent = atomic_load(&g_renderScalePct);
	const bool enabled = atomic_load(&g_layerScaleEnabled);
	const CGFloat wanted = enabled ? (nativeScale * (CGFloat)percent / 100.0) : nativeScale;

	if (view.layer.contentsScale != wanted) {
		view.layer.contentsScale = wanted;
		// SDL recomputes the drawable size from contentsScale in layoutSubviews
		// and nowhere else, so the change is not live until a layout runs.
		[view setNeedsLayout];
		[view layoutIfNeeded];
	}

	// MoltenVK's naturalDrawableSizeMVK rounding, reproduced exactly.
	const int w = (int)trunc(bounds.width * wanted + 0.5);
	const int h = (int)trunc(bounds.height * wanted + 0.5);
	CAMetalLayer *metal = (CAMetalLayer *)view.layer;
	if (metal.drawableSize.width != (CGFloat)w || metal.drawableSize.height != (CGFloat)h) {
		metal.drawableSize = CGSizeMake((CGFloat)w, (CGFloat)h);
	}

	const int previousW = atomic_exchange(&g_layerPixelWidth, w);
	const int previousH = atomic_exchange(&g_layerPixelHeight, h);
	const bool wasValid = atomic_exchange(&g_layerPixelValid, enabled);
	if (!wasValid || previousW != w || previousH != h) {
		fprintf(stdout, "openQ4 render scale: layer bounds %.0fx%.0f x contentsScale %.4f"
						" -> drawable %dx%d (native scale %.2f, %d%%%s)\n",
				bounds.width, bounds.height, (double)wanted, w, h,
				(double)nativeScale, percent, enabled ? "" : ", layer scaling disabled");
		fflush(stdout);
	}
}

bool OpenQ4_iOS_RenderPixelSize(int *width, int *height) {
	if (!atomic_load(&g_layerPixelValid)) {
		return false;
	}
	const int w = atomic_load(&g_layerPixelWidth);
	const int h = atomic_load(&g_layerPixelHeight);
	if (w <= 0 || h <= 0) {
		return false;
	}
	if (width != NULL) { *width = w; }
	if (height != NULL) { *height = h; }
	return true;
}

#if !defined(OPENQ4_PUBLIC_BUILD)
// Bridge-only A/B lever (`!renderscalelayer`); absent from a public build.
static void OpenQ4_SetRenderScaleLayerEnabled(bool enabled) {
	atomic_store(&g_layerScaleEnabled, enabled);
	OpenQ4_ApplyRenderScaleToLayer();
}

static bool OpenQ4_RenderScaleLayerEnabled(void) {
	return atomic_load(&g_layerScaleEnabled);
}
#endif

void OpenQ4_iOS_RenderScaleRefreshLayer(void) {
	OpenQ4_ApplyRenderScaleToLayer();
}

int OpenQ4_iOS_RenderScalePercent(void) {
	return atomic_load(&g_renderScalePct);
}

float OpenQ4_iOS_RenderScale(void) {
	return (float)atomic_load(&g_renderScalePct) / 100.0f;
}

void OpenQ4_iOS_SetRenderScalePercent(int percent) {
	if (percent < 50) { percent = 50; }
	if (percent > 100) { percent = 100; }
	const int previous = atomic_exchange(&g_renderScalePct, percent);
	if (previous != percent) {
		// One line per real change: the engine prints the resulting drawable
		// size itself on the next frame, and the pair is the whole story.
		fprintf(stdout, "openQ4 render scale: %d%% (was %d%%)\n", percent, previous);
		fflush(stdout);
	}
	// Unconditional: the layer may not have existed the last time this ran
	// (the renderer creates it during common->Init), so re-asking is how a
	// persisted setting reaches a window that appeared later.
	OpenQ4_ApplyRenderScaleToLayer();
}

/*
 * Heartbeat counters. Read-and-reset in one call, because the heartbeat prints
 * per-window numbers and a counter it did not clear would read as monotonic
 * growth forever.
 */
void OpenQ4_iOS_TakeFramePacingCounters(int *missed, int *catchUp, int *paceMode) {
	if (missed != NULL) {
		*missed = atomic_exchange(&g_missedTickCount, 0);
	}
	if (catchUp != NULL) {
		*catchUp = atomic_exchange(&g_catchUpFrames, 0);
	}
	if (paceMode != NULL) {
		*paceMode = atomic_load(&g_paceMode);
	}
}

void OpenQ4_iOS_StartFrameLoop(void) {
	// The MoltenVK override constructor runs before main() and therefore before
	// the stdout tee exists, so this is the first moment its result can be
	// printed where anyone will see it.
	fprintf(stdout, "openQ4: MoltenVK config: %s\n", OpenQ4_iOS_MvkEnvApplied());
	if (g_frameSem == nil) {
		g_frameSem = dispatch_semaphore_create(0);
		OpenQ4_InstallSigAltStack();
	}

	// dispatch_async so the link is installed on the main queue after main()
	// has returned control to the run loop.
	dispatch_async(dispatch_get_main_queue(), ^{
		if (g_frameLink != nil) {
			return;
		}
		g_frameDriver = [OpenQ4FrameDriver new];
		g_frameLink = [CADisplayLink displayLinkWithTarget:g_frameDriver
												  selector:@selector(tick:)];

		// Ask for the panel's full rate with a 60 floor. The minimum matters:
		// iOS otherwise demotes a heavy app's grant into a lower bucket
		// persistently, per app identity.
		const float maxFps = OpenQ4_iOS_MaxFramesPerSecond();
		g_frameLink.preferredFrameRateRange =
			CAFrameRateRangeMake(fminf(60.0f, maxFps), maxFps, maxFps);

		// Common modes, not default: frames must keep running during touch
		// tracking, or the game stops while a finger is down.
		[g_frameLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

		// Lifecycle observers live with the link they control. Registered on the
		// main queue so the handlers run there too, which is where
		// CADisplayLink.paused must be touched.
		NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
		[nc addObserverForName:UIApplicationDidEnterBackgroundNotification
						object:nil queue:NSOperationQueue.mainQueue
					usingBlock:^(NSNotification *note) {
			(void)note;
			OpenQ4_SetFrameLoopBackgrounded(1);
		}];
		// Both foreground notifications, because they are not interchangeable:
		// WillEnterForeground is the one that always follows a background, and
		// DidBecomeActive is what fires when the app was only ever inactive.
		// The setter is idempotent, so arriving twice costs one log line.
		[nc addObserverForName:UIApplicationWillEnterForegroundNotification
						object:nil queue:NSOperationQueue.mainQueue
					usingBlock:^(NSNotification *note) {
			(void)note;
			OpenQ4_SetFrameLoopBackgrounded(0);
		}];
		[nc addObserverForName:UIApplicationDidBecomeActiveNotification
						object:nil queue:NSOperationQueue.mainQueue
					usingBlock:^(NSNotification *note) {
			(void)note;
			if (atomic_load(&g_bgPaused) != 0) {
				OpenQ4_SetFrameLoopBackgrounded(0);
			}
		}];

		fprintf(stdout, "openQ4: display link started (max %.0f Hz)\n", maxFps);
	});
}

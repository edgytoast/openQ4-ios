/*
 * openq4_ios_url.m — `openq4://` deep links. D-096.
 *
 * Routes (deliberately five, deliberately small):
 *
 *   openq4://                        just open the app
 *   openq4://continue                -> `loadNewestGame` (newest save this build
 *                                       can load), or just open when none (D-112)
 *   openq4://map/<name>              -> `map <name>`      (e.g. map/mp/q4dm1)
 *   openq4://connect/<host[:port]>   -> `connect <host>`
 *   openq4://console/<cmd>           -> one console line, OTA builds only
 *                                       (not compiled into public builds, D-113)
 *
 * Delivery differs per shell and neither is obvious:
 *
 *   iOS       SDL owns the app delegate (SDL_RunApp), and SDL3's handling of an
 *             incoming URL is to synthesise an SDL_EVENT_DROP_FILE — the same
 *             event a real file drop produces, with no way to tell them apart
 *             and no route to our own code. So the three delegate entry points
 *             are swizzled and SDL's originals are still called afterwards, so
 *             genuine drops keep working. Both the legacy
 *             (`application:openURL:options:`, which is the mode this app runs
 *             in — ios/Info.plist declares no UIApplicationSceneManifest) and
 *             the scene (`scene:openURLContexts:`) paths are covered, because
 *             which one iOS uses is a plist property that could change, and a
 *             deep link that silently stops arriving is a bad way to find out.
 *             Cold launch is covered separately: iOS hands a launch URL to
 *             didFinishLaunching and never calls openURL for it.
 *
 *   visionOS  SwiftUI entry, so `.onOpenURL` in OpenQ4VisionApp.swift calls
 *             straight in here. No swizzle, and no SDL delegate to swizzle.
 *
 * The command is QUEUED, never executed inline: idCmdSystem is not thread-safe,
 * a URL can arrive before the engine exists at all, and the shared route to the
 * engine is the bridge's locked queue (OpenQ4_iOS_QueueConsoleCommand).
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../compat/openq4_ios_compat.h"
#include <objc/runtime.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "openq4_ios_url.h"
#include "openq4_ios_bridge.h"
#include "openq4_ios_blackbox.h"
#include "openq4_ios_onboarding.h"
#include "openq4_ios_mods.h"

#define OPENQ4_URL_MAX_PENDING 8
#define OPENQ4_URL_MAX_ARG     256

static pthread_mutex_t g_urlLock = PTHREAD_MUTEX_INITIALIZER;
static char           *g_urlPending[OPENQ4_URL_MAX_PENDING];
static int             g_urlPendingCount = 0;

/* Logged to stdout (bridge + simctl --console) and to the black box, because a
 * deep link is normally exercised on a build with no console attached. */
static void URLLog(const char *fmt, ...) {
	char line[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	fprintf(stdout, "openQ4 url: %s\n", line);
	fflush(stdout);
	OpenQ4_iOS_BlackBox("url: %s", line);
}

/*
 * Argument charset for the map and connect routes.
 *
 * The engine's command buffer separates commands on ';' and newlines, so an
 * unvalidated argument turns `openq4://map/x` into an arbitrary console line
 * and gives every web page the console the public build deliberately withholds.
 * Map names and host:port need none of those characters.
 */
static BOOL URLArgIsSafe(NSString *arg) {
	static NSCharacterSet *allowed;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		allowed = [[NSCharacterSet characterSetWithCharactersInString:
					@"abcdefghijklmnopqrstuvwxyz"
					@"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
					@"0123456789._-/:"] invertedSet];
	});
	if (arg.length == 0 || arg.length > OPENQ4_URL_MAX_ARG) {
		return NO;
	}
	return [arg rangeOfCharacterFromSet:allowed].location == NSNotFound;
}

/*
 * The `continue` route queues an engine command, not a save name: which save is
 * newest — and which of them this build can actually restore — is a question
 * about the game directory and save format of the RUNNING engine. The engine's
 * `loadNewestGame` (overlay patch 0009, iOS only) walks the Load menu's own list
 * newest first and loads the first save LoadGame accepts, so a name never goes
 * through a console line and an unloadable newest save falls back to the next.
 */
static const char *const kContinueCommand = "loadNewestGame";

/* Hand everything queued to the engine. Caller holds no lock. */
static void URLFlushLocked(void) {
	char *ready[OPENQ4_URL_MAX_PENDING];
	int count = 0;

	pthread_mutex_lock(&g_urlLock);
	if (OpenQ4_iOS_InitCompleted()) {
		for (int i = 0; i < g_urlPendingCount; i++) {
			ready[count++] = g_urlPending[i];
		}
		g_urlPendingCount = 0;
	}
	pthread_mutex_unlock(&g_urlLock);

	for (int i = 0; i < count; i++) {
		URLLog("running '%s'", ready[i]);
		OpenQ4_iOS_QueueConsoleCommand(ready[i]);
		free(ready[i]);
	}
}

static void URLQueueCommand(const char *cmd) {
	pthread_mutex_lock(&g_urlLock);
	if (g_urlPendingCount < OPENQ4_URL_MAX_PENDING) {
		g_urlPending[g_urlPendingCount++] = strdup(cmd);
	} else {
		fprintf(stdout, "openQ4 url: pending queue full, dropping '%s'\n", cmd);
	}
	pthread_mutex_unlock(&g_urlLock);
	URLFlushLocked();
}

void OpenQ4_iOS_DrainPendingURLs(void) {
	// Cheap enough to call every frame: one uncontended lock and, in the normal
	// case, an immediate zero-count exit.
	if (g_urlPendingCount == 0) {
		return;
	}
	URLFlushLocked();
}

void OpenQ4_iOS_HandleURL(const char *urlStr) {
	if (urlStr == NULL || urlStr[0] == '\0') {
		return;
	}
	@autoreleasepool {
		NSString *raw = [NSString stringWithUTF8String:urlStr];
		if (raw == nil) {
			URLLog("ignored (not UTF-8)");
			return;
		}
		URLLog("received %s", raw.UTF8String);

		NSURLComponents *c = [NSURLComponents componentsWithString:raw];
		if (c == nil || ![c.scheme.lowercaseString isEqualToString:@"openq4"]) {
			URLLog("ignored (not an openq4:// URL)");
			return;
		}

		NSString *route = c.host.lowercaseString ?: @"";
		// percentEncodedPath, not path: the console route carries an encoded
		// command whose spaces and slashes must survive to exactly one decode.
		NSString *rest = c.percentEncodedPath ?: @"";
		while ([rest hasPrefix:@"/"]) {
			rest = [rest substringFromIndex:1];
		}
		NSString *arg = [rest stringByRemovingPercentEncoding] ?: @"";

		if (route.length == 0) {
			// `openq4://` — the app is already opening, which was the request.
			URLLog("open (no route)");
			return;
		}

		NSString *cmd = nil;
		if ([route isEqualToString:@"continue"]) {
			URLLog("route 'continue' -> '%s' (newest loadable savegame, chosen by the engine)", kContinueCommand);
			URLQueueCommand(kContinueCommand);
			return;
		} else if ([route isEqualToString:@"map"]) {
			if (!URLArgIsSafe(arg)) {
				URLLog("REFUSED map: unsafe or empty name");
				return;
			}
			cmd = [NSString stringWithFormat:@"map %@", arg];
		} else if ([route isEqualToString:@"connect"]) {
			if (!URLArgIsSafe(arg)) {
				URLLog("REFUSED connect: unsafe or empty address");
				return;
			}
			cmd = [NSString stringWithFormat:@"connect %@", arg];
#if !defined(OPENQ4_PUBLIC_BUILD)
		} else if ([route isEqualToString:@"console"]) {
			// Same gate as the console bridge, and for the same reason: a public
			// build must not hand arbitrary console execution to anything that
			// can open a link. In a public build (D-113) the route is not
			// compiled in at all and falls through to "unknown route".
			if (!OpenQ4_iOS_BridgeEnabled()) {
				URLLog("REFUSED console: disabled in public builds");
				return;
			}
			if (arg.length == 0 || arg.length > OPENQ4_URL_MAX_ARG ||
				[arg rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
				URLLog("REFUSED console: empty, too long, or multi-line");
				return;
			}
			cmd = arg;
		} else {
			URLLog("unknown route '%s' — try continue map/ connect/ console/", route.UTF8String);
			return;
		}
#else
		} else {
			URLLog("unknown route '%s' — try continue map/ connect/", route.UTF8String);
			return;
		}
#endif

		URLLog("route '%s' -> '%s'", route.UTF8String, cmd.UTF8String);
		URLQueueCommand(cmd.UTF8String);
	}
}

/* ------------------------------------------------------------ iOS delivery */

#if !TARGET_OS_VISION

static BOOL (*g_origOpenURL)(id, SEL, UIApplication *, NSURL *, NSDictionary *);
static BOOL (*g_origDidFinishLaunching)(id, SEL, UIApplication *, NSDictionary *);
static void (*g_origSceneOpenURLContexts)(id, SEL, UIScene *, NSSet *);
static void (*g_origSceneWillConnect)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *);

static BOOL OpenQ4_OpenURL(id self, SEL _cmd, UIApplication *app, NSURL *url, NSDictionary *opts) {
	if (url) {
		OpenQ4_iOS_HandleURL(url.absoluteString.UTF8String);
	}
	// SDL's original still runs: a real file drop must keep working.
	return g_origOpenURL ? g_origOpenURL(self, _cmd, app, url, opts) : YES;
}

static BOOL OpenQ4_DidFinishLaunching(id self, SEL _cmd, UIApplication *app, NSDictionary *options) {
	// Cold launch from a link: iOS passes the URL here and never calls
	// application:openURL:. Handled BEFORE SDL's original, which is what starts
	// the engine — the command simply waits on the pending queue until init
	// finishes.
	NSURL *url = options[UIApplicationLaunchOptionsURLKey];
	if (url) {
		OpenQ4_iOS_HandleURL(url.absoluteString.UTF8String);
	}
	return g_origDidFinishLaunching ? g_origDidFinishLaunching(self, _cmd, app, options) : YES;
}

static void OpenQ4_SceneOpenURLContexts(id self, SEL _cmd, UIScene *scene, NSSet *contexts) {
	for (UIOpenURLContext *ctx in contexts) {
		OpenQ4_iOS_HandleURL(ctx.URL.absoluteString.UTF8String);
	}
	if (g_origSceneOpenURLContexts) {
		g_origSceneOpenURLContexts(self, _cmd, scene, contexts);
	}
}

static void OpenQ4_SceneWillConnect(id self, SEL _cmd, UIScene *scene,
									UISceneSession *session, UISceneConnectionOptions *options) {
	for (UIOpenURLContext *ctx in options.URLContexts) {
		OpenQ4_iOS_HandleURL(ctx.URL.absoluteString.UTF8String);
	}
	if (g_origSceneWillConnect) {
		g_origSceneWillConnect(self, _cmd, scene, session, options);
	}
}

/*
 * Diagnostic, reachable over the bridge as `!urlinfo`: which class the live app
 * delegate actually is, and whether our implementation is the one installed on
 * it. Deep links fail silently by nature — the OS simply never calls you — so
 * "is the hook in place" has to be answerable without a rebuild.
 */
void OpenQ4_iOS_ReportURLHandler(void) {
	id delegate = UIApplication.sharedApplication.delegate;
	Class dcls = delegate ? object_getClass(delegate) : Nil;
	struct { const char *label; SEL sel; IMP ours; } probes[] = {
		{ "application:openURL:options:",   @selector(application:openURL:options:),   (IMP)OpenQ4_OpenURL },
		{ "scene:openURLContexts:",         @selector(scene:openURLContexts:),         (IMP)OpenQ4_SceneOpenURLContexts },
		{ "scene:willConnectToSession:",    @selector(scene:willConnectToSession:options:), (IMP)OpenQ4_SceneWillConnect },
	};
	fprintf(stdout, "openQ4 url: live delegate=%s pending=%d\n",
			dcls ? class_getName(dcls) : "(none)", g_urlPendingCount);
	for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
		Method m = dcls ? class_getInstanceMethod(dcls, probes[i].sel) : NULL;
		fprintf(stdout, "openQ4 url:   %-32s %s\n", probes[i].label,
				m == NULL ? "ABSENT" :
					(method_getImplementation(m) == probes[i].ours ? "ours" : "NOT ours"));
	}
	fflush(stdout);
}

static IMP OpenQ4_SwizzleIfPresent(Class cls, SEL sel, IMP replacement, const char *label) {
	if (cls == Nil) {
		return NULL;
	}
	Method m = class_getInstanceMethod(cls, sel);
	if (m == NULL) {
		fprintf(stdout, "openQ4 url: %s not found on %s — that route is dead\n",
				label, class_getName(cls));
		return NULL;
	}
	IMP orig = method_getImplementation(m);
	method_setImplementation(m, replacement);
	return orig;
}

void OpenQ4_iOS_InstallURLHandler(void) {
	static int installed = 0;
	if (installed) {
		return;
	}
	installed = 1;

	/*
	 * WHICH class is the app delegate is not obvious, and getting it wrong is a
	 * silent failure. SDL_RunApp prefers the SCENE delegate's class name over
	 * SDLUIKitDelegate's, and our own SDL overlay (patches-sdl 0002, the
	 * SwiftUI-coexistence fix) RENAMES that class to SDLUIKitSceneShim — so the
	 * live delegate on iOS is SDLUIKitSceneShim, a class that does not implement
	 * application:openURL:options: at all. Measured with !urlinfo: swizzling
	 * SDLUIKitDelegate alone installed a hook on a class nothing ever asks.
	 *
	 * So every candidate is hooked, and `!urlinfo` reports which one the running
	 * app actually uses.
	 */
	Class appCls   = objc_getClass("SDLUIKitDelegate");
	Class shimCls  = objc_getClass("SDLUIKitSceneShim");
	Class sceneCls = shimCls ?: objc_getClass("SDLUIKitSceneDelegate");

	g_origOpenURL = (BOOL (*)(id, SEL, UIApplication *, NSURL *, NSDictionary *))
		OpenQ4_SwizzleIfPresent(appCls, @selector(application:openURL:options:),
								(IMP)OpenQ4_OpenURL, "application:openURL:options:");
	g_origDidFinishLaunching = (BOOL (*)(id, SEL, UIApplication *, NSDictionary *))
		OpenQ4_SwizzleIfPresent(appCls, @selector(application:didFinishLaunchingWithOptions:),
								(IMP)OpenQ4_DidFinishLaunching, "application:didFinishLaunchingWithOptions:");
	g_origSceneOpenURLContexts = (void (*)(id, SEL, UIScene *, NSSet *))
		OpenQ4_SwizzleIfPresent(sceneCls, @selector(scene:openURLContexts:),
								(IMP)OpenQ4_SceneOpenURLContexts, "scene:openURLContexts:");
	g_origSceneWillConnect = (void (*)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *))
		OpenQ4_SwizzleIfPresent(sceneCls, @selector(scene:willConnectToSession:options:),
								(IMP)OpenQ4_SceneWillConnect, "scene:willConnectToSession:options:");

	// The scene class conforms to UIApplicationDelegate but does not implement
	// the URL entry point, so UIKit would have nothing to call if this app ever
	// runs in the legacy (non-scene) regime with the shim as its delegate.
	// Added rather than swizzled, and with no original to chain to.
	if (sceneCls != Nil &&
		class_getInstanceMethod(sceneCls, @selector(application:openURL:options:)) == NULL) {
		class_addMethod(sceneCls, @selector(application:openURL:options:),
						(IMP)OpenQ4_OpenURL, "B@:@@@");
	}

	fprintf(stdout, "openQ4 url: handler installed (app=%s scene=%s)\n",
			appCls ? class_getName(appCls) : "none",
			sceneCls ? class_getName(sceneCls) : "none");
	fflush(stdout);
}

/*
 * Before main(), and that is the point: a cold launch from a link runs the app
 * delegate's didFinishLaunching before SDL_main exists, so installing from the
 * engine's main() (as dhewm3-ios does) can never catch it.
 */
__attribute__((constructor))
static void OpenQ4_InstallURLHandlerAtLoad(void) {
	OpenQ4_iOS_InstallURLHandler();
}

#else  /* TARGET_OS_VISION */

/* SwiftUI entry: OpenQ4VisionApp.swift calls OpenQ4_iOS_HandleURL directly and
 * there is no SDL delegate in the process to intercept. */
void OpenQ4_iOS_InstallURLHandler(void) {}

void OpenQ4_iOS_ReportURLHandler(void) {
	fprintf(stdout, "openQ4 url: visionOS — SwiftUI .onOpenURL, no delegate hook; pending=%d\n",
			g_urlPendingCount);
	fflush(stdout);
}

#endif

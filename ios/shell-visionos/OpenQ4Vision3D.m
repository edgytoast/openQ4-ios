/*
 * OpenQ4Vision3D.m — entering, leaving and reporting on the visionOS 3D panel.
 * Phase 6 round 2, D-100.
 *
 * Ordering is the whole content of this file, and it is vkQuake's (D-029/D-031,
 * adopted verbatim in docs/stereo-design.md §3):
 *
 *   enter  = curtain up
 *          -> r_stereo3d 1 through the ENGINE'S OWN COMMAND QUEUE
 *          -> wait for the engine to confirm the bypass is live
 *          -> open the space (SwiftUI)
 *   exit   = stop the compositor thread and wait for it to leave
 *          -> dismissImmersiveSpace (SwiftUI)
 *          -> finalize: r_stereo3d 0, curtain down
 *
 * Two details are load-bearing:
 *
 *  - The cvar is NEVER written directly. The engine runs on its own thread
 *    (openq4_ios_bridge.m's OpenQ4_EngineThread); the bridge's command queue is
 *    the one channel that is safe from here, and it is the same one the console
 *    uses. The confirmation poll reads a latched int the engine publishes, so
 *    "the space opened before the engine stopped presenting to the window" is
 *    not a race anyone has to reason about.
 *  - The thread STOP handshake completes before the space is dismissed. A
 *    render thread still holding a layer renderer SwiftUI is tearing down is
 *    the sibling's most expensive crash.
 *
 * ROUND 3b KEEPS THE PARK AND REPLACES ITS CONTENT (D-102). The maintainer's 0.1.0.60
 * verdict — "the parked window should be a black window that says playing in 3d
 * like the other ports do" — was first read as "do not shrink it", and briefly
 * implemented that way. It is wrong: what the other ports SHIP is a 480 pt card
 * (vkQuake VKQHostViewController.m:153-158 at the panel's aspect, quake3e
 * AppShell_vision.m:153-184 at a fixed 480x270), opaque black, one centred
 * "Playing in 3D". A full-size window is worse than the card for the reason the
 * card exists: it sits in front of the panel and covers the crosshair, which is
 * the 0.1.0.58 complaint the park was introduced to fix.
 *
 * What he actually objected to was the round-3 card's CONTENT — a wall of
 * "drag this card out of the way" copy and an unlabelled gear glyph on a
 * 480 pt surface — and the letterboxed 2D window the exit left behind. The
 * second is fixed in the backend (the one-shot reconcile on the 3D-ownership
 * release, vk_Backend.cpp); the first is fixed here: the card now carries the
 * siblings' exact string and nothing else, and the ornament below it carries
 * LABELLED bordered Exit 3D and 3D Settings buttons.
 *
 * The park ordering stays D-101's — park BEFORE the space opens, not the
 * siblings' park-1.5 s-after. A window geometry change is a scene
 * reconfiguration and a live CompositorLayer does not survive one: parking
 * after cost two runs in five, silently falling back to 2D about ten seconds
 * in with withheld=1 invalidated=1. Parking first is free, because the engine
 * is already rendering into the offscreen pair and the eye extent is decoupled
 * from the window, so the resize touches only a swapchain nothing reads.
 */

#import "OpenQ4Vision3D.h"
#import "OpenQ4Immersive.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach_time.h>

#import "../shell/openq4_ios_blackbox.h"
#import "../shell/openq4_ios_bridge.h"
#import "../shell/openq4_ios_loc.h"
#import "../shell/openq4_ios_settings.h"
#import "../shell/openq4_ios_touch.h"

// Engine bridge (overlay 0019/0027, OPENQ4_VISIONOS_3D).
extern int  OpenQ4_VK3D_Enabled(void);
extern int  OpenQ4_VK3D_Frames(void);
extern void OpenQ4_VK3D_SetStereo(float separation, float convergence, float gunDepth);
extern void OpenQ4_VK3D_GetStereo(float *separation, float *convergence, float *gunDepth);
extern void OpenQ4_VK3D_SetEyeSize(int width, int height);
extern void OpenQ4_VK3D_PresentSize(int *width, int *height);
extern void OpenQ4_VK3D_GuiViewport(int *x, int *y, int *width, int *height);
extern void OpenQ4_VK3D_WindowStats(int *winSkips, int *acqTimeouts, int *exitRecreates, int *grace);
// D-107 review fold-in: while the window's Metal view is hidden, the engine's
// window acquires are bounded (vk_GuiExecutor.cpp vk3dWindowHidden).
extern void OpenQ4_VK3D_SetWindowHidden(int hidden);

// Swift (@_cdecl in OpenQ4VisionApp.swift): flips the state that actually opens
// or dismisses the ImmersiveSpace.
extern void OpenQ4_SetImmersiveMode(_Bool on);

static int g_wanted3D = 0;	// what the shell asked for; the truth is the engine's
/*
 * Exit-race bookkeeping (D-107 review fold-in, found by the rapid enter/exit
 * cycles the review asked for). The exit used to reach Finalize ONLY through
 * SwiftUI: OpenQ4_SetImmersiveMode(false) -> onChange(false) -> dismiss ->
 * Finalize. Two simulator runs showed that chain can be absent or never return:
 *  - an exit during the park wait (before the space was ever asked for) flips a
 *    model value that is already false, so onChange never fires: curtain up,
 *    window parked and r_stereo3d 1 for good;
 *  - an exit ~50 ms after the space opened called dismissImmersiveSpace and it
 *    never returned, so Finalize never ran either.
 * g_spaceRequested says whether SwiftUI was asked to open a space this entry;
 * g_finalizePending says an exit is owed a Finalize, and makes Finalize run
 * exactly once per exit whichever path (SwiftUI, direct, watchdog) gets there.
 */
static int g_spaceRequested = 0;
static int g_finalizePending = 0;
/*
 * Exit generations and queued re-entry (review of 657cdac5).
 *
 * g_exitGen counts exit requests. The 3 s dismiss watchdog captures it when it
 * is armed and does nothing if another exit has started since: without it, exit
 * #1's watchdog (finalized normally, then 3D re-entered and left again inside
 * 3 s) ran Finalize while exit #2's dismiss was still in flight.
 *
 * g_exitInFlight spans an exit from the request to the END of Finalize's tail
 * (curtain down, live 2D). An entry asked for inside that span is QUEUED in
 * g_reenterQueued and started when the exit completes, instead of being run
 * over the top of it. Abandoning the exit is not possible: once openq4_immStop
 * is set the space's compositor thread is gone and cannot be restarted, so that
 * space has to be dismissed whatever the user asks for next — and a new entry
 * that runs concurrently either finds the dead space still open (model value
 * already true, so no new space ever opens) or has its own space dismissed by
 * the old exit's poll, or has Finalize's tail send r_stereo3d 0 and drop the
 * curtain on it. Leaving again while the entry is still queued just cancels it.
 */
static unsigned g_exitGen = 0;
static int g_exitInFlight = 0;
static int g_reenterQueued = 0;

static void OpenQ4_Vision3D_SetCurtain(BOOL show);	// defined below
static void OpenQ4_Vision3D_EnforceCurtain(void);	// defined below

// --- the park ----------------------------------------------------------------
/*
 * In 3D the 2D window exists only as a control surface: the ornament's Exit 3D
 * and 3D Settings buttons, and the curtain that says where the game went. Full
 * size, it is a black slab in front of the panel covering the crosshair — which
 * is what the maintainer reported from 0.1.0.58, and what a full-size curtain
 * reproduced when D-102 first tried one. Parked, it is a small card he can
 * leave wherever he put it.
 *
 * 480 pt wide at the PANEL's aspect, so the card reads as a miniature of the
 * screen rather than an unrelated rectangle. That is vkQuake's shipped shape
 * (D-029) — quake3e fixes it at 480x270 instead, which is the same card at a
 * hardcoded 16:9.
 *
 * visionOS has no API to MOVE a window, so shrinking is the whole of the lever
 * and the panel's own Position Height row is the other half. The card is not
 * captioned with that advice any more: a 480 pt surface cannot carry three
 * lines of it legibly, and burying "Playing in 3D" under them is exactly what
 * the maintainer rejected.
 */
#define OPENQ4_PARK_WIDTH_PT	480.0

static CGSize g_pre3dWindowSize = { 0.0, 0.0 };

static UIWindowScene *OpenQ4_Vision3D_WindowScene(void) {
	/*
	 * D-107: the GAME window's own scene first. connectedScenes is an NSSet —
	 * unordered — and while the space is open (and for a moment after it is
	 * dismissed, which is exactly when RestoreWindow runs) it also holds the
	 * ImmersiveSpace's scene, which is a UIWindowScene too and is not
	 * Unattached. "The first one" could therefore be the space, and a geometry
	 * request sent there restores nothing.
	 */
	UIWindowScene *game = OpenQ4_iOS_GameWindow().windowScene;
	if (game != nil) { return game; }
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if ([scene isKindOfClass:UIWindowScene.class]
				&& scene.activationState != UISceneActivationStateUnattached) {
			return (UIWindowScene *)scene;
		}
	}
	return nil;
}

static void OpenQ4_Vision3D_RequestWindowSize(CGSize size) {
	UIWindowScene *scene = OpenQ4_Vision3D_WindowScene();
	if (scene == nil || size.width < 1.0 || size.height < 1.0) {
		OpenQ4_iOS_BlackBox("xr3d: park skipped — no attached window scene");
		return;
	}
	UIWindowSceneGeometryPreferencesVision *prefs =
		[[UIWindowSceneGeometryPreferencesVision alloc] initWithSize:size];
	[scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
		OpenQ4_iOS_BlackBox("xr3d: window geometry request refused: %s",
							error.localizedDescription.UTF8String);
	}];
	OpenQ4_iOS_BlackBox("xr3d: window geometry requested %.0fx%.0f pt",
						size.width, size.height);
}

// `!xrwin` (see the header): the park's own call, reachable from the bridge.
void OpenQ4_Vision3D_RequestWindowSizePt(double widthPt, double heightPt) {
	dispatch_async(dispatch_get_main_queue(), ^{
		OpenQ4_Vision3D_RequestWindowSize(CGSizeMake(widthPt, heightPt));
	});
}

static void OpenQ4_Vision3D_ParkWindow(void) {
	if (!g_wanted3D) {
		return;	// the user left 3D while the park was pending
	}
	UIWindowScene *scene = OpenQ4_Vision3D_WindowScene();
	if (scene == nil) { return; }
	if (g_pre3dWindowSize.width < 1.0) {
		// The window's own bounds, in points, and not the scene's
		// effectiveGeometry.systemFrame — that property is compiled out on
		// visionOS (a system frame is not a thing an app may read there). Bounds
		// are what requestGeometryUpdate takes back, so the round trip is exact.
		// The GAME window's bounds, for the same reason the curtain uses it
		// (D-106): on device the key window right after the ornament tap that
		// started this park can be SwiftUI's, and saving ITS size means the
		// restore hands the game window a size that was never its own.
		UIWindow *win = OpenQ4_iOS_GameWindow();
		if (win == nil) {
			win = scene.windows.firstObject;
			for (UIWindow *w in scene.windows) {
				if (w.isKeyWindow) { win = w; break; }
			}
		}
		if (win != nil) { g_pre3dWindowSize = win.bounds.size; }
	}
	float dist = 0.0f, halfW = 0.0f, halfH = 0.0f, height = 0.0f;
	OpenQ4_Immersive_GetPanel(&dist, &halfW, &halfH, &height);
	const double aspect = (halfH > 0.01f) ? ((double)halfW / (double)halfH) : (16.0 / 9.0);
	OpenQ4_Vision3D_RequestWindowSize(CGSizeMake(OPENQ4_PARK_WIDTH_PT,
												 OPENQ4_PARK_WIDTH_PT / aspect));
	// The curtain's constraints are pinned to the window, so it follows the
	// animation — but anything added during it can end up on top, so re-assert.
	OpenQ4_Vision3D_SetCurtain(YES);
	/*
	 * ...and again once the park ANIMATION has fully settled. vkQuake's belt
	 * and braces (ios/shell-visionos/VKQHostViewController.m:79-84), and it is
	 * explicitly for "the device-only animated-layout path the sim can't
	 * reproduce" — the same class of defect as the wrong-window bug this round
	 * fixes, and the simulator is no more able to disprove it now than it was
	 * then.
	 */
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		if (g_wanted3D) { OpenQ4_Vision3D_SetCurtain(YES); }
	});
}

/*
 * The restore, and the case D-102's backend fix now has to survive.
 *
 * Growing the window back changes the swapchain extent while 3D still owns
 * glConfig, so nothing updates it on the way through; the ownership release a
 * moment later then has to reconcile glConfig to a swapchain whose extent
 * already matches the window. That is exactly the one-shot reconcile in
 * vk_Backend.cpp's poll, and this is the path that exercises it — the
 * letterboxed 2D window the maintainer saw in 0.1.0.60 is what its absence looked like.
 */
static void OpenQ4_Vision3D_RestoreWindow(void) {
	if (g_pre3dWindowSize.width < 1.0) {
		return;
	}
	const CGSize restore = g_pre3dWindowSize;
	g_pre3dWindowSize = CGSizeZero;
	OpenQ4_Vision3D_RequestWindowSize(restore);
}

// --- engine-tick sampler (Q-035) ---------------------------------------------
/*
 * Q-035: does the parked window's display link keep full rate while the
 * ImmersiveSpace is open? It is not a question anyone can answer from the
 * documentation, and the fallback if the answer is "no" — a link not tied to the
 * window scene — changes the shell. So it is measured, here, from the one place
 * that sees every tick.
 *
 * Two numbers, because they answer different halves. engineTick p50/p95 is the
 * DISTRIBUTION of intervals between the ticks that did arrive. `link` is the
 * count of ticks divided by wall time since the previous report, so a link that
 * has stopped entirely reads 0.0 Hz instead of reading whatever its last
 * healthy intervals were.
 */
#define OPENQ4_TICK_SAMPLES 240
static double	g_tickSamples[OPENQ4_TICK_SAMPLES];
static int		g_tickCount;
static int		g_tickCursor;
static double	g_tickLastMs;
static long		g_tickTotal;			// every tick since launch
static long		g_tickAtLastReport = -1;
static double	g_tickReportMs;

static double OpenQ4_Vision3D_NowMs(void) {
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) { mach_timebase_info(&tb); }
	return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom / 1.0e6;
}

void OpenQ4_Vision3D_NoteEngineTick(void) {
	const double now = OpenQ4_Vision3D_NowMs();
	g_tickTotal++;
	if (g_tickLastMs > 0.0) {
		g_tickSamples[g_tickCursor] = now - g_tickLastMs;
		g_tickCursor = (g_tickCursor + 1) % OPENQ4_TICK_SAMPLES;
		if (g_tickCount < OPENQ4_TICK_SAMPLES) { g_tickCount++; }
	}
	g_tickLastMs = now;
	// D-107: the tick is on the main thread and sees every frame, so it is
	// also where the curtain is kept on top for the whole 3D session.
	OpenQ4_Vision3D_EnforceCurtain();
}

static int OpenQ4_Vision3D_CmpDouble(const void *a, const void *b) {
	const double x = *(const double *)a, y = *(const double *)b;
	return (x < y) ? -1 : (x > y) ? 1 : 0;
}

static void OpenQ4_Vision3D_TickPercentiles(double *p50, double *p95) {
	double sorted[OPENQ4_TICK_SAMPLES];
	const int n = g_tickCount;
	if (n <= 0) {
		*p50 = *p95 = 0.0;
		return;
	}
	memcpy(sorted, g_tickSamples, (size_t)n * sizeof(double));
	qsort(sorted, (size_t)n, sizeof(double), OpenQ4_Vision3D_CmpDouble);
	int i95 = (n * 95) / 100;
	if (i95 >= n) { i95 = n - 1; }
	*p50 = sorted[(n * 50) / 100 >= n ? n - 1 : (n * 50) / 100];
	*p95 = sorted[i95];
}

// --- the curtain -------------------------------------------------------------
/*
 * In 3D the engine stops presenting to the window swapchain, so the 2D window
 * freezes on its last frame: a confusing duplicate of the game hanging in front
 * of the panel. Cover it. The window stays interactive underneath, which is
 * what keeps the ornament's Exit button reachable.
 *
 * Edge CONSTRAINTS, not a frame: once anything constraint-based lives on the
 * window, the window lays out with Auto Layout, and an autoresizing curtain is
 * then left at stale geometry by any animated change (vkQuake's regression,
 * inherited rather than re-earned).
 */
static UIView  *g_curtain;
static UILabel *g_curtainLabel;

/*
 * D-107 defect 1 — the card was STILL the frozen frame on 0.1.0.62.
 *
 * D-106 moved the curtain to the right window and the simulator's `!views`
 * verdict was "OPAQUE AND ON TOP". The headset still showed the game's last
 * frame. Whatever puts that frame over the curtain on device — the window's
 * root view re-added above it (UIKit appends a re-rooted view ABOVE every
 * sibling, openq4_ios_bridge.m's OpenQ4_AfterViewHierarchyRebuild), the 2D
 * scene deactivating when the space opens (device-only; vkQuake
 * ios/shell/ios_touch.m:1274-1279), or the CAMetalLayer being composited
 * differently there — the frame itself lives in exactly one place: the game
 * window's CAMetalLayer. So while the curtain is up that layer is HIDDEN. No
 * stacking order, re-rooting or snapshot can show a game frame from a hidden
 * layer, and the curtain no longer has to win a z-order fight to be the
 * only thing on the card.
 *
 * Pad input is unaffected: SDL attaches GCEventInteraction to every WINDOW
 * (SDL_uikitvideo.m UIKit_SetGameControllerInteraction), not only to this view.
 * The engine never presents into the window while 3D is on (vk_GuiExecutor.cpp,
 * D-107: no-pair frames are dropped, not sent to the window), so nothing waits
 * on a hidden layer's drawable.
 *
 * And the curtain is kept on top for the whole session rather than at three
 * moments: the display-link tick checks it (two pointer compares) and counts
 * every time something had covered it, so the next device round can SAY
 * whether that happens instead of us guessing again.
 */
static NSMutableArray<UIView *> *g_hiddenMetalViews;
static int g_curtainRaises;		// times the tick found the curtain covered
static int g_metalRehides;		// times the tick found a metal view visible again
static int g_spatialAudio = -2;	// -2 never set, -1 failed, 0 window, 1 front
static BOOL g_curtainHidesMetal;
static volatile int g_curtainState;	// 0 down, 1 on top, 2 covered — written on main, read by !xr3diag
static volatile int g_metalHiddenCount;	// cleared on exit BEFORE the engine goes back to the window

static void OpenQ4_Vision3D_CollectMetalViews(UIView *v, NSMutableArray<UIView *> *out) {
	if ([v.layer isKindOfClass:CAMetalLayer.class]) { [out addObject:v]; }
	for (UIView *child in v.subviews) {
		OpenQ4_Vision3D_CollectMetalViews(child, out);
	}
}

static void OpenQ4_Vision3D_HideMetal(BOOL hide, UIWindow *win) {
	if (hide) {
		if (g_hiddenMetalViews == nil) { g_hiddenMetalViews = [NSMutableArray array]; }
		NSMutableArray<UIView *> *found = [NSMutableArray array];
		if (win != nil) { OpenQ4_Vision3D_CollectMetalViews(win, found); }
		for (UIView *v in found) {
			if (![g_hiddenMetalViews containsObject:v]) { [g_hiddenMetalViews addObject:v]; }
			v.hidden = YES;
		}
		OpenQ4_VK3D_SetWindowHidden(1);
		OpenQ4_iOS_BlackBox("xr3d: %d window Metal view(s) hidden behind the curtain",
							(int)found.count);
	} else {
		for (UIView *v in g_hiddenMetalViews) { v.hidden = NO; }
		OpenQ4_VK3D_SetWindowHidden(0);
		OpenQ4_iOS_BlackBox("xr3d: %d window Metal view(s) shown again",
							(int)g_hiddenMetalViews.count);
		[g_hiddenMetalViews removeAllObjects];
	}
}

// Main thread, every display-link tick, via OpenQ4_Vision3D_NoteEngineTick.
static void OpenQ4_Vision3D_EnforceCurtain(void) {
	if (g_curtain == nil) { g_curtainState = 0; g_metalHiddenCount = (int)g_hiddenMetalViews.count; return; }
	UIView *sv = g_curtain.superview;
	if (sv != nil && sv.subviews.lastObject != g_curtain) {
		[sv bringSubviewToFront:g_curtain];
		if (++g_curtainRaises <= 5) {
			OpenQ4_iOS_BlackBox("xr3d: curtain had been COVERED — raised again (%d)", g_curtainRaises);
		}
	}
	g_metalHiddenCount = (int)g_hiddenMetalViews.count;
	if (!g_curtainHidesMetal) { return; }
	// A rebuilt SDL view is a NEW metal view; hide that one too.
	UIWindow *win = (UIWindow *)sv;
	NSMutableArray<UIView *> *found = [NSMutableArray array];
	if (win != nil) { OpenQ4_Vision3D_CollectMetalViews(win, found); }
	g_curtainState = (sv != nil && sv.subviews.lastObject == g_curtain) ? 1 : 2;
	for (UIView *v in found) {
		if (!v.hidden) {
			v.hidden = YES;
			if (![g_hiddenMetalViews containsObject:v]) { [g_hiddenMetalViews addObject:v]; }
			if (++g_metalRehides <= 5) {
				OpenQ4_iOS_BlackBox("xr3d: a window Metal view was visible under the curtain — hidden (%d)",
									g_metalRehides);
			}
		}
	}
}

/*
 * THE CURTAIN'S WINDOW — and the cause of the maintainer's 0.1.0.61 frozen-frame card
 * (D-106).
 *
 * This used to be "the key window, else the scene's first". On the SIMULATOR
 * that is the game window, every time, because nothing else is ever key — which
 * is exactly why five sim rounds photographed a black card and the headset did
 * not. On DEVICE the curtain is raised from the ornament's button handler, and
 * right after an ornament tap the key window is SwiftUI's own ornament hosting
 * window: the curtain went up, opaque and on top, over a window nobody was
 * looking at, while the game window kept its frozen last frame.
 *
 * That trap is vkQuake's, named in its own curtain code
 * (ios/shell-visionos/VKQHostViewController.m:248-251, "'the key window' can be
 * a SwiftUI ornament/sheet hosting window right after a button tap on
 * visionOS") and answered the same way: ask for the GAME window explicitly,
 * which is the touch overlay's superview (vkQuake ios/shell/ios_touch.m:688-694
 * VKQ_iOS_GameWindow). The overlay is attached once, early, while the game
 * window is the only one there is — so its superview is the answer forever
 * after and no button tap can move it.
 *
 * The old search stays as the fallback for the window before the overlay is
 * attached, which is the only case it was ever right for.
 */
static UIWindow *OpenQ4_Vision3D_GameWindow(void) {
	UIWindow *game = OpenQ4_iOS_GameWindow();
	if (game != nil) { return game; }
	UIWindow *win = nil;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (w.isKeyWindow) { win = w; break; }
		}
		if (win == nil) { win = ((UIWindowScene *)scene).windows.firstObject; }
	}
	return win;
}

static void OpenQ4_Vision3D_SetCurtain(BOOL show) {
	if (show) {
		if (g_curtain != nil) {
			// Re-assert: anything added to the window later (or a layout pass)
			// can cover it.
			[g_curtain.superview bringSubviewToFront:g_curtain];
			return;
		}
		UIWindow *win = OpenQ4_Vision3D_GameWindow();
		if (win == nil) {
			OpenQ4_iOS_BlackBox("xr3d: no window found — curtain skipped");
			return;
		}
		g_curtain = [[UIView alloc] init];
		g_curtain.backgroundColor = UIColor.blackColor;
		// Stated, not inferred: `!views` reads all three back and prints a
		// verdict, and a curtain that is merely dark is not a curtain.
		g_curtain.opaque = YES;
		g_curtain.alpha = 1.0;
		g_curtain.tag = OPENQ4_CURTAIN_TAG;
		g_curtain.translatesAutoresizingMaskIntoConstraints = NO;

		// ONE line, the siblings' exact string, and nothing else on the card.
		// quake3e (AppShell_vision.m:120) and vkQuake (VKQHostViewController.m's
		// VKQ_CurtainRefreshText) both put exactly "Playing in 3D" here at
		// 16-24 pt, and that is what the maintainer meant by "like the other ports do".
		// Round 3 added two more lines of advice about dragging the card; on a
		// 480 pt surface they crowded the headline off its own card, which is
		// the half of his complaint that was about the card and not the park.
		// The advice now lives in the settings sheet's Screen Position Height
		// row, which is the control that actually acts on it.
		UILabel *l = [UILabel new];
		l.text = OpenQ4_LS(@"Playing in 3D");
		l.numberOfLines = 1;
		l.textAlignment = NSTextAlignmentCenter;
		l.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
		l.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
		l.adjustsFontSizeToFitWidth = YES;
		l.minimumScaleFactor = 0.6;
		l.translatesAutoresizingMaskIntoConstraints = NO;
		g_curtainLabel = l;
		[g_curtain addSubview:l];

		[win addSubview:g_curtain];
		g_curtainHidesMetal = YES;
		OpenQ4_Vision3D_HideMetal(YES, win);
		[NSLayoutConstraint activateConstraints:@[
			[g_curtain.leadingAnchor constraintEqualToAnchor:win.leadingAnchor],
			[g_curtain.trailingAnchor constraintEqualToAnchor:win.trailingAnchor],
			[g_curtain.topAnchor constraintEqualToAnchor:win.topAnchor],
			[g_curtain.bottomAnchor constraintEqualToAnchor:win.bottomAnchor],
			[l.centerXAnchor constraintEqualToAnchor:g_curtain.centerXAnchor],
			[l.centerYAnchor constraintEqualToAnchor:g_curtain.centerYAnchor],
			[l.widthAnchor constraintLessThanOrEqualToAnchor:g_curtain.widthAnchor multiplier:0.9],
		]];
		OpenQ4_iOS_BlackBox("xr3d: curtain up on %s window %p %.0fx%.0f "
							"(subview %d of %d)",
							(OpenQ4_iOS_GameWindow() == win) ? "GAME" : "fallback",
							(void *)(__bridge void *)win,
							win.bounds.size.width, win.bounds.size.height,
							(int)[win.subviews indexOfObject:g_curtain],
							(int)win.subviews.count);
	} else {
		g_curtainHidesMetal = NO;
		OpenQ4_Vision3D_HideMetal(NO, nil);	// idempotent: the exit already did it
		[g_curtain removeFromSuperview];
		g_curtain = nil;
		g_curtainLabel = nil;
		OpenQ4_iOS_BlackBox("xr3d: curtain down");
	}
}

// --- enter / exit ------------------------------------------------------------
static void OpenQ4_Vision3D_OpenSpaceWhenEngineReady(int triesLeft) {
	if (!g_wanted3D) {
		return;	// exit raced the entry; nothing to open
	}
	if (OpenQ4_VK3D_Enabled()) {
		OpenQ4_iOS_BlackBox("xr3d: engine bypass live (frames=%d) — parking the window",
							OpenQ4_VK3D_Frames());
		/*
		 * PARK FIRST, THEN OPEN THE SPACE. The siblings both park ~1.5 s AFTER
		 * the space is open; do not copy that. The first version here did, and
		 * the simulator answered by withholding a drawable and invalidating the
		 * layer about ten seconds later — 3D silently fell back to 2D
		 * mid-session, twice in five runs. A window geometry change is a scene
		 * reconfiguration, and reconfiguring the scene under a live
		 * CompositorLayer is what it cannot survive.
		 *
		 * Ordering it this way costs nothing: the engine is already rendering
		 * into the offscreen pair (r_stereo3d confirmed above), the eye extent
		 * is decoupled from the window (D-101), so the resize touches only the
		 * swapchain nothing is looking at. vkQuake reached the same ordering
		 * from the other direction (D-033: resize while still safely 2D, poll,
		 * then open).
		 */
		OpenQ4_Vision3D_ParkWindow();
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			if (!g_wanted3D) {
				return;	// exit raced the entry
			}
			OpenQ4_iOS_BlackBox("xr3d: window parked — opening the space");
			g_spaceRequested = 1;
			OpenQ4_SetImmersiveMode(true);
		});
		return;
	}
	if (triesLeft <= 0) {
		// Loud, and rolled back. Entering with the engine still presenting to
		// the window would leave a space with nothing in it and a game the
		// user can see twice.
		OpenQ4_iOS_BlackBox("xr3d: FATAL-ish — engine never confirmed r_stereo3d; "
							"entry abandoned, staying in 2D");
		fprintf(stdout, "openQ4 xr3d: engine never confirmed r_stereo3d — staying in 2D\n");
		fflush(stdout);
		g_wanted3D = 0;
		OpenQ4_iOS_QueueConsoleCommand("r_stereo3d 0");
		OpenQ4_Vision3D_SetCurtain(NO);
		return;
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		OpenQ4_Vision3D_OpenSpaceWhenEngineReady(triesLeft - 1);
	});
}

static void OpenQ4_Vision3D_DismissWhenThreadStopped(int triesLeft, unsigned gen) {
	if (gen != g_exitGen) {
		// A later exit owns the dismiss now (cannot happen while re-entry is
		// queued behind g_exitInFlight, but a stale poll must never act).
		OpenQ4_iOS_BlackBox("xr3d: exit poll superseded (gen %u, now %u) — dropped", gen, g_exitGen);
		return;
	}
	if (openq4_immRunning && triesLeft > 0) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			OpenQ4_Vision3D_DismissWhenThreadStopped(triesLeft - 1, gen);
		});
		return;
	}
	if (openq4_immRunning) {
		OpenQ4_iOS_BlackBox("xr3d: compositor thread did not stop in time — dismissing anyway");
	}
	if (!g_spaceRequested) {
		// The exit landed before SwiftUI was asked for a space (the park
		// wait). There is no space to dismiss and no onChange to come.
		OpenQ4_iOS_BlackBox("xr3d: exit before the space was requested — finalizing directly");
		OpenQ4_Vision3D_Finalize();
		return;
	}
	g_spaceRequested = 0;
	OpenQ4_SetImmersiveMode(false);
	// SwiftUI's dismiss normally finalizes within ~0.2 s. If it never reports
	// back, do not leave the user on a black card.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		// Only for the exit that armed it: a later exit has its own watchdog.
		if (gen == g_exitGen && g_finalizePending && !g_wanted3D) {
			OpenQ4_iOS_BlackBox("xr3d: dismiss did not report back in 3 s — finalizing anyway");
			OpenQ4_Vision3D_Finalize();
		}
	});
}

// Main thread. Only ever called with no exit in flight (see g_reenterQueued).
static void OpenQ4_Vision3D_Enter(void) {
	g_wanted3D = 1;
	OpenQ4_iOS_BlackBox("xr3d: entering — curtain, then r_stereo3d 1");
	// A new entry owes nothing to the previous exit, which has fully finished.
	g_finalizePending = 0;
	g_spaceRequested = 0;
	OpenQ4_Vision3D_SetCurtain(YES);
	// The engine's own queue, drained on the engine thread. Never a
	// direct cvar write from here.
	OpenQ4_iOS_QueueConsoleCommand("r_stereo3d 1");
	OpenQ4_Vision3D_OpenSpaceWhenEngineReady(60);	// ~3 s
}

void OpenQ4_Vision3D_Set(int on) {
	dispatch_async(dispatch_get_main_queue(), ^{
		// What the user has asked for last: an entry queued behind an exit
		// counts as "on".
		const int wanted = (g_wanted3D || g_reenterQueued) ? 1 : 0;
		if ((on != 0) == wanted) {
			OpenQ4_iOS_BlackBox("xr3d: already %s", on ? "on" : "off");
			return;
		}
		if (on) {
			if (g_exitInFlight) {
				g_reenterQueued = 1;
				OpenQ4_iOS_BlackBox("xr3d: entry queued — the previous exit is still in flight");
				return;
			}
			OpenQ4_Vision3D_Enter();
		} else {
			if (g_reenterQueued) {
				// Left again before the queued entry started: the exit in
				// flight already ends where this request wants to be.
				g_reenterQueued = 0;
				OpenQ4_iOS_BlackBox("xr3d: queued entry cancelled — the exit in flight continues");
				return;
			}
			g_wanted3D = 0;
			OpenQ4_iOS_BlackBox("xr3d: exiting — stopping the compositor thread");
			g_exitGen++;
			g_exitInFlight = 1;
			g_finalizePending = 1;
			openq4_immStop = 1;
			OpenQ4_Vision3D_DismissWhenThreadStopped(50, g_exitGen);	// ~1 s
		}
	});
}

int OpenQ4_Vision3D_IsOn(void) {
	return g_wanted3D;
}

/*
 * D-114. The engine thread asks this before a game-module swap or an engine
 * reload (Common.cpp Com_DeferTeardownWhile3D), both of which destroy and
 * rebuild the Vulkan device. With the space open that froze the panel on the
 * loading frame or crashed the app (Arena started from 3D), so 3D is left
 * first, by the ordinary exit, and the engine re-asks every frame until the
 * exit has fully finished: no entry wanted or queued, no exit in flight, and
 * the engine's own bypass unlatched. The flags are main-thread state read from
 * the engine thread, the same way OpenQ4_Vision3D_IsOn is; a stale read only
 * costs one more frame of waiting, since the engine asks again.
 */
static volatile int g_teardownExitAsked = 0;

int OpenQ4_Vision3D_HoldRendererTeardown(void) {
	const int entryWanted = (g_wanted3D || g_reenterQueued) ? 1 : 0;
	const int busy = entryWanted || g_exitInFlight || OpenQ4_VK3D_Enabled();
	if (!busy) {
		g_teardownExitAsked = 0;
		return 0;
	}
	if (entryWanted && !g_teardownExitAsked) {
		g_teardownExitAsked = 1;
		OpenQ4_iOS_BlackBox("xr3d: renderer rebuild requested in 3D — leaving 3D first");
		fprintf(stdout, "openQ4 xr3d: leaving 3D for a renderer rebuild (game module swap)\n");
		OpenQ4_Vision3D_Set(0);
	}
	return 1;
}

void OpenQ4_Vision3D_ImmersiveEnded(void) {
	// The compositor thread saw the layer invalidated: the Crown or the system
	// took the space. Run the ordinary exit so the engine and the UI agree.
	OpenQ4_iOS_BlackBox("xr3d: layer invalidated (Crown/system) — reconciling to 2D");
	dispatch_async(dispatch_get_main_queue(), ^{
		g_wanted3D = 0;
		g_exitGen++;
		g_exitInFlight = 1;
		g_finalizePending = 1;
		g_spaceRequested = 0;
		OpenQ4_SetImmersiveMode(false);
	});
}

void OpenQ4_Vision3D_Finalize(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		// Once per exit, whichever path arrives first (see g_finalizePending).
		if (!g_finalizePending) {
			OpenQ4_iOS_BlackBox("xr3d: finalize — already done for this exit, skipped");
			return;
		}
		g_finalizePending = 0;
		// Restore the window FIRST and let its animation finish before the
		// engine goes back to the swapchain: a geometry animation concurrent
		// with a swapchain recreate is the wedge vkQuake documented (D-029), and
		// r_stereo3d 0 is exactly such a recreate. The engine stays safely
		// offscreen during the gap and the curtain stays up, so what the user
		// sees is a growing black card and not a frozen game frame.
		//
		// The grow itself changes the swapchain extent while 3D still owns
		// glConfig, so nothing writes glConfig on the way through and the
		// extents already agree by the time ownership is released. Putting
		// glConfig back is therefore entirely down to the one-shot reconcile
		// vk_Backend.cpp arms on that release (D-102 defect 2) — this is the
		// path that exercises it, and the 0.4 s below is what gives it the
		// present or two it needs before the curtain comes down.
		OpenQ4_Vision3D_RestoreWindow();
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			// D-107: the window's Metal layer must be displayable BEFORE the
			// engine goes back to it — the curtain stays up over it for the
			// 0.4 s below, so nothing stale is seen in between.
			g_curtainHidesMetal = NO;
			OpenQ4_Vision3D_HideMetal(NO, nil);
			OpenQ4_iOS_QueueConsoleCommand("r_stereo3d 0");
			// Give the engine a frame or two to re-adopt the swapchain before
			// the curtain comes down, so what appears is a live frame and not
			// the stale one the window froze on.
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
						   dispatch_get_main_queue(), ^{
				OpenQ4_Vision3D_SetCurtain(NO);
				OpenQ4_iOS_BlackBox("xr3d: exit finalized — window rendering resumes (engineBypass=%d)",
									OpenQ4_VK3D_Enabled());
				// The exit is over only here: an entry asked for at any point
				// since the exit began starts now, from clean, live 2D.
				g_exitInFlight = 0;
				if (g_reenterQueued) {
					g_reenterQueued = 0;
					OpenQ4_iOS_BlackBox("xr3d: starting the entry queued during the exit");
					OpenQ4_Vision3D_Enter();
				}
			});
		});
	});
}

// --- D-107: after the space is really open ------------------------------------
/*
 * Swift calls this once openImmersiveSpace() has returned .opened. On hardware
 * that is the moment the 2D scene deactivates, i.e. the moment anything that
 * re-lays the window out would happen; vkQuake re-asserts its curtain 1.5 s and
 * 3 s after the space opens (VKQHostViewController.m:74-85) and so do we, on
 * top of the per-tick check, with the window's state written to the blackbox
 * each time so a device round can read what the card actually was.
 */
static void OpenQ4_Vision3D_LogCard(const char *when) {
	UIView *sv = g_curtain.superview;
	int visibleMetal = 0;
	NSMutableArray<UIView *> *found = [NSMutableArray array];
	if (sv != nil) { OpenQ4_Vision3D_CollectMetalViews(sv, found); }
	for (UIView *v in found) { if (!v.hidden) { visibleMetal++; } }
	UIWindowScene *ws = [sv isKindOfClass:UIWindow.class] ? ((UIWindow *)sv).windowScene : nil;
	OpenQ4_iOS_BlackBox("xr3d: card %s — curtain=%s top=%d metalViews=%d visibleMetal=%d "
						"scene=%ld window=%.0fx%.0f raises=%d rehides=%d",
						when, g_curtain != nil ? "up" : "DOWN",
						(sv != nil && sv.subviews.lastObject == g_curtain) ? 1 : 0,
						(int)found.count, visibleMetal,
						ws != nil ? (long)ws.activationState : -9L,
						sv.bounds.size.width, sv.bounds.size.height,
						g_curtainRaises, g_metalRehides);
}

void OpenQ4_Vision3D_SpaceOpened(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		// Review fold-in (D-107): an exit that lands as the space reports
		// opened has already run Finalize, which took the curtain down and
		// showed the Metal view. Re-raising here would hide it again with
		// nothing left to undo it, and EnforceCurtain would keep the 2D window
		// black for good. The +1.5 s / +3 s re-asserts below already check.
		if (!g_wanted3D) { return; }
		OpenQ4_Vision3D_SetCurtain(YES);	// re-assert; a no-op build if already up
		OpenQ4_Vision3D_LogCard("at space open");
		for (int i = 1; i <= 2; i++) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * i * NSEC_PER_SEC)),
						   dispatch_get_main_queue(), ^{
				if (!g_wanted3D) { return; }
				OpenQ4_Vision3D_SetCurtain(YES);
				OpenQ4_Vision3D_LogCard(i == 1 ? "+1.5 s" : "+3.0 s");
			});
		}
	});
}

void OpenQ4_Vision3D_NoteSpatialAudio(int state) {
	g_spatialAudio = state;
	OpenQ4_iOS_BlackBox("xr3d: spatial audio %s",
						state == 1 ? "FRONT (the panel)" : state == 0 ? "automatic (the window)" : "FAILED");
}

// --- compositor layout capabilities ------------------------------------------
// Recorded from OpenQ4VisionApp.swift's makeConfiguration, which is the only
// place the capability set exists. The Swift side already logs it to NSLog;
// this carries it into !xr3diag, where a device round can actually read it back
// over the bridge (0.1.0.58 reported layout=layered with no way to tell whether
// .dedicated had been refused or never asked for).
static int g_capDedicated = -1, g_capLayered = -1, g_capShared = -1, g_capFoveation = -1;
static int g_fovWanted = -1, g_fovEnabled = -1;

void OpenQ4_Vision3D_NoteLayoutCaps(int dedicated, int layered, int shared, int foveation,
									int wanted, int enabled) {
	g_capDedicated = dedicated;
	g_capLayered = layered;
	g_capShared = shared;
	g_capFoveation = foveation;
	g_fovWanted = wanted;
	g_fovEnabled = enabled;
	OpenQ4_iOS_BlackBox("xr3d: compositor layouts dedicated=%d layered=%d shared=%d "
						"supportsFoveation=%d want=%d foveation=%d "
						"(layouts queried WITH .foveationEnabled when wanted)",
						dedicated, layered, shared, foveation, wanted, enabled);
}

/*
 * Why fov= reads what it reads, in one word, because a device round reads this
 * line over the bridge and "0" on its own has three different causes:
 *   on          - configured with foveation, rate maps expected in the drawable
 *   off         - the Foveation row is off (the maintainer's A/B lever)
 *   unsupported - capabilities.supportsFoveation == false (every simulator)
 *   unknown     - the space has not been configured this run
 */
const char *OpenQ4_Vision3D_FoveationWhy(void) {
	if (g_fovEnabled < 0) { return "unknown"; }
	if (g_fovEnabled > 0) { return "on"; }
	if (g_capFoveation == 0) { return "unsupported"; }
	// D-106 retired the kill switch: foveation is now asked for unconditionally,
	// so "off" can no longer be a state the shell chose. g_fovWanted is kept in
	// the diag line because a future build could still be refused.
	return "refused";
}

const char *OpenQ4_Vision3D_LayoutCaps(void) {
	static char caps[48];
	if (g_capDedicated < 0) {
		return "unknown";	// the space has never been configured this run
	}
	snprintf(caps, sizeof(caps), "ded%d/lay%d/shr%d/fov%d",
			 g_capDedicated, g_capLayered, g_capShared, g_capFoveation);
	return caps;
}

// --- !xr3dtune ---------------------------------------------------------------
/*
 * One command for every live knob, so a device session over the tailnet bridge
 * can sweep the stereo without a rebuild and without hunting through the sheet
 * in a headset: `!xr3dtune <sep> <conv> [dist halfW halfH height dim]`.
 *
 * Separation and convergence are the two that decide whether the scene is
 * comfortable, so they are mandatory and first; the panel geometry and dimming
 * are optional tail arguments. Everything here is the SAME path the settings
 * sheet takes — a tuner that reaches past the product's own plumbing measures
 * the tuner (dhewm3-ios D-014).
 */
void OpenQ4_Vision3D_Tune(float separation, float convergence,
						  const float *dist, const float *halfW, const float *halfH,
						  const float *height, const float *dim) {
	OpenQ4_VK3D_SetStereo(separation, convergence, -2.0f);	// -2 = leave gun depth alone
	if (dist != NULL && halfW != NULL && halfH != NULL) {
		OpenQ4_Immersive_SetPanel(*dist, *halfW, *halfH);
	}
	if (height != NULL) { OpenQ4_Immersive_SetHeight(*height); }
	if (dim != NULL)    { OpenQ4_Immersive_SetDim(*dim); }
	OpenQ4_iOS_BlackBox("xr3d: tuned sep=%.2f conv=%.0f", separation, convergence);
}

void OpenQ4_Vision3D_SetGunDepth(float gunDepth) {
	OpenQ4_VK3D_SetStereo(-1.0f, -1.0f, gunDepth);	// -1 = leave sep/conv alone
}

void OpenQ4_Vision3D_SetEyeSize(int width, int height) {
	OpenQ4_VK3D_SetEyeSize(width, height);
	OpenQ4_iOS_BlackBox("xr3d: panel resolution requested %dx%d per eye", width, height);
}

// --- !xr3diag ----------------------------------------------------------------
void OpenQ4_Vision3D_DiagLine(char *buf, size_t size) {
	if (buf == NULL || size == 0) { return; }

	OpenQ4ImmersiveStats s;
	memset(&s, 0, sizeof(s));
	OpenQ4_Immersive_GetStats(&s);

	double tickP50 = 0.0, tickP95 = 0.0;
	OpenQ4_Vision3D_TickPercentiles(&tickP50, &tickP95);

	// Ticks per second since the PREVIOUS report: a frozen link reads 0.0.
	const double now = OpenQ4_Vision3D_NowMs();
	double linkHz = -1.0;
	if (g_tickAtLastReport >= 0 && now > g_tickReportMs + 1.0) {
		linkHz = (double)(g_tickTotal - g_tickAtLastReport) * 1000.0 / (now - g_tickReportMs);
	}
	g_tickAtLastReport = g_tickTotal;
	g_tickReportMs = now;

	char link[32];
	if (linkHz < 0.0) {
		snprintf(link, sizeof(link), "n/a");	// first report: no interval yet
	} else {
		snprintf(link, sizeof(link), "%.1f", linkHz);
	}

	float sep = 0.0f, conv = 0.0f, gun = 0.0f;
	OpenQ4_VK3D_GetStereo(&sep, &conv, &gun);

	// D-102 defect 1: the 2D composite's own extent, which is a DIFFERENT
	// rectangle from eye= whenever the UI viewport is still the window's. In 3D
	// it must read 0,0 at the full eye size; anything else is the HUD and the
	// crosshair laid out in a sub-rect of the panel.
	int guiX = 0, guiY = 0, guiW = 0, guiH = 0;
	OpenQ4_VK3D_GuiViewport(&guiX, &guiY, &guiW, &guiH);
	int winSkips = 0, acqTimeouts = 0, exitRecreates = 0, grace = 0;
	OpenQ4_VK3D_WindowStats(&winSkips, &acqTimeouts, &exitRecreates, &grace);

	// The field list is the spec (docs/stereo-design.md section 7). Round 3
	// fills the ones round 2 could only report n/a for: eyeL/eyeR (per-eye
	// renders, which MUST advance together — a gap between them is the doubling
	// having failed, and nothing else in this line would show it), pairs (what
	// the engine published), sep/conv/gun and dim. gpuEye is still round 4's.
	snprintf(buf, size,
			 "imm=%d frames=%d withheld=%d invalidated=%d anchor=%s views=%d "
			 "layout=%s fov=%d fovWhy=%s fovLayout=%s rmaps=%d rmap=%dx%d/%dx%d "
			 "drawable=%dx%d eye=%dx%d gui=%dx%d@%d,%d pairs=%d "
			 "eyeL=%d eyeR=%d consumed=%d engineTick=%.2f/%.2f compTick=%.2f/%.2f "
			 "gpuEye=n/a link=%s dim=%.2f sep=%.2f conv=%.0f gun=%.2f "
			 "engineFrames=%d published=%d pubLatency=%d superseded=%d bypass=%d "
			 "notReady=%d stalls=%d overruns=%d halfPairs=%d caps=%s "
			 "curtain=%s raises=%d metalHidden=%d rehides=%d audio=%s "
			 "winSkips=%d acqTimeouts=%d exitRecreates=%d grace=%d "
			 "exitInFlight=%d queued=%d exitGen=%u",
			 OpenQ4_Vision3D_IsOn() ? 1 : 0,
			 s.frames, s.withheld, s.invalidated,
			 s.anchorOk ? "ok" : "pending",
			 s.views,
			 s.dedicated ? "dedicated" : "layered",
			 // fov= is what the DRAWABLE carries (rate maps present), fovWhy=
			 // why that is, fovLayout= which of the two rate-map paths the loop
			 // is taking, and rmap= the granted map's screen (logical) size over
			 // its physical size — the ratio IS the foveation, and a device
			 // round that reads 2048x1984/1462x1416 knows the fovea is real.
			 s.foveation, OpenQ4_Vision3D_FoveationWhy(),
			 s.fovLayered ? "layered" : (s.foveation ? "dedicated" : "none"),
			 s.rateMaps,
			 s.rmapScreenW, s.rmapScreenH, s.rmapPhysW, s.rmapPhysH,
			 s.drawableW, s.drawableH,
			 // eye= is the PER-EYE render extent, which is now the Panel
			 // Resolution setting and no longer the window's drawable size.
			 s.eyeW, s.eyeH,
			 guiW, guiH, guiX, guiY,
			 s.pairs,
			 s.eyeL, s.eyeR, s.consumed,
			 tickP50, tickP95,
			 s.compP50, s.compP95,
			 link,
			 s.dim, sep, conv, gun,
			 // engineFrames is what it says: EYE frames the engine rendered into
			 // a present image (two per pair). published is the pairs that
			 // reached the panel, and published*2/engineFrames is the health
			 // number the 0.1.0.58 hardware round had no way to read.
			 s.submitted,
			 s.published,
			 s.pubLatency,
			 s.superseded,
			 OpenQ4_VK3D_Enabled(),
			 // notReady counts fence polls that found the GPU not yet finished:
			 // EXPECTED to be large at 120 Hz, where the guaranteed retire is
			 // the next wait on the frame's own slot, and no longer a lost
			 // frame. stalls counts engine frames that had to wait for the
			 // compositor to let go of a pair, overruns must stay 0. halfPairs
			 // counts right eyes that never reached their host frame's pair —
			 // also 0 in steady state, and the counter that would have shown
			 // the round-3 stale-pair bug had it been able to fire.
			 s.notReady, s.stalls, s.overruns, s.halfPairs,
			 // What the compositor actually offered, against what the shell
			 // asked for: the device reported layout=layered in 0.1.0.58 while
			 // OpenQ4VisionApp.swift asks for .dedicated, and only the
			 // capability query can say why.
			 OpenQ4_Vision3D_LayoutCaps(),
			 // D-107: what the card IS (curtain on top, how many times something
			 // covered it, whether the window's Metal layer is hidden), where the
			 // audio is anchored, and the window-swapchain rules' counters.
			 g_curtainState == 0 ? "down" : (g_curtainState == 1 ? "top" : "COVERED"),
			 g_curtainRaises, g_metalHiddenCount, g_metalRehides,
			 g_spatialAudio == 1 ? "front" : g_spatialAudio == 0 ? "window"
				 : g_spatialAudio == -1 ? "FAILED" : "unset",
			 winSkips, acqTimeouts, exitRecreates, grace,
			 g_exitInFlight, g_reenterQueued, g_exitGen);
}

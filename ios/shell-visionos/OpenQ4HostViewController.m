/*
 * OpenQ4HostViewController.m — boots the engine under the SwiftUI app entry
 * (visionOS only). D-090.
 *
 * Why a SwiftUI entry at all (D-089, decided a round before this file existed):
 * an ImmersiveSpace — the thing Phase 6's stereo mode renders into — can ONLY be
 * declared by a SwiftUI `App`. SDL3's own UIApplicationMain wrapper is therefore
 * bypassed on visionOS: the engine is built with -DOPENQ4_SWIFT_MAIN=1, which
 * renames `main` to `openq4_engine_main` and drops <SDL3/SDL_main.h>, and this
 * view controller calls that function once the SwiftUI window scene is live.
 * SDL then creates its own UIWindow against the active window scene
 * (UIKit_GetActiveWindowScene) and everything downstream — the display link, the
 * touch overlay, the console bridge — works exactly as it does on the SDL-main
 * path. SDL's lifecycle observation is NSNotification-based, not delegate-based,
 * so it keeps working with no app delegate of ours at all.
 *
 * The two load-bearing details, both inherited scar tissue rather than taste:
 *
 *  - Boot ON THE MAIN THREAD, ONE RUNLOOP HOP AFTER viewDidAppear. Earlier and
 *    UIKit_GetActiveWindowScene finds no foreground-active scene, so
 *    SDL_CreateWindow fails; on another thread and SDL's Darwin main-thread
 *    assertions fire. (vkQuake-ios shell-visionos/VKQHostViewController.m.)
 *  - Request the geometry lock with resizingRestrictions = Uniform and NO size.
 *    quake3e-ios AppShell_vision.m: asking for a SIZE here races the boot and
 *    the window comes up wrong; asking only for uniform (scale-only) resizing
 *    means a fixed-aspect render always fills its window, no bars, no
 *    distortion.
 *
 * `openq4_engine_main` RETURNS, it does not block: on every Apple mobile lane
 * OpenQ4_Main stashes argv, shows the boot overlay, starts the CADisplayLink and
 * returns 0 (overlay patch 0002) — common->Init() runs later, on the engine
 * thread, off the link's first tick. So there is nothing to spawn a thread for
 * here, and the main run loop is free the instant this returns, which is what
 * the launch watchdog requires.
 */

#import "OpenQ4HostViewController.h"

#import <GameController/GameController.h>

#include <unistd.h>

#import "../shell/openq4_ios_blackbox.h"

// SDL3 is statically linked and this target has no SDL header search path, so
// the two symbols it needs are declared by hand, as vkQuake's host does.
extern void SDL_SetMainReady(void);

// The engine entry, renamed by -DOPENQ4_SWIFT_MAIN=1 (overlay patch 0002).
extern int openq4_engine_main(int argc, char **argv);

static BOOL g_openq4Booted = NO;

@interface OpenQ4HostViewController ()
@property (nonatomic) BOOL geometryLocked;
@end

@implementation OpenQ4HostViewController

- (void)loadView {
	self.view = [[UIView alloc] initWithFrame:CGRectZero];
	self.view.backgroundColor = UIColor.blackColor;
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];

	[self lockWindowAspect];

	if (g_openq4Booted) {
		return;
	}
	g_openq4Booted = YES;

	OpenQ4_iOS_BlackBox("visionOS: host viewDidAppear — booting the engine next hop");

	// One run-loop hop, so the window scene is fully active before
	// SDL_CreateWindow goes looking for it.
	dispatch_async(dispatch_get_main_queue(), ^{
		UIWindowScene *ws = self.view.window.windowScene;
		const CGSize sz = ws ? ws.coordinateSpace.bounds.size : CGSizeZero;
		OpenQ4_iOS_BlackBox("visionOS: scene %.0fx%.0f pt, displayScale %.2f — calling openq4_engine_main",
							sz.width, sz.height,
							ws ? ws.traitCollection.displayScale : 0.0);

		/*
		 * chdir to the app bundle BEFORE the engine runs. This is not
		 * housekeeping — without it the app cannot find its own runtime packs.
		 *
		 * Sys_DefaultBasePath (src/sys/osx/macosx_compat.mm) walks exe path,
		 * cwd and three bundle paths looking for a directory containing
		 * BASE_GAMEDIR — which is `q4base`, the RETAIL data, and no .app bundle
		 * ever contains that. So every candidate is rejected on iOS too, and
		 * fs_basepath lands on the last-resort branch: "using current directory
		 * as fallback base path". On iOS that fallback is correct by accident,
		 * because an iOS app process starts with its working directory set to
		 * the .app bundle. A visionOS app starts at "/", so the same fallback
		 * produced fs_basepath='/' and the engine hard-fatalled with
		 * "runtime directory 'baseoq4' is missing a compatible mod.json" — the
		 * packs were in the bundle all along, three directories away.
		 *
		 * Making the cwd match what iOS hands us is the smallest honest fix and
		 * keeps ONE basepath story across both platforms. Changing
		 * Sys_DefaultBasePath instead would mean an overlay patch to upstream
		 * path logic that is behaving exactly as designed.
		 */
		const char *bundle = NSBundle.mainBundle.bundlePath.fileSystemRepresentation;
		if (bundle == NULL || chdir(bundle) != 0) {
			OpenQ4_iOS_BlackBox("visionOS: FATAL chdir to the bundle failed (%s) — "
								"fs_basepath will not find baseoq4",
								bundle ? bundle : "(null)");
		} else {
			OpenQ4_iOS_BlackBox("visionOS: cwd -> %s (what iOS gives a process for free)", bundle);
		}

		SDL_SetMainReady();
		// argv[0] is the real executable path, as UIApplicationMain would have
		// passed it on the SDL-entry path.
		static char  arg0fallback[] = "openQ4";
		char *arg0 = (char *)NSBundle.mainBundle.executablePath.fileSystemRepresentation;
		if (arg0 == NULL || arg0[0] == '\0') { arg0 = arg0fallback; }
		char *argv[] = { arg0, NULL };
		// Returns once the display link is armed; see the file comment.
		const int rc = openq4_engine_main(1, argv);
		OpenQ4_iOS_BlackBox("visionOS: openq4_engine_main returned %d (display link armed)", rc);

		// Whether SDL attached the pad interaction is not observable from a
		// screenshot and matters a great deal on visionOS, where an unclaimed
		// controller has its presses converted into gaze-pinch UI events and the
		// engine never sees them. SDL3 does attach it itself, on its own view
		// controller (SDL_uikitviewcontroller.m calls
		// UIKit_SetViewGameControllerInteraction when a pad connects) — so this
		// reports rather than duplicates. Adding a second interaction on OUR
		// view would not help: SDL's window is the one on top.
		[self reportGameControllerInteraction];
	});
}

/*
 * SDL's Metal view geometry is now SDL's own business again.
 *
 * D-090 shipped a 0.5 s timer here that re-pinned the view to its superview's
 * bounds, because SDL3's visionOS backend reported one fake
 * SDL_XR_SCREENWIDTH x SDL_XR_SCREENHEIGHT (1280x720) display and
 * `UIKit_ComputeViewFrame` placed the view with SDL window coordinates taken
 * against it — leaving a correctly sized view at (-320,-240) inside a real
 * 1920x1200 pt scene, and, through the same fake display bounds, a 2D UI
 * viewport clipped to the overlap.
 *
 * Overlay patch 0003 of the `apple` SDL set (visionos-window-geometry-from-the-
 * scene) fixes it at the root: on visionOS the display mode, the
 * window bounds and the Metal view frame all come from the live UIWindowScene,
 * and a geometry change propagates as SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED. The
 * timer is deleted rather than kept "just in case": a healing poll that can
 * never observe a mismatch is a claim nobody can check, and it would silently
 * mask the next regression in the patch. See D-091.
 */

/*
 * Scale-only resizing. NO size is requested: quake3e-ios found that asking for
 * one here races the boot sequence.
 */
- (void)lockWindowAspect {
	if (self.geometryLocked) {
		return;
	}
	UIWindowScene *ws = self.view.window.windowScene;
	if (ws == nil) {
		return;
	}
	self.geometryLocked = YES;

	UIWindowSceneGeometryPreferencesVision *geo =
		[[UIWindowSceneGeometryPreferencesVision alloc] init];
	geo.resizingRestrictions = UIWindowSceneResizingRestrictionsUniform;
	[ws requestGeometryUpdateWithPreferences:geo errorHandler:^(NSError *error) {
		OpenQ4_iOS_BlackBox("visionOS: geometry lock FAILED: %s",
							error.localizedDescription.UTF8String);
	}];
	OpenQ4_iOS_BlackBox("visionOS: window aspect locked (uniform resizing, no size requested)");
}

- (void)reportGameControllerInteraction {
	// A little later: SDL attaches the interaction when a pad CONNECTS, and a
	// pad paired before launch is reported asynchronously.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		int found = 0, views = 0;
		for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
			if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
			for (UIWindow *w in ((UIWindowScene *)scene).windows) {
				views++;
				for (id<UIInteraction> i in w.interactions) {
					if ([i isKindOfClass:GCEventInteraction.class]) { found++; }
				}
			}
		}
		OpenQ4_iOS_BlackBox("visionOS: GCEventInteraction on %d of %d window(s); %lu controller(s) connected",
							found, views, (unsigned long)GCController.controllers.count);
	});
}

@end

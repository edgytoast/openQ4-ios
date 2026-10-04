/*
 * openq4_ios_compat.h — the small set of UIKit things that genuinely differ
 * between iOS and visionOS, in ONE place.
 *
 * D-090. visionOS has no `UIScreen` at all — there is no single display, no
 * native scale and no panel refresh rate to ask about; an app is a window in a
 * shared space the compositor owns. Every `UIScreen` use in ios/shell/ is
 * therefore a hard compile error on xrOS, and so are the taptic engine and the
 * interface orientation. Each one needs a real ANSWER rather than an #ifdef
 * wrapped round the call site, and collecting them here is what makes the
 * visionOS gating auditable: one file to read, instead of a grep across 9k
 * lines of shell. (dhewm3-ios `app/ios/ios_compat.h` is the model.)
 *
 * The iOS branches below are textually the expressions the call sites used
 * before this header existed, so the iOS build is unchanged by construction.
 *
 * `TARGET_OS_VISION` is tested BEFORE `TARGET_OS_IPHONE` everywhere (D-069):
 * visionOS sets both.
 *
 * Included with a relative path (`#import "../compat/openq4_ios_compat.h"`)
 * rather than through HEADER_SEARCH_PATHS, so adding it needed no change to the
 * iOS target's build settings.
 */
#pragma once

#import <UIKit/UIKit.h>
#include <TargetConditionals.h>

/*
 * The window scene the app is actually running in, or nil before one attaches.
 * Foreground-active first, then any window scene: during a launch or a
 * transition the scene exists before it is active, and answering nil then makes
 * callers fall back to worse numbers than the scene already has.
 */
static inline UIWindowScene *OpenQ4_iOS_ActiveWindowScene(void) {
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if ([s isKindOfClass:UIWindowScene.class] &&
			s.activationState == UISceneActivationStateForegroundActive) {
			return (UIWindowScene *)s;
		}
	}
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if ([s isKindOfClass:UIWindowScene.class]) { return (UIWindowScene *)s; }
	}
	return nil;
}

/*
 * Native pixel scale for a view — what the render-scale code multiplies the
 * layer's contentsScale by.
 *
 * On iOS: the window's screen, falling back to the main screen. On visionOS:
 * the scene's trait collection. NOT a hardcoded 1.0 — dhewm3 tried that and its
 * native-resolution assertion then compared a 2560x1440 drawable against
 * 1280x720 points and reported a mismatch that was not one. 2.0 is the last
 * resort, which is what Vision Pro's window scenes actually report.
 */
static inline CGFloat OpenQ4_iOS_NativeScaleForView(UIView *view) {
#if TARGET_OS_VISION
	UIWindowScene *ws = view.window.windowScene ?: OpenQ4_iOS_ActiveWindowScene();
	CGFloat s = ws ? ws.traitCollection.displayScale : 0.0;
	return s > 0.0 ? s : 2.0;
#else
	return (view.window != nil) ? view.window.screen.nativeScale
								: UIScreen.mainScreen.nativeScale;
#endif
}

/*
 * Panel refresh rate, for the display link's preferredFrameRateRange.
 *
 * visionOS does not expose one: the compositor owns presentation and an app
 * does not drive a panel. 90 is what Vision Pro's compositor targets, and it is
 * a NOMINAL figure — the pacing telemetry's measured link deltas are the number
 * to trust there, exactly as dhewm3 records.
 */
static inline float OpenQ4_iOS_MaxFramesPerSecond(void) {
#if TARGET_OS_VISION
	return 90.0f;
#else
	return (float)UIScreen.mainScreen.maximumFramesPerSecond;
#endif
}

/*
 * UIImpactFeedbackStyleLight / …Medium by value. They are spelled out here
 * because the ENUM ITSELF is marked unavailable on visionOS — a function that
 * merely ignores its argument still will not compile with that type in the
 * signature.
 */
#define OPENQ4_HAPTIC_LIGHT   0   /* == UIImpactFeedbackStyleLight  */
#define OPENQ4_HAPTIC_MEDIUM  1   /* == UIImpactFeedbackStyleMedium */

/*
 * A light/medium impact tick, if the platform has one. visionOS has no
 * touchscreen and no taptic engine — there is nothing to buzz — so this is a
 * no-op there rather than an #ifdef at each of the three call sites.
 */
static inline void OpenQ4_iOS_HapticImpact(int style) {
#if TARGET_OS_VISION
	(void)style;
#else
	[[[UIImpactFeedbackGenerator alloc]
		initWithStyle:(UIImpactFeedbackStyle)style] impactOccurred];
#endif
}

/*
 * Set a button's title so that it actually RENDERS on visionOS (D-092).
 *
 * MEASURED, not guessed. On visionOS a `[UIButton buttonWithType:
 * UIButtonTypeSystem]` comes back with `configuration == nil`, exactly as on
 * iOS — but once that button has been laid out, its drawn title can no longer
 * be changed through the legacy path at all. A probe build on the Vision Pro
 * simulator retitled an on-screen button and photographed the result:
 *
 *   setTitle:forState:       currentTitle='Start openQ4'  rendered: BLANK
 *   + titleLabel.text/layout titleLabel ='Start openQ4'  rendered: BLANK
 *   + a UIButtonConfiguration                             rendered: correct
 *
 * That blank is the bug the maintainer hit on glass: after "I Added Files — Check
 * Again" the proceed button lost its label entirely and he had to guess which
 * unlabelled slab to pinch.
 *
 * So: write the legacy state title (which is what an iOS button, and a
 * visionOS button that has not been laid out yet, draw from), and on visionOS
 * also put the string in a UIButtonConfiguration — installing a plain one if
 * the button has none — because that is the only channel the visionOS button
 * re-reads. The font is carried over from titleLabel so the configuration path
 * does not silently reset it. iOS is untouched: the whole visionOS half is
 * behind TARGET_OS_VISION.
 *
 * The rule that follows, and which ios/shell/ now obeys: prefer showing and
 * hiding a button whose title was set at construction over retitling one.
 */
static inline void OpenQ4_iOS_SetButtonTitle(UIButton *button, NSString *title) {
	if (button == nil) { return; }
	[button setTitle:title forState:UIControlStateNormal];
#if TARGET_OS_VISION
	UIFont *font = button.titleLabel.font;
	NSAttributedString *attributed = [[NSAttributedString alloc]
		initWithString:(title ?: @"")
			attributes:(font != nil ? @{ NSFontAttributeName : font } : @{})];
	UIButtonConfiguration *cfg = button.configuration;
	if (cfg == nil) {
		cfg = [UIButtonConfiguration plainButtonConfiguration];
		// The surrounding layout already sizes these buttons; a configuration's
		// own padding on top of that would shift every label off centre.
		cfg.contentInsets = NSDirectionalEdgeInsetsZero;
	}
	cfg.attributedTitle = attributed;
	button.configuration = cfg;
#endif
}

/*
 * True when this platform has a gyroscope the player can aim with. CoreMotion
 * does not exist on visionOS at all (the framework is absent, so even the
 * import is an error), and head pose is not an aiming input anyway — Phase 6
 * owns head tracking, and it comes from ARKit, not from here.
 */
#if TARGET_OS_VISION
#define OPENQ4_HAVE_GYRO 0
#else
#define OPENQ4_HAVE_GYRO 1
#endif

/* Likewise: no touchscreen means no device/interface orientation. */
#if TARGET_OS_VISION
#define OPENQ4_HAVE_INTERFACE_ORIENTATION 0
#else
#define OPENQ4_HAVE_INTERFACE_ORIENTATION 1
#endif

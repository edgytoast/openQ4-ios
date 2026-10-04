/*
 * openq4_ios_touch.m — touch controls overlay.
 *
 * Layout (landscape):
 *
 *   left third      floating movement stick — spawns wherever the finger lands
 *   right two-thirds drag to look
 *   bottom right    fire / jump / crouch / use / reload
 *   top left        MENU (engine menu) and a gear for the iOS settings sheet
 *
 * Look accumulates between frames and is drained once per engine frame, so the
 * engine sees one coherent delta per tic rather than a burst of touch events at
 * whatever rate UIKit delivers them.
 */

#import <UIKit/UIKit.h>
#import "../compat/openq4_ios_compat.h"
#if OPENQ4_HAVE_GYRO
#import <CoreMotion/CoreMotion.h>
#endif
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <math.h>

#include "openq4_ios_touch.h"
#include "openq4_ios_settings.h"
#include "openq4_ios_loc.h"
#include "openq4_ios_bridge.h"
/*
 * Engine entry point for D-085's safe-area insets. Declared here rather than
 * through a header because it lives in the ENGINE (overlay patch 0005,
 * src/sys/sdl3/sdl3_backend.cpp), on the other side of the shell/engine line.
 */
extern void OpenQ4_iOS_PublishSafeAreaInsets(float left, float top, float right, float bottom);

// Tuned against the sibling ports' shipped values. Degrees per point, so
// sensitivity means the same thing on every panel density.
#define OPENQ4_LOOK_DEGREES_PER_POINT 0.34f
#define OPENQ4_STICK_RADIUS_PT        70.0f
#define OPENQ4_BUTTON_SIZE_PT         76.0f

// A tap is a touch that neither travelled far nor lingered. Both bounds matter:
// the slop keeps a look drag from steering the focus ray with the player's thumb
// while they walk (dhewm3-ios D-014), and the time bound keeps a slow, deliberate
// aim-and-hold from ending in a phantom panel click.
#define OPENQ4_TAP_SLOP_PT            16.0f
#define OPENQ4_TAP_MAX_SECONDS        0.35
// The click is held for ~6 tics. A down and up inside one 60 Hz tic nets the
// state back to zero before the game samples it and the click vanishes silently
// (dhewm3-ios D-013); a real finger is about this long anyway.
#define OPENQ4_TAP_CLICK_SECONDS      0.10
#define OPENQ4_TAP_RELEASE_SECONDS    0.06

/*
 * Gyro aim (D-083).
 *
 * Sampled at 120 Hz and consumed once per engine frame, which over-samples a
 * 60 Hz frame deliberately: the rate is integrated with the SAMPLE's own dt, so
 * a discarded sample costs nothing and a slow frame does not slow the turn.
 * vkQuake-ios and quake3e-ios both had the opposite bug — per-frame
 * accumulation with no dt, which made a 60 Hz refresh setting halve the gyro
 * turn rate.
 */
#define OPENQ4_GYRO_UPDATE_HZ         120.0
// A sample older than this is a resume, a stall, or a hitch, not a hand
// movement. Without the clamp the first frame after coming back from the
// background delivers the whole backgrounded interval as one enormous turn.
#define OPENQ4_GYRO_MAX_DT            0.25
// Degrees per second, per axis, below which a rate is treated as zero. None of
// the siblings has one; vkQuake sends floats straight through and therefore has
// no floor at all, while quake3e and dhewm3 get an accidental one from
// quantising to whole mouse counts. An explicit floor is the honest version of
// that accident: a phone resting on a table still reports tenths of a degree
// per second and the crosshair should not crawl.
#define OPENQ4_GYRO_DEADZONE_DPS      0.6f
// The dt the bridge's synthetic sample claims: ONE 60 Hz frame's worth of
// motion. It must be inside OPENQ4_GYRO_MAX_DT or the hitch clamp eats the
// sample — the first version of `!gyro` claimed dt = 1 s and was silently
// suppressed while reporting success, which is exactly the class of harness bug
// the command exists to avoid.
#define OPENQ4_GYRO_SYNTH_DT          (1.0 / 60.0)
// Radians to degrees, spelled out because it appears in the one place where
// getting it wrong is a factor-of-57 bug rather than a wrong sign.
#define OPENQ4_RAD_TO_DEG             57.29577951308232f

/*
 * Gyro activation, as stored in the `gyroMode` setting. Deliberately a mode and
 * not "sensitivity > 0 means on" (vkQuake's shape): the three states are not
 * points on one scale, and folding them into the slider makes "off" and "very
 * slow" the same gesture.
 */
typedef enum {
	OPENQ4_GYRO_OFF = 0,
	OPENQ4_GYRO_WHILE_TOUCHING = 1,
	OPENQ4_GYRO_ALWAYS = 2,
} openq4GyroMode_t;

// -1 = believe GameController, 0/1 = pretend. A TEST LEVER (D-106), for the
// same reason as g_forceVisible: no pad can be paired to a simulator, so
// "Touch Controls: Auto hides the overlay while a pad drives the game" has no
// other way to produce an artifact. Never set in a shipped path.
static int g_forcePad = -1;

@interface OpenQ4TouchView : UIView
- (void)beginEditingLayout;
- (NSString *)layoutDescription;
- (void)synthesizeTapAtNormalizedX:(CGFloat)nx y:(CGFloat)ny;
- (UIButton *)chromeButtonNamed:(NSString *)key;
// Gyro aim (D-083).
- (void)pollGyro;
- (int)injectSyntheticGyroYaw:(float)yawDegrees pitch:(float)pitchDegrees;
- (NSString *)gyroDescription;
- (void)setGyroBackgrounded:(BOOL)bg;
// Diagnostics (`!views`): the two pieces of state that decide whether the
// controls are on screen, readable from the C entry points below.
- (BOOL)shouldHideForPad;
@property (nonatomic, readonly) BOOL controlsVisible;
- (void)setControlsVisible:(BOOL)visible;
- (void)applyAppearance;
@end

@implementation OpenQ4TouchView {
	// _controlsVisible backs the readonly controlsVisible property declared above.
	// Movement stick
	UITouch  *_stickTouch;
	CGPoint   _stickOrigin;
	CGPoint   _stickCurrent;
	UIView   *_stickBase;
	UIView   *_stickKnob;

	// Look
	UITouch  *_lookTouch;
	CGPoint   _lookLast;
	// Direct touch on in-world GUIs (D-071): where the look touch landed, when,
	// and whether it still qualifies as a tap rather than a look drag.
	CGPoint   _lookStart;
	NSTimeInterval _lookStartTime;
	BOOL      _lookIsTap;
	// Bumped by every published aim. A deferred clear only fires if it still
	// owns the aim, so a second tap arriving inside the first one's click
	// window is not wiped by the first one's timer.
	NSUInteger _aimGeneration;
	CGFloat   _pendingYaw;      // degrees, drained per frame; written on the MAIN thread (touches)
	CGFloat   _pendingPitch;
	CGFloat   _gyroPendingYaw;  // degrees; written and drained on the ENGINE thread only (D-083)
	CGFloat   _gyroPendingPitch;

	NSMutableDictionary<NSString *, UIButton *> *_buttons;

	// Chrome, kept out of _buttons because these do not inject engine actions
	// and must not be scaled by the control-size slider — they are navigation,
	// not aiming, and a user who shrank their controls still needs to escape.
	UIButton *_settingsButton;
	UIButton *_pauseButton;        // hamburger, in-game, top right
	UIButton *_objectivesButton;   // objectives / scores, left of the hamburger
	NSDictionary<NSString *, UIButton *> *_chrome;

	// A connected pad retires the sticks and action buttons. The chrome stays:
	// a pad user still needs the settings sheet, and the engine's own menu is
	// reachable from the pad, so MENU is the only redundant one.
	BOOL _padConnected;
	BOOL _padStateKnown;
	UIButton *_dismissKeyboardButton;

	// Layout editing
	BOOL      _editing;
	UIButton *_dragButton;
	CGPoint   _dragOffset;
	UIView   *_editBar;
	UISlider *_editSlider;
	UILabel  *_editPercent;

	// Gyro aim (D-083). CoreMotion is created on demand and torn down the
	// moment the mode goes to Off, so an install that never enables it never
	// starts the sensor.
#if OPENQ4_HAVE_GYRO
	CMMotionManager *_motion;
#else
	// No CoreMotion on visionOS (the framework does not exist). Kept as a
	// typeless nil so the "is the sensor running" tests below — and `!gyro`'s
	// report — stay one code path on both platforms.
	id        _motion;
#endif
	BOOL      _motionUnavailable;    // no device motion here (simulator)
	BOOL      _gyroBackgrounded;
	NSTimeInterval _gyroLastSample;  // CoreMotion's own clock, not ours
	// Counters, for `!views`. "Gyro does nothing" has as many independent
	// causes as the overlay being invisible did (D-082), and a screenshot
	// distinguishes none of them either.
	unsigned long _gyroSamples;
	unsigned long _gyroSuppressed;
	double    _gyroYawApplied;       // cumulative view degrees, both sources
	double    _gyroPitchApplied;

	// Weapon wheel: a finger that lands on the wheel button steers it.
	UITouch  *_wheelTouch;
	CGPoint   _wheelLast;
	CGPoint   _wheelResidual;   // sub-count drag carried to the next sample
	BOOL      _crouchLatched;
	BOOL      _crouchHeldDown;      // we owe the engine a matching "up"
	BOOL      _crouchPressIsDouble;
	NSTimeInterval _lastCrouchPressTime;
}

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self == nil) {
		return nil;
	}
	self.multipleTouchEnabled = YES;
	self.backgroundColor = UIColor.clearColor;
	// The overlay must not eat touches meant for the engine's own GUI; it
	// forwards everything it handles and is hidden outside gameplay.
	self.userInteractionEnabled = YES;

	_buttons = [NSMutableDictionary dictionary];

	_stickBase = [[UIView alloc] initWithFrame:CGRectMake(0, 0, OPENQ4_STICK_RADIUS_PT * 2,
														 OPENQ4_STICK_RADIUS_PT * 2)];
	_stickBase.layer.cornerRadius = OPENQ4_STICK_RADIUS_PT;
	_stickBase.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
	_stickBase.layer.borderWidth = 2.0;
	_stickBase.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
	_stickBase.hidden = YES;
	_stickBase.userInteractionEnabled = NO;
	[self addSubview:_stickBase];

	_stickKnob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
	_stickKnob.layer.cornerRadius = 28;
	_stickKnob.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
	_stickKnob.hidden = YES;
	_stickKnob.userInteractionEnabled = NO;
	[self addSubview:_stickKnob];

	// SF Symbols, not text and not unicode glyphs — they scale cleanly, share a
	// weight, and are legible at these sizes where a text glyph is not. Fire is
	// a crosshair and stays the largest, because it is pressed constantly and
	// under pressure; everything else drops well below it.
	//
	// These positions are only starting points: the layout editor writes the
	// player's own into NSUserDefaults, and whatever the maintainer settles on becomes
	// the shipped default.
	// the maintainer's own arrangement, read off his device with `!layout` and pasted
	// back here — fractions of the view, so they hold on any screen.
	[self addButton:@"attack"    symbol:@"scope"                   atFraction:CGPointMake(0.8790f, 0.7167f) size:84];
	[self addButton:@"jump"      symbol:@"arrow.up"                atFraction:CGPointMake(0.9671f, 0.6317f) size:58];
	[self addButton:@"crouch"    symbol:@"arrow.down"              atFraction:CGPointMake(0.8063f, 0.9127f) size:58];
	// Quake 4 has no separate "use" action — attack activates — so this slot is
	// the weapon wheel, which is genuinely useful on a touch screen.
	[self addButton:@"weapwheel" symbol:@"circle.hexagongrid.fill" atFraction:CGPointMake(0.9258f, 0.3897f) size:58];
	[self addButton:@"reload"    symbol:@"arrow.clockwise"         atFraction:CGPointMake(0.8805f, 0.5397f) size:54];


	// In-game chrome, top right: the pause menu and the objectives list. These
	// are how a touch-only player reaches the menu at all, so unlike the gear
	// they belong ON SCREEN DURING PLAY.
	// One hamburger, not two. It was duplicated top-left and top-right, which
	// is just clutter — the same button in two places.
	_pauseButton = [self addSymbolChrome:@"line.3.horizontal" action:@selector(menuTapped)];
	_objectivesButton = [self addSymbolChrome:@"list.number"
									  action:@selector(objectivesUp)];
	// Down on press, up on release: objectives is a HELD display, exactly like
	// holding D-pad up, which is the thing the maintainer confirmed works.
	[_objectivesButton addTarget:self action:@selector(objectivesDown)
				forControlEvents:UIControlEventTouchDown];
	[_objectivesButton addTarget:self action:@selector(objectivesUp)
				forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
	_settingsButton = [self addSymbolChrome:@"gearshape.fill" action:@selector(settingsTapped)];

	// SF Symbols carry no accessible name of their own: without these VoiceOver
	// announces all three as "button".
	_pauseButton.accessibilityLabel = OpenQ4_L("Menu");
	_objectivesButton.accessibilityLabel = OpenQ4_L("Objectives");
	_settingsButton.accessibilityLabel = OpenQ4_L("Settings");

	// Chrome is draggable and persisted like everything else — it is on screen,
	// so it is part of the layout. It keeps its own show/hide rules; only its
	// POSITION is editable.
	_chrome = @{ @"chrome.pause":      _pauseButton,
				 @"chrome.objectives": _objectivesButton,
				 @"chrome.settings":   _settingsButton };

	// A keyboard with no way out is a trap: SDL raises it for save-game names
	// and console input, and nothing on screen dismisses it — the player is
	// stuck, and it comes back when they return to the menu.
	[NSNotificationCenter.defaultCenter addObserver:self
										   selector:@selector(keyboardShown:)
											   name:UIKeyboardWillShowNotification
											 object:nil];
	[NSNotificationCenter.defaultCenter addObserver:self
										   selector:@selector(keyboardHidden:)
											   name:UIKeyboardWillHideNotification
											 object:nil];

	[NSNotificationCenter.defaultCenter addObserver:self
										   selector:@selector(padsChanged)
											   name:GCControllerDidConnectNotification
											 object:nil];
	[NSNotificationCenter.defaultCenter addObserver:self
										   selector:@selector(padsChanged)
											   name:GCControllerDidDisconnectNotification
											 object:nil];
	[self padsChanged];

	return self;
}

- (void)addButton:(NSString *)action symbol:(NSString *)symbolName
	   atFraction:(CGPoint)fraction size:(CGFloat)size {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	UIImageSymbolConfiguration *cfg =
		[UIImageSymbolConfiguration configurationWithPointSize:size * 0.40f
														weight:UIImageSymbolWeightSemibold];
	[b setImage:[[UIImage systemImageNamed:symbolName] imageWithConfiguration:cfg]
	   forState:UIControlStateNormal];
	b.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
	b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
	b.layer.cornerRadius = size / 2;
	b.layer.borderWidth = 1.5;
	b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
	b.frame = CGRectMake(0, 0, size, size);
	b.tag = (NSInteger)[action hash];
	objc_setAssociatedObject(b, "openq4.action", action, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	[b addTarget:self action:@selector(buttonDown:) forControlEvents:UIControlEventTouchDown];
	[b addTarget:self action:@selector(buttonUp:)
		forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
						 UIControlEventTouchCancel];

	if ([action isEqualToString:@"weapwheel"]) {
		// Drag tracking on the control itself. UIControl follows the finger that
		// pressed it, inside the button and out, which is precisely the "hold
		// the wheel and steer with the same thumb" behaviour — and it avoids
		// fighting the button for its own touch, which is what forced a second
		// hand before.
		[b addTarget:self action:@selector(wheelDragged:withEvent:)
			forControlEvents:UIControlEventTouchDragInside | UIControlEventTouchDragOutside];
	}
	[self addSubview:b];
	_buttons[action] = b;
	objc_setAssociatedObject(b, "openq4.fraction", [NSValue valueWithCGPoint:fraction],
							 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIButton *)addChromeButton:(NSString *)title action:(SEL)sel {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
	[b setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.85] forState:UIControlStateNormal];
	b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
	b.layer.cornerRadius = 8;
	b.layer.borderWidth = 1.0;
	b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
	[b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
	[self addSubview:b];
	return b;
}

// A pad the player is not actually holding must never be able to strand them
// with no controls: pad detection is a convenience, and this is its escape
// hatch. The simulator, for one, reports the host Mac's controller.
/*
 * Touch Controls — Auto (0) / On (1) / Off (2), D-106.
 *
 * Auto is the shipped behaviour and the default: the playing controls hide
 * whenever a pad drives the game. On keeps them regardless — a pad the player
 * is not actually holding (the simulator reports the host Mac's controller)
 * must never be able to strand anyone with no controls. Off is the row this
 * port did not have: a Vision Pro with a Backbone, or a phone in a controller
 * clip, wants the overlay gone whether or not GameController has noticed yet.
 */
- (BOOL)shouldHideForPad {
	const int mode = (int)(OpenQ4_iOS_SettingFloat("touchMode", 0.0f) + 0.5f);
	if (mode == 1) { return NO; }    // On
	if (mode == 2) { return YES; }   // Off
	if (g_forcePad >= 0) { return g_forcePad != 0; }
	return _padConnected;
}

/*
 * Show or hide the playing controls. The chrome (MENU, gear) is deliberately
 * untouched: it must be reachable in menus, during cinematics and while a
 * controller is connected.
 */
- (void)keyboardShown:(NSNotification *)note {
	if (_dismissKeyboardButton == nil) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
		[b setTitle:OpenQ4_L("Done") forState:UIControlStateNormal];
		b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
		[b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
		b.backgroundColor = [UIColor colorWithRed:0.20 green:0.42 blue:0.85 alpha:0.95];
		b.layer.cornerRadius = 10;
		[b addTarget:self action:@selector(dismissKeyboard)
			forControlEvents:UIControlEventTouchUpInside];
		[self addSubview:b];
		_dismissKeyboardButton = b;
	}
	// Above the keyboard, on the trailing side, out of the text field's way.
	const CGRect kb = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
	const CGFloat top = MAX(0.0, CGRectGetMinY(kb) - 52.0);
	_dismissKeyboardButton.frame = CGRectMake(self.bounds.size.width - 104, top, 88, 40);
	_dismissKeyboardButton.hidden = NO;
	[self bringSubviewToFront:_dismissKeyboardButton];
}

- (void)keyboardHidden:(NSNotification *)note {
	(void)note;
	_dismissKeyboardButton.hidden = YES;
}

- (void)dismissKeyboard {
	// Ask SDL to stop text input as well as resigning first responder: SDL
	// re-presents the keyboard on its own if it still believes text input is
	// active, which is why it reappeared on returning to the menu.
	OpenQ4_iOS_StopTextInput();
	[self endEditing:YES];
	UIWindow *w = self.window;
	[w endEditing:YES];
	_dismissKeyboardButton.hidden = YES;
}

/*
 * Only claim touches that land on something we are actually showing.
 *
 * The overlay used to be hidden outright in menus, so taps fell through to SDL
 * and drove the engine's own cursor. Making the view permanently visible (so the
 * chrome could live in it) meant it began swallowing every menu tap instead —
 * which took away the ability to start a game at all by touch.
 *
 * So the view is transparent to hit testing except where a visible control
 * really is: a shown button, the chrome, the stick zone during play, or
 * anywhere at all while editing the layout or skipping a cinematic. Everything
 * else falls through to SDL's view underneath, exactly as before.
 */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	UIView *hit = [super hitTest:point withEvent:event];

	if (_editing) {
		// Let the edit bar's own controls answer first. Returning self
		// unconditionally here swallowed the reset button, the scale slider and
		// the green checkmark — which left the editor with no way out at all.
		// Only the bare surface belongs to dragging.
		return hit;
	}
	if (OpenQ4_iOS_AwaitingContinue()) {
		return self;                       // tap anywhere to continue
	}
	if (OpenQ4_iOS_InCinematic()) {
		return self;                       // tap anywhere to skip
	}

	if (hit != self) {
		return hit;                        // a real subview (button, slider)
	}

	// Bare view: only claim it if the playing controls are up, and then only
	// the left-hand stick zone. The look area is the right side, which the
	// engine handles through SDL when we decline.
	if (_controlsVisible && !_dismissKeyboardButton.hidden) {
		return self;
	}
	if (_controlsVisible && ![self shouldHideForPad]) {
		return self;
	}
	return nil;                            // fall through to SDL
}

- (void)setEditingInteraction:(BOOL)editing {
	for (NSString *action in _buttons) {
		((UIButton *)_buttons[action]).userInteractionEnabled = !editing;
	}
}

/*
 * `visible` is "the player is in a map", i.e. NOT in a menu.
 *
 * Chrome is the inverse: MENU and the gear belong to menus and the pause menu
 * and nowhere else — with or without a controller. They are clutter during
 * play, and a controller can already reach everything they offer.
 */
- (void)setControlsVisible:(BOOL)visible {
	const BOOL hideForPad = [self shouldHideForPad];
	for (NSString *action in _buttons) {
		((UIButton *)_buttons[action]).hidden = !visible || hideForPad;
	}
	if (!visible || hideForPad) {
		_stickBase.hidden = YES;
		_stickKnob.hidden = YES;
	}
	// The hamburger is the way into the menu without a controller, so it stays
	// up everywhere — menus, cinematics, gameplay — whenever no pad is
	// connected. With a pad it goes away entirely: Start/Menu on the pad opens
	// the same pause menu, and the maintainer's Vision Pro verdict on 0.1.0.55 was that
	// a lone hamburger over the game with a Backbone paired is clutter (the
	// old expression hid it only in menus, i.e. exactly backwards for play).
	// shouldHideForPad, not _padConnected: "Always Show Touch Controls" means
	// the player wants the touch UI even with a pad paired, and the hamburger is
	// the most load-bearing part of it — during demo playback it is the ONLY way
	// into the transport deck (D-086).
	_pauseButton.hidden = hideForPad;
	_objectivesButton.hidden = !visible || hideForPad;
	_settingsButton.hidden = visible;
	_controlsVisible = visible;
}

- (void)padsChanged {
	const BOOL connected = (GCController.controllers.count > 0);
	if (_padStateKnown && connected == _padConnected) {
		return;
	}
	// The first call always logs, even when it finds no pad: "no line in the
	// log" would otherwise be ambiguous between "no controller" and "this
	// wiring never ran".
	_padStateKnown = YES;
	_padConnected = connected;
	// Re-apply straight away so unplugging a controller brings the touch
	// controls back without waiting for anything else to change.
	[self setControlsVisible:_controlsVisible];
	fprintf(stdout, "openQ4 touch: %s (%lu pad(s)), touch controls %s\n",
			connected ? "controller present" : "no controller",
			(unsigned long)GCController.controllers.count,
			connected ? "hidden" : "shown");
	fflush(stdout);
	[self applyAppearance];
}

- (UIButton *)addSymbolChrome:(NSString *)symbolName action:(SEL)sel {
	return [self addSymbolChrome:symbolName action:sel pointSize:19];
}

- (UIButton *)addSymbolChrome:(NSString *)symbolName action:(SEL)sel pointSize:(CGFloat)pt {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	// Same weight, tint and border as the action buttons — these read as much
	// heavier than the rest of the controls when they are bolder.
	[b setImage:[[UIImage systemImageNamed:symbolName]
		imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pt
																			  weight:UIImageSymbolWeightRegular]]
	   forState:UIControlStateNormal];
	b.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
	b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
	b.layer.cornerRadius = 8;
	b.layer.borderWidth = 1.5;
	b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
	[b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
	[self addSubview:b];
	return b;
}

/*
 * Objectives is a HELD display, not a toggle — in-game it shows while
 * usercmd.buttons carries BUTTON_SCORES and hides the moment the flag drops.
 * (The IMPULSE_19 handler in Player.cpp is commented out upstream: the impulse
 * does nothing, the flag does everything.)
 *
 * This used to synthesise K_JOY9, the pad's D-pad-up binding, on the theory
 * that respecting the player's binding was the polite thing to do. It cannot
 * work: that path posts SE_KEY into the sys event queue, which feeds GUIs and
 * the console, while BUTTON_SCORES comes from buttonState[UB_IMPULSE19] — fed
 * only by the SDL backend's keyboard poll queue or by TouchButton. The pad
 * works precisely because the backend posts to BOTH planes; the shell posted
 * to one, and the wrong one. Holding it for a week would not have helped.
 *
 * The named-action path below is the one attack, jump and crouch already prove
 * on device, and "objectives" is mapped to UB_IMPULSE19 in UsercmdGen. Held
 * behaviour comes free, because TouchButton keeps the counter up while down.
 */
- (void)objectivesDown {
	OpenQ4_iOS_InjectButton("objectives", 1);
}

- (void)objectivesUp {
	OpenQ4_iOS_InjectButton("objectives", 0);
}

- (void)objectivesTapped {
	// Objectives in single player, scores in multiplayer — the engine picks
	// based on the game type; this is the same action the pad's Back button has.
	OpenQ4_iOS_InjectButton("objectives", 1);
	OpenQ4_iOS_InjectButton("objectives", 0);
}

- (void)menuTapped {
	// Escape, not a bound command: this has to reach whatever the engine
	// currently considers "back" — in-game menu, cinematic skip, GUI dismissal.
	OpenQ4_iOS_InjectEscape();
}

- (void)settingsTapped {
	OpenQ4_iOS_ShowSettings();
}

#pragma mark - Layout editing

- (BOOL)isEditingLayout { return _editing; }

- (void)beginEditingLayout {
	if (_editing) {
		return;
	}
	_editing = YES;
	[self setEditingInteraction:YES];

	// Drop anything mid-press: a held button would otherwise stick down for the
	// whole edit session and leave the engine with +attack asserted.
	for (NSString *action in _buttons) {
		OpenQ4_iOS_InjectButton(action.UTF8String, 0);
	}
	OpenQ4_iOS_InjectMove(0.0f, 0.0f);
	[self resetCrouchState];

	// Everything visible and grabbable while editing, whatever the game state
	// or whether a controller is connected.
	for (NSString *action in _buttons) {
		UIButton *b = _buttons[action];
		b.hidden = NO;
		b.layer.borderColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.4 alpha:0.95].CGColor;
		b.layer.borderWidth = 2.0;
	}
	for (NSString *key in _chrome) {
		UIButton *b = _chrome[key];
		b.hidden = NO;
		b.layer.borderColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.4 alpha:0.95].CGColor;
		b.layer.borderWidth = 2.0;
		b.userInteractionEnabled = NO;
	}
	_stickBase.hidden = NO;
	_stickKnob.hidden = NO;
	_stickBase.center = CGPointMake(self.bounds.size.width * 0.18,
									self.bounds.size.height * 0.72);
	_stickKnob.center = _stickBase.center;

	UIView *bar = [UIView new];
	bar.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:bar];
	_editBar = bar;

	UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
	reset.backgroundColor = [UIColor colorWithRed:0.85 green:0.20 blue:0.22 alpha:0.95];
	[reset setImage:[[UIImage systemImageNamed:@"arrow.uturn.backward"]
		imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17
																			  weight:UIImageSymbolWeightBold]]
		   forState:UIControlStateNormal];
	reset.tintColor = UIColor.whiteColor;
	reset.layer.cornerRadius = 21;
	reset.accessibilityLabel = OpenQ4_L("Reset Layout");
	[reset addTarget:self action:@selector(editResetTapped) forControlEvents:UIControlEventTouchUpInside];

	UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
	done.backgroundColor = [UIColor colorWithRed:0.18 green:0.78 blue:0.34 alpha:0.95];
	[done setImage:[[UIImage systemImageNamed:@"checkmark"]
		imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20
																			  weight:UIImageSymbolWeightBold]]
		  forState:UIControlStateNormal];
	done.tintColor = UIColor.whiteColor;
	done.layer.cornerRadius = 21;
	done.accessibilityLabel = OpenQ4_L("Save Layout");
	[done addTarget:self action:@selector(endEditingLayout) forControlEvents:UIControlEventTouchUpInside];

	UISlider *sl = [UISlider new];
	sl.minimumValue = 0.6f;
	sl.maximumValue = 1.6f;
	sl.value = OpenQ4_iOS_SettingFloat("touchScale", 1.0f);
	sl.minimumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.9];
	[sl addTarget:self action:@selector(editScaleChanged:) forControlEvents:UIControlEventValueChanged];
	_editSlider = sl;

	UILabel *pct = [UILabel new];
	pct.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
	pct.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
	pct.textAlignment = NSTextAlignmentCenter;
	_editPercent = pct;
	[self updateScaleLabel];

	for (UIView *v in @[ reset, done, sl, pct ]) {
		v.translatesAutoresizingMaskIntoConstraints = NO;
		[bar addSubview:v];
	}
	UILayoutGuide *safe = self.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14],
		[bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-14],
		[bar.heightAnchor constraintEqualToConstant:42],
		[reset.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
		[reset.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[reset.widthAnchor constraintEqualToConstant:42],
		[reset.heightAnchor constraintEqualToConstant:42],
		[sl.leadingAnchor constraintEqualToAnchor:reset.trailingAnchor constant:14],
		[sl.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[sl.widthAnchor constraintEqualToConstant:180],
		[pct.leadingAnchor constraintEqualToAnchor:sl.trailingAnchor constant:10],
		[pct.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[pct.widthAnchor constraintEqualToConstant:54],
		[done.leadingAnchor constraintEqualToAnchor:pct.trailingAnchor constant:14],
		[done.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
		[done.widthAnchor constraintEqualToConstant:42],
		[done.heightAnchor constraintEqualToConstant:42],
		[bar.trailingAnchor constraintEqualToAnchor:done.trailingAnchor],
	]];
}

- (void)updateScaleLabel {
	_editPercent.text = [NSString stringWithFormat:@"%.0f%%", _editSlider.value * 100.0f];
}

- (void)editScaleChanged:(UISlider *)sl {
	OpenQ4_iOS_SettingSetFloat("touchScale", sl.value);
	[self updateScaleLabel];
	[self applyAppearance];
}

- (void)editResetTapped {
	[self resetLayout];
	_editSlider.value = 1.0f;
	OpenQ4_iOS_SettingSetFloat("touchScale", 1.0f);
	[self updateScaleLabel];
	[self layoutIfNeeded];
	[self applyAppearance];
}

- (void)endEditingLayout {
	if (!_editing) {
		return;
	}
	_editing = NO;
	[self setEditingInteraction:NO];
	for (NSString *action in _buttons) {
		UIButton *b = _buttons[action];
		b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
		b.layer.borderWidth = 1.5;
	}
	for (NSString *key in _chrome) {
		UIButton *b = _chrome[key];
		b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
		b.layer.borderWidth = 1.0;
		b.userInteractionEnabled = YES;
	}
	[_editBar removeFromSuperview];
	_editBar = nil;
	_editSlider = nil;
	_editPercent = nil;
	_dragButton = nil;
	[self setControlsVisible:_controlsVisible];
	[self applyAppearance];
}

#pragma mark - Layout persistence

/*
 * Per-button positions live in NSUserDefaults as a fraction of the view, so a
 * layout survives rotation and reads the same on any device. Absent keys fall
 * back to the shipped offsets, which is what makes "reset" a deletion rather
 * than a table of numbers.
 *
 * the maintainer will arrange these himself in the editor; `!layout` on the console
 * bridge prints the result in the exact form needed to paste back here as the
 * new shipped defaults.
 */
static NSString *OpenQ4_LayoutKey(NSString *action) {
	return [NSString stringWithFormat:@"openq4.layout.%@", action];
}

- (CGPoint)storedCenterFor:(NSString *)action {
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	NSString *k = OpenQ4_LayoutKey(action);
	if ([d objectForKey:k] == nil) {
		return CGPointZero;
	}
	NSArray *xy = [d arrayForKey:k];
	if (xy.count != 2) {
		return CGPointZero;
	}
	return CGPointMake([xy[0] floatValue] * self.bounds.size.width,
					   [xy[1] floatValue] * self.bounds.size.height);
}

- (void)storeCenter:(CGPoint)c for:(NSString *)action {
	if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) {
		return;
	}
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	[d setObject:@[ @(c.x / self.bounds.size.width), @(c.y / self.bounds.size.height) ]
		  forKey:OpenQ4_LayoutKey(action)];
	[d synchronize];
}

- (void)resetLayout {
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	for (NSString *action in _buttons) {
		[d removeObjectForKey:OpenQ4_LayoutKey(action)];
	}
	for (NSString *key in _chrome) {
		[d removeObjectForKey:OpenQ4_LayoutKey(key)];
	}
	[d removeObjectForKey:@"openq4.touchScale"];
	[d synchronize];
	[self setNeedsLayout];
}

/* Dump the current layout for pasting back as shipped defaults. */
- (NSString *)layoutDescription {
	NSMutableString *out = [NSMutableString stringWithString:
		@"openQ4 touch layout (fractions of the view, origin top-left):\n"];
	const float scale = OpenQ4_iOS_SettingFloat("touchScale", 1.0f);
	[out appendFormat:@"  scale = %.3f\n", scale];
	NSMutableArray<NSString *> *names = [_buttons.allKeys mutableCopy];
	[names addObjectsFromArray:_chrome.allKeys];
	for (NSString *action in [names sortedArrayUsingSelector:@selector(compare:)]) {
		UIButton *b = _buttons[action] ?: _chrome[action];
		[out appendFormat:@"  %-9s x=%.4f y=%.4f  (size %.0f)\n",
			action.UTF8String,
			b.center.x / self.bounds.size.width,
			b.center.y / self.bounds.size.height,
			b.bounds.size.width];
	}
	return out;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	const CGFloat w = self.bounds.size.width;
	const CGFloat h = self.bounds.size.height;
#if !TARGET_OS_VISION
	// Q-036 / D-104. This overlay is a direct subview of the SDL window with a
	// flexible autoresizing mask, so its layout pass is the one signal the
	// shell reliably gets when the window's geometry changes — including the
	// final rotation into landscape, which the engine's metal view does not
	// follow on its own. Re-pinning lives in the render-scale path; this is
	// only the trigger, and it fires on a real size change, never per layout.
	{
		static CGSize s_lastOverlaySize = { 0.0, 0.0 };
		if (!CGSizeEqualToSize(self.bounds.size, s_lastOverlaySize)) {
			s_lastOverlaySize = self.bounds.size;
			OpenQ4_iOS_RenderScaleRefreshLayer();
		}
	}
#endif
	for (NSString *action in _buttons) {
		UIButton *b = _buttons[action];
		NSValue *v = objc_getAssociatedObject(b, "openq4.fraction");
		const CGPoint frac = v.CGPointValue;
		const CGSize sz = b.frame.size;
		CGPoint c = [self storedCenterFor:action];
		if (c.x <= 0.0 || c.y <= 0.0) {
			c = CGPointMake(frac.x * w, frac.y * h);
		}
		b.frame = CGRectMake(c.x - sz.width / 2, c.y - sz.height / 2, sz.width, sz.height);
	}
	// Inside the safe area: on a notched phone in landscape the left inset is
	// the sensor housing, and a button under it cannot be tapped.
	const UIEdgeInsets safe = self.safeAreaInsets;
	const CGFloat x = safe.left + 16;
	const CGFloat y = safe.top + 14;
	// Gear in the top-left corner; hamburger and objectives top-right, the same
	// size as each other. Stored positions win over all of it.
	//
	// Do not move the gear to make room for the FPS counter. The counter now
	// draws in the same corner (Console.cpp, SCR_DiagnosticOrigin) and clears it
	// by sitting in the band ABOVE it — the gear starts 14 pt down, the counter
	// is about 8 pt tall, and the engine side is what gives way.
	_settingsButton.frame = CGRectMake(x, y, 46, 38);
	const CGFloat rx = w - safe.right - 16;
	_pauseButton.frame = CGRectMake(rx - 46, y, 46, 38);
	_objectivesButton.frame = CGRectMake(rx - 46 - 54, y, 46, 38);
	for (NSString *key in _chrome) {
		UIButton *b = _chrome[key];
		const CGPoint stored = [self storedCenterFor:key];
		if (stored.x > 0.0 && stored.y > 0.0) {
			b.center = stored;
		}
	}
	[self applyAppearance];
	// The chrome above was just placed inside self.safeAreaInsets; the engine's
	// 2D UI viewport is inset by the SAME numbers (D-085), and this is the one
	// callback that fires whenever they can have changed.
	OpenQ4_iOS_PublishSafeArea();
}

- (void)applyAppearance {
	const float alpha = OpenQ4_iOS_SettingFloat("touchOpacity", 0.55f);
	const float scale = OpenQ4_iOS_SettingFloat("touchScale", 1.0f);
	for (NSString *action in _buttons) {
		UIButton *b = _buttons[action];
		b.alpha = alpha;
		b.transform = CGAffineTransformMakeScale(scale, scale);
		// Re-apply the crouch latch's darkening: this pass runs on every layout
		// and setting change and would otherwise wipe it, which looked exactly
		// like the toggle not working at all.
		if ([action isEqualToString:@"crouch"]) {
			b.backgroundColor = _crouchLatched
				? [UIColor colorWithWhite:0.0 alpha:0.45]
				: [UIColor colorWithWhite:1.0 alpha:0.12];
		}
		// Hidden, not merely transparent: an invisible button still swallows
		// the touch that lands on it, which would punch dead spots into the
		// look area for a player who is holding a pad and not expecting any.
		//
		// _controlsVisible as well as the pad, and that second term is not
		// belt-and-braces: this pass runs on every settings change, and without
		// it changing any touch setting from a MENU re-showed the whole action
		// cluster on top of that menu until the next gameplay transition. Found
		// while photographing demo playback, where it put a fire button over
		// the thing being watched (D-086).
		b.hidden = !_controlsVisible || [self shouldHideForPad];
	}
	_stickBase.alpha = alpha;
	_stickKnob.alpha = alpha;
	if ([self shouldHideForPad]) {
		_stickBase.hidden = YES;
		_stickKnob.hidden = YES;
	}
	// Chrome floors at 0.5 alpha and never scales: at the slider's minimum the
	// action buttons should fade into the scene, but the way out of the game
	// must stay findable.
	const float chromeAlpha = (alpha < 0.5f) ? 0.5f : alpha;
	_pauseButton.alpha = chromeAlpha;
	_objectivesButton.alpha = chromeAlpha;
	_settingsButton.alpha = chromeAlpha;
}

- (NSString *)actionForButton:(UIButton *)b {
	return objc_getAssociatedObject(b, "openq4.action");
}

- (void)buttonDown:(UIButton *)b {
	NSString *action = [self actionForButton:b];

	if ([action isEqualToString:@"weapwheel"]) {
		_wheelLast = CGPointZero;   // first drag sample establishes the origin
		_wheelResidual = CGPointZero;
	}

	if ([action isEqualToString:@"crouch"] &&
		OpenQ4_iOS_SettingFloat("crouchDoubleTap", 1.0f) > 0.5f) {
		[self crouchPressed:b];
		return;
	}

	OpenQ4_iOS_InjectButton(action.UTF8String, 1);

	// 0 = off, 1 = every button, 2 = fire only. Fire-only exists because the
	// feedback is genuinely useful on the trigger and mostly noise elsewhere.
	const int haptics = (int)OpenQ4_iOS_SettingFloat("haptics", 1.0f);
	const BOOL wantHaptic = (haptics == 1) || (haptics == 2 && [action isEqualToString:@"attack"]);
	if (wantHaptic) {
		OpenQ4_iOS_HapticImpact(OPENQ4_HAPTIC_LIGHT);
	}
}

- (void)buttonUp:(UIButton *)b {
	NSString *action = [self actionForButton:b];
	if ([action isEqualToString:@"crouch"] &&
		OpenQ4_iOS_SettingFloat("crouchDoubleTap", 1.0f) > 0.5f) {
		[self crouchReleased:b];
		return;
	}
	OpenQ4_iOS_InjectButton(action.UTF8String, 0);
}

/*
 * Crouch, to the spec exactly:
 *
 *   hold             -> crouched while held, stand on release
 *   single quick tap -> crouched for that instant, then stand (same path)
 *   DOUBLE TAP       -> latched; stays crouched after the finger lifts
 *   one tap while latched -> unlatch and stand
 *
 * buttonState[UB_DOWN] in the engine is a COUNTER, so every injected down must
 * be matched by exactly one up or crouch sticks permanently. _crouchHeldDown
 * tracks whether an up is currently owed.
 */
- (void)setCrouchVisualLatched:(BOOL)latched on:(UIButton *)b {
	b.backgroundColor = latched
		? [UIColor colorWithWhite:0.0 alpha:0.55]
		: [UIColor colorWithWhite:1.0 alpha:0.12];
}

- (void)crouchPressed:(UIButton *)b {
	const NSTimeInterval now = CACurrentMediaTime();

	if (_crouchLatched) {
		_crouchLatched = NO;
		if (_crouchHeldDown) {
			OpenQ4_iOS_InjectButton("crouch", 0);
			_crouchHeldDown = NO;
		}
		[self setCrouchVisualLatched:NO on:b];
		_lastCrouchPressTime = 0.0;
		return;
	}

	_crouchPressIsDouble = (now - _lastCrouchPressTime) < 0.32;
	_lastCrouchPressTime = now;

	if (!_crouchHeldDown) {
		OpenQ4_iOS_InjectButton("crouch", 1);
		_crouchHeldDown = YES;
	}
	if (OpenQ4_iOS_SettingFloat("haptics", 1.0f) > 0.5f) {
		OpenQ4_iOS_HapticImpact(OPENQ4_HAPTIC_LIGHT);
	}
}

- (void)crouchReleased:(UIButton *)b {
	// The second tap has to be a TAP. Deciding this at press time alone meant
	// "tap, then press and hold" latched on release — the player was holding
	// crouch down deliberately and got a latch they never asked for.
	const BOOL secondTapWasShort = (CACurrentMediaTime() - _lastCrouchPressTime) < 0.25;
	if (_crouchPressIsDouble && secondTapWasShort) {
		_crouchPressIsDouble = NO;
		_crouchLatched = YES;                 // keep the button held down
		[self setCrouchVisualLatched:YES on:b];
		if (OpenQ4_iOS_SettingFloat("haptics", 1.0f) > 0.5f) {
			OpenQ4_iOS_HapticImpact(OPENQ4_HAPTIC_MEDIUM);
		}
		return;
	}
	_crouchPressIsDouble = NO;
	if (_crouchHeldDown) {
		OpenQ4_iOS_InjectButton("crouch", 0);
		_crouchHeldDown = NO;
	}
	[self setCrouchVisualLatched:NO on:b];
}

/*
 * Drop any latch and settle the debt to the engine. Anything that takes the
 * player out of direct control has to call this: entering the layout editor
 * injects an "up" for every action, and leaving the latch believed-on afterwards
 * desynchronises the shell's bookkeeping from buttonState[UB_DOWN].
 */
- (void)resetCrouchState {
	if (_crouchHeldDown) {
		OpenQ4_iOS_InjectButton("crouch", 0);
		_crouchHeldDown = NO;
	}
	_crouchLatched = NO;
	_crouchPressIsDouble = NO;
	_lastCrouchPressTime = 0.0;
	UIButton *b = _buttons[@"crouch"];
	if (b != nil) {
		[self setCrouchVisualLatched:NO on:b];
	}
}

/*
 * Steer the weapon wheel with the finger holding it.
 *
 * The game reads usercmd.mx/my deltas while BUTTON_WEAPONWHEEL is held, so the
 * drag has to arrive as mouse motion — the touch look path deliberately
 * bypasses the mouse chain and cannot drive it.
 */
- (void)wheelDragged:(UIButton *)b withEvent:(UIEvent *)event {
	// touchesForView, not allTouches: allTouches is every finger on the screen,
	// so with a movement stick or a look finger already down this picked an
	// arbitrary one. That alone made the drag behave differently depending on
	// what else the other hand was doing.
	UITouch *t = [event touchesForView:b].anyObject;
	if (t == nil) {
		return;
	}
	const CGPoint p = [t locationInView:self];
	if (CGPointEqualToPoint(_wheelLast, CGPointZero)) {
		_wheelLast = p;
		return;
	}
	// No negation, and the scale is now a setting. The game applies its own 0.70
	// cursor-units per mouse count against a 118-unit wheel radius, so the base
	// 4.0 puts the rim about 42 pt from where the thumb landed and the 24-unit
	// dead zone about 9 pt out — roughly one thumb-joint of travel to reach any
	// slot. The first shipped number was half that, which is a reach on a phone
	// held in two hands.
	// 3.4 counts per point, fixed. This was briefly a slider so the maintainer could
	// find the number; he found it (0.85 of the 4.0 base) and the setting is
	// gone rather than left behind as a knob nobody needs to touch.
	const float wheelSpeed = 3.4f;

	// Whole mouse counts only — InjectWheelAim truncates — so the fraction is
	// carried to the next sample instead of being thrown away. At 120 Hz a
	// deliberate, slow drag moves well under a point per sample, and rounding
	// each of those to zero would make careful aim on the wheel do nothing at
	// all while a flick worked fine.
	_wheelResidual.x += (p.x - _wheelLast.x) * wheelSpeed;
	_wheelResidual.y += (p.y - _wheelLast.y) * wheelSpeed;
	const CGFloat sendX = truncf((float)_wheelResidual.x);
	const CGFloat sendY = truncf((float)_wheelResidual.y);
	_wheelResidual.x -= sendX;
	_wheelResidual.y -= sendY;
	if (sendX != 0.0 || sendY != 0.0) {
		OpenQ4_iOS_InjectWheelAim((float)sendX, (float)sendY);
	}
	_wheelLast = p;
}

#pragma mark - In-world GUI touch (D-071)

- (BOOL)touchPanelsEnabled {
	return OpenQ4_iOS_SettingFloat("touchPanels", 1.0f) > 0.5f;
}

/*
 * Publish where the finger is, in normalised device coords: -1..1 with +x right
 * and +y UP. UIKit's y grows downward, hence the flip. The centre of the view
 * must come out exactly (0,0) — that is the identity that makes a centre tap
 * reproduce the crosshair ray bit-for-bit.
 */
- (void)publishAimAtViewPoint:(CGPoint)p {
	const CGFloat w = self.bounds.size.width;
	const CGFloat h = self.bounds.size.height;
	if (w <= 0.0 || h <= 0.0) {
		return;
	}
	const float ndcX = (float)((p.x / w) * 2.0 - 1.0);
	const float ndcY = (float)(1.0 - (p.y / h) * 2.0);
	_aimGeneration++;
	OpenQ4_iOS_SetTouchAim(1, ndcX, ndcY);
}

- (void)clearAimForGeneration:(NSUInteger)gen {
	if (_aimGeneration != gen) {
		return;   // a newer tap owns the aim
	}
	OpenQ4_iOS_SetTouchAim(0, 0.0f, 0.0f);
}

/*
 * Turn the finished tap into a click.
 *
 * The aim stays published across the click window so the panel the finger
 * landed on keeps focus while the game sees the press and the release.
 */
- (void)commitAimTap {
	const NSUInteger gen = _aimGeneration;
	OpenQ4_iOS_SetTouchAimClick(1);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
	                             (int64_t)(OPENQ4_TAP_CLICK_SECONDS * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		// Gated like the aim clear below: a second tap inside this window owns
		// the click now, and this older block must not cut its hold short.
		if (self->_aimGeneration != gen) {
			return;
		}
		OpenQ4_iOS_SetTouchAimClick(0);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
		                             (int64_t)(OPENQ4_TAP_RELEASE_SECONDS * NSEC_PER_SEC)),
		               dispatch_get_main_queue(), ^{
			[self clearAimForGeneration:gen];
		});
	});
}

/*
 * The console bridge's `!touchtap`. It runs the same publish and the same
 * commit the real handlers run; only UIKit's delivery of a UITouch is skipped,
 * because nothing can synthesise one.
 */
- (UIButton *)chromeButtonNamed:(NSString *)key {
	return _chrome[key];
}

- (void)synthesizeTapAtNormalizedX:(CGFloat)nx y:(CGFloat)ny {
	if (![self touchPanelsEnabled]) {
		fprintf(stdout, "openQ4 touch: touchtap ignored, Touch Panels Directly is off\n");
		fflush(stdout);
		return;
	}
	const CGPoint p = CGPointMake(nx * self.bounds.size.width,
	                              ny * self.bounds.size.height);
	fprintf(stdout, "openQ4 touch: touchtap at norm %.3f,%.3f -> view %.1f,%.1f of %.0fx%.0f\n",
	        (double)nx, (double)ny, (double)p.x, (double)p.y,
	        (double)self.bounds.size.width, (double)self.bounds.size.height);
	fflush(stdout);
	[self publishAimAtViewPoint:p];
	[self commitAimTap];
}

#pragma mark - Touch handling

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	if (_editing) {
		// Grab whichever control is under the finger and drag it. Buttons have
		// userInteractionEnabled off while editing so their own press handling
		// cannot fire.
		const CGPoint p = [touches.anyObject locationInView:self];
		for (NSString *action in _buttons) {
			UIButton *b = _buttons[action];
			if (CGRectContainsPoint(CGRectInset(b.frame, -8, -8), p)) {
				_dragButton = b;
				_dragOffset = CGPointMake(p.x - b.center.x, p.y - b.center.y);
				return;
			}
		}
		for (NSString *key in _chrome) {
			UIButton *b = _chrome[key];
			if (CGRectContainsPoint(CGRectInset(b.frame, -8, -8), p)) {
				_dragButton = b;
				_dragOffset = CGPointMake(p.x - b.center.x, p.y - b.center.y);
				return;
			}
		}
		return;
	}
	// A tap anywhere dismisses the "press any key to continue" screen. There is
	// no keyboard on a phone, so without this the only ways past it were a pad
	// or the auto-advance timer.
	if (OpenQ4_iOS_AwaitingContinue()) {
		OpenQ4_iOS_InjectContinueKey();
		return;
	}
	// A tap anywhere skips a cinematic. The MENU button is menus-only now, so
	// without this a touch player has no way past one at all.
	if (OpenQ4_iOS_InCinematic()) {
		OpenQ4_iOS_InjectEscape();
		return;
	}
	if ([self shouldHideForPad] || !_controlsVisible) {
		return;
	}
	const CGFloat mid = self.bounds.size.width * 0.38f;
	for (UITouch *t in touches) {
		const CGPoint p = [t locationInView:self];
		if (p.x < mid && _stickTouch == nil) {
			// Floating stick: the centre is wherever the finger landed, so
			// there is no deadzone and no "find the stick" problem.
			_stickTouch = t;
			_stickOrigin = p;
			_stickCurrent = p;
			_stickBase.center = p;
			_stickKnob.center = p;
			_stickBase.hidden = NO;
			_stickKnob.hidden = NO;
		} else if (p.x >= mid && _lookTouch == nil) {
			_lookTouch = t;
			_lookLast = p;
			// The same touch is both a candidate look drag and a candidate
			// panel tap; which one it was is only knowable when it ends. The
			// aim is published now so the ray leads the click by the whole
			// duration of the touch — the game has already focused the panel
			// under the finger by the time the click arrives.
			_lookStart = p;
			_lookStartTime = t.timestamp;
			_lookIsTap = [self touchPanelsEnabled];
			if (_lookIsTap) {
				[self publishAimAtViewPoint:p];
			}
		}
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	if (_editing) {
		if (_dragButton != nil) {
			const CGPoint p = [touches.anyObject locationInView:self];
			CGPoint c = CGPointMake(p.x - _dragOffset.x, p.y - _dragOffset.y);
			// Clamped to the view, and nothing more. The safe-area inset used to
			// be enforced too and it kept buttons well away from every edge —
			// which is exactly where a thumb wants them. There is no danger in
			// letting a button go right to the edge: reset is one tap away.
			const CGFloat r = _dragButton.bounds.size.width * 0.5f;
			c.x = MAX(r * 0.25f, MIN(self.bounds.size.width - r * 0.25f, c.x));
			c.y = MAX(r * 0.25f, MIN(self.bounds.size.height - r * 0.25f, c.y));
			_dragButton.center = c;
		}
		return;
	}
	for (UITouch *t in touches) {
		if (t == _stickTouch) {
			_stickCurrent = [t locationInView:self];
			CGPoint d = CGPointMake(_stickCurrent.x - _stickOrigin.x,
									_stickCurrent.y - _stickOrigin.y);
			const CGFloat len = sqrtf((float)(d.x * d.x + d.y * d.y));
			if (len > OPENQ4_STICK_RADIUS_PT) {
				d.x = d.x / len * OPENQ4_STICK_RADIUS_PT;
				d.y = d.y / len * OPENQ4_STICK_RADIUS_PT;
			}
			_stickKnob.center = CGPointMake(_stickOrigin.x + d.x, _stickOrigin.y + d.y);
		} else if (t == _lookTouch) {
			// Predicted touches remove the trailing-finger feel: UIKit delivers
			// events behind the finger, and aiming is where that latency reads
			// worst.
			NSArray<UITouch *> *predicted = [event predictedTouchesForTouch:t];
			const CGPoint p = predicted.lastObject
				? [predicted.lastObject locationInView:self]
				: [t locationInView:self];
			const CGFloat dx = p.x - _lookLast.x;
			const CGFloat dy = p.y - _lookLast.y;
			_lookLast = [t locationInView:self];

			if (_lookIsTap) {
				const CGFloat mx = _lookLast.x - _lookStart.x;
				const CGFloat my = _lookLast.y - _lookStart.y;
				if ((mx * mx + my * my) > (OPENQ4_TAP_SLOP_PT * OPENQ4_TAP_SLOP_PT)) {
					// A look drag, not a panel tap. Stop steering the ray, or
					// focus follows the player's thumb while they walk.
					_lookIsTap = NO;
					[self clearAimForGeneration:_aimGeneration];
				}
			}

			const float sensX = OpenQ4_iOS_SettingFloat("lookSensX", 1.0f);
			const float sensY = OpenQ4_iOS_SettingFloat("lookSensY", 1.0f);
			const float invert = OpenQ4_iOS_SettingFloat("invertLook", 0.0f) > 0.5f ? -1.0f : 1.0f;

			_pendingYaw   -= dx * OPENQ4_LOOK_DEGREES_PER_POINT * sensX;
			_pendingPitch += dy * OPENQ4_LOOK_DEGREES_PER_POINT * sensY * invert;
		}
	}
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
	if (_wheelTouch != nil && [touches containsObject:_wheelTouch]) {
		_wheelTouch = nil;
		_buttons[@"weapwheel"].backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
		OpenQ4_iOS_InjectButton("weapwheel", 0);   // release selects
		return;
	}
	if (_editing) {
		if (_dragButton != nil) {
			NSString *name = objc_getAssociatedObject(_dragButton, "openq4.action");
			if (name == nil) {
				for (NSString *key in _chrome) {
					if (_chrome[key] == _dragButton) { name = key; break; }
				}
			}
			if (name != nil) {
				[self storeCenter:_dragButton.center for:name];
			}
			_dragButton = nil;
		}
		return;
	}
	for (UITouch *t in touches) {
		if (t == _stickTouch) {
			_stickTouch = nil;
			_stickBase.hidden = YES;
			_stickKnob.hidden = YES;
			OpenQ4_iOS_InjectMove(0.0f, 0.0f);
		} else if (t == _lookTouch) {
			_lookTouch = nil;
			if (_lookIsTap) {
				_lookIsTap = NO;
				if ((t.timestamp - _lookStartTime) <= OPENQ4_TAP_MAX_SECONDS) {
					[self commitAimTap];
				} else {
					[self clearAimForGeneration:_aimGeneration];
				}
			}
		}
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	[self endTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	// A cancelled touch is not a tap. Without this a system gesture stealing
	// the touch would click whatever panel the finger happened to be over.
	if (_lookTouch != nil && [touches containsObject:_lookTouch] && _lookIsTap) {
		_lookIsTap = NO;
		[self clearAimForGeneration:_aimGeneration];
	}
	[self endTouches:touches];
}

#pragma mark - Gyro aim (D-083)

/*
 * Device motion drives the view through the SAME path as a look drag:
 * OpenQ4_iOS_InjectLook, in absolute view degrees, never the engine's mouse
 * chain and never upstream's `in_gyro`.
 *
 * `in_gyro` is worth being explicit about, because the settings sheet used to
 * point a row at it. Upstream's gyro is GAMEPAD gyro — SDL_SENSOR_GYRO on an
 * opened SDL_Gamepad, fed to SDL3_QueueMouseDelta, i.e. through mouse
 * sensitivity, m_yaw/m_pitch and mouse acceleration. On iOS it is doubly wrong:
 * the phone's own motion is not a gamepad sensor, so the row moved a cvar that
 * described a Steam Deck and nothing else, and the destination is the exact
 * chain this port's look input was taken off (D-071, patch 0002). Retired.
 *
 * WHY COREMOTION AND NOT SDL3'S SENSOR API. SDL3 does expose SDL_SENSOR_GYRO
 * for the device itself, but it hands back RAW DEVICE-FRAME rates and nothing
 * else — SDL_sensor.h says outright that "the gyroscope axis data is not
 * changed when the device is rotated". The mapping below needs the gravity
 * vector, which SDL can only approximate from SDL_SENSOR_ACCEL (gravity plus
 * hand motion, unfiltered); CMDeviceMotion delivers a sensor-fused gravity
 * separated from user acceleration, plus each sample's own timestamp. It is
 * also where the whole rest of this file already lives, so the gyro needs no
 * new thread and no new event queue. All three sibling ports made the same
 * choice, none of them through SDL.
 */

/* The mode, clamped: a stored float from any older build cannot mean a mode
 * that does not exist. */
- (openq4GyroMode_t)gyroMode {
	const float v = OpenQ4_iOS_SettingFloat("gyroMode", 0.0f);
	if (v >= 1.5f) { return OPENQ4_GYRO_ALWAYS; }
	if (v >= 0.5f) { return OPENQ4_GYRO_WHILE_TOUCHING; }
	return OPENQ4_GYRO_OFF;
}

/*
 * The single gate, used by BOTH the real sensor and the bridge's synthetic
 * sample, so a harness can never exercise a path the product does not have.
 *
 * Menus are the load-bearing clause. The engine's menu cursor is driven by the
 * same view-angle-adjacent machinery a look drag feeds, and the overlay is only
 * drained while OpenQ4_iOS_InGame() — so gyro degrees accumulated in a menu
 * would not merely move the cursor, they would sit in the accumulator and
 * arrive as one lurch on the first frame back in the map. Gating at the SOURCE
 * rather than at the drain is what prevents that.
 */
- (BOOL)gyroActiveNow {
	if (_gyroBackgrounded) { return NO; }
	const openq4GyroMode_t mode = [self gyroMode];
	if (mode == OPENQ4_GYRO_OFF) { return NO; }
	if (!OpenQ4_iOS_InGame()) { return NO; }
	// A cinematic is not gameplay: the view is the director's, and letting the
	// player's wrist push it is the letterbox equivalent of moving the camera.
	if (OpenQ4_iOS_InCinematic()) { return NO; }
	if (mode == OPENQ4_GYRO_WHILE_TOUCHING && _lookTouch == nil) { return NO; }
	return YES;
}

/*
 * One motion sample -> view degrees, in the WORLD frame rather than the device
 * frame. This is vkQuake-ios's mapping (D-0xx, "the gyro axes were simply
 * swapped"), adopted deliberately rather than re-derived, because the naive
 * version has a recorded hardware failure attached to it.
 *
 * CMDeviceMotion.rotationRate is in DEVICE (portrait-referenced) axes: +x out
 * the right edge, +y out the top edge, +z out of the screen. Held in landscape
 * the device is rolled 90 degrees, so reading .y as yaw and .x as pitch is
 * exactly backwards — and merely SWAPPING them fixes the perfectly-upright hold
 * only. Nobody holds a phone upright; at a 45-degree hold a device-axis mapping
 * bleeds each rotation into the wrong angle (a pure world-yaw turn reads at
 * cos45 ~ 0.7 of its rate). So resolve against gravity, which is roll-
 * independent and needs no orientation enum at all:
 *
 *   u = world up in device coords (= -gravity)
 *   yaw   = the component of the rotation about u          (turning the phone)
 *   pitch = the component about the horizontal axis in the screen plane,
 *           h = normalize(-u.y, u.x, 0), perpendicular to both u and the
 *           screen normal                                  (tilting the phone)
 *
 * SIGNS. This engine's look convention is +yaw = look LEFT and +pitch = look
 * DOWN (idTech 4 view angles; the touch path's `_pendingYaw -= dx` is the same
 * statement). A right-handed rotation about world up IS a turn to the left, so
 * yaw passes through unnegated — the opposite of vkQuake, whose VKQ_TouchLook
 * takes +yaw = look right. Pitch is negated: tilting the phone face-up should
 * look UP, which is negative pitch here.
 *
 * The sample lands in _gyroPendingYaw/_gyroPendingPitch, NOT the touch
 * accumulator: touches write _pendingYaw/_pendingPitch on the main thread and
 * this runs on the engine thread, so sharing one pair was an unsynchronised
 * two-writer race (review of D-083). drainToEngine, on the engine thread, sums
 * both pairs into one InjectLook, so a finger and a wrist in the same frame
 * still compose instead of fighting.
 */
- (void)applyGyroSampleWx:(double)wx wy:(double)wy wz:(double)wz
					   gx:(double)gx gy:(double)gy gz:(double)gz
					   dt:(double)dt {
	if (dt <= 0.0 || dt > OPENQ4_GYRO_MAX_DT) {
		_gyroSuppressed++;
		return;
	}

	double ux = -gx, uy = -gy, uz = -gz;
	const double un = sqrt(ux * ux + uy * uy + uz * uz);
	// Free fall, or a gravity vector the fusion has not settled on yet. There is
	// no up, so there is no yaw axis; drop the sample rather than guess.
	if (un <= 0.1) {
		_gyroSuppressed++;
		return;
	}
	ux /= un; uy /= un; uz /= un;

	const double yawLeft = wx * ux + wy * uy + wz * uz;

	// Screen-plane horizontal axis. It collapses only when the screen faces
	// straight up or down (|h| -> 0), a pose nobody aims from; fall back to the
	// landscape long edge there so it can never divide by ~0. LandscapeLeft is
	// the one that needs the flip: UIInterfaceOrientationLandscapeLeft ==
	// UIDeviceOrientationLandscapeRight, i.e. the portrait TOP edge points to
	// the user's right, which reverses both screen axes.
	const double hx = -uy, hy = ux;
	const double hn = sqrt(hx * hx + hy * hy);
	double pitchUp;
	if (hn > 0.2) {
		pitchUp = (wx * hx + wy * hy) / hn;
	} else {
#if OPENQ4_HAVE_INTERFACE_ORIENTATION
		const UIInterfaceOrientation o = self.window.windowScene.interfaceOrientation;
		pitchUp = (o == UIInterfaceOrientationLandscapeLeft) ? -wy : wy;
#else
		// visionOS windows have no orientation. Unreachable in practice — this
		// whole function only runs off a gyro sample and visionOS has no gyro —
		// but `!gyro` can drive it synthetically, so it needs an answer.
		pitchUp = wy;
#endif
	}

	// Deadzone on the RATE, before dt scaling, so its meaning is degrees per
	// second at any frame rate.
	float yawDps   = (float)(yawLeft * OPENQ4_RAD_TO_DEG);
	float pitchDps = (float)(pitchUp * OPENQ4_RAD_TO_DEG);
	if (fabsf(yawDps)   < OPENQ4_GYRO_DEADZONE_DPS) { yawDps = 0.0f; }
	if (fabsf(pitchDps) < OPENQ4_GYRO_DEADZONE_DPS) { pitchDps = 0.0f; }
	if (yawDps == 0.0f && pitchDps == 0.0f) {
		_gyroSamples++;
		return;
	}

	// Per-axis sensitivity, matching the touch path's own pair rather than
	// inventing a single scalar: a phone is turned about its long axis far more
	// comfortably than it is tilted, so the two axes genuinely want different
	// numbers. 1.0 means one view degree per device degree.
	const float sensX = OpenQ4_iOS_SettingFloat("gyroSensX", 1.0f);
	const float sensY = OpenQ4_iOS_SettingFloat("gyroSensY", 1.0f);
	// Its OWN switch, not the touch "Invert Vertical Look". Tilt-to-aim has two
	// equally defensible conventions (tilt up = look up, or the camera-lens one
	// where it looks down) and that preference is unrelated to how a thumb drag
	// should behave. Cheap insurance against a second OTA round on a behaviour
	// only hardware can judge.
	const float invert = OpenQ4_iOS_SettingFloat("gyroInvertPitch", 0.0f) > 0.5f ? -1.0f : 1.0f;

	const double yawDeg   =  (double)yawDps   * sensX * dt;
	const double pitchDeg = -(double)pitchDps * sensY * invert * dt;

	_gyroPendingYaw   += (CGFloat)yawDeg;
	_gyroPendingPitch += (CGFloat)pitchDeg;
	_gyroSamples++;
	_gyroYawApplied   += yawDeg;
	_gyroPitchApplied += pitchDeg;
}

/*
 * Bring the sensor up or take it down. Called from the frame path, which runs on
 * the engine thread, so the CoreMotion calls are bounced to main — and the ivar
 * is only ever written there.
 */
- (void)updateGyroHardwareWanted:(BOOL)wanted {
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self updateGyroHardwareWanted:wanted]; });
		return;
	}
#if !OPENQ4_HAVE_GYRO
	// visionOS: no CoreMotion, so there is no hardware to bring up. Latch the
	// same "unavailable" flag the simulator sets, which is what makes `!gyro`
	// report the truth instead of claiming a stopped sensor that could start.
	(void)wanted;
	_motionUnavailable = YES;
	return;
#else
	if (wanted) {
		if (_motionUnavailable || _motion != nil) { return; }
		CMMotionManager *m = [[CMMotionManager alloc] init];
		if (!m.deviceMotionAvailable) {
			// The simulator has no gyro, by definition. Say so once: otherwise
			// "gyro does nothing on the sim" reads as a bug in this code, which
			// is exactly the confusion the `!gyro` command exists to remove.
			_motionUnavailable = YES;
#if !defined(OPENQ4_PUBLIC_BUILD)
			fprintf(stdout, "openQ4 gyro: device motion unavailable (simulator?) — "
					"the sensor path is inert; use the bridge's !gyro to drive it\n");
#else
			fprintf(stdout, "openQ4 gyro: device motion unavailable — gyro aim is inert\n");
#endif
			fflush(stdout);
			return;
		}
		m.deviceMotionUpdateInterval = 1.0 / OPENQ4_GYRO_UPDATE_HZ;
		// Pull, not push: startDeviceMotionUpdates with no queue, then read the
		// latest sample at the instant the engine is about to consume it. A
		// handler-and-queue variant would hand us a sample that then waits for
		// the next frame, which is latency for nothing.
		[m startDeviceMotionUpdates];
		_motion = m;
		_gyroLastSample = 0.0;
		fprintf(stdout, "openQ4 gyro: device motion started (%.0f Hz)\n", OPENQ4_GYRO_UPDATE_HZ);
		fflush(stdout);
	} else {
		if (_motion == nil) { return; }
		[_motion stopDeviceMotionUpdates];
		_motion = nil;
		_gyroLastSample = 0.0;
		fprintf(stdout, "openQ4 gyro: device motion stopped\n");
		fflush(stdout);
	}
#endif
}

/* Once per engine frame, immediately before the accumulator is drained. */
- (void)pollGyro {
	const BOOL active = [self gyroActiveNow];
	// The sensor is wanted whenever the MODE is on, not only while it is
	// currently allowed to steer: stopping and restarting CoreMotion every time
	// a finger lands would cost a fusion warm-up on each touch.
	const BOOL wantHardware = (!_gyroBackgrounded && [self gyroMode] != OPENQ4_GYRO_OFF);
	if (wantHardware != (_motion != nil) && !(wantHardware && _motionUnavailable)) {
		[self updateGyroHardwareWanted:wantHardware];
	}
	if (!active) {
		// Drop the clock too. Otherwise the first sample after a menu, a
		// cinematic or a released finger carries the whole gap as its dt and
		// arrives as a lurch — the clamp would catch a long one, but not a
		// half-second pause.
		_gyroLastSample = 0.0;
		return;
	}
#if !OPENQ4_HAVE_GYRO
	return;   // visionOS: nothing to poll (see updateGyroHardwareWanted:)
#else
	CMMotionManager *m = _motion;
	if (m == nil) { return; }
	CMDeviceMotion *dm = m.deviceMotion;
	if (dm == nil) { return; }
	// CoreMotion's own timestamp, not CACurrentMediaTime: it dates the SAMPLE
	// rather than the moment we got round to reading it, so a late frame does
	// not inflate the turn and a duplicate read contributes exactly zero.
	if (_gyroLastSample <= 0.0 || dm.timestamp <= _gyroLastSample) {
		_gyroLastSample = dm.timestamp;
		return;
	}
	const double dt = dm.timestamp - _gyroLastSample;
	_gyroLastSample = dm.timestamp;
	[self applyGyroSampleWx:dm.rotationRate.x wy:dm.rotationRate.y wz:dm.rotationRate.z
						 gx:dm.gravity.x gy:dm.gravity.y gz:dm.gravity.z
						 dt:dt];
#endif
}

/*
 * `!gyro <dyaw> <dpitch>` — one synthetic motion sample, in the ENGINE's view
 * degrees (the same convention OpenQ4_iOS_InjectLook takes, so `!gyro 30 0`
 * should move `getviewpos`'s yaw by 30 at sensitivity 1.0).
 *
 * It is a synthetic SAMPLE, not a synthetic result: the arguments are turned
 * back into a (rotationRate, gravity, dt) triple and pushed through
 * applyGyroSampleWx:… — the gate, the gravity projection, the deadzone, both
 * sensitivities and the invert switch all run. A harness that re-implements the
 * behaviour it tests passes while the product is broken (dhewm3-ios D-014), and
 * the simulator has no gyro at all, so this is the only way any of this is
 * verifiable before hardware.
 *
 * The inverse, for an upright landscape hold with world up along -x
 * (gravity = (1,0,0), so u = (-1,0,0), h = (0,-1,0), both unit length):
 *
 *   yawLeft = w·u = -wx     and   yawDeg   =  yawLeft  * RAD2DEG * sensX * dt
 *   pitchUp = -wy           and   pitchDeg = -pitchUp  * RAD2DEG * sensY * dt
 *
 * so with dt = OPENQ4_GYRO_SYNTH_DT:
 *
 *   wx = -radians(dyaw)  / dt,   wy = +radians(dpitch) / dt,   wz = 0
 *
 * One consequence worth knowing: because the sample claims a single frame, its
 * implied RATE is the requested degrees times 60, so the deadzone (0.6 deg/s)
 * only bites below about 0.01 requested degrees. `!gyro` therefore cannot
 * exercise the deadzone; that is a real-sensor property and stays device-gated.
 */
- (int)injectSyntheticGyroYaw:(float)yawDegrees pitch:(float)pitchDegrees {
	if (![self gyroActiveNow]) {
		const openq4GyroMode_t mode = [self gyroMode];
		fprintf(stdout, "openQ4 gyro: sample REFUSED — mode=%d inGame=%d cinematic=%d "
				"lookTouch=%d backgrounded=%d\n",
				(int)mode, OpenQ4_iOS_InGame(), OpenQ4_iOS_InCinematic(),
				_lookTouch != nil ? 1 : 0, _gyroBackgrounded ? 1 : 0);
		fflush(stdout);
		return 0;
	}
	const double before_y = _gyroYawApplied, before_p = _gyroPitchApplied;
	[self applyGyroSampleWx:-(double)yawDegrees   / (OPENQ4_RAD_TO_DEG * OPENQ4_GYRO_SYNTH_DT)
						 wy: (double)pitchDegrees / (OPENQ4_RAD_TO_DEG * OPENQ4_GYRO_SYNTH_DT)
						 wz: 0.0
						 gx: 1.0 gy: 0.0 gz: 0.0
						 dt: OPENQ4_GYRO_SYNTH_DT];
	const double gotY = _gyroYawApplied - before_y, gotP = _gyroPitchApplied - before_p;
	// "Applied" must mean the view moved, not merely that the call returned.
	// Reporting success for a sample the deadzone or a clamp swallowed is how a
	// harness passes while the product is broken.
	const int moved = (gotY != 0.0 || gotP != 0.0);
	fprintf(stdout, "openQ4 gyro: sample %s — asked yaw %+.2f pitch %+.2f, "
			"produced yaw %+.3f pitch %+.3f view degrees (sensX %.2f sensY %.2f invert %.0f)\n",
			moved ? "applied" : "APPLIED BUT PRODUCED NOTHING (deadzone or clamp)",
			yawDegrees, pitchDegrees, gotY, gotP,
			OpenQ4_iOS_SettingFloat("gyroSensX", 1.0f),
			OpenQ4_iOS_SettingFloat("gyroSensY", 1.0f),
			OpenQ4_iOS_SettingFloat("gyroInvertPitch", 0.0f));
	fflush(stdout);
	return moved;
}

- (NSString *)gyroDescription {
	return [NSString stringWithFormat:
		@"openQ4 gyro state: mode=%d active=%d hardware=%s unavailable=%d backgrounded=%d\n"
		 "openQ4 gyro state: sensX=%.2f sensY=%.2f invertPitch=%.0f deadzone=%.2f deg/s\n"
		 "openQ4 gyro state: samples=%lu suppressed=%lu applied yaw %+.2f pitch %+.2f view degrees\n",
		(int)[self gyroMode], [self gyroActiveNow] ? 1 : 0,
		_motion != nil ? "running" : "stopped", _motionUnavailable ? 1 : 0,
		_gyroBackgrounded ? 1 : 0,
		OpenQ4_iOS_SettingFloat("gyroSensX", 1.0f),
		OpenQ4_iOS_SettingFloat("gyroSensY", 1.0f),
		OpenQ4_iOS_SettingFloat("gyroInvertPitch", 0.0f),
		(double)OPENQ4_GYRO_DEADZONE_DPS,
		_gyroSamples, _gyroSuppressed, _gyroYawApplied, _gyroPitchApplied];
}

/*
 * Backgrounding. The display link stops when the app leaves the screen, so
 * nothing would be drained anyway — but CMMotionManager keeps running and
 * keeps costing battery, which none of the siblings noticed. Stop it, and drop
 * the sample clock so the first frame back does not carry the whole absence.
 */
- (void)setGyroBackgrounded:(BOOL)bg {
	_gyroBackgrounded = bg;
	_gyroLastSample = 0.0;
	[self updateGyroHardwareWanted:(!bg && [self gyroMode] != OPENQ4_GYRO_OFF)];
}

- (void)drainToEngine {
	if (_stickTouch != nil) {
		CGPoint d = CGPointMake(_stickCurrent.x - _stickOrigin.x,
								_stickCurrent.y - _stickOrigin.y);
		const CGFloat len = sqrtf((float)(d.x * d.x + d.y * d.y));
		const CGFloat clamped = (len > OPENQ4_STICK_RADIUS_PT) ? OPENQ4_STICK_RADIUS_PT : len;
		if (len > 0.001f) {
			const float scale = (float)(clamped / OPENQ4_STICK_RADIUS_PT / len);
			OpenQ4_iOS_InjectMove((float)(-d.y * scale), (float)(d.x * scale));
		}
	}
	// _pendingYaw/_pendingPitch are the touch accumulator (single writer: the
	// main thread; single reader/clearer: here). The gyro pair is engine-thread
	// only. Summed here so both sources land in one InjectLook per frame.
	const CGFloat yaw   = _pendingYaw + _gyroPendingYaw;
	const CGFloat pitch = _pendingPitch + _gyroPendingPitch;
	_gyroPendingYaw = 0.0f;
	_gyroPendingPitch = 0.0f;
	if (yaw != 0.0f || pitch != 0.0f) {
		OpenQ4_iOS_InjectLook((float)yaw, (float)pitch);
		_pendingYaw = 0.0f;
		_pendingPitch = 0.0f;
	}
}

@end

#pragma mark - C entry points

static OpenQ4TouchView *g_touchView = nil;

// -1 = follow the engine's GUI state, 0 = forced hidden, 1 = forced visible.
// The override exists because the simulator cannot reach gameplay, so the
// overlay's layout would otherwise never be verifiable there.
static int g_forceVisible = -1;


// The key window, or the scene's first — the same search OpenQ4_iOS_TouchSetup
// does, kept in one place so "which window" can never differ between attaching
// the overlay and re-attaching it.
static UIWindow *OpenQ4_iOS_TouchWindow(void) {
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

/*
 * The GAME window — the one whose swapchain freezes when the engine stops
 * presenting to it, and therefore the one a shell overlay such as the visionOS
 * 3D curtain MUST land on (D-106).
 *
 * It is the touch overlay's superview, not "the key window". vkQuake's
 * VKQ_iOS_GameWindow (ios/shell/ios_touch.m:688-694) is the same function with
 * the same comment: "'the key window' is a guess that can pick a SwiftUI
 * ornament/sheet hosting window on visionOS". The overlay is attached once,
 * early, while the game window is unambiguously the only one — so its superview
 * is the answer forever after, and it cannot be moved by a button tap.
 *
 * nil until the overlay is attached; callers fall back.
 */
UIWindow *OpenQ4_iOS_GameWindow(void) {
	return (UIWindow *)g_touchView.superview;
}

void OpenQ4_iOS_TouchSetup(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		if (g_touchView != nil) {
			return;
		}
		UIWindow *win = OpenQ4_iOS_TouchWindow();
		if (win == nil) {
			fprintf(stderr, "openQ4 touch: no window to attach to\n");
			return;
		}
		g_touchView = [[OpenQ4TouchView alloc] initWithFrame:win.bounds];
		g_touchView.autoresizingMask =
			UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		g_touchView.hidden = YES;   // shown once gameplay starts
		[win addSubview:g_touchView];
		// The view logs its own frame: UIKit placement is invisible to engine
		// screenshots, so this is the only way to verify it remotely.
		fprintf(stdout, "openQ4 touch: overlay attached, frame %.0fx%.0f\n",
				g_touchView.bounds.size.width, g_touchView.bounds.size.height);
		fflush(stdout);

		// Gyro lifecycle (D-083). The display link already stops when the app
		// leaves the screen, so nothing would be drained — but CMMotionManager
		// keeps sampling and keeps costing battery. Observers live next to the
		// thing they control, on the main queue, which is where CoreMotion is
		// started and stopped.
		NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
		[nc addObserverForName:UIApplicationDidEnterBackgroundNotification
						object:nil queue:NSOperationQueue.mainQueue
					usingBlock:^(NSNotification *n) {
			(void)n; [g_touchView setGyroBackgrounded:YES];
		}];
		[nc addObserverForName:UIApplicationWillEnterForegroundNotification
						object:nil queue:NSOperationQueue.mainQueue
					usingBlock:^(NSNotification *n) {
			(void)n; [g_touchView setGyroBackgrounded:NO];
		}];
	});
}

void OpenQ4_iOS_TouchFrame(void) {
	OpenQ4TouchView *v = g_touchView;
	if (v == nil) {
		return;
	}
	// Visibility follows the engine's own notion of being in a map, so the
	// controls disappear in menus without the shell tracking game state itself.
	// Demo playback is "in a map" as far as the engine is concerned, but there
	// is no player to steer: the sticks and action buttons come down and only
	// the chrome stays, so the hamburger can still open the transport (D-086).
	const BOOL inDemoPlayback = OpenQ4_iOS_InDemoPlayback() ? YES : NO;
	const BOOL wantVisible = (g_forceVisible >= 0)
		? (g_forceVisible ? YES : NO)
		: ((OpenQ4_iOS_InGame() && !inDemoPlayback) ? YES : NO);

	// The overlay VIEW is never hidden — only its parts are.
	//
	// Hiding the whole thing took the MENU and gear buttons with it, so the iOS
	// settings were unreachable in menus, during cinematics, and whenever a
	// controller was connected: exactly the moments a player needs them. The
	// chrome now stays up always and only the stick and action buttons follow
	// gameplay.
	//
	// This function runs on the ENGINE thread, and UIKit state must change on
	// the main thread. Setting it here is undefined, and in practice meant the
	// controls did not appear on entering a map — they showed up only after
	// backgrounding and returning, because that forces a main-thread layout
	// pass which finally applied the change.
	static BOOL lastWanted = NO;
	static BOOL everApplied = NO;
	if (!everApplied || wantVisible != lastWanted) {
		everApplied = YES;
		lastWanted = wantVisible;
		dispatch_async(dispatch_get_main_queue(), ^{
			v.hidden = NO;
			[v setControlsVisible:wantVisible];
		});
	}

	// Gyro FIRST, and unconditionally.
	//
	// First, because the sample it takes then leaves in the same injection as
	// the finger's degrees rather than as two turns the engine sees a tic apart,
	// and because reading the sensor immediately before it is consumed is the
	// lowest latency available.
	//
	// Unconditionally, because pollGyro also owns starting and stopping
	// CoreMotion. Calling it only while the controls are up would leave the
	// sensor running for the rest of the process after the player left the map —
	// its own gate already refuses to accumulate anything outside gameplay.
	[v pollGyro];

	// Reading the stick and draining accumulated look is engine-side state and
	// is safe from this thread; only the UIKit mutation above is not.
	if (wantVisible) {
		[v drainToEngine];
	}
}

void OpenQ4_iOS_TouchRefreshAppearance(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		OpenQ4TouchView *v = g_touchView;
		if (v == nil) {
			return;
		}
		// setNeedsLayout rather than calling applyAppearance directly: the
		// pad-hidden state also affects hit testing, and a layout pass is what
		// re-runs the whole placement.
		[v setNeedsLayout];
	});
}

void OpenQ4_iOS_TouchBeginLayoutEdit(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		[g_touchView beginEditingLayout];
	});
}

void OpenQ4_iOS_TouchPrintLayout(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		fputs(g_touchView.layoutDescription.UTF8String, stdout);
		fflush(stdout);
	});
}

void OpenQ4_iOS_TouchReassertFront(void) {
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ OpenQ4_iOS_TouchReassertFront(); });
		return;
	}
	OpenQ4TouchView *v = g_touchView;
	if (v == nil) {
		return;   // first boot: the overlay is attached later, on top of whatever exists then
	}
	UIWindow *win = OpenQ4_iOS_TouchWindow();
	if (win == nil) {
		return;
	}
	// Re-add covers the case where the overlay's superview went away with the
	// old view; bringSubviewToFront covers the ordinary case, where it survived
	// but a later sibling was appended over it.
	if (v.superview != win) {
		[v removeFromSuperview];
		v.frame = win.bounds;
		[win addSubview:v];
		fprintf(stdout, "openQ4 touch: overlay re-attached to the window after a view rebuild\n");
		fflush(stdout);
		return;
	}
	if (win.subviews.lastObject != v) {
		[win bringSubviewToFront:v];
		fprintf(stdout, "openQ4 touch: overlay raised back to the front after a view rebuild\n");
		fflush(stdout);
	}
}

void OpenQ4_iOS_TouchForcePad(int state) {
	dispatch_async(dispatch_get_main_queue(), ^{
		g_forcePad = (state < 0) ? -1 : (state != 0 ? 1 : 0);
		OpenQ4TouchView *v = g_touchView;
		[v setControlsVisible:v.controlsVisible];
		[v applyAppearance];
		fprintf(stdout, "openQ4 touch: forcePad=%d (test lever) — hideForPad now %d\n",
				g_forcePad, v != nil ? ([v shouldHideForPad] ? 1 : 0) : -1);
		fflush(stdout);
	});
}

void OpenQ4_iOS_TouchPrintState(void) {
	// The engine-side verdict is read here rather than on the main thread: it
	// is what OpenQ4_iOS_TouchFrame polls, and reading it from a different
	// thread than the report's other half would be a different question.
	const int inGame = OpenQ4_iOS_InGame();
	dispatch_async(dispatch_get_main_queue(), ^{
		OpenQ4TouchView *v = g_touchView;
		fprintf(stdout, "openQ4 touch state: overlay=%s inGame=%d forceVisible=%d\n",
				v != nil ? "attached" : "MISSING", inGame, g_forceVisible);
		if (v == nil) {
			fflush(stdout);
			return;
		}
		static const char *const kTouchModeNames[] = { "Auto", "On", "Off" };
		const int tmode = (int)(OpenQ4_iOS_SettingFloat("touchMode", 0.0f) + 0.5f);
		fprintf(stdout, "openQ4 touch state: controlsVisible=%d hideForPad=%d "
				"touchMode=%s padConnected=%d forcePad=%d "
				"hidden=%d window=%s superview=%s\n",
				v.controlsVisible ? 1 : 0, [v shouldHideForPad] ? 1 : 0,
				(tmode >= 0 && tmode <= 2) ? kTouchModeNames[tmode] : "?",
				(GCController.controllers.count > 0) ? 1 : 0, g_forcePad,
				v.hidden ? 1 : 0,
				v.window != nil ? "yes" : "NONE (orphaned)",
				v.superview != nil ? NSStringFromClass(v.superview.class).UTF8String : "(none)");
		fputs(v.gyroDescription.UTF8String, stdout);
		fprintf(stdout, "openQ4 touch state: %lu pad(s)\n",
				(unsigned long)GCController.controllers.count);
		// Safe-area provenance (D-085). Four zeros here after a game-module swap
		// is the whole 2D UI losing its insets, and nothing else in this report
		// distinguishes "no insets on this device" from "the window we are
		// reading has no scene".
		{
			const UIEdgeInsets vi = v.safeAreaInsets;
			UIWindow *win = v.window;
			const UIEdgeInsets wi = (win != nil) ? win.safeAreaInsets : UIEdgeInsetsZero;
			UIWindow *key = nil;
			for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
				if (![sc isKindOfClass:UIWindowScene.class]) { continue; }
				for (UIWindow *w in ((UIWindowScene *)sc).windows) {
					if (w.isKeyWindow) { key = w; break; }
				}
				if (key == nil) { key = ((UIWindowScene *)sc).windows.firstObject; }
				if (key != nil) { break; }
			}
			const UIEdgeInsets ki = (key != nil) ? key.safeAreaInsets : UIEdgeInsetsZero;
			fprintf(stdout, "openQ4 touch state: safeArea view=%.0f/%.0f/%.0f/%.0f "
							"window=%.0f/%.0f/%.0f/%.0f (scene=%s) key=%.0f/%.0f/%.0f/%.0f%s\n",
					vi.left, vi.top, vi.right, vi.bottom,
					wi.left, wi.top, wi.right, wi.bottom,
					(win != nil && win.windowScene != nil) ? "yes" : "no",
					ki.left, ki.top, ki.right, ki.bottom,
					(key == win) ? " (same window)" : "");
		}
		// Enough per pad to tell a real controller from a synthetic one (the
		// simulators present a pad named "Gamepad" with no motors, D-112).
		for (GCController *c in GCController.controllers) {
			fprintf(stdout, "openQ4 touch state:   pad vendor '%s' category '%s' extended=%d micro=%d "
							"haptics=%d snapshot=%d attached=%d battery=%s light=%d profile=%s\n",
					c.vendorName != nil ? c.vendorName.UTF8String : "(none)",
					c.productCategory != nil ? c.productCategory.UTF8String : "(none)",
					c.extendedGamepad != nil ? 1 : 0, c.microGamepad != nil ? 1 : 0,
					c.haptics != nil ? 1 : 0, c.isSnapshot ? 1 : 0,
					c.isAttachedToDevice ? 1 : 0,
					c.battery != nil ? "yes" : "no", c.light != nil ? 1 : 0,
					NSStringFromClass(c.physicalInputProfile.class).UTF8String);
		}
		fflush(stdout);
	});
}

/*
 * `!gyro <dyaw> <dpitch>` — see -injectSyntheticGyroYaw:pitch:.
 *
 * Synchronous on the main thread, so the bridge's reply is the RESULT rather
 * than an acknowledgement that the request was queued: a caller sampling
 * `getviewpos` immediately afterwards must not race the sample.
 */
int OpenQ4_iOS_TouchInjectGyro(float yawDegrees, float pitchDegrees) {
	__block int applied = 0;
	void (^work)(void) = ^{
		OpenQ4TouchView *v = g_touchView;
		if (v == nil) {
			fprintf(stdout, "openQ4 gyro: no overlay yet; sample ignored\n");
			fflush(stdout);
			return;
		}
		applied = [v injectSyntheticGyroYaw:yawDegrees pitch:pitchDegrees];
	};
	if (NSThread.isMainThread) {
		work();
	} else {
		dispatch_sync(dispatch_get_main_queue(), work);
	}
	return applied;
}

void OpenQ4_iOS_TouchPrintGyroState(void) {
	OpenQ4TouchView *v = g_touchView;
	if (v == nil) {
		fprintf(stdout, "openQ4 gyro state: no overlay\n");
		fflush(stdout);
		return;
	}
	fputs(v.gyroDescription.UTF8String, stdout);
	fflush(stdout);
}

void OpenQ4_iOS_TouchSynthesizeTap(float nx, float ny) {
	dispatch_async(dispatch_get_main_queue(), ^{
		OpenQ4TouchView *v = g_touchView;
		if (v == nil) {
			fprintf(stdout, "openQ4 touch: no overlay yet; touchtap ignored\n");
			fflush(stdout);
			return;
		}
		[v synthesizeTapAtNormalizedX:(CGFloat)nx y:(CGFloat)ny];
	});
}

void OpenQ4_iOS_TouchSetVisible(int visible) {
	// Latch the override so the per-frame visibility logic does not immediately
	// undo it. Pass a negative value to hand control back to the engine state.
	g_forceVisible = visible;
	dispatch_async(dispatch_get_main_queue(), ^{
		if (visible >= 0) {
			g_touchView.hidden = visible ? NO : YES;
		}
	});
}

/*
 * Safe-area insets as fractions of the view.
 *
 * The engine draws diagnostics in a 640x480 virtual space and has no idea a
 * sensor housing exists; its top-right corner is physically off screen on a
 * modern iPhone, which is where the FPS counter was landing. Fractions rather
 * than points, so the engine can scale them into its own space without knowing
 * anything about this one.
 */
/*
 * Push the safe-area insets into the engine, where they shrink the ONE
 * rectangle every 2D element is drawn through (D-085).
 *
 * Fractions, not points, and fractions of the view — which has the same aspect
 * as the drawable whatever the render scale is doing, so the engine can turn
 * them back into drawable pixels without knowing anything about either.
 *
 * Main thread because UIView.safeAreaInsets is UIKit state; the engine side
 * only stores atomics, so an early publish is kept and applied on the first
 * engine frame rather than dropped.
 */
/*
 * Press one of the chrome buttons, through its real target/action.
 *
 * `!touchtap` cannot do this: it publishes the in-world aim ray and never goes
 * near a UIButton, so the hamburger — the only way into the demo transport
 * during playback, and into the in-game menu everywhere else — has never been
 * provable on the simulator. Names match the layout keys: "pause" (hamburger),
 * "objectives", "settings" (gear). Returns 0 if there is no such button.
 */
int OpenQ4_iOS_TouchPressChrome(const char *name) {
	if (name == NULL) {
		return 0;
	}
	NSString *key = [NSString stringWithFormat:@"chrome.%s", name];
	__block int ok = 0;
	void (^work)(void) = ^{
		OpenQ4TouchView *v = g_touchView;
		UIButton *b = (v != nil) ? [v chromeButtonNamed:key] : nil;
		if (b == nil) {
			fprintf(stdout, "openQ4 chrome: no button '%s'\n", key.UTF8String);
			fflush(stdout);
			return;
		}
		fprintf(stdout, "openQ4 chrome: pressing %s (hidden=%d alpha=%.2f)\n",
				key.UTF8String, b.hidden ? 1 : 0, (double)b.alpha);
		fflush(stdout);
		[b sendActionsForControlEvents:UIControlEventTouchUpInside];
		ok = 1;
	};
	if (NSThread.isMainThread) { work(); } else { dispatch_sync(dispatch_get_main_queue(), work); }
	return ok;
}

void OpenQ4_iOS_PublishSafeArea(void) {
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{ OpenQ4_iOS_PublishSafeArea(); });
		return;
	}
	float l = 0.0f, t = 0.0f, r = 0.0f, b = 0.0f;
	OpenQ4_iOS_SafeAreaFractions(&l, &t, &r, &b);
	OpenQ4_iOS_PublishSafeAreaInsets(l, t, r, b);
}

void OpenQ4_iOS_SafeAreaFractions(float *l, float *t, float *r, float *b) {
	// Defaults matter: this is called from the engine thread and the view may
	// not exist yet, and a zero inset is the safe answer.
	if (l) { *l = 0.0f; }
	if (t) { *t = 0.0f; }
	if (r) { *r = 0.0f; }
	if (b) { *b = 0.0f; }

	OpenQ4TouchView *v = g_touchView;
	if (v == nil) {
		return;
	}
	/*
	 * The WINDOW's insets, not the view's, whenever there is a window.
	 *
	 * A view that has just been re-parented reports UIEdgeInsetsZero until UIKit
	 * lays it out, and the D-082 game-module swap re-parents this one on every
	 * SP<->MP transition. Reading the view there published four zeros, which
	 * un-inset the whole 2D UI mid-session — caught by the harness asserting the
	 * viewport across an Arena swap, not by looking at it. The window is laid
	 * out by the system and its insets are stable across the swap.
	 */
	UIWindow *win = v.window;
	if (win == nil) {
		// Mid-rebuild: the D-082 game-module swap re-roots the window and this
		// view is briefly detached, where UIKit reports UIEdgeInsetsZero for it.
		// Publishing that zero un-inset the entire 2D UI for the rest of the
		// session — the harness caught it across an Arena swap; a screenshot of
		// the swap would not have. Fall back to the scene's key window, which is
		// laid out throughout.
		for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
			if (![sc isKindOfClass:UIWindowScene.class]) { continue; }
			for (UIWindow *w in ((UIWindowScene *)sc).windows) {
				if (w.isKeyWindow) { win = w; break; }
			}
			if (win == nil) { win = ((UIWindowScene *)sc).windows.firstObject; }
			if (win != nil) { break; }
		}
	}
	UIView *src = (win != nil) ? (UIView *)win : (UIView *)v;
	if (src.bounds.size.width <= 0.0 || src.bounds.size.height <= 0.0) {
		return;
	}
	const UIEdgeInsets in = src.safeAreaInsets;
	const CGFloat w = src.bounds.size.width;
	const CGFloat h = src.bounds.size.height;
	if (l) { *l = (float)(in.left / w); }
	if (t) { *t = (float)(in.top / h); }
	if (r) { *r = (float)(in.right / w); }
	if (b) { *b = (float)(in.bottom / h); }
}

/*
 * openq4_ios_touch.h — touch controls.
 *
 * A UIKit overlay above SDL's Metal view: a floating movement stick on the left,
 * drag-to-look on the right, and action buttons. Input is injected straight into
 * the engine as movement axes and key events.
 *
 * Two conventions inherited from the sibling ports, both load-bearing:
 *
 *  - Look is fed as **absolute view degrees**, never through the engine's mouse
 *    sensitivity chain. Routing touch through mouse deltas makes sensitivity
 *    depend on m_pitch/m_yaw/sensitivity and their interactions, so a "touch
 *    sensitivity" slider then behaves differently at different mouse settings.
 *  - The movement stick has **zero deadzone and floats**: its centre is wherever
 *    the finger landed. A fixed stick with a deadzone feels broken on glass,
 *    because there is no physical centre to return to.
 */

#ifndef OPENQ4_IOS_TOUCH_H
#define OPENQ4_IOS_TOUCH_H

#ifdef __cplusplus
extern "C" {
#endif

/* Build the overlay over SDL's window. Call once, after common->Init(). */
void OpenQ4_iOS_TouchSetup(void);

/*
 * The visionOS 3D curtain's view tag. It lives here, next to the game-window
 * accessor it is raised on, so the bridge's `!views` verdict and the curtain
 * itself cannot disagree about how to recognise it (D-106). Arbitrary, and
 * distinctive enough to grep.
 */
#define OPENQ4_CURTAIN_TAG 0x4f513344   /* 'OQ3D' */

#ifdef __OBJC__
@class UIWindow;
/*
 * The GAME window (the overlay's superview), for shell overlays that must land
 * on it — the visionOS 3D curtain (D-106). NOT the key window: on visionOS the
 * key window right after an ornament tap can be SwiftUI's own hosting window.
 * nil before OpenQ4_iOS_TouchSetup has run.
 */
UIWindow *OpenQ4_iOS_GameWindow(void);

/*
 * TEST LEVER (D-106), not a feature: pretend a controller is connected, so the
 * Touch Controls row's Auto behaviour ("hidden while a pad drives the game")
 * can be photographed on a simulator that has no pad to pair. -1 restores real
 * GCController detection. Bridge: `!forcepad 0|1|off`.
 */
void OpenQ4_iOS_TouchForcePad(int state);
#endif

/*
 * Per-frame: feed accumulated look delta and stick state to the engine.
 * Called from the frame loop, before common->Frame().
 */
void OpenQ4_iOS_TouchFrame(void);

/* Show/hide the overlay — hidden in menus, shown in gameplay. */
void OpenQ4_iOS_TouchSetVisible(int visible);

/*
 * Re-read the appearance settings (size, opacity, always-show) and apply them.
 * Called when a setting changes; without it the overlay only picks up new
 * values on the next layout pass, so dragging the size slider appears to do
 * nothing until something else happens to trigger one.
 */
void OpenQ4_iOS_TouchRefreshAppearance(void);

/* Enter the drag-to-move layout editor (green check to finish, red to reset). */
void OpenQ4_iOS_TouchBeginLayoutEdit(void);

/*
 * Print the current layout as fractions of the view. This is how a layout the
 * player arranges by hand becomes the shipped default: arrange it, run
 * `!layout` on the console bridge, paste the numbers back.
 */
void OpenQ4_iOS_TouchPrintLayout(void);

/*
 * Print why the controls are (or are not) on screen: pad detection and its
 * names, the always-show escape hatch, the engine's in-game verdict, and where
 * the overlay sits in the view hierarchy. "The controls are gone" has at least
 * four independent causes (D-082) and a screenshot distinguishes none of them.
 */
void OpenQ4_iOS_TouchPrintState(void);

/*
 * Put the overlay back on top of the window, re-adding it if its superview was
 * torn down. Call after ANYTHING that can rebuild SDL's view: a game-module
 * swap re-creates the Vulkan surface, and SDL's -[SDL_uikitview setSDLWindow:]
 * re-assigns the window's rootViewController, which appends the new SDL view
 * ABOVE every earlier sibling — burying the controls for the rest of the
 * process (D-082). Idempotent and silent when nothing needed moving.
 */
void OpenQ4_iOS_TouchReassertFront(void);

/*
 * Engine-side hooks, implemented in the platform layer (overlay patch).
 * Kept as C so this ObjC file needs no engine C++ headers.
 */
void OpenQ4_iOS_InjectMove(float forward, float right);
void OpenQ4_iOS_InjectLook(float yawDegrees, float pitchDegrees);
void OpenQ4_iOS_InjectButton(const char *name, int down);
void OpenQ4_iOS_InjectEscape(void);
/* Mouse-style delta while the weapon wheel is held; the game reads mx/my. */
void OpenQ4_iOS_InjectWheelAim(float dx, float dy);
/* Press and release JOYn, so the player's own binding is what runs. */
void OpenQ4_iOS_InjectJoyKeyState(int joyIndex, int down);

/*
 * Direct touch on in-world GUIs (D-071).
 *
 * The shell publishes the touched point in normalised device coords (-1..1,
 * +x right, +y up); the game module casts its focus ray through that point
 * instead of the crosshair. The centre of the screen, (0,0), must reproduce
 * the crosshair ray exactly.
 *
 * The click is deliberately NOT BUTTON_ATTACK: the game turns it into a gui
 * mouse click only when a gui already has focus, so a tap on a wall can never
 * fire the weapon.
 */
void OpenQ4_iOS_SetTouchAim(int active, float ndcX, float ndcY);
void OpenQ4_iOS_SetTouchAimClick(int down);

/*
 * Synthesise a tap at a normalised view point (0..1, origin top-left) through
 * the same code the real touch handlers run. This is the console bridge's
 * `!touchtap` — the simulator cannot deliver a finger, and a harness that
 * re-implements the behaviour it tests passes while the product is broken
 * (dhewm3-ios D-014). Only UIKit's event delivery is skipped.
 */
void OpenQ4_iOS_TouchSynthesizeTap(float nx, float ny);

/*
 * Press a chrome button ("pause" = hamburger, "objectives", "settings") through
 * its real target/action. The bridge's `!chrome <name>`; the only way to prove
 * the hamburger on a simulator, and the hamburger is the door to the demo
 * transport (D-086).
 */
int OpenQ4_iOS_TouchPressChrome(const char *name);

/*
 * Gyro aim (D-083).
 *
 * Device motion reaches the view through OpenQ4_iOS_InjectLook, in absolute
 * view degrees, exactly like a look drag — never through the engine's mouse
 * chain and never through upstream's `in_gyro`, which is GAMEPAD gyro routed to
 * SDL3_QueueMouseDelta and therefore back through mouse sensitivity.
 *
 * `OpenQ4_iOS_TouchInjectGyro` is the console bridge's `!gyro <dyaw> <dpitch>`:
 * ONE synthetic motion sample, expressed in the engine's own view degrees, run
 * through the real gate + gravity projection + deadzone + sensitivity + invert.
 * The simulator has no gyro, so this is the only way any of it is verifiable
 * before hardware. Returns 1 if the sample was applied, 0 if the gate refused it
 * (and says why on stdout). Synchronous: a caller may read `getviewpos`
 * immediately afterwards.
 */
int  OpenQ4_iOS_TouchInjectGyro(float yawDegrees, float pitchDegrees);
void OpenQ4_iOS_TouchPrintGyroState(void);

/* Safe-area insets as fractions of the view, for engine-space diagnostics. */
void OpenQ4_iOS_SafeAreaFractions(float *l, float *t, float *r, float *b);
/*
 * Push those insets into the engine, which shrinks the 2D UI viewport by them
 * (D-085). Safe to call from any thread and at any time: it hops to the main
 * thread and does nothing until the engine is up.
 */
void OpenQ4_iOS_PublishSafeArea(void);
/* Tell SDL text input is over, so it does not re-present the keyboard. */
void OpenQ4_iOS_StopTextInput(void);
int  OpenQ4_iOS_InGame(void);
int  OpenQ4_iOS_InCinematic(void);
/*
 * True while a demo is playing back. The sticks and action buttons come down
 * for it (there is nobody to steer); the chrome stays, because the hamburger is
 * how the transport deck is opened (D-086).
 */
int  OpenQ4_iOS_InDemoPlayback(void);
/* True while a demo is being recorded; the settings sheet's Demos row reads it. */
int  OpenQ4_iOS_IsRecordingDemo(void);

// True while the engine's post-load "press any key to continue" gate is up.
// That gate is a blocking loop inside the engine, so it is invisible to the
// ordinary game-state predicates and has to be asked for directly.
int  OpenQ4_iOS_AwaitingContinue(void);
void OpenQ4_iOS_InjectContinueKey(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_TOUCH_H */

/*
 * openq4_ios_url.h — `openq4://` deep links (charter Phase 1, D-096).
 *
 * One handler for both shells. iOS is SDL-entry, so the URL arrives at SDL's
 * own app delegate and has to be intercepted there; visionOS is SwiftUI-entry
 * and delivers it through `.onOpenURL`. Both funnel into
 * OpenQ4_iOS_HandleURL(), which is the ONLY place a URL is parsed.
 *
 * A URL is an OUTSIDE input: any app, web page or Shortcut can open one. So the
 * routes are deliberately few, their arguments are character-validated, and the
 * one route that can run arbitrary console text is gated exactly as the :8774
 * bridge is (OTA builds on, public builds off).
 */

#ifndef OPENQ4_IOS_URL_H
#define OPENQ4_IOS_URL_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Handle one `openq4://` URL. Safe from any thread and at any point in the
 * app's life, including before the engine exists: the resulting console command
 * is queued and run by OpenQ4_iOS_DrainPendingURLs() once init has finished.
 *
 * Every URL is logged, handled or not.
 */
void OpenQ4_iOS_HandleURL(const char *url);

/*
 * Hand any queued deep-link commands to the engine. Called from the frame
 * thread (OpenQ4_iOS_BridgeDrain); a no-op until the engine is past
 * common->Init(), which on iOS is also past onboarding — OpenQ4_iOS_EnsureGameData
 * runs before Init and blocks, so "init complete" implies "out of onboarding".
 */
void OpenQ4_iOS_DrainPendingURLs(void);

/*
 * iOS only, and a no-op elsewhere: intercept SDL's app-delegate URL entry
 * points. SDL3 forwards an incoming URL to SDL_SendDropFile() and nothing else,
 * which would make a deep link indistinguishable from a genuine file drop, so
 * the delegate methods are swizzled and SDL's originals still called.
 *
 * Installed from a constructor in this file so it is in place before the
 * delegate is instantiated — a cold launch straight from a link hands the URL
 * to didFinishLaunching, long before SDL_main runs (this is exactly the case
 * dhewm3-ios could not cover by installing from main).
 */
void OpenQ4_iOS_InstallURLHandler(void);

/*
 * Print which class the live app delegate is and whether our openURL is the one
 * installed on it. Registered as the bridge's `!urlinfo`.
 */
void OpenQ4_iOS_ReportURLHandler(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_URL_H */

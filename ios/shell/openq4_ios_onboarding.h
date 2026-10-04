/*
 * openq4_ios_onboarding.h — first-run game-data import.
 *
 * openQ4 ships its own baseoq4 runtime packs but no retail Quake 4 data; the
 * user supplies q4base. On desktop the engine simply fatals when it cannot find
 * it. On iOS that is useless: there is no console to read the message in, and
 * the fatal path itself is unreliable (upstream #96), so a missing-data launch
 * presents as the app silently quitting.
 *
 * So the shell checks for data BEFORE common->Init() and, when it is absent,
 * puts up a real UI: explain what is needed, let the user pick a folder, copy it
 * in with progress, and report what was found.
 */

#ifndef OPENQ4_IOS_ONBOARDING_H
#define OPENQ4_IOS_ONBOARDING_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Returns once retail data is present under Documents/q4base, having run the
 * import UI if it was not. Blocks by pumping the run loop, so UIKit stays live
 * while the engine's boot is suspended.
 *
 * Call from main() before common->Init().
 */
void OpenQ4_iOS_EnsureGameData(void);

/*
 * Documents directory (also used by the engine's iOS save-path override).
 */
const char *OpenQ4_iOS_DocumentsPath(void);

/*
 * Boot overlay. Engine init takes 15-20 seconds on this content and happens
 * after the launch screen has gone, so without this the user watches a black
 * screen and assumes the app has hung — which is precisely what it looked like.
 */
void OpenQ4_iOS_ShowBootOverlay(void);

/* Update the overlay's caption, or pass NULL to tear it down. */
void OpenQ4_iOS_SetBootStatus(const char *text);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_ONBOARDING_H */

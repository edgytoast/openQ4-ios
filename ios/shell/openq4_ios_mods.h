/*
 * openq4_ios_mods.h — data-only mods: discovery, case normalisation, and the
 * one moment a mod can be chosen.
 *
 * Mods live beside q4base in the app's Documents directory (fs_savepath and
 * fs_homepath on iOS, which is also what Files.app shows), and a directory is a
 * mod only if it contains a `mod.json` manifest. See docs/mods.md.
 *
 * Two iOS-shaped facts drive everything here:
 *
 * 1. **`fs_game` can only be chosen before `common->Init()`.** It is CVAR_INIT,
 *    and the filesystem builds its search paths inside init; the engine's own
 *    Mods menu changes it and then calls `reloadEngine`, which tears the
 *    renderer down. So the shell's picker stores a choice and applies it as a
 *    `+set fs_game <dir>` startup argument on the NEXT cold launch.
 *
 * 2. **The container filesystem is case-sensitive.** `ListMods` drops any
 *    candidate directory whose name contains an uppercase letter — silently —
 *    so a `MyMod/` folder dragged in from Files is invisible with no warning at
 *    all. Everything under a mod directory is lowercased on launch, and what
 *    changed is logged. Nothing is ever deleted.
 */

#ifndef OPENQ4_IOS_MODS_H
#define OPENQ4_IOS_MODS_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Lowercase every mod directory under Documents, and everything inside it.
 * Call once per launch, on the main thread, BEFORE common->Init(). Only
 * directories carrying a mod.json are touched — q4base, baseoq4 and the
 * engine's own working directories are left exactly as they are.
 */
void OpenQ4_iOS_NormalizeModFolders(void);

/*
 * Extra arguments for common->Init(), in argv order and already in the
 * engine's `+set <cvar> <value>` form. Returns NULL with *outCount == 0 when
 * the player has chosen no mod, which is the overwhelmingly common case and
 * must leave the command line byte-for-byte what it was.
 *
 * The returned pointers stay valid until the next call (there is only ever
 * one, from the engine's iOS init path).
 */
const char *const *OpenQ4_iOS_StartupArgs(int *outCount);

/*
 * The game directory under Documents this launch runs from: the active mod's
 * directory, or "baseoq4" (where the base game writes its savegames). Valid
 * once OpenQ4_iOS_StartupArgs has run, i.e. from common->Init() on.
 */
const char *OpenQ4_iOS_LaunchGameDir(void);

/*
 * Print what the shell can see: every candidate directory, whether its
 * manifest is usable, and which mod is selected for the next launch. This is
 * the console bridge's `!mods`.
 */
void OpenQ4_iOS_PrintMods(void);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>

/* One discovered, manifest-valid mod. */
@interface OpenQ4ModInfo : NSObject
@property (nonatomic, copy) NSString *dir;      /* directory name, lowercase   */
@property (nonatomic, copy) NSString *name;     /* mod.json "name"             */
@property (nonatomic, copy) NSString *version;  /* mod.json "version"          */
@end

/* Mods that the engine would also accept, sorted by display name. */
NSArray<OpenQ4ModInfo *> *OpenQ4_iOS_ScanMods(void);

/* What the settings row should show: a mod's name, or "None (base game)". */
NSString *OpenQ4_iOS_ActiveModDisplayName(void);
#endif

#endif /* OPENQ4_IOS_MODS_H */

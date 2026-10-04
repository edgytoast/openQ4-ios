/*
 * openq4_ios_mods.m — mod discovery, case normalisation, and the startup
 * argument that selects one. See openq4_ios_mods.h for the two facts that
 * shape all of this, and docs/mods.md for the user-facing story.
 */

#import "openq4_ios_imagecache.h"
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "openq4_ios_mods.h"
#include "openq4_ios_onboarding.h"   /* OpenQ4_iOS_DocumentsPath */
#include "openq4_ios_settings.h"     /* OpenQ4_iOS_SettingString */

@implementation OpenQ4ModInfo
@end

/*
 * The manifest name is the engine's OPENQ4_MOD_MANIFEST_FILENAME. Keeping the
 * spelling in one place here means a rename upstream fails in one spot rather
 * than in four.
 */
static NSString *const kManifestName = @"mod.json";

/*
 * Directories under Documents that are NOT mods and must never be renamed or
 * recursed into. This list is belt and braces: the real gate is "does it
 * contain a mod.json", and none of these do. It exists so that a stray
 * manifest dropped into a game-data tree cannot make the normaliser start
 * lowercasing 2.6 GB of retail paks.
 */
static BOOL OpenQ4_IsReservedDirName(NSString *name) {
	static NSArray<NSString *> *reserved = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		reserved = @[ @"q4base", @"q4mp", @"baseoq4", @"inbox", @"logs",
					  @"savegames", @"screenshots", @"demos", @"crashes" ];
	});
	for (NSString *r in reserved) {
		if ([name caseInsensitiveCompare:r] == NSOrderedSame) {
			return YES;
		}
	}
	return NO;
}

static NSString *OpenQ4_DocsDir(void) {
	return [NSString stringWithUTF8String:OpenQ4_iOS_DocumentsPath()];
}

/* The entry named `mod.json` in any case, or nil. */
static NSString *OpenQ4_ManifestEntryIn(NSString *dir) {
	NSFileManager *fm = NSFileManager.defaultManager;
	for (NSString *e in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
		if ([e caseInsensitiveCompare:kManifestName] == NSOrderedSame) {
			return e;
		}
	}
	return nil;
}

#pragma mark - Case normalisation

/*
 * Names INSIDE a mod directory that the engine itself writes, and that the
 * normaliser must leave alone.
 *
 * The engine writes `openQ4Config.cfg` (mixed case, by that spelling) and its
 * savegames into the ACTIVE gamedir, which for a mod is the mod's own folder.
 * Lowercasing those turns the normaliser into a fight the engine re-starts on
 * every clean exit: rename, rewrite, rename, forever, with a log line each
 * time — and it renames the player's savegames as a side effect. None of them
 * came from a Windows-authored archive, which is the only thing this pass is
 * for. (The engine finds them either way — overlay patch 0011 made directory
 * lookups case-insensitive — which is exactly why the churn would have been
 * invisible except in the log.)
 */
static BOOL OpenQ4_IsEngineWrittenName(NSString *name) {
	static NSArray<NSString *> *owned = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		owned = @[ @"savegames", @"screenshots", @"logs", @"generated", @"demos",
				   @"openQ4Config.cfg", @"config.spec" ];
	});
	for (NSString *n in owned) {
		if ([name caseInsensitiveCompare:n] == NSOrderedSame) {
			return YES;
		}
	}
	return NO;
}

/*
 * Lowercase every name under `dir`, depth first.
 *
 * Never deletes and never overwrites: if the lowercase name is already taken by
 * something else the rename is refused and said out loud, because silently
 * clobbering one of the two files would be the one unrecoverable outcome here.
 */
/* Symlinks are skipped everywhere in the walk: fileExistsAtPath: follows
 * them, so a link inside a mod folder pointing at q4base, savegames, another
 * mod or an ancestor would have the normaliser renaming files it does not own,
 * or recursing forever. A mod is plain files and directories; a link is not
 * content. */
static BOOL OpenQ4_IsSymlink(NSString *path) {
	NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
	return [attrs.fileType isEqualToString:NSFileTypeSymbolicLink];
}

static void OpenQ4_LowercaseTree(NSString *dir, int *renamed, int *conflicts) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:NULL];
	if (entries == nil) {
		return;
	}
	for (NSString *e in entries) {
		// Dotfiles are never game content — `.DS_Store` rides in on every
		// folder copied from a Mac — and renaming one is pure log noise.
		if ([e hasPrefix:@"."] || OpenQ4_IsEngineWrittenName(e)) {
			continue;
		}
		NSString *lower = e.lowercaseString;
		NSString *path = [dir stringByAppendingPathComponent:e];
		if (OpenQ4_IsSymlink(path)) {
			fprintf(stdout, "openQ4 mods: skipping symlink '%s'\n", path.UTF8String);
			continue;
		}
		if (![lower isEqualToString:e]) {
			NSString *to = [dir stringByAppendingPathComponent:lower];
			if ([fm fileExistsAtPath:to]) {
				fprintf(stdout, "openQ4 mods: NOT renaming '%s' — '%s' already exists\n",
						path.UTF8String, to.UTF8String);
				(*conflicts)++;
			} else if ([fm moveItemAtPath:path toPath:to error:NULL]) {
				fprintf(stdout, "openQ4 mods: renamed '%s' -> '%s'\n",
						e.UTF8String, lower.UTF8String);
				(*renamed)++;
				path = to;
			} else {
				fprintf(stdout, "openQ4 mods: rename of '%s' FAILED\n", path.UTF8String);
				(*conflicts)++;
			}
		}
		BOOL isDir = NO;
		if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
			OpenQ4_LowercaseTree(path, renamed, conflicts);
		}
	}
}

void OpenQ4_iOS_NormalizeModFolders(void) {
	@autoreleasepool {
		NSFileManager *fm = NSFileManager.defaultManager;
		NSString *docs = OpenQ4_DocsDir();
		NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:docs error:NULL];
		if (entries == nil) {
			return;
		}

		int dirsSeen = 0, renamed = 0, conflicts = 0;
		for (NSString *e in entries) {
			if (OpenQ4_IsReservedDirName(e)) {
				continue;
			}
			NSString *path = [docs stringByAppendingPathComponent:e];
			BOOL isDir = NO;
			if (OpenQ4_IsSymlink(path)) {
				continue;   // a link is never a mod folder; never follow it
			}
			if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
				continue;
			}
			if (OpenQ4_ManifestEntryIn(path) == nil) {
				continue;   // not a mod; leave it completely alone
			}
			dirsSeen++;

			// The directory's own name first: ListMods deletes any candidate
			// whose name has an uppercase letter, so this rename is the one
			// that decides whether the mod is visible at all.
			NSString *lower = e.lowercaseString;
			if (![lower isEqualToString:e]) {
				NSString *to = [docs stringByAppendingPathComponent:lower];
				if ([fm fileExistsAtPath:to]) {
					fprintf(stdout, "openQ4 mods: NOT renaming mod folder '%s' — '%s' already exists\n",
							e.UTF8String, lower.UTF8String);
					conflicts++;
				} else if ([fm moveItemAtPath:path toPath:to error:NULL]) {
					fprintf(stdout, "openQ4 mods: renamed mod folder '%s' -> '%s'\n",
							e.UTF8String, lower.UTF8String);
					renamed++;
					path = to;
				} else {
					fprintf(stdout, "openQ4 mods: rename of mod folder '%s' FAILED\n", e.UTF8String);
					conflicts++;
				}
			}
			OpenQ4_LowercaseTree(path, &renamed, &conflicts);
		}
		fprintf(stdout, "openQ4 mods: normalised %d mod folder(s), %d name(s) lowercased, %d conflict(s)\n",
				dirsSeen, renamed, conflicts);
		fflush(stdout);
	}
}

#pragma mark - Discovery

/*
 * The six fields FS_ParseModManifest requires, all of them strings. A manifest
 * missing one is rejected by the engine with a `Skipping mod` warning, so the
 * picker must reject it too — offering a mod the engine will not load is worse
 * than not offering it, because the failure then happens after a relaunch with
 * nothing on screen to explain it.
 */
static NSArray<NSString *> *OpenQ4_RequiredManifestKeys(void) {
	return @[ @"name", @"version", @"releaseDate", @"website", @"author",
			  @"requiredopenQ4Version" ];
}

NSArray<OpenQ4ModInfo *> *OpenQ4_iOS_ScanMods(void) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *docs = OpenQ4_DocsDir();
	NSMutableArray<OpenQ4ModInfo *> *found = [NSMutableArray array];

	for (NSString *e in [fm contentsOfDirectoryAtPath:docs error:NULL]) {
		if (OpenQ4_IsReservedDirName(e)) {
			continue;
		}
		NSString *path = [docs stringByAppendingPathComponent:e];
		BOOL isDir = NO;
		if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
			continue;
		}
		NSString *manifestEntry = OpenQ4_ManifestEntryIn(path);
		if (manifestEntry == nil) {
			continue;
		}
		NSString *manifest = [path stringByAppendingPathComponent:manifestEntry];
		NSData *data = [NSData dataWithContentsOfFile:manifest];
		if (data == nil) {
			fprintf(stdout, "openQ4 mods: skipping '%s': %s could not be read\n",
					e.UTF8String, manifestEntry.UTF8String);
			continue;
		}
		NSError *err = nil;
		id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
		if (![parsed isKindOfClass:NSDictionary.class]) {
			fprintf(stdout, "openQ4 mods: skipping '%s': mod.json is not a JSON object (%s)\n",
					e.UTF8String, err.localizedDescription.UTF8String ?: "parse failed");
			continue;
		}
		NSDictionary *dict = (NSDictionary *)parsed;
		BOOL ok = YES;
		for (NSString *key in OpenQ4_RequiredManifestKeys()) {
			if (![dict[key] isKindOfClass:NSString.class]) {
				fprintf(stdout, "openQ4 mods: skipping '%s': mod.json has no string field '%s'\n",
						e.UTF8String, key.UTF8String);
				ok = NO;
				break;
			}
		}
		if (!ok) {
			continue;
		}
		// A name with an uppercase letter is invisible to the engine's own
		// ListMods; normalisation runs before this, so reaching here means the
		// rename was refused, and that is worth one line rather than silence.
		if (![e isEqualToString:e.lowercaseString]) {
			fprintf(stdout, "openQ4 mods: skipping '%s': the folder name must be all lowercase\n",
					e.UTF8String);
			continue;
		}
		OpenQ4ModInfo *info = [OpenQ4ModInfo new];
		info.dir = e;
		info.name = dict[@"name"];
		info.version = dict[@"version"];
		[found addObject:info];
	}

	[found sortUsingComparator:^NSComparisonResult(OpenQ4ModInfo *a, OpenQ4ModInfo *b) {
		return [a.name localizedCaseInsensitiveCompare:b.name];
	}];
	return found;
}

NSString *OpenQ4_iOS_ActiveModDisplayName(void) {
	NSString *chosen = OpenQ4_iOS_SettingString("activeMod");
	if (chosen.length == 0) {
		return @"None (base game)";
	}
	for (OpenQ4ModInfo *m in OpenQ4_iOS_ScanMods()) {
		if ([m.dir isEqualToString:chosen]) {
			return m.version.length ? [NSString stringWithFormat:@"%@ %@", m.name, m.version]
									: m.name;
		}
	}
	// Chosen but not found: the folder was deleted or renamed between launches.
	// Say so in the row rather than showing "None", because the next launch will
	// silently be the base game and the player needs to know why.
	return [NSString stringWithFormat:@"%@ (missing)", chosen];
}

#pragma mark - Startup argument

/*
 * `+set fs_game <dir> +set fs_game_base baseoq4`.
 *
 * **The fs_game_base half is not optional, and leaving it out is silent.**
 * openQ4 ships its own runtime content as the gamedir `baseoq4` and runs with
 * `fs_game baseoq4` by default — so `fs_game <mod>` REPLACES it rather than
 * adding to it, and the search path becomes mod -> q4base with openQ4's own
 * GUIs, TTF fonts, strings, bot files, `openq4_defaults.cfg` and our
 * `openq4_profile_ios.cfg` all gone. The engine does not complain: its baseoq4
 * MD5 gate is skipped precisely when neither fs_game nor fs_game_base is
 * baseoq4, and retail q4base carries a `default.cfg` of its own, so the game
 * boots and plays with the 2005 UI and none of the port's settings. Measured
 * on lane 1 (D-080) — the first mod launch execed `default.cfg` alone where a
 * base launch execs default + openq4_defaults + openq4_profile_ios.
 *
 * `fs_game_base` is exactly the slot for this: FileSystem::Startup sets up
 * BASE_GAMEDIR (q4base), then fs_game_base, then fs_game, so the mod still
 * wins every file it overrides and baseoq4 backs it up. Upstream's own Mods
 * menu sets fs_game alone and has the same hole; worth filing.
 *
 * si_gameType is deliberately NOT forced. openQ4's default.cfg does
 * `sets si_gameType singleplayer` for exactly this reason ("the client picks
 * its game module from si_gameType before anything is loaded") and that
 * default.cfg comes back with baseoq4.
 */
static char **s_args = NULL;
static int    s_argCount = 0;

static void OpenQ4_FreeArgs(void) {
	for (int i = 0; i < s_argCount; i++) {
		free(s_args[i]);
	}
	free(s_args);
	s_args = NULL;
	s_argCount = 0;
}

/*
 * The mod that should be active this launch: the stored choice, validated
 * against the filesystem (the choice survives in NSUserDefaults across app
 * updates and reinstalls, and the folder does not have to). nil = base game.
 */
static NSString *OpenQ4_ValidatedActiveMod(void) {
	NSString *chosen = OpenQ4_iOS_SettingString("activeMod");
	if (chosen.length == 0) {
		fprintf(stdout, "openQ4 mods: no mod selected; launching the base game\n");
		return nil;
	}
	NSString *dir = [OpenQ4_DocsDir() stringByAppendingPathComponent:chosen];
	BOOL isDir = NO;
	if (![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
		fprintf(stdout, "openQ4 mods: selected mod '%s' is not in Documents any more; "
						"launching the base game\n", chosen.UTF8String);
		return nil;
	}
	if (OpenQ4_ManifestEntryIn(dir) == nil) {
		fprintf(stdout, "openQ4 mods: selected mod '%s' has no mod.json; "
						"launching the base game\n", chosen.UTF8String);
		return nil;
	}
	return chosen;
}

/* The game directory this launch runs from (D-112's "Continue" reads its
 * savegames). Set once by OpenQ4_iOS_StartupArgs, before common->Init(). */
static char s_launchGameDir[256] = "baseoq4";

const char *OpenQ4_iOS_LaunchGameDir(void) {
	return s_launchGameDir;
}

const char *const *OpenQ4_iOS_StartupArgs(int *outCount) {
	@autoreleasepool {
		OpenQ4_FreeArgs();
		if (outCount != NULL) {
			*outCount = 0;
		}

		NSMutableArray<NSString *> *args = [NSMutableArray array];
		NSString *mod = OpenQ4_ValidatedActiveMod();
		snprintf(s_launchGameDir, sizeof(s_launchGameDir), "%s",
				 mod != nil ? mod.UTF8String : "baseoq4");
		if (mod != nil) {
			[args addObjectsFromArray:@[ @"+set", @"fs_game", mod,
										 @"+set", @"fs_game_base", @"baseoq4" ]];
			fprintf(stdout, "openQ4 mods: launching with mod '%s' "
							"(+set fs_game %s +set fs_game_base baseoq4)\n",
					mod.UTF8String, mod.UTF8String);
		}
		fflush(stdout);

		/*
		 * The image cache guard (D-109) runs here for the same reason the mod
		 * does: it must act before common->Init() — before the filesystem
		 * exists and before the first image is read from generated/. It wipes
		 * a stale cache and says whether the engine may skip the image
		 * source-timestamp checks; the answer travels as a `+set`, explicitly
		 * 0 or 1, so a stray value in a saved config can never decide it.
		 */
		const BOOL skipTimes = OpenQ4_iOS_ImageCacheGuard(mod);
		[args addObjectsFromArray:@[ @"+set", @"image_skipSourceTimeChecks", skipTimes ? @"1" : @"0" ]];

		const int n = (int)args.count;
		s_args = (char **)calloc((size_t)n, sizeof(char *));
		if (s_args == NULL) {
			return NULL;
		}
		for (int i = 0; i < n; i++) {
			s_args[i] = strdup(args[i].UTF8String);
		}
		s_argCount = n;
		if (outCount != NULL) {
			*outCount = n;
		}
		return (const char *const *)s_args;
	}
}

void OpenQ4_iOS_PrintMods(void) {
	@autoreleasepool {
		NSArray<OpenQ4ModInfo *> *mods = OpenQ4_iOS_ScanMods();
		NSString *chosen = OpenQ4_iOS_SettingString("activeMod");
		fprintf(stdout, "openQ4 mods: %d usable mod(s) in %s\n",
				(int)mods.count, OpenQ4_iOS_DocumentsPath());
		for (OpenQ4ModInfo *m in mods) {
			fprintf(stdout, "  %s  %s %s%s\n",
					m.dir.UTF8String, m.name.UTF8String, m.version.UTF8String,
					[m.dir isEqualToString:chosen] ? "   <- selected" : "");
		}
		fprintf(stdout, "openQ4 mods: selected for the next launch: '%s' (%s)\n",
				chosen.length ? chosen.UTF8String : "",
				OpenQ4_iOS_ActiveModDisplayName().UTF8String);
		fflush(stdout);
	}
}

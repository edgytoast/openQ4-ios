/*
 * openq4_ios_imagecache.m — see openq4_ios_imagecache.h (D-109).
 */
#import "openq4_ios_imagecache.h"
#import "openq4_ios_onboarding.h"

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdio.h>

static NSString *const kStampName = @"openq4-imagecache.txt";

/* Same LC_UUID read as the D-108 pak gate (FileSystem.cpp, overlay 0011). */
static NSString *OpenQ4_ExecutableUUID(void) {
	const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
	if (header == NULL || header->magic != MH_MAGIC_64) {
		return nil;
	}
	const uint8_t *cursor = (const uint8_t *)(header + 1);
	for (uint32_t i = 0; i < header->ncmds; i++) {
		const struct load_command *cmd = (const struct load_command *)cursor;
		if (cmd->cmd == LC_UUID) {
			const struct uuid_command *u = (const struct uuid_command *)cmd;
			NSMutableString *s = [NSMutableString string];
			for (int b = 0; b < 16; b++) {
				[s appendFormat:@"%02x", u->uuid[b]];
			}
			return s;
		}
		cursor += cmd->cmdsize;
	}
	return nil;
}

/* Retail Quake 4 pk4 names, as the onboarding classifier knows them: the
 * numbered paks (001-025 across patch levels), the language packs (zpak_*),
 * the Collector's Edition pak (q4cmp_*), and game*.pk4, which the engine
 * ignores on this platform. Anything else is a player's own pk4. */
static BOOL OpenQ4_IsRetailPk4(NSString *name) {
	static NSRegularExpression *re = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		re = [NSRegularExpression
			regularExpressionWithPattern:@"^(pak[0-9]{3}|zpak_[a-z0-9_]+|q4cmp_pak[0-9]{3}|game[0-9]*)\\.pk4$"
								 options:NSRegularExpressionCaseInsensitive error:NULL];
	});
	return [re numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] == 1;
}

/* Directories the ENGINE writes into a game directory under fs_savepath. None
 * of them can hold an asset the filesystem would serve in place of a pak's.
 * "_oq4" (since the v0.13.2 pin, D-110) is the staging namespace the session
 * writes expanded loadscreens through before an atomic rename; it only ever
 * holds <128-bit nonce>.tmp files, which no asset lookup resolves to. */
static BOOL OpenQ4_IsEngineWrittenDir(NSString *name) {
	static NSArray<NSString *> *names = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		names = @[ @"generated", @"logs", @"savegames", @"demos", @"screenshots", @"crashes", @"_oq4" ];
	});
	if ([name hasPrefix:@"generated.wipe-"]) {
		return YES;
	}
	for (NSString *n in names) {
		if ([name caseInsensitiveCompare:n] == NSOrderedSame) {
			return YES;
		}
	}
	return NO;
}

/* baseoq4/guis is engine-written too, as long as everything in it is the
 * loadscreen cache under guis/assets/generated (D-108). Anything else in it is
 * a player's loose GUI override. */
static BOOL OpenQ4_GuisDirIsEngineCache(NSString *guisDir) {
	NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:guisDir];
	for (NSString *rel in en) {
		if ([en.fileAttributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
			continue;
		}
		if ([rel.lastPathComponent hasPrefix:@"."]) {
			continue;
		}
		if (![rel.lowercaseString hasPrefix:@"assets/generated/"]) {
			return NO;
		}
	}
	return YES;
}

BOOL OpenQ4_iOS_ImageCacheGuard(NSString *mod) {
	@autoreleasepool {
		NSFileManager *fm = NSFileManager.defaultManager;
		NSString *docs = [NSString stringWithUTF8String:OpenQ4_iOS_DocumentsPath()];

		NSMutableArray<NSString *> *gameDirs = [NSMutableArray arrayWithArray:@[ @"q4base", @"q4mp", @"baseoq4" ]];
		if (mod.length > 0) {
			[gameDirs addObject:mod];
		}

		NSString *uuid = OpenQ4_ExecutableUUID() ?: @"unknown";
		NSMutableArray<NSString *> *lines = [NSMutableArray array];
		NSMutableArray<NSString *> *userContent = [NSMutableArray array];
		if (mod.length > 0) {
			[userContent addObject:[NSString stringWithFormat:@"mod '%@'", mod]];
		}

		for (NSString *gd in gameDirs) {
			NSString *dir = [docs stringByAppendingPathComponent:gd];
			NSArray<NSString *> *entries =
				[[fm contentsOfDirectoryAtPath:dir error:NULL] sortedArrayUsingSelector:@selector(compare:)];
			for (NSString *e in entries) {
				if ([e hasPrefix:@"."]) {
					continue;
				}
				NSString *path = [dir stringByAppendingPathComponent:e];
				NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
				if (attrs == nil) {
					continue;
				}
				const BOOL isDir = [attrs[NSFileType] isEqualToString:NSFileTypeDirectory];
				if (!isDir) {
					if ([e.pathExtension caseInsensitiveCompare:@"pk4"] != NSOrderedSame) {
						continue;   // configs, logs, readmes: nothing the image loader reads
					}
					[lines addObject:[NSString stringWithFormat:@"pk4 %@/%@ size=%llu mtime=%.6f",
						gd, e, [attrs[NSFileSize] unsignedLongLongValue],
						[(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970]]];
					const BOOL retail = OpenQ4_IsRetailPk4(e) && ![gd isEqualToString:@"baseoq4"];
					if (!retail) {
						[userContent addObject:[NSString stringWithFormat:@"%@/%@", gd, e]];
					}
					continue;
				}
				if (OpenQ4_IsEngineWrittenDir(e)) {
					continue;
				}
				if ([gd isEqualToString:@"baseoq4"] && [e caseInsensitiveCompare:@"guis"] == NSOrderedSame
						&& OpenQ4_GuisDirIsEngineCache(path)) {
					continue;
				}
				[lines addObject:[NSString stringWithFormat:@"dir %@/%@ mtime=%.6f",
					gd, e, [(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970]]];
				[userContent addObject:[NSString stringWithFormat:@"%@/%@/", gd, e]];
			}
		}

		/* The paks the app bundle ships (baseoq4/pak0, pak1). The executable's
		 * UUID does not move when only pak content changes, so they are
		 * fingerprinted directly — by name RELATIVE to the bundle (the bundle's
		 * absolute path changes across installs), size and mtime. The bundle is
		 * read-only, so these are stable from launch to launch of one install. */
		NSMutableArray<NSString *> *bundleLines = [NSMutableArray array];
		{
			NSString *bdir = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"baseoq4"];
			NSArray<NSString *> *bentries =
				[[fm contentsOfDirectoryAtPath:bdir error:NULL] sortedArrayUsingSelector:@selector(compare:)];
			for (NSString *e in bentries) {
				if ([e.pathExtension caseInsensitiveCompare:@"pk4"] != NSOrderedSame) {
					continue;
				}
				NSDictionary *attrs = [fm attributesOfItemAtPath:[bdir stringByAppendingPathComponent:e] error:NULL];
				if (attrs == nil) {
					continue;
				}
				[bundleLines addObject:[NSString stringWithFormat:@"bundle baseoq4/%@ size=%llu mtime=%.6f",
					e, [attrs[NSFileSize] unsignedLongLongValue],
					[(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970]]];
			}
		}
		NSString *bundleBlock = [bundleLines componentsJoinedByString:@"\n"];

		NSString *key = [NSString stringWithFormat:@"openq4-imagecache v2 exe=%@ fs_game=%@\n%@\n%@\n",
			uuid, mod ?: @"", bundleBlock, [lines componentsJoinedByString:@"\n"]];

		NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
		NSString *stampPath = [caches stringByAppendingPathComponent:kStampName];
		NSString *stored = [NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:NULL];

		// What changed, in words, for the log line.
		NSString *reason = nil;
		if (stored == nil) {
			reason = @"no stamp (first launch of this cache scheme, or Caches was purged)";
		} else if (![stored isEqualToString:key]) {
			NSString *firstStored = [[stored componentsSeparatedByString:@"\n"] firstObject];
			NSString *firstKey = [[key componentsSeparatedByString:@"\n"] firstObject];
			if (![firstStored isEqualToString:firstKey]) {
				reason = [firstStored containsString:[NSString stringWithFormat:@"exe=%@ ", uuid]]
					? @"the active mod changed" : @"the app build changed";
			} else if (bundleBlock.length > 0 && ![stored containsString:bundleBlock]) {
				reason = @"the bundled baseoq4 paks changed";
			} else {
				reason = @"the pk4s or loose content in the game folders changed";
			}
		}

		// Leftovers of an interrupted background delete go first, every launch.
		NSMutableArray<NSString *> *toDelete = [NSMutableArray array];
		for (NSString *gd in gameDirs) {
			NSString *dir = [docs stringByAppendingPathComponent:gd];
			for (NSString *e in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
				if ([e hasPrefix:@"generated.wipe-"]) {
					[toDelete addObject:[dir stringByAppendingPathComponent:e]];
				}
			}
		}

		NSMutableArray<NSString *> *wiped = [NSMutableArray array];
		NSMutableArray<NSString *> *stuck = [NSMutableArray array];
		if (reason != nil) {
			const long long stamp = (long long)([NSDate date].timeIntervalSince1970 * 1000.0);
			for (NSString *gd in gameDirs) {
				NSString *gen = [[docs stringByAppendingPathComponent:gd] stringByAppendingPathComponent:@"generated"];
				BOOL isDir = NO;
				if (![fm fileExistsAtPath:gen isDirectory:&isDir] || !isDir) {
					continue;
				}
				// Renamed aside first, so the engine starts on an empty cache at
				// once whatever the delete costs (1.3 GB on the simulator).
				NSString *aside = [gen stringByAppendingFormat:@".wipe-%lld", stamp];
				NSError *err = nil;
				if ([fm moveItemAtPath:gen toPath:aside error:&err]) {
					[toDelete addObject:aside];
					[wiped addObject:[NSString stringWithFormat:@"%@/generated", gd]];
				} else {
					fprintf(stdout, "openQ4 imagecache: FAILED to move %s aside: %s\n",
							gen.UTF8String, err.localizedDescription.UTF8String);
					[stuck addObject:[NSString stringWithFormat:@"%@/generated", gd]];
				}
			}
			// A stale generated/ that could not be moved is still there. Leave
			// the OLD stamp in place so the next launch retries the wipe, and
			// do not trust the cache this launch (checked below).
			if (stuck.count == 0) {
				NSError *err = nil;
				if (![key writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
					fprintf(stdout, "openQ4 imagecache: FAILED to write %s: %s\n",
							stampPath.UTF8String, err.localizedDescription.UTF8String);
				}
			}
		}

		if (toDelete.count > 0) {
			NSArray<NSString *> *paths = [toDelete copy];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
				for (NSString *p in paths) {
					NSError *err = nil;
					if (![NSFileManager.defaultManager removeItemAtPath:p error:&err]) {
						fprintf(stdout, "openQ4 imagecache: FAILED to delete %s: %s\n",
								p.UTF8String, err.localizedDescription.UTF8String);
					}
				}
				fprintf(stdout, "openQ4 imagecache: background delete of %d old cache dir(s) finished\n",
						(int)paths.count);
				fflush(stdout);
			});
		}

		if (stuck.count > 0) {
			fprintf(stdout, "openQ4 imagecache: could not move %s aside; stamp NOT renewed, "
							"source-time checks forced ON this launch\n",
					[stuck componentsJoinedByString:@", "].UTF8String);
		}
		const BOOL skip = (userContent.count == 0) && (stuck.count == 0);
		NSString *contentWord = (userContent.count == 0) ? @"retail only"
			: [NSString stringWithFormat:@"user content: %@",
				[[userContent subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)4, userContent.count))]
					componentsJoinedByString:@", "]];
		if (reason != nil) {
			fprintf(stdout, "openQ4 imagecache: %s because %s; wiped %s; source-time checks %s (%s)\n",
					wiped.count ? "cache reset" : (stuck.count ? "cache reset FAILED" : "stamp renewed"),
					reason.UTF8String,
					wiped.count ? [wiped componentsJoinedByString:@", "].UTF8String : "nothing (no generated/ yet)",
					skip ? "SKIPPED" : "ON", contentWord.UTF8String);
		} else {
			fprintf(stdout, "openQ4 imagecache: stamp matches (exe=%s), cache kept; source-time checks %s (%s)\n",
					uuid.UTF8String, skip ? "SKIPPED" : "ON", contentWord.UTF8String);
		}
		fflush(stdout);
		return skip;
	}
}

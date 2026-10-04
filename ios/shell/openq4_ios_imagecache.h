/*
 * openq4_ios_imagecache.h — keep the engine's generated/ image cache honest
 * when the image source-timestamp checks are skipped (D-109).
 *
 * The engine's `image_skipSourceTimeChecks` (overlay patch 0006) is the image
 * half of com_productionMode: it stops re-parsing every image program and
 * stat()ing its sources just to prove a cached generated/ image is not stale.
 * That proof is moved here, to one comparison per launch: a fingerprint of
 * everything that could make the cache stale —
 *
 *   - the running executable's Mach-O LC_UUID (unique per link, so every app
 *     build: the image code ships with it),
 *   - the bundle's own baseoq4/*.pk4 (bundle-relative name, size, mtime), since
 *     a build that changes only pak content does not relink,
 *   - the active mod (fs_game),
 *   - every pk4 in the game directories (name, size, mtime),
 *   - every loose content directory in them,
 *
 * stored in Library/Caches/openq4-imagecache.txt. Any difference renames each
 * game directory's `generated/` aside and deletes it in the background; if a
 * rename fails, the old stamp is kept (the wipe retries next launch) and the
 * timestamp checks stay ON for that launch. Only
 * `generated/` is ever touched: saves, configs, logs, demos and game data are
 * never in it.
 *
 * The skip itself is only switched on for PRISTINE content — retail pk4s, no
 * mod, no extra pk4s, no loose directories. Anything else runs upstream's full
 * checks, because a loose TGA override has to beat a retail DDS and only the
 * timestamp comparison knows that.
 */
#ifndef OPENQ4_IOS_IMAGECACHE_H
#define OPENQ4_IOS_IMAGECACHE_H

#ifdef __OBJC__
#import <Foundation/Foundation.h>

/*
 * Run before common->Init(). `mod` is the validated fs_game directory name or
 * nil for the base game. Wipes stale caches, logs one line, and returns YES
 * when the engine may skip image source-timestamp checks.
 */
BOOL OpenQ4_iOS_ImageCacheGuard(NSString *mod);
#endif

#endif /* OPENQ4_IOS_IMAGECACHE_H */

/*
 * openq4_ios_onboarding.m — first-run game-data import.
 *
 * Flow:
 *
 *   EnsureGameData()  →  data present?  →  return, engine boots
 *                     →  absent?        →  show UI, block pumping the run loop
 *                                          until the user has imported a q4base
 *
 * Three things here are less obvious than they look:
 *
 * 1. **Case normalisation.** The iOS container filesystem is case-SENSITIVE
 *    where macOS's is not. Retail trees copied from Windows routinely carry
 *    `PAK001.PK4` or `Q4Base`, which the engine then cannot open. Upstream's own
 *    diagnostics call case-mismatched Windows-sourced trees the dominant Linux
 *    failure, and iOS inherits it exactly. Everything is lowercased on import
 *    and what changed is logged.
 *
 * 2. **Security-scoped access.** A folder from UIDocumentPicker is only readable
 *    between startAccessingSecurityScopedResource and its stop, and the picker
 *    hands back a URL that may live outside the sandbox entirely (iCloud, a USB
 *    drive, another app's container).
 *
 * 3. **The classifier is advisory, not authoritative.** It runs before the
 *    engine exists, so it can only judge by filename. The authoritative check is
 *    the engine's own checksum table (DECISIONS D-005), which runs at startup
 *    right after this. The UI's job is to catch the common mistakes early and in
 *    plain language — wrong folder, unpatched install, still-downloading files.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../compat/openq4_ios_compat.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "openq4_ios_onboarding.h"
#include "openq4_ios_mods.h"
#include "openq4_ios_loc.h"

// Retail Quake 4 requires pak001..pak022; anything below pak019 present but
// pak019+ absent is the signature of a pre-1.4.2 install.
static const int kRequiredPakFirst = 1;
static const int kRequiredPakLast = 22;

const char *OpenQ4_iOS_DocumentsPath(void) {
	static char cached[1024];
	if (cached[0] != '\0') {
		return cached;
	}
	@autoreleasepool {
		NSArray<NSString *> *paths =
			NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		if (paths.count == 0) {
			return "";
		}
		snprintf(cached, sizeof(cached), "%s", paths.firstObject.fileSystemRepresentation);
	}
	return cached;
}

static NSString *OpenQ4_DocumentsDir(void) {
	return [NSString stringWithUTF8String:OpenQ4_iOS_DocumentsPath()];
}

static NSString *OpenQ4_Q4BaseDir(void) {
	return [OpenQ4_DocumentsDir() stringByAppendingPathComponent:@"q4base"];
}

/*
 * D-112: where an import is copied BEFORE it becomes Documents/q4base.
 *
 * The old import wrote straight into Documents/q4base, and the launch check
 * only asked "is any pak there?" — so a copy killed half-way (the app swiped
 * away, the phone locked long enough to be suspended, a crash) left eleven
 * paks and a truncated twelfth that the next launch took for game data and
 * handed to the engine, which then died on the checksum gate. Now the copy
 * lands in Library/Application Support (not visible in Files, same volume as
 * Documents so the final step is a rename), a marker is written only once
 * every byte is there and every size matches, and only then are the files
 * moved into q4base. On launch, a staging dir WITH the marker is finished
 * (the move was interrupted); one WITHOUT it is discarded — it is our own
 * half-copy, never the player's data.
 */
static NSString *OpenQ4_ImportStagingDir(void) {
	NSArray<NSString *> *paths =
		NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
	NSString *base = paths.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
	return [base stringByAppendingPathComponent:@"openq4-import"];
}
static NSString *const kImportCompleteMarker = @".import-complete";

/* The entry of `dir` whose name matches `name` ignoring case, or nil. */
static NSString *OpenQ4_ChildIgnoringCase(NSString *dir, NSString *name) {
	for (NSString *e in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL]) {
		if ([e caseInsensitiveCompare:name] == NSOrderedSame) {
			return [dir stringByAppendingPathComponent:e];
		}
	}
	return nil;
}

/*
 * Case normalisation of a q4base that arrived in Documents behind the app's
 * back (Files, Finder, AirDrop): `Q4Base` -> `q4base`, `PAK001.PK4` ->
 * `pak001.pk4`. Run at EVERY launch before the data check, not only from the
 * "Check Again" button, so a player who drops the folder in and then opens the
 * app goes straight to the game. Renames only; never deletes. Returns how many
 * names changed and logs each one.
 */
static int OpenQ4_NormalizeQ4BaseInDocuments(void) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *q4base = OpenQ4_Q4BaseDir();
	int renamed = 0;
	if (![fm fileExistsAtPath:q4base]) {
		NSString *found = OpenQ4_ChildIgnoringCase(OpenQ4_DocumentsDir(), @"q4base");
		if (found != nil && [fm moveItemAtPath:found toPath:q4base error:NULL]) {
			fprintf(stdout, "openQ4 onboarding: renamed '%s' -> 'q4base'\n",
					found.lastPathComponent.UTF8String);
			renamed++;
		}
	}
	for (NSString *e in [fm contentsOfDirectoryAtPath:q4base error:NULL]) {
		NSString *lower = e.lowercaseString;
		if ([lower isEqualToString:e] || ![lower.pathExtension isEqualToString:@"pk4"]) {
			continue;
		}
		NSString *to = [q4base stringByAppendingPathComponent:lower];
		if ([fm fileExistsAtPath:to]) {
			fprintf(stdout, "openQ4 onboarding: NOT renaming '%s': '%s' already exists\n",
					e.UTF8String, lower.UTF8String);
			continue;
		}
		if ([fm moveItemAtPath:[q4base stringByAppendingPathComponent:e] toPath:to error:NULL]) {
			fprintf(stdout, "openQ4 onboarding: renamed '%s' -> '%s'\n", e.UTF8String, lower.UTF8String);
			renamed++;
		}
	}
	fflush(stdout);
	return renamed;
}

/*
 * Move a COMPLETE staged import into Documents/q4base. Each pak is a rename on
 * the same volume; a pak of the same name already in q4base is the same file
 * from an earlier import or drop and is replaced atomically by the rename. Returns NO (and leaves the
 * staging dir for the next launch to retry) if any move fails.
 */
static BOOL OpenQ4_CommitStagedImport(NSString *staging) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *dest = OpenQ4_Q4BaseDir();
	[fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:NULL];
	int moved = 0;
	for (NSString *e in [fm contentsOfDirectoryAtPath:staging error:NULL]) {
		if ([e isEqualToString:kImportCompleteMarker]) {
			continue;
		}
		NSString *to = [dest stringByAppendingPathComponent:e];
		// rename(2), not remove + move: it replaces an existing pak of the
		// same name atomically, so a failure part way leaves the OLD pak in
		// place rather than no pak at all. Staging and Documents are the same
		// container volume; a cross-volume EXDEV fails here, loudly, with the
		// destination untouched.
		NSString *from = [staging stringByAppendingPathComponent:e];
		if (rename(from.fileSystemRepresentation, to.fileSystemRepresentation) != 0) {
			fprintf(stderr, "openQ4 onboarding: commit failed on %s: %s\n",
					e.UTF8String, strerror(errno));
			fflush(stderr);
			return NO;
		}
		moved++;
	}
	[fm removeItemAtPath:staging error:NULL];
	fprintf(stdout, "openQ4 onboarding: committed staged import (%d pak(s) moved into q4base)\n", moved);
	fflush(stdout);
	return YES;
}

/*
 * Launch-time recovery for an import that did not finish. Returns YES when an
 * interrupted COPY was thrown away (the UI says so); a finished copy whose
 * move was interrupted is completed instead and reported as NO.
 */
static BOOL OpenQ4_RecoverInterruptedImport(void) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *staging = OpenQ4_ImportStagingDir();
	if (![fm fileExistsAtPath:staging]) {
		return NO;
	}
	if ([fm fileExistsAtPath:[staging stringByAppendingPathComponent:kImportCompleteMarker]]) {
		fprintf(stdout, "openQ4 onboarding: finishing an import whose copy completed but whose move was interrupted\n");
		fflush(stdout);
		OpenQ4_CommitStagedImport(staging);
		return NO;
	}
	unsigned long long bytes = 0;
	int files = 0;
	for (NSString *e in [fm contentsOfDirectoryAtPath:staging error:NULL]) {
		bytes += [fm attributesOfItemAtPath:[staging stringByAppendingPathComponent:e] error:NULL].fileSize;
		files++;
	}
	[fm removeItemAtPath:staging error:NULL];
	fprintf(stdout, "openQ4 onboarding: discarded an INTERRUPTED import (%d partial file(s), %llu bytes); "
			"Documents/q4base was not touched\n", files, bytes);
	fflush(stdout);
	return YES;
}

/*
 * Copy one file in 8 MB chunks, reporting bytes as they land — so the bar moves
 * through a 220 MB pak instead of jumping once per file (the old per-file
 * NSFileManager copy). Returns NO with `*outError` set on any short write.
 */
static BOOL OpenQ4_CopyFileWithProgress(NSString *from, NSString *to,
										void (^progress)(unsigned long long delta),
										NSString **outError) {
	const int in = open(from.fileSystemRepresentation, O_RDONLY);
	if (in < 0) {
		*outError = [NSString stringWithUTF8String:strerror(errno)];
		return NO;
	}
	const int out = open(to.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (out < 0) {
		*outError = [NSString stringWithUTF8String:strerror(errno)];
		close(in);
		return NO;
	}
	const size_t kChunk = 8u << 20;
	char *buf = malloc(kChunk);
	BOOL ok = (buf != NULL);
	if (!ok) {
		*outError = @"out of memory";
	}
	while (ok) {
		const ssize_t n = read(in, buf, kChunk);
		if (n == 0) {
			break;
		}
		if (n < 0) {
			if (errno == EINTR) continue;
			*outError = [NSString stringWithUTF8String:strerror(errno)];
			ok = NO;
			break;
		}
		ssize_t written = 0;
		while (written < n) {
			const ssize_t w = write(out, buf + written, (size_t)(n - written));
			if (w < 0) {
				if (errno == EINTR) continue;
				*outError = [NSString stringWithUTF8String:strerror(errno)];
				ok = NO;
				break;
			}
			written += w;
		}
		if (ok) {
			progress((unsigned long long)n);
		}
	}
	free(buf);
	close(in);
	if (close(out) != 0 && ok) {
		*outError = [NSString stringWithUTF8String:strerror(errno)];
		ok = NO;
	}
	return ok;
}

/*
 * Advisory classification of a candidate q4base directory.
 * Fills out counts and returns a human-readable verdict.
 */
static NSString *OpenQ4_ClassifyQ4Base(NSString *dir, int *outPresent, BOOL *outUsable) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:NULL];
	if (entries == nil) {
		if (outPresent) *outPresent = 0;
		if (outUsable) *outUsable = NO;
		return OpenQ4_L("Folder could not be read.");
	}

	NSMutableSet<NSString *> *lower = [NSMutableSet set];
	for (NSString *e in entries) {
		[lower addObject:e.lowercaseString];
	}

	int present = 0;
	NSMutableArray<NSString *> *missing = [NSMutableArray array];
	for (int i = kRequiredPakFirst; i <= kRequiredPakLast; i++) {
		NSString *name = [NSString stringWithFormat:@"pak%03d.pk4", i];
		if ([lower containsObject:name]) {
			present++;
		} else {
			[missing addObject:name];
		}
	}

	const BOOL hasMappack = [lower containsObject:@"q4cmp_pak001.pk4"];
	int langPacks = 0;
	for (NSString *e in lower) {
		if ([e hasPrefix:@"zpak_"]) langPacks++;
	}

	if (outPresent) *outPresent = present;

	if (present == 0) {
		if (outUsable) *outUsable = NO;
		return OpenQ4_L("No Quake 4 pak files here. Pick the folder that contains "
						"pak001.pk4 … pak022.pk4 (usually called q4base).");
	}
	if (present < (kRequiredPakLast - kRequiredPakFirst + 1)) {
		if (outUsable) *outUsable = NO;
		// Missing the high paks specifically means an unpatched install, which
		// is a different (and fixable) problem from a wrong folder.
		BOOL missingHigh = NO;
		for (NSString *m in missing) {
			if ([m compare:@"pak019.pk4"] != NSOrderedAscending) { missingHigh = YES; break; }
		}
		if (missingHigh && present >= 18) {
			return [NSString stringWithFormat:
					OpenQ4_L("This looks like an unpatched Quake 4 (%d of 22 paks). "
							 "openQ4 needs the 1.4.2 patch — Steam and GOG copies already "
							 "include it. Missing: %@"),
					present, [missing componentsJoinedByString:@", "]];
		}
		return [NSString stringWithFormat:
				OpenQ4_L("Incomplete: %d of 22 required paks. Missing: %@"),
				present, [missing componentsJoinedByString:@", "]];
	}

	if (outUsable) *outUsable = YES;
	/*
	 * Whole sentences, joined — not a stem with fragments appended. " Mission-pack
	 * maps included." and " %d language pack(s)." were not translatable units:
	 * they carried a leading space, assumed they followed something, and fixed an
	 * order a translator may need to change. One key per sentence instead.
	 */
	NSMutableArray<NSString *> *sentences = [NSMutableArray arrayWithObject:
		OpenQ4_L("All 22 required paks found.")];
	if (hasMappack) {
		[sentences addObject:OpenQ4_L("Mission-pack maps included.")];
	}
	if (langPacks > 0) {
		[sentences addObject:[NSString stringWithFormat:
			OpenQ4_L("%d language pack(s)."), langPacks]];
	}
	return [sentences componentsJoinedByString:@" "];
}

/*
 * Is booting worth attempting? All 22 required paks by name (D-112). It used
 * to be "any pak at all", which booted a half-copied or unpatched tree straight
 * into the engine's checksum fatal; now those land on the import screen with
 * the classifier's sentence saying what is wrong. The engine's checksum table
 * (D-005) still renders the final verdict on the CONTENTS.
 *
 * `*outVerdict` is the classifier's sentence when some paks exist but the set
 * is not usable, nil otherwise.
 */
static BOOL OpenQ4_GameDataPresent(NSString **outVerdict) {
	int present = 0;
	BOOL usable = NO;
	*outVerdict = nil;
	NSString *dir = OpenQ4_Q4BaseDir();
	if (![NSFileManager.defaultManager fileExistsAtPath:dir]) {
		return NO;
	}
	NSString *verdict = OpenQ4_ClassifyQ4Base(dir, &present, &usable);
	if (!usable && present > 0) {
		*outVerdict = verdict;
	}
	return usable;
}

/*
 * Run a block on the MAIN RUN LOOP — deliberately NOT on the main dispatch
 * queue (D-092).
 *
 * On visionOS the engine is started from inside a block already running on the
 * main queue (`OpenQ4HostViewController` calls `openq4_engine_main` from a
 * `dispatch_async(dispatch_get_main_queue())`), and this function is called
 * from inside that. The main queue is SERIAL, so every further
 * `dispatch_async(dispatch_get_main_queue(), ...)` issued from here is queued
 * behind a block that has not returned yet and does not run until onboarding is
 * over — which is to say, never, for a screen whose whole job is to update
 * while it is up. That silently killed the copy progress readout and the
 * post-import proceed button on visionOS, and it was invisible on iOS, where
 * SDL's `main` is not a queued block.
 *
 * The run loop is the channel that still works: the blocking loop below pumps
 * NSDefaultRunLoopMode, so a run-loop perform on the main thread is serviced
 * within the same 50 ms slice that already services touches.
 */
static void OpenQ4_OnMainRunLoop(void (^block)(void)) {
	if (NSThread.isMainThread) {
		block();
		return;
	}
	NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:block];
	[op performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO
							  modes:@[ NSDefaultRunLoopMode ]];
}

#pragma mark - Onboarding view controller

@interface OpenQ4OnboardingVC : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *progress;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *chooseButton;
@property (nonatomic, strong) UIButton *recheckButton;
@property (nonatomic, assign) BOOL finished;
// Shown under the intro when the launch found something to explain (D-112):
// a discarded interrupted import, or a q4base that is present but unusable.
@property (nonatomic, copy) NSString *launchNote;
- (void)recheckTapped;
- (void)importFromURL:(NSURL *)sourceURL;
@end

@implementation OpenQ4OnboardingVC

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;

	self.titleLabel = [UILabel new];
	self.titleLabel.text = @"openQ4";
	self.titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
	self.titleLabel.textColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
	self.titleLabel.textAlignment = NSTextAlignmentCenter;

	self.statusLabel = [UILabel new];
	NSString *intro = OpenQ4_L(
		"openQ4 needs your own copy of Quake 4.\n\n"
		"Copy the game's q4base folder into this app's folder using the Files "
		"app, or tap below to choose it directly.\n\n"
		"Quake 4 from Steam or GOG already includes the 1.4.2 patch that openQ4 "
		"requires.");
	self.statusLabel.text = self.launchNote.length > 0
		? [NSString stringWithFormat:@"%@\n\n%@", intro, self.launchNote] : intro;
	self.statusLabel.adjustsFontSizeToFitWidth = YES;
	self.statusLabel.minimumScaleFactor = 0.6;
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.textColor = UIColor.whiteColor;
	self.statusLabel.font = [UIFont systemFontOfSize:16];
	self.statusLabel.textAlignment = NSTextAlignmentCenter;

	self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
	self.progress.hidden = YES;

	/*
	 * The proceed button is its OWN button, hidden until the data checks out —
	 * it is not the folder-picker button wearing a new title (D-092).
	 *
	 * Retitling was the bug the maintainer hit on Vision Pro: a visionOS button that has
	 * already been laid out does not redraw its title for `setTitle:forState:`,
	 * so the proceed button went BLANK and he had to guess which unlabelled slab
	 * to pinch (the measurement is in openq4_ios_compat.h). A button whose title
	 * is set once, at construction, is the case that demonstrably renders on
	 * both platforms — it is what the two buttons below already do — and it also
	 * reads better: "choose a folder" and "start the game" are two different
	 * actions and now look like two, in the accent colour the title uses.
	 */
	self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
	// Font BEFORE the title: the helper bakes titleLabel.font into the
	// visionOS configuration at call time.
	self.startButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
	OpenQ4_iOS_SetButtonTitle(self.startButton, OpenQ4_L("Start openQ4"));
	self.startButton.tintColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
	[self.startButton setTitleColor:self.startButton.tintColor forState:UIControlStateNormal];
	self.startButton.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
	self.startButton.layer.cornerRadius = 12;
	self.startButton.hidden = YES;   // a hidden arranged subview takes no space
	[self.startButton addTarget:self action:@selector(startTapped)
			   forControlEvents:UIControlEventTouchUpInside];

	self.chooseButton = [UIButton buttonWithType:UIButtonTypeSystem];
	// Font BEFORE the title: the helper bakes titleLabel.font into the
	// visionOS configuration at call time.
	self.chooseButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
	OpenQ4_iOS_SetButtonTitle(self.chooseButton, OpenQ4_L("Choose Quake 4 Folder"));
	self.chooseButton.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
	self.chooseButton.layer.cornerRadius = 12;
	[self.chooseButton addTarget:self action:@selector(chooseTapped)
				forControlEvents:UIControlEventTouchUpInside];

	// Files-app users add data behind the app's back. Without this they have to
	// force-quit and relaunch for it to be noticed, which is exactly what
	// happened in testing.
	self.recheckButton = [UIButton buttonWithType:UIButtonTypeSystem];
	// Font BEFORE the title: the helper bakes titleLabel.font into the
	// visionOS configuration at call time.
	self.recheckButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
	OpenQ4_iOS_SetButtonTitle(self.recheckButton, OpenQ4_L("I Added Files — Check Again"));
	self.recheckButton.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
	self.recheckButton.layer.cornerRadius = 12;
	[self.recheckButton addTarget:self action:@selector(recheckTapped)
				 forControlEvents:UIControlEventTouchUpInside];

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
		self.titleLabel, self.statusLabel, self.progress,
		self.startButton, self.chooseButton, self.recheckButton
	]];
	stack.axis = UILayoutConstraintAxisVertical;
	// 24 pt on a tall screen; a landscape phone (~390 pt) cannot afford it.
#if TARGET_OS_VISION
	stack.spacing = 24;   // no UIScreen on visionOS, and the window is tall
#else
	stack.spacing = (MIN(UIScreen.mainScreen.bounds.size.width,
						 UIScreen.mainScreen.bounds.size.height) < 500) ? 12 : 24;
#endif
	stack.alignment = UIStackViewAlignmentFill;
	[self.statusLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
													   forAxis:UILayoutConstraintAxisVertical];
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:stack];

	[NSLayoutConstraint activateConstraints:@[
		[stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
		// A long verdict on a landscape phone (~390 pt tall) must shrink the
		// text, not push the buttons off the screen (D-112).
		[stack.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
		[stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
		[stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:48],
		[stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-48],
		[self.startButton.heightAnchor constraintEqualToConstant:58],
		[self.chooseButton.heightAnchor constraintEqualToConstant:54],
		[self.recheckButton.heightAnchor constraintEqualToConstant:48],
	]];
}

/*
 * The data checks out: reveal the proceed button (and hand the picker button
 * back, in case this came after a failed import).
 */
- (void)revealStartButton {
	self.startButton.hidden = NO;
	self.chooseButton.enabled = YES;
}

- (void)chooseTapped {
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc]
			initForOpeningContentTypes:@[ UTTypeFolder ]];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)setStatus:(NSString *)text {
	OpenQ4_OnMainRunLoop(^{
		self.statusLabel.text = text;
	});
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSURL *picked = urls.firstObject;
	if (picked == nil) {
		return;
	}
	fprintf(stdout, "openQ4 onboarding: document picker returned '%s'\n", picked.path.UTF8String);
	fflush(stdout);
	self.chooseButton.enabled = NO;
	self.recheckButton.enabled = NO;
	self.progress.hidden = NO;
	[self importFromURL:picked];
}

/*
 * Copy the picked tree into Documents/q4base, through a staging dir (D-112).
 *
 * Runs off the main thread: a retail q4base is ~2.6 GB and copying it on the
 * main thread would both freeze the UI and trip the watchdog.
 *
 * Order matters and is the point of the D-112 rewrite:
 *   1. find q4base (the pick itself, or a child of it in ANY casing);
 *   2. classify the SOURCE first — an unpatched or wrong folder is explained
 *      in a second, instead of after copying 2.6 GB;
 *   3. check free space;
 *   4. copy, in chunks, into the staging dir, lowercasing names;
 *   5. verify every size, write the completion marker, move into q4base.
 */
- (void)importFromURL:(NSURL *)sourceURL {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		@autoreleasepool {
			const BOOL scoped = [sourceURL startAccessingSecurityScopedResource];
			NSFileManager *fm = NSFileManager.defaultManager;
			void (^giveUp)(NSString *) = ^(NSString *message) {
				[self setStatus:message];
				OpenQ4_OnMainRunLoop(^{
					self.chooseButton.enabled = YES;
					self.recheckButton.enabled = YES;
					self.progress.hidden = YES;
				});
				if (scoped) [sourceURL stopAccessingSecurityScopedResource];
			};

			// The user may pick either q4base itself or the install root that
			// contains it — in whatever casing a Windows copy arrived with.
			NSString *src = sourceURL.path;
			if ([src.lastPathComponent caseInsensitiveCompare:@"q4base"] != NSOrderedSame) {
				NSString *inner = OpenQ4_ChildIgnoringCase(src, @"q4base");
				if (inner != nil) {
					src = inner;
				}
			}
			fprintf(stdout, "openQ4 onboarding: import picked '%s' (scoped=%d), source '%s'\n",
					sourceURL.path.UTF8String, scoped ? 1 : 0, src.UTF8String);
			fflush(stdout);

			// Picking the q4base that is ALREADY in this app's folder (Files
			// shows it under On My iPhone > openQ4) must not copy a tree onto
			// itself — the old copy deleted each destination pak before
			// copying it, i.e. deleted the source. Treat it as "check again".
			NSString *srcReal = src.stringByResolvingSymlinksInPath.stringByStandardizingPath;
			NSString *ownReal = OpenQ4_Q4BaseDir().stringByResolvingSymlinksInPath.stringByStandardizingPath;
			if ([srcReal caseInsensitiveCompare:ownReal] == NSOrderedSame) {
				if (scoped) [sourceURL stopAccessingSecurityScopedResource];
				fprintf(stdout, "openQ4 onboarding: picked our own q4base — checking it in place\n");
				fflush(stdout);
				OpenQ4_OnMainRunLoop(^{
					self.progress.hidden = YES;
					self.chooseButton.enabled = YES;
					self.recheckButton.enabled = YES;
					[self recheckTapped];
				});
				return;
			}

			NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:src error:NULL];
			if (entries == nil) {
				giveUp(OpenQ4_L("Folder could not be read."));
				return;
			}
			NSMutableArray<NSString *> *paks = [NSMutableArray array];
			unsigned long long totalBytes = 0;
			for (NSString *e in entries) {
				if (![e.pathExtension.lowercaseString isEqualToString:@"pk4"]) {
					continue;
				}
				// The engine ships its own game modules and ignores retail
				// game*.pk4 entirely, so copying them wastes hundreds of MB.
				if ([e.lowercaseString hasPrefix:@"game"]) {
					continue;
				}
				[paks addObject:e];
				totalBytes += [fm attributesOfItemAtPath:[src stringByAppendingPathComponent:e]
												   error:NULL].fileSize;
			}

			if (paks.count == 0) {
				giveUp(OpenQ4_L("That folder has no .pk4 files. Choose the folder "
								"containing pak001.pk4 … pak022.pk4 (usually q4base)."));
				return;
			}

			// Every pak is stored lowercase, so two source names that differ
			// only in case (pak001.pk4 + PAK001.PK4 from a merged Windows copy)
			// would land on ONE file and the second would silently replace the
			// first. Refuse, naming both, before anything is copied.
			NSMutableDictionary<NSString *, NSString *> *byLower = [NSMutableDictionary dictionary];
			for (NSString *e in paks) {
				NSString *other = byLower[e.lowercaseString];
				if (other != nil) {
					fprintf(stdout, "openQ4 onboarding: source refused: '%s' and '%s' differ only in case\n",
							other.UTF8String, e.UTF8String);
					fflush(stdout);
					giveUp([NSString stringWithFormat:
						OpenQ4_L("Two files in that folder differ only in capital letters: %@ and %@. "
								 "Keep one of them and choose the folder again."), other, e]);
					return;
				}
				byLower[e.lowercaseString] = e;
			}

			int present = 0;
			BOOL usable = NO;
			NSString *verdict = OpenQ4_ClassifyQ4Base(src, &present, &usable);
			if (!usable) {
				fprintf(stdout, "openQ4 onboarding: source refused before copying (%d of 22 paks): %s\n",
						present, verdict.UTF8String);
				fflush(stdout);
				giveUp(verdict);
				return;
			}

			NSNumber *freeBytes = nil;
			[[NSURL fileURLWithPath:OpenQ4_DocumentsDir()]
				getResourceValue:&freeBytes forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:NULL];
			const unsigned long long margin = 256ull << 20;
			if (freeBytes != nil && freeBytes.unsignedLongLongValue < totalBytes + margin) {
				giveUp([NSString stringWithFormat:
					OpenQ4_L("Not enough free space. Importing needs %.1f GB and this device has %.1f GB free."),
					(totalBytes + margin) / 1073741824.0, freeBytes.unsignedLongLongValue / 1073741824.0]);
				return;
			}

			NSString *staging = OpenQ4_ImportStagingDir();
			[fm removeItemAtPath:staging error:NULL];
			if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:NULL]) {
				giveUp([NSString stringWithFormat:OpenQ4_L("Copy failed on %@:\n%@"),
						@"q4base", @"could not create the import folder"]);
				return;
			}
			fprintf(stdout, "openQ4 onboarding: copying %d pak(s), %llu bytes, into staging\n",
					(int)paks.count, totalBytes);
			fflush(stdout);

			__block unsigned long long copied = 0;
			__block CFAbsoluteTime lastUpdate = 0;
			int renamed = 0;
			for (NSString *e in paks) {
				@autoreleasepool {
					NSString *from = [src stringByAppendingPathComponent:e];
					// Lowercase on import: the container filesystem is
					// case-sensitive and the engine opens lowercase names.
					NSString *lower = e.lowercaseString;
					if (![lower isEqualToString:e]) {
						renamed++;
						fprintf(stdout, "openQ4 onboarding: lowercasing '%s' -> '%s'\n",
								e.UTF8String, lower.UTF8String);
					}
					NSString *to = [staging stringByAppendingPathComponent:lower];
					NSString *copyError = nil;
					const BOOL ok = OpenQ4_CopyFileWithProgress(from, to, ^(unsigned long long delta) {
						copied += delta;
						const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
						if (now - lastUpdate < 0.1 && copied < totalBytes) {
							return;
						}
						lastUpdate = now;
						const unsigned long long c = copied;
						const double frac = totalBytes ? (double)c / (double)totalBytes : 1.0;
						OpenQ4_OnMainRunLoop(^{
							self.progress.progress = (float)frac;
							self.statusLabel.text = [NSString stringWithFormat:
								OpenQ4_L("Copying %@\n%.1f of %.1f GB"),
								lower, c / 1073741824.0, totalBytes / 1073741824.0];
						});
					}, &copyError);
					const unsigned long long want = [fm attributesOfItemAtPath:from error:NULL].fileSize;
					const unsigned long long got = [fm attributesOfItemAtPath:to error:NULL].fileSize;
					if (!ok || want != got) {
						fprintf(stderr, "openQ4 onboarding: copy FAILED on %s (%llu of %llu bytes): %s\n",
								e.UTF8String, got, want, copyError.UTF8String ?: "size mismatch");
						fflush(stderr);
						[fm removeItemAtPath:staging error:NULL];
						giveUp([NSString stringWithFormat:OpenQ4_L("Copy failed on %@:\n%@"),
								e, copyError ?: @"size mismatch"]);
						return;
					}
				}
			}
			if (scoped) [sourceURL stopAccessingSecurityScopedResource];

			// Every byte is there and every size matched: only now does the
			// copy count as complete, and only now does q4base change.
			[@"" writeToFile:[staging stringByAppendingPathComponent:kImportCompleteMarker]
				  atomically:YES encoding:NSUTF8StringEncoding error:NULL];
#if !defined(OPENQ4_PUBLIC_BUILD)
			if (getenv("OPENQ4_ONBOARDING_STOP_BEFORE_COMMIT") != NULL) {
				// Test lever for the "copied, not yet moved" recovery path.
				// Not compiled into public builds (D-113).
				fprintf(stdout, "openQ4 onboarding: OPENQ4_ONBOARDING_STOP_BEFORE_COMMIT — exiting with a complete staged copy\n");
				fflush(stdout);
				_exit(0);
			}
#endif
			const BOOL committed = OpenQ4_CommitStagedImport(staging);

			present = 0;
			usable = NO;
			verdict = OpenQ4_ClassifyQ4Base(OpenQ4_Q4BaseDir(), &present, &usable);
			if (!committed) {
				usable = NO;
				verdict = [NSString stringWithFormat:OpenQ4_L("Copy failed on %@:\n%@"),
						   @"q4base", @"could not move the copied files into place"];
			}
			if (renamed > 0) {
				verdict = [verdict stringByAppendingFormat:@"\n\n%@",
					[NSString stringWithFormat:
						OpenQ4_L("(%d file name(s) lowercased for this device.)"), renamed]];
			}
			fprintf(stdout, "openQ4 onboarding: imported %d pak(s), %llu bytes, %d renamed — %s\n",
					(int)paks.count, copied, renamed, verdict.UTF8String);
			fflush(stdout);

			[self setStatus:verdict];
			OpenQ4_OnMainRunLoop(^{
				self.progress.hidden = YES;
				self.chooseButton.enabled = YES;
				self.recheckButton.enabled = YES;
				if (usable) {
					[self revealStartButton];
				}
			});
		}
	});
}

/*
 * Re-scan Documents for data the user added out-of-band (Files app, AirDrop,
 * iTunes sharing). Also accepts q4mp alongside q4base, since a full retail copy
 * has both and people naturally drag the whole thing across.
 */
- (void)recheckTapped {
	const int renamed = OpenQ4_NormalizeQ4BaseInDocuments();

	int present = 0;
	BOOL usable = NO;
	NSString *verdict = nil;
	if (![NSFileManager.defaultManager fileExistsAtPath:OpenQ4_Q4BaseDir()]) {
		// Nothing dropped in yet. The classifier would say "Folder could not
		// be read." here, which reads like a permissions error to a player who
		// simply has not copied anything yet (D-112, seen in the sim run).
		verdict = OpenQ4_L("There is no q4base folder in the openQ4 folder yet.");
	} else {
		verdict = OpenQ4_ClassifyQ4Base(OpenQ4_Q4BaseDir(), &present, &usable);
	}
	if (renamed > 0) {
		verdict = [verdict stringByAppendingFormat:@"\n\n%@",
			[NSString stringWithFormat:
				OpenQ4_L("(%d file name(s) lowercased for this device.)"), renamed]];
	}
	if (present == 0) {
		verdict = [verdict stringByAppendingFormat:@"\n\n%@",
			OpenQ4_L("Put the q4base folder directly inside the openQ4 folder in Files.")];
	}
	fprintf(stdout, "openQ4 onboarding: recheck — %d pak(s), %d renamed, usable=%d\n",
			present, renamed, usable ? 1 : 0);
	fflush(stdout);

	self.statusLabel.text = verdict;
	if (usable) {
		[self revealStartButton];
	}
}

- (void)startTapped {
	self.finished = YES;
}

@end

#pragma mark - Entry point

void OpenQ4_iOS_EnsureGameData(void) {
	@autoreleasepool {
		/*
		 * Mod folders are normalised on EVERY launch, before the "is there any
		 * game data" question is even asked. A mod arrives through Files.app
		 * long after the import that this function exists for, so gating it on
		 * the import path would mean it never ran for the case it is for. It
		 * touches only directories carrying a mod.json, and never deletes.
		 */
		OpenQ4_iOS_NormalizeModFolders();

		// D-112: finish or discard an import a previous launch did not
		// complete, and fix the casing of a q4base dropped in through Files,
		// BEFORE asking whether there is game data.
		const BOOL discardedImport = OpenQ4_RecoverInterruptedImport();
		OpenQ4_NormalizeQ4BaseInDocuments();

		NSString *partialVerdict = nil;
		if (OpenQ4_GameDataPresent(&partialVerdict)) {
			fprintf(stdout, "openQ4 onboarding: game data present, skipping import UI\n");
			fflush(stdout);
			return;
		}
		fprintf(stdout, "openQ4 onboarding: no usable game data%s%s — presenting import UI\n",
				partialVerdict ? " (q4base present but incomplete: " : "",
				partialVerdict ? [partialVerdict stringByAppendingString:@")"].UTF8String : "");
		fflush(stdout);

		__block OpenQ4OnboardingVC *vc = nil;
		UIWindow *window = nil;
		for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
			if ([scene isKindOfClass:UIWindowScene.class]) {
				window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
				break;
			}
		}
		if (window == nil) {
			// No scene yet means UIKit has not finished launching; without a
			// window there is nothing to present on, so let the engine proceed
			// and fail with its own message rather than hanging here.
			fprintf(stderr, "openQ4 onboarding: no window scene available; skipping UI\n");
			return;
		}

		vc = [OpenQ4OnboardingVC new];
		if (discardedImport) {
			vc.launchNote = OpenQ4_L("The last import was interrupted before it finished, so none of it "
									 "was kept. Choose the folder again.");
		} else if (partialVerdict != nil) {
			vc.launchNote = partialVerdict;
		}
		window.rootViewController = vc;
		window.windowLevel = UIWindowLevelNormal + 1;
		[window makeKeyAndVisible];

#if !defined(OPENQ4_PUBLIC_BUILD)
		// Both development hooks below are absent from public builds (D-113).
		/*
		 * Development hook, env-gated exactly like OPENQ4_CONSOLE_BRIDGE: the
		 * simulator cannot be tapped, and the onboarding screen runs BEFORE
		 * common->Init(), so the console bridge that drives every other shell
		 * gesture does not exist yet. `OPENQ4_ONBOARDING_AUTOCHECK=<seconds>`
		 * fires the recheck button once, which is the whole path a player takes
		 * after dropping q4base in with Files. Never set on a shipped build —
		 * there is no environment to set it from.
		 */
		const char *autocheck = getenv("OPENQ4_ONBOARDING_AUTOCHECK");
		if (autocheck != NULL && atof(autocheck) > 0.0) {
			const double delay = atof(autocheck);
			fprintf(stdout, "openQ4 onboarding: OPENQ4_ONBOARDING_AUTOCHECK=%g\n", delay);
			fflush(stdout);
			// An NSTimer on THIS run loop, for the reason OpenQ4_OnMainRunLoop
			// exists: a main-queue dispatch would not run until the blocking
			// loop below is over, which is after the thing it is meant to test.
			[NSTimer scheduledTimerWithTimeInterval:delay repeats:NO
											  block:^(NSTimer *t) { (void)t; [vc recheckTapped]; }];
		}

		/*
		 * Second development hook, same gate: `OPENQ4_ONBOARDING_IMPORT=<dir>`
		 * hands a folder URL to -importFromURL:, the method the document
		 * picker's delegate calls, after a short delay. It proves everything
		 * from the pick onward (classifier, copy, staging, commit) but NOT the
		 * picker's own UI or its security scope — the D-112 record says which
		 * runs used which.
		 */
		const char *importDir = getenv("OPENQ4_ONBOARDING_IMPORT");
		if (importDir != NULL && importDir[0] != '\0') {
			NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:importDir] isDirectory:YES];
			fprintf(stdout, "openQ4 onboarding: OPENQ4_ONBOARDING_IMPORT=%s\n", importDir);
			fflush(stdout);
			[NSTimer scheduledTimerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *t) {
				(void)t;
				vc.chooseButton.enabled = NO;
				vc.recheckButton.enabled = NO;
				vc.progress.hidden = NO;
				[vc importFromURL:url];
			}];
		}

#endif /* !OPENQ4_PUBLIC_BUILD */

		// Block the engine's boot while keeping UIKit alive. The run loop must
		// keep spinning or the picker never appears and the watchdog kills us.
		while (!vc.finished) {
			@autoreleasepool {
				[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
									   beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
			}
		}

		window.hidden = YES;
		fprintf(stdout, "openQ4 onboarding: import complete, continuing boot\n");
		fflush(stdout);
	}
}


#pragma mark - Boot overlay

static UIWindow *g_bootWindow = nil;
static UILabel  *g_bootLabel = nil;

void OpenQ4_iOS_ShowBootOverlay(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		if (g_bootWindow != nil) {
			g_bootWindow.hidden = NO;
			return;
		}
		UIWindowScene *scene = nil;
		for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
			if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
		}
		if (scene == nil) {
			return;
		}
		g_bootWindow = [[UIWindow alloc] initWithWindowScene:scene];
		UIViewController *vc = [UIViewController new];
		vc.view.backgroundColor = UIColor.blackColor;

		UILabel *title = [UILabel new];
		title.text = @"openQ4";
		title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
		title.textColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
		title.textAlignment = NSTextAlignmentCenter;

		g_bootLabel = [UILabel new];
		// Two lines: the fixed caption plus whatever asset is loading right now.
		g_bootLabel.numberOfLines = 2;
		g_bootLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
		g_bootLabel.text = OpenQ4_L("Starting...");
		g_bootLabel.font = [UIFont systemFontOfSize:16];
		g_bootLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
		g_bootLabel.textAlignment = NSTextAlignmentCenter;
		g_bootLabel.numberOfLines = 0;

		UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
			initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
		spinner.color = UIColor.whiteColor;
		[spinner startAnimating];

		UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
			title, g_bootLabel, spinner ]];
		stack.axis = UILayoutConstraintAxisVertical;
		stack.spacing = 18;
		stack.alignment = UIStackViewAlignmentCenter;
		stack.translatesAutoresizingMaskIntoConstraints = NO;
		[vc.view addSubview:stack];
		[NSLayoutConstraint activateConstraints:@[
			[stack.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
			[stack.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
			[stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:vc.view.leadingAnchor constant:40],
		]];

		g_bootWindow.rootViewController = vc;
		g_bootWindow.windowLevel = UIWindowLevelNormal + 2;
		[g_bootWindow makeKeyAndVisible];

#if !TARGET_OS_VISION
		/*
		 * D-104 / Q-036 — the landscape gate, and the last moment it can run.
		 *
		 * common->Init() is driven from the first display-link tick and blocks
		 * the MAIN thread for fifteen to twenty seconds, servicing the run loop
		 * only in short slices. UIKit cannot finish rotating a scene while that
		 * is true. So on a launch that starts portrait — a cold simulator, a
		 * phone held upright — the renderer creates its SDL window against the
		 * still-portrait geometry, the front end latches a 1320x2868 screen,
		 * and the rotation lands only once init returns: too late, because
		 * nothing re-sizes glConfig afterwards. The photograph of that is
		 * Q-036, a portrait image in the left third of a landscape screen.
		 *
		 * This function is already called on the main thread immediately before
		 * the frame loop starts (overlay patch 0002), which makes it the one
		 * place the shell can insist on the orientation while the run loop is
		 * still free. Ask for landscape, then pump the run loop until UIKit has
		 * applied it. Bounded, once per process, and skipped entirely when the
		 * window is already landscape — which is every warm launch.
		 */
		if (@available(iOS 16.0, *)) {
			UIWindowSceneGeometryPreferencesIOS *prefs =
				[[UIWindowSceneGeometryPreferencesIOS alloc]
					initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
			[scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *err) {
				fprintf(stderr, "openQ4 boot: landscape geometry request refused: %s\n",
						err.localizedDescription.UTF8String);
				fflush(stderr);
			}];
		}
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
		int turns = 0;
		while (g_bootWindow.bounds.size.width <= g_bootWindow.bounds.size.height &&
				deadline.timeIntervalSinceNow > 0.0) {
			[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
								   beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
			turns++;
		}
		const CGSize gated = g_bootWindow.bounds.size;
		fprintf(stdout, "openQ4 boot: landscape gate %s after %d run-loop turn(s) (window %.0fx%.0f)\n",
				(gated.width > gated.height) ? "passed" : "TIMED OUT",
				turns, gated.width, gated.height);
		fflush(stdout);
#endif
	});
}

void OpenQ4_iOS_SetBootStatus(const char *text) {
	if (text == NULL) {
		dispatch_async(dispatch_get_main_queue(), ^{
			// Hidden, never released. Creating a UIWindow and calling
			// makeKeyAndVisible is a scene-level round trip with the render
			// server; doing that mid-map-load — from inside a blocked engine
			// that can only service the run loop in 2 ms slices — starts a
			// negotiation the app cannot finish, and FrontBoard's scene-update
			// watchdog kills for it at 10.00 seconds. Build it once while the
			// main thread is free, then only ever hide and unhide.
			g_bootWindow.hidden = YES;
		});
		return;
	}
	NSString *s = [NSString stringWithUTF8String:text];
	dispatch_async(dispatch_get_main_queue(), ^{
		g_bootLabel.text = s;
	});
}

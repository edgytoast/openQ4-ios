/*
 * openq4_ios_mvkenv.m — apply Documents/mvk.env before MoltenVK reads anything.
 *
 * Why a constructor and not ordinary init code: MoltenVK caches each
 * MVK_CONFIG_* knob the first time it is asked for, and the earliest of those
 * happens inside vkCreateInstance. By the time the engine has a cvar system
 * there is nothing left to configure. __attribute__((constructor)) runs before
 * main(), which is comfortably before any Vulkan entry point.
 *
 * Deliberately paranoid about what it will set: only keys beginning with
 * MVK_CONFIG_ or ALSOFT_, at most 64 of them, and only from a file the user (or
 * the bridge) put in this app's own Documents directory. Nothing is shipped in
 * that file — absence is the shipping configuration.
 *
 * openal-soft reads ALSOFT_* the same way and just as early (its logging level
 * is latched when the library first initialises), so the same constructor is
 * the right place for it — see D-067.
 */

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "openq4_ios_mvkenv.h"

#define MVKENV_MAX_LINES   64

/*
 * Two accepted prefixes. MVK_CONFIG_ is MoltenVK's own knob namespace; ALSOFT_
 * is openal-soft's (ALSOFT_LOGLEVEL above all — its trace is the only way to
 * see inside the audio device on a device we cannot attach a debugger to).
 * Both are read the same way, from the environment, at library init, which is
 * exactly what a pre-main constructor can still influence.
 */
static const char *const kMvkEnvKeyPrefixes[] = { "MVK_CONFIG_", "ALSOFT_" };

static int MvkEnvKeyAllowed(const char *key) {
	if (key == NULL) {
		return 0;
	}
	for (size_t i = 0; i < sizeof(kMvkEnvKeyPrefixes) / sizeof(kMvkEnvKeyPrefixes[0]); i++) {
		const char *prefix = kMvkEnvKeyPrefixes[i];
		if (strncmp(key, prefix, strlen(prefix)) == 0) {
			return 1;
		}
	}
	return 0;
}

static char g_applied[2048];

static NSString *MvkEnvPath(void) {
	NSArray<NSString *> *dirs =
		NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	if (dirs.count == 0) {
		return nil;
	}
	return [dirs[0] stringByAppendingPathComponent:@"mvk.env"];
}

/*
 * Read the file with stdio rather than Foundation. A constructor runs before
 * UIApplicationMain, and while NSSearchPathForDirectoriesInDomains is fine
 * there, keeping the parse itself in C avoids any question about autorelease
 * pools this early.
 */
__attribute__((constructor))
static void OpenQ4_iOS_MvkEnvApply(void) {
	@autoreleasepool {
		NSString *path = MvkEnvPath();
		if (path == nil) {
			snprintf(g_applied, sizeof(g_applied), "(no Documents directory)");
			return;
		}
		FILE *f = fopen(path.fileSystemRepresentation, "r");
		if (f == NULL) {
			snprintf(g_applied, sizeof(g_applied), "(no mvk.env; MoltenVK defaults)");
			return;
		}

		int applied = 0;
		size_t used = 0;
		char line[512];
		for (int n = 0; n < MVKENV_MAX_LINES && fgets(line, sizeof(line), f) != NULL; n++) {
			// strip trailing newline / whitespace
			size_t len = strlen(line);
			while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'
							   || line[len - 1] == ' ' || line[len - 1] == '\t')) {
				line[--len] = '\0';
			}
			if (len == 0 || line[0] == '#') {
				continue;
			}
			char *eq = strchr(line, '=');
			if (eq == NULL) {
				continue;
			}
			*eq = '\0';
			const char *key = line;
			const char *value = eq + 1;
			if (!MvkEnvKeyAllowed(key)) {
				continue;   // not ours; ignore rather than trust
			}
			setenv(key, value, 1);
			applied++;
			const int written = snprintf(g_applied + used, sizeof(g_applied) - used,
										 "%s%s=%s", (used > 0) ? " " : "", key, value);
			if (written > 0 && (size_t)written < sizeof(g_applied) - used) {
				used += (size_t)written;
			}
		}
		fclose(f);
		if (applied == 0) {
			snprintf(g_applied, sizeof(g_applied), "(mvk.env present but empty; MoltenVK defaults)");
		}
	}
}

const char *OpenQ4_iOS_MvkEnvApplied(void) {
	return (g_applied[0] != '\0') ? g_applied : "(not yet evaluated)";
}

void OpenQ4_iOS_MvkEnvReport(void) {
	NSString *path = MvkEnvPath();
	fprintf(stdout, "openQ4 mvkenv: applied this process: %s\n", OpenQ4_iOS_MvkEnvApplied());
	if (path == nil) {
		fflush(stdout);
		return;
	}
	fprintf(stdout, "openQ4 mvkenv: file %s\n", path.UTF8String);
	NSError *err = nil;
	NSString *body = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
	if (body == nil) {
		fprintf(stdout, "openQ4 mvkenv:   (no file — MoltenVK defaults on next launch)\n");
	} else if (body.length == 0) {
		fprintf(stdout, "openQ4 mvkenv:   (empty)\n");
	} else {
		for (NSString *l in [body componentsSeparatedByString:@"\n"]) {
			if (l.length > 0) {
				fprintf(stdout, "openQ4 mvkenv:   %s\n", l.UTF8String);
			}
		}
	}
	fflush(stdout);
}

int OpenQ4_iOS_MvkEnvSet(const char *key, const char *value) {
	if (key == NULL || value == NULL || !MvkEnvKeyAllowed(key)) {
		return -1;
	}
	NSString *path = MvkEnvPath();
	if (path == nil) {
		return -1;
	}
	NSString *nsKey = [NSString stringWithUTF8String:key];
	NSString *nsValue = [NSString stringWithUTF8String:value];
	if (nsKey == nil || nsValue == nil) {
		return -1;
	}

	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	NSString *body = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
	if (body != nil) {
		for (NSString *l in [body componentsSeparatedByString:@"\n"]) {
			if (l.length == 0) {
				continue;
			}
			// replace, never duplicate: two lines for one key is a silent A/B lie
			if ([l hasPrefix:[nsKey stringByAppendingString:@"="]]) {
				continue;
			}
			[lines addObject:l];
		}
	}
	[lines addObject:[NSString stringWithFormat:@"%@=%@", nsKey, nsValue]];

	NSString *out = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
	NSError *err = nil;
	if (![out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
		fprintf(stdout, "openQ4 mvkenv: write failed: %s\n", err.localizedDescription.UTF8String);
		fflush(stdout);
		return -1;
	}
	return 0;
}

void OpenQ4_iOS_MvkEnvClear(void) {
	NSString *path = MvkEnvPath();
	if (path == nil) {
		return;
	}
	[NSFileManager.defaultManager removeItemAtPath:path error:NULL];
}

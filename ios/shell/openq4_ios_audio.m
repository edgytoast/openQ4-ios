/*
 * openq4_ios_audio.m — AVAudioSession configuration.
 *
 * Nothing in this port had ever set a session category, which is why the menu
 * was silent: the default category is silenced by the ring/silent switch, so a
 * phone with the switch flipped plays nothing and reports no error anywhere.
 *
 * Category is Playback in every mode — that is what lets a game keep playing
 * with the switch off. The OPTIONS are what decide what happens to everybody
 * else's audio, and only the mode the player picked may decide them: ducking is
 * a property of OUR ACTIVE SESSION, not of our output gain, so silencing the
 * game does nothing at all to a ducked podcast (D-087).
 *
 * Per ~/dev/IOS-AUDIO-SESSION-GUIDE.md, which this follows:
 *
 *  - The session must be RE-ASSERTED. Route changes, interruptions and audio
 *    device re-opens all put the category back, so setting it once at boot and
 *    walking away does not hold. Notifications cover most of it and a cheap
 *    4 Hz poll heals what they miss.
 *  - It must be set BEFORE the sound system opens its device. Activation is
 *    what interrupts other apps, and setActive:YES on an already-active session
 *    is a no-op — so configuring afterwards is too late for that launch.
 *
 * openQ4 uses openal-soft rather than SDL's audio backend, so SDL's own session
 * meddling (TRAP 1 in the guide) does not apply here — but openal-soft does not
 * set a category either, which is the whole problem.
 */

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdio.h>

#include "openq4_ios_audio.h"
#include "openq4_ios_settings.h"

float openQ4_iOSDuckGain(void);            /* engine-facing; defined below */
float OpenQ4_iOS_AudioGainTarget(void);    /* diagnostics only */

/* Player-facing name of a mode, for the log and for !audiosession. */
static const char *OpenQ4_AudioModeName(int mode) {
	switch (mode) {
		case 0: return "Lower Other Audio";
		case 1: return "Play Both";
		case 2: return "Stop Other Audio";
		case 3: return "Lower Game Audio";
		case 4: return "Mute Game Audio";
		default: return "?";
	}
}

/*
 * Which session options each mode wants.
 *
 * EXHAUSTIVE, and that is the whole of D-087: this switch used to carry cases
 * 0, 1 and 2 with `default:` returning MixWithOthers|DuckOthers, so the two
 * modes that exist precisely to leave other audio alone — "Lower Game Audio"
 * and "Mute Game Audio", which attenuate OUR mix (D-043) — fell into the
 * default and ducked the player's podcast the whole time. Muting ourselves
 * cannot undo that: iOS ducks on behalf of the active session's options.
 *
 * An unknown index now never ducks and says so, rather than silently inheriting
 * the one behaviour a new mode is least likely to want.
 */
static AVAudioSessionCategoryOptions OpenQ4_DesiredOptions(void) {
	// Index order matches OpenQ4_AudioModeTitles() in the settings sheet.
	const int mode = OpenQ4_iOS_AudioModeIndex();
	switch (mode) {
		case 0:  // Lower Other Audio — iOS ducks THEM for us
			return AVAudioSessionCategoryOptionMixWithOthers |
				   AVAudioSessionCategoryOptionDuckOthers;
		case 1:  // Play Both
			return AVAudioSessionCategoryOptionMixWithOthers;
		case 2:  // Stop Other Audio — non-mixable; activation interrupts them
			return 0;
		case 3:  // Lower Game Audio  — our gain drops; theirs is untouched
		case 4:  // Mute Game Audio   — our gain hits zero; theirs is untouched
			return AVAudioSessionCategoryOptionMixWithOthers;
		default: {
			static int warned = -1;
			if (warned != mode) {
				warned = mode;
				fprintf(stderr, "openQ4 audio: unknown audioMode %d; mixing without ducking\n", mode);
			}
			return AVAudioSessionCategoryOptionMixWithOthers;
		}
	}
}

/* Decode the option bits we care about, for a log line a human can read. */
static NSString *OpenQ4_DescribeOptions(AVAudioSessionCategoryOptions o) {
	NSMutableArray<NSString *> *bits = [NSMutableArray array];
	if (o & AVAudioSessionCategoryOptionMixWithOthers)  { [bits addObject:@"MixWithOthers"]; }
	if (o & AVAudioSessionCategoryOptionDuckOthers)     { [bits addObject:@"DuckOthers"]; }
	if (o & AVAudioSessionCategoryOptionAllowBluetoothA2DP) { [bits addObject:@"AllowBluetoothA2DP"]; }
	if (o & AVAudioSessionCategoryOptionAllowAirPlay)   { [bits addObject:@"AllowAirPlay"]; }
	if (o & AVAudioSessionCategoryOptionDefaultToSpeaker) { [bits addObject:@"DefaultToSpeaker"]; }
	if (bits.count == 0) { [bits addObject:@"none"]; }
	return [bits componentsJoinedByString:@"|"];
}

/* Our own record of activation: AVAudioSession has no isActive to read back. */
static BOOL g_sessionActive = NO;

/* Set once AudioSessionInit has run; before that there is nothing to refresh. */
static BOOL g_watcherReady = NO;

static void OpenQ4_ApplySession(BOOL logIt) {
	AVAudioSession *session = AVAudioSession.sharedInstance;
	const AVAudioSessionCategoryOptions want = OpenQ4_DesiredOptions();
	const AVAudioSessionCategoryOptions had = session.categoryOptions;

	const BOOL categoryOK = [session.category isEqualToString:AVAudioSessionCategoryPlayback];
	const BOOL optionsOK  = (had == want);

	if (logIt) {
		// Report unconditionally on the first call, including the case where
		// nothing needed changing. "No line in the log" is otherwise ambiguous
		// between "already correct" and "this never ran", and that ambiguity
		// has cost real time on this port already.
		fprintf(stdout, "openQ4 audio: found category '%s' options 0x%lx (%s); want Playback options 0x%lx (%s)%s\n",
				session.category.UTF8String ?: "?",
				(unsigned long)had, OpenQ4_DescribeOptions(had).UTF8String,
				(unsigned long)want, OpenQ4_DescribeOptions(want).UTF8String,
				(categoryOK && optionsOK) ? " (already correct)" : "");
		fflush(stdout);
	}

	if (categoryOK && optionsOK && g_sessionActive) {
		return;
	}

	// Every transition is logged, not just the first one: the 4 Hz poll means a
	// mode change applies without anything else happening, and "which options
	// were live when the podcast ducked" is the only question that matters here.
	const int mode = OpenQ4_iOS_AudioModeIndex();
	fprintf(stdout, "openQ4 audio: transition -> mode %d (%s): category '%s' options 0x%lx (%s) => Playback 0x%lx (%s)\n",
			mode, OpenQ4_AudioModeName(mode),
			session.category.UTF8String ?: "?",
			(unsigned long)had, OpenQ4_DescribeOptions(had).UTF8String,
			(unsigned long)want, OpenQ4_DescribeOptions(want).UTF8String);
	fflush(stdout);

	NSError *err = nil;
	if (![session setCategory:AVAudioSessionCategoryPlayback
					  mode:AVAudioSessionModeDefault
				   options:want
					 error:&err]) {
		fprintf(stderr, "openQ4 audio: setCategory failed: %s\n",
				err.localizedDescription.UTF8String ?: "?");
		return;
	}
	if (![session setActive:YES error:&err]) {
		fprintf(stderr, "openQ4 audio: setActive failed: %s\n",
				err.localizedDescription.UTF8String ?: "?");
		return;
	}
	g_sessionActive = YES;

	// Dropping DuckOthers while the session stays active restores the other
	// app's volume on its own — but tell the system explicitly anyway, because
	// the one report that brought us here was "the podcast never came back up".
	if ((had & AVAudioSessionCategoryOptionDuckOthers) != 0 &&
		(want & AVAudioSessionCategoryOptionDuckOthers) == 0) {
		fprintf(stdout, "openQ4 audio: DuckOthers dropped; other audio should return to full volume\n");
		fflush(stdout);
	}

	fprintf(stdout, "openQ4 audio: session = Playback, options = 0x%lx (%s), active = yes\n",
			(unsigned long)want, OpenQ4_DescribeOptions(want).UTF8String);
	fflush(stdout);
}

void OpenQ4_iOS_AudioSessionRefresh(void) {
	if (g_watcherReady) {
		OpenQ4_ApplySession(YES);
		OpenQ4_iOS_UpdateDuckGain();
	}
}

void OpenQ4_iOS_PrintAudioSessionState(void) {
	AVAudioSession *session = AVAudioSession.sharedInstance;
	const int mode = OpenQ4_iOS_AudioModeIndex();
	const AVAudioSessionCategoryOptions want = OpenQ4_DesiredOptions();
	fprintf(stdout,
			"openQ4 audiosession: mode=%d (%s)\n"
			"openQ4 audiosession: category=%s\n"
			"openQ4 audiosession: options=0x%lx (%s)\n"
			"openQ4 audiosession: wanted =0x%lx (%s)%s\n"
			"openQ4 audiosession: ducksOthers=%s\n"
			"openQ4 audiosession: active=%s (our record; AVAudioSession has no readback)\n"
			"openQ4 audiosession: isOtherAudioPlaying=%s secondaryAudioShouldBeSilencedHint=%s\n"
			"openQ4 audiosession: gameGain=%.3f (target %.3f)\n"
			"openQ4 audiosession: sampleRate=%.0f outputChannels=%ld\n",
			mode, OpenQ4_AudioModeName(mode),
			session.category.UTF8String ?: "?",
			(unsigned long)session.categoryOptions,
			OpenQ4_DescribeOptions(session.categoryOptions).UTF8String,
			(unsigned long)want, OpenQ4_DescribeOptions(want).UTF8String,
			(session.categoryOptions == want) ? " (match)" : " (MISMATCH)",
			(session.categoryOptions & AVAudioSessionCategoryOptionDuckOthers) ? "YES" : "no",
			g_sessionActive ? "yes" : "no",
			session.isOtherAudioPlaying ? "yes" : "no",
			session.secondaryAudioShouldBeSilencedHint ? "yes" : "no",
			(double)openQ4_iOSDuckGain(), (double)OpenQ4_iOS_AudioGainTarget(),
			session.sampleRate, (long)session.outputNumberOfChannels);
	fflush(stdout);
}

@interface OpenQ4AudioSessionWatcher : NSObject
@end

@implementation OpenQ4AudioSessionWatcher
- (void)reassert:(NSNotification *)note {
	OpenQ4_ApplySession(NO);
}

- (void)interrupted:(NSNotification *)note {
	const NSUInteger type =
		[note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
	if (type != AVAudioSessionInterruptionTypeEnded) {
		return;
	}
	// Reactivate unconditionally. iOS deactivates the session for a call or
	// Siri but leaves the CATEGORY intact, so OpenQ4_ApplySession's
	// already-correct early return skips the setActive: that would revive it —
	// and openal-soft has no session awareness to restart its unit either. The
	// result would be an app that is silent from the first interruption until
	// relaunch.
	NSError *err = nil;
	if (![AVAudioSession.sharedInstance setActive:YES error:&err]) {
		fprintf(stderr, "openQ4 audio: reactivate after interruption failed: %s\n",
				err.localizedDescription.UTF8String ?: "?");
	} else {
		g_sessionActive = YES;
		fprintf(stdout, "openQ4 audio: session reactivated after interruption\n");
		fflush(stdout);
	}
	// And re-assert the options: an interruption is exactly the moment the
	// category can come back as something else.
	OpenQ4_ApplySession(NO);
}
@end

static OpenQ4AudioSessionWatcher *g_watcher = nil;

void OpenQ4_iOS_AudioSessionInit(void) {
	if (g_watcher != nil) {
		return;
	}
	g_watcher = [OpenQ4AudioSessionWatcher new];
	g_watcherReady = YES;
	OpenQ4_ApplySession(YES);

	NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
	for (NSNotificationName name in @[ AVAudioSessionRouteChangeNotification,
									  AVAudioSessionSilenceSecondaryAudioHintNotification,
									  UIApplicationDidBecomeActiveNotification ]) {
		[nc addObserver:g_watcher selector:@selector(reassert:) name:name object:nil];
	}
	[nc addObserver:g_watcher selector:@selector(interrupted:)
			   name:AVAudioSessionInterruptionNotification object:nil];

	fprintf(stdout, "openQ4 audio: session sampleRate=%.0f Hz, outputChannels=%ld\n",
			AVAudioSession.sharedInstance.sampleRate,
			(long)AVAudioSession.sharedInstance.outputNumberOfChannels);
	fflush(stdout);

	// The poll is what makes this reliable rather than mostly-reliable: it heals
	// anything the notifications miss, and costs a category comparison at 4 Hz.
	// It re-asserts nothing when the session is already right, so a normal boot
	// logs exactly one category set.
	[NSTimer scheduledTimerWithTimeInterval:0.25
									repeats:YES
									  block:^(NSTimer *t) {
		(void)t;
		OpenQ4_ApplySession(NO);
		OpenQ4_iOS_UpdateDuckGain();
	}];
}

#pragma mark - Game-side ducking

/*
 * "Lower Game Audio" and "Mute Game Audio" have no AVAudioSession equivalent:
 * iOS will duck OTHER apps for you, and never itself. So these two modes are
 * implemented by attenuating our own mix, which is what the engine multiplies in
 * via openQ4_iOSDuckGain().
 *
 * The gain glides rather than steps — a hard cut when music starts is audible as
 * a click on a sustained ambient loop.
 */
static float g_duckGainCurrent = 1.0f;
static float g_duckGainTarget = 1.0f;

float openQ4_iOSDuckGain(void) {
	// Read only. The glide happens in the poller below, on a clock.
	//
	// It used to step here, and that was wrong for a reason worth keeping: this
	// is called once per emitter per mix, so the "rate" depended on how many
	// sounds happened to be playing — a busy scene ducked several times faster
	// than a quiet one. vkQuake-ios drives its equivalent from a timer with a
	// time constant, which is the correct shape and is what this now does.
	return g_duckGainCurrent;
}

float OpenQ4_iOS_AudioGainTarget(void) {
	return g_duckGainTarget;
}

void OpenQ4_iOS_UpdateDuckGain(void) {
	static const float kGainTau = 0.09f;      // ~0.2 s to settle
	static const float kDuckedGain = 0.22f;   // matches the sibling ports
	static CFTimeInterval lastTime = 0.0;

	const int mode = OpenQ4_iOS_AudioModeIndex();
	if (mode == 3 || mode == 4) {
		AVAudioSession *session = AVAudioSession.sharedInstance;
		// isOtherAudioPlaying is the broad "someone else has sound out";
		// secondaryAudioShouldBeSilencedHint is the narrower "another app is
		// playing PRIMARY audio". Either means the player is listening to
		// something that is not us.
		const BOOL othersActive =
			session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint;
		g_duckGainTarget = othersActive ? ((mode == 4) ? 0.0f : kDuckedGain) : 1.0f;
	} else {
		g_duckGainTarget = 1.0f;
	}

	const CFTimeInterval now = CACurrentMediaTime();
	const double dt = (lastTime > 0.0) ? (now - lastTime) : 0.0;
	lastTime = now;

	if (dt <= 0.0 || dt > 0.5) {
		g_duckGainCurrent = g_duckGainTarget;   // first tick, or a long stall
		return;
	}
	const float a = 1.0f - expf(-(float)dt / kGainTau);
	g_duckGainCurrent += (g_duckGainTarget - g_duckGainCurrent) * a;
	if (fabsf(g_duckGainTarget - g_duckGainCurrent) < 0.001f) {
		g_duckGainCurrent = g_duckGainTarget;
	}
}

/*
 * openq4_ios_audio.h — AVAudioSession configuration.
 *
 * Must be called BEFORE the sound system opens its device: activation is what
 * interrupts other apps, and setActive:YES on an already-active session is a
 * no-op, so configuring afterwards is too late for that launch.
 */

#ifndef OPENQ4_IOS_AUDIO_H
#define OPENQ4_IOS_AUDIO_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Set the session to Playback and keep it there. Idempotent; installs the
 * notification observers and the healing poll on first call.
 */
void OpenQ4_iOS_AudioSessionInit(void);

/* Re-evaluate game-side ducking against what other apps are doing. */
void OpenQ4_iOS_UpdateDuckGain(void);

/*
 * Print the live session state: mode, category, decoded options, whether they
 * match what the mode wants, whether we are ducking anyone, our activation
 * record, isOtherAudioPlaying / secondaryAudioShouldBeSilencedHint, and the
 * game-side gain. This is what `!audiosession` on the bridge calls.
 */
void OpenQ4_iOS_PrintAudioSessionState(void);

/*
 * Apply the session for the CURRENT mode right now, logging the transition.
 * Called when the "Other App Audio" row changes so the podcast un-ducks on the
 * tap rather than on the next poll tick.
 */
void OpenQ4_iOS_AudioSessionRefresh(void);

/* The game-side gain this mode is heading for (diagnostics). */
float OpenQ4_iOS_AudioGainTarget(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_AUDIO_H */

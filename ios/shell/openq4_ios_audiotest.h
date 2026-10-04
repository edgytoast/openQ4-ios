/*
 * openq4_ios_audiotest.h — raw-OpenAL partition test for the silence.
 *
 * Plays a short sine through a raw AL source on the engine's context, bypassing
 * sound worlds, emitters, decls, volume cvars and the focus check. Audible means
 * the session and backend are fine and the fault is engine-side; silent means it
 * is below the engine.
 */

#ifndef OPENQ4_IOS_AUDIOTEST_H
#define OPENQ4_IOS_AUDIOTEST_H

#ifdef __cplusplus
extern "C" {
#endif

/* Call after the sound system has initialised (i.e. after common->Init). */
void OpenQ4_iOS_AudioSelfTest(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_AUDIOTEST_H */

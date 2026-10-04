/*
 * openq4_ios_audiotest.mm — the audio partition test.
 *
 * The menu has been silent through several rounds of fixes, each of which was a
 * real defect and none of which restored sound: the session category was wrong
 * (SoloAmbient, muted by the ring/silent switch), the speaker count was 5.1 on a
 * two-speaker device, and the engine mutes itself when it believes the window is
 * unfocused. All three are fixed and it is still silent.
 *
 * That means guessing again is worthless. This plays a short sine through a RAW
 * OpenAL source on the engine's own context, bypassing every layer of engine
 * sound logic — sound worlds, emitters, decls, volume cvars, the focus check.
 *
 *   tone audible  -> session + openal-soft + CoreAudio are all fine, and the
 *                    fault is engine-side voice/world logic
 *   tone silent   -> the fault is below the engine, in the session or the
 *                    backend, and the AL error codes below say which
 *
 * One bit of information, and it halves the search space either way.
 */

#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>

#include "openq4_ios_audiotest.h"

// Declared here rather than by including AL headers: the shell has no include
// path to the openal-soft prefix, and these five entry points are stable.
extern "C" {
	typedef unsigned int ALuint;
	typedef int ALint;
	typedef int ALenum;
	typedef int ALsizei;
	typedef float ALfloat;
	void  alGenBuffers(ALsizei, ALuint *);
	void  alBufferData(ALuint, ALenum, const void *, ALsizei, ALsizei);
	void  alGenSources(ALsizei, ALuint *);
	void  alSourcei(ALuint, ALenum, ALint);
	void  alSourcef(ALuint, ALenum, ALfloat);
	void  alSourcePlay(ALuint);
	ALenum alGetError(void);
}

#define OPENQ4_AL_FORMAT_MONO16   0x1101
#define OPENQ4_AL_BUFFER          0x1009
#define OPENQ4_AL_GAIN            0x100A
#define OPENQ4_AL_SOURCE_RELATIVE 0x0202

static const char *OpenQ4_ALErrorName(ALenum err) {
	switch (err) {
		case 0:      return "none";
		case 0xA001: return "AL_INVALID_NAME";
		case 0xA002: return "AL_INVALID_ENUM";
		case 0xA003: return "AL_INVALID_VALUE";
		case 0xA004: return "AL_INVALID_OPERATION";
		case 0xA005: return "AL_OUT_OF_MEMORY";
		default:     return "unknown";
	}
}

static void OpenQ4_ReportAL(const char *step) {
	const ALenum err = alGetError();
	fprintf(stdout, "openQ4 audiotest: %s -> %s\n", step, OpenQ4_ALErrorName(err));
	fflush(stdout);
}

void OpenQ4_iOS_AudioSelfTest(void) {
	// Drain first. AL errors latch, so a stale one from any earlier call would
	// otherwise be attributed to the first step here — which is precisely the
	// mistake that made EFX look broken.
	OpenQ4_ReportAL("drain (any error here predates this test)");

	static const int rate = 44100;
	static const int ms = 400;
	const int frames = rate * ms / 1000;
	short *pcm = (short *)malloc((size_t)frames * sizeof(short));
	if (pcm == NULL) {
		return;
	}
	for (int i = 0; i < frames; i++) {
		// Fade the last 10% out; a hard cut on a sine is an audible click and
		// would be easy to mistake for a fault.
		const double fade = (i > frames * 9 / 10)
			? (double)(frames - i) / (double)(frames / 10) : 1.0;
		pcm[i] = (short)(12000.0 * fade * sin(2.0 * M_PI * 440.0 * (double)i / (double)rate));
	}

	ALuint buffer = 0, source = 0;
	alGenBuffers(1, &buffer);
	OpenQ4_ReportAL("alGenBuffers");
	alBufferData(buffer, OPENQ4_AL_FORMAT_MONO16, pcm, (ALsizei)(frames * sizeof(short)), rate);
	OpenQ4_ReportAL("alBufferData");
	free(pcm);

	alGenSources(1, &source);
	OpenQ4_ReportAL("alGenSources");
	// Relative + centred so listener position and orientation cannot attenuate
	// it: this must test the pipeline, not the engine's 3D placement.
	alSourcei(source, OPENQ4_AL_SOURCE_RELATIVE, 1);
	alSourcef(source, OPENQ4_AL_GAIN, 1.0f);
	alSourcei(source, OPENQ4_AL_BUFFER, (ALint)buffer);
	OpenQ4_ReportAL("alSourcei(AL_BUFFER)");
	alSourcePlay(source);
	OpenQ4_ReportAL("alSourcePlay");

	fprintf(stdout, "openQ4 audiotest: a 440 Hz tone should be audible NOW. "
					"If it is, the backend is fine and the fault is engine-side.\n");
	fflush(stdout);
}

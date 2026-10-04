/*
 * openq4_ios_mvkenv.h — MoltenVK / OpenAL overrides from Documents/mvk.env.
 *
 * MoltenVK is statically linked and configured entirely through MVK_CONFIG_*
 * environment variables, which it reads with getenv() the first time each knob
 * is needed — i.e. before the first Vulkan call, and therefore before anything
 * the engine could set them from. A constructor is the only place early enough
 * that does not require a rebuild per experiment.
 *
 * The file is the A/B mechanism: over the tailnet bridge, `!mvkenv KEY VALUE`
 * writes a line, the next launch applies it, and `!mvkenv clear` puts the app
 * back to stock. NOTHING is shipped in the file, so a shipping build is
 * byte-identical to MoltenVK's own defaults unless someone deliberately writes
 * one.
 *
 * ALSOFT_* keys are accepted on the same terms (D-067): static openal-soft
 * latches ALSOFT_LOGLEVEL and friends at library init, so turning its trace on
 * over the bridge needs the same pre-main window.
 */

#ifndef OPENQ4_IOS_MVKENV_H
#define OPENQ4_IOS_MVKENV_H

#ifdef __cplusplus
extern "C" {
#endif

/* Human-readable summary of what the constructor applied in THIS process.
 * Never NULL. */
const char *OpenQ4_iOS_MvkEnvApplied(void);

/* Print the file's contents and the applied set. Safe on any thread. */
void OpenQ4_iOS_MvkEnvReport(void);

/* Set/replace one MVK_CONFIG_* line. Returns 0 on success. */
int OpenQ4_iOS_MvkEnvSet(const char *key, const char *value);

/* Delete the file entirely. */
void OpenQ4_iOS_MvkEnvClear(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_MVKENV_H */

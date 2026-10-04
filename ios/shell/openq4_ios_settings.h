/*
 * openq4_ios_settings.h — NSUserDefaults-backed iOS settings.
 *
 * NSUserDefaults is the source of truth, not the engine's cvars. The engine
 * writes its config on a clean exit, and iOS swipe-kill is SIGKILL — so a
 * setting that lived only in a cvar would be lost exactly when the user quit
 * the way users actually quit. Values are pushed INTO cvars at boot and on
 * change; they are never read back out as authority.
 */

#ifndef OPENQ4_IOS_SETTINGS_H
#define OPENQ4_IOS_SETTINGS_H

#include <stdbool.h>
#include <TargetConditionals.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Register defaults and push everything into the engine. Call after common->Init(). */
void  OpenQ4_iOS_SettingsApply(void);

/* Read a setting; returns fallback when unset. Cheap enough to call per frame. */
float OpenQ4_iOS_SettingFloat(const char *key, float fallback);

/* Write a setting, persist it, and push any cvar it maps to. */
void  OpenQ4_iOS_SettingSetFloat(const char *key, float value);

/* Text settings (OPENQ4_ROW_TEXT). Stored as strings, pushed into their cvar the
 * same way the numeric ones are. The getter is ObjC-only; the setter is plain C
 * so the bridge can drive it. */
#ifdef __OBJC__
@class NSString;
NSString *OpenQ4_iOS_SettingString(const char *key);
#endif
void OpenQ4_iOS_SettingSetString(const char *key, const char *value);

/* Run the Multiplayer section's Connect row: issues `connect <directAddr>` on
 * the shell command queue. Returns false when no address is stored. */
bool OpenQ4_iOS_SettingsDirectConnect(void);

/* Set the Render Resolution row from a percentage, snapping to the nearest
 * offered step. The bridge's !renderscale is the only caller. */
void  OpenQ4_iOS_SetRenderScaleSettingPercent(int percent);

/* Present the settings sheet. */
void  OpenQ4_iOS_ShowSettings(void);

/* Present it scrolled to a named section ("Multiplayer", "Display", ...).
 * NULL or "" means the top. The bridge's `!settings [section]` is the caller. */
void  OpenQ4_iOS_ShowSettingsSection(const char *section);
/* Dismiss it again (`!settings off`). No-op when it is not up. */
void  OpenQ4_iOS_HideSettings(void);

#if TARGET_OS_VISION
/* Push the whole visionOS 3D section at the compositor and the renderer
   (D-101). Called on every 3D row change, at launch, and by Reset. */
void  OpenQ4_Apply3DSettings(void);
/* Put the 3D section back to the shipped defaults (D-106). The Reset button on
   the 3D section's own pinned header row is the caller. */
void  OpenQ4_Reset3DSettings(void);
#endif

/* Present it with the Mods > Active Mod list already pushed. The simulator
 * cannot tap a table row, and a photograph of the row is not a photograph of
 * the list it opens. Bridge: `!modpicker`. */
void  OpenQ4_iOS_ShowModPicker(void);

/* Press the sheet's own "< Back" / "Done" chrome, through the same target
 * action the control carries (D-092). The simulator cannot manufacture a
 * UITouch, and a photograph of a Back button is not proof that it pops.
 * Bridge: `!settingsback`, `!settingsdone`. */
void  OpenQ4_iOS_SettingsBack(void);
void  OpenQ4_iOS_SettingsDone(void);

/* Engine-side: set a cvar by name (implemented in the platform layer). */
void  OpenQ4_iOS_SetCvar(const char *name, const char *value);

/* Chosen "Other App Audio" mode; index matches the settings sheet. */
int OpenQ4_iOS_AudioModeIndex(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_SETTINGS_H */

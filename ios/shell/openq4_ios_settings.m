/*
 * openq4_ios_settings.m — iOS settings, backed by NSUserDefaults.
 *
 * Each entry declares how it reaches the engine:
 *
 *   cvar != NULL   pushed into that cvar whenever it changes
 *   cvar == NULL   read directly by the shell each frame (touch layout, haptics)
 *
 * Settings that only the shell consumes deliberately do NOT round-trip through
 * cvars — a cvar the engine also writes would fight the user's choice on the
 * next config write.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../compat/openq4_ios_compat.h"
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

#include "openq4_ios_settings.h"
#include "openq4_ios_touch.h"
#include "openq4_ios_bridge.h"
#include "openq4_ios_mods.h"
#include "openq4_ios_audio.h"
#include "openq4_ios_loc.h"
#if TARGET_OS_VISION
#include "../shell-visionos/OpenQ4Immersive.h"
#include "../shell-visionos/OpenQ4Vision3D.h"
#endif

/*
 * Row kinds. A plain slider/toggle table is not enough: the audio options are
 * meaningless without a sentence each ("duck" and "mix" mean nothing to a
 * player), and the layout editor is an action rather than a value.
 */
typedef enum {
	OPENQ4_ROW_SLIDER,
	OPENQ4_ROW_SWITCH,
	OPENQ4_ROW_CHOICE,
	/*
	 * A one-of-N row whose options are SELF-EVIDENT, shown as a
	 * UISegmentedControl in the cell rather than a pushed list. vkQuake's split
	 * (ios/shell/ios_settings.m:829-838 ROW_SEG vs :1043-1070 ROW_CHOICE): a
	 * list exists to carry a sentence per option, so options that need no
	 * sentence do not get a list.
	 */
	OPENQ4_ROW_SEG,
	OPENQ4_ROW_BUTTON,
	/*
	 * A free-text row. Its value is a STRING in NSUserDefaults, not a float, so
	 * it does not travel through OpenQ4_iOS_SettingFloat at all — a master
	 * server address cannot be expressed as a number and pretending otherwise
	 * would mean a second, parallel storage scheme hidden inside a float row.
	 */
	OPENQ4_ROW_TEXT,
	/*
	 * The mod picker. Its value is a STRING (the mod's directory name, empty
	 * for the base game) like OPENQ4_ROW_TEXT, but its list is discovered from
	 * the filesystem at the moment the row is opened rather than declared here,
	 * so it cannot be an OPENQ4_ROW_CHOICE either — those index a fixed table.
	 */
	OPENQ4_ROW_MODS,
} openq4RowKind_t;

typedef struct {
	const char *key;        // NSUserDefaults key (also the shell-side name)
	const char *label;      // shown in the sheet
	const char *cvar;       // engine cvar, or NULL for shell-only
	const char *section;
	float       defaultValue;
	float       minValue;
	float       maxValue;
	openq4RowKind_t kind;
	const char *defaultText; // OPENQ4_ROW_TEXT only; NULL elsewhere
} openq4Setting_t;

/*
 * "Other App Audio" — named in player language, one sentence each. The
 * mechanism differs per mode: the first three are AVAudioSession category
 * options; the last two have no session equivalent at all and are implemented
 * by attenuating our own mix (see ~/dev/IOS-AUDIO-SESSION-GUIDE.md).
 */
/*
 * Render resolution, as a percentage of the display's native drawable.
 *
 * This used to drive r_screenFraction with r_resolutionScaleMode 2, and it did
 * nothing at all: the Vulkan renderer never implements the scaled scene target
 * those modes describe (grep resolutionScale under src/renderer/Vulkan — there
 * is none), and mode 0 is a debug crop that draws the 3D view small inside a
 * full-size frame. Every "Battery Saver" install has been rendering at native.
 *
 * It now scales the pixel size the SDL3 backend reports, which is what the
 * swapchain extent and therefore CAMetalLayer.drawableSize follow, and the
 * compositor upscales the layer to the screen for free. That also means the 2D
 * GUI renders at the reduced resolution and is upscaled with the rest of the
 * frame — the honest trade for a knob that lives below the renderer.
 *
 * No supersampling entries: the swapchain extent is clamped to the surface's
 * maximum, which is the native drawable, so anything above 100 would be
 * silently clamped — the exact failure this replaces.
 */
static const int kRenderScalePercents[] = { 50, 66, 75, 85, 100 };
#define OPENQ4_RENDER_SCALE_DEFAULT_INDEX 4

NSArray<NSString *> *OpenQ4_ResolutionTitles(void) {
	return @[ OpenQ4_L("50%"), OpenQ4_L("66%"), OpenQ4_L("75%"), OpenQ4_L("85%"),
			  OpenQ4_L("Native (100%)") ];
}
NSArray<NSString *> *OpenQ4_ResolutionDetails(void) {
	return @[
		OpenQ4_L("Quarter the pixels. Longest battery life, softest image."),
		OpenQ4_L("Two thirds. A large frame-rate gain for a visible softening."),
		OpenQ4_L("Three quarters."),
		OpenQ4_L("Barely distinguishable from native, with real headroom back."),
		OpenQ4_L("Renders at the display's full resolution. The default."),
	];
}

NSArray<NSString *> *OpenQ4_AudioModeTitles(void) {
	return @[ OpenQ4_L("Lower Other Audio"), OpenQ4_L("Play Both"),
			  OpenQ4_L("Stop Other Audio"), OpenQ4_L("Lower Game Audio"),
			  OpenQ4_L("Mute Game Audio") ];
}
NSArray<NSString *> *OpenQ4_AudioModeDetails(void) {
	return @[
		OpenQ4_L("Music or a podcast keeps playing, quieter, while the game plays over it."),
		OpenQ4_L("Both play at full volume. Useful with your own soundtrack."),
		OpenQ4_L("Starting the game stops whatever else was playing."),
		OpenQ4_L("The game drops to the background while something else is playing. Your music stays at full volume."),
		OpenQ4_L("The game goes silent while something else is playing, and comes back when it stops."),
	];
}

#if TARGET_OS_VISION
/*
 * Panel Resolution — the PER-EYE render size, and D-097's first knob (D-101).
 *
 * Not the 2D Render Resolution row above it: that scales the WINDOW's drawable,
 * and in 3D the window is a parked card that nothing is rendered into. These
 * sizes drive the engine's offscreen present images directly and take effect at
 * the next frame boundary, with no vid_restart, because the swapchain is not
 * involved at all.
 *
 * 16:9 throughout, which is the panel's default shape; the panel's own
 * width/height rows change its aspect without changing these, and the stretch
 * that produces is the same one a 16:9 monitor makes of a 16:10 desktop.
 */
static const int kPanelResWidths[]  = { 1920, 2240, 2560, 2880 };
static const int kPanelResHeights[] = { 1080, 1260, 1440, 1620 };
#define OPENQ4_PANEL_RES_DEFAULT_INDEX 2

NSArray<NSString *> *OpenQ4_PanelResTitles(void) {
	return @[ @"1920 × 1080", @"2240 × 1260", @"2560 × 1440",
			  @"2880 × 1620" ];
}
NSArray<NSString *> *OpenQ4_PanelResDetails(void) {
	// A pushed picker's options DO keep a sentence each — that is what a picker
	// is for (vkQuake ios_settings.m:462-470). It is rows that lose theirs.
	return @[
		OpenQ4_L("The floor. Use this if the picture stutters at all."),
		OpenQ4_L("A modest saving over the default."),
		OpenQ4_L("The default. 120 fps measured here in the opening map."),
		OpenQ4_L("Sharpest, and about 25% more work per eye. Watch the frame rate."),
	];
}
// Segment titles, not picker titles: vkQuake's Units row is a two-segment
// control reading "m"/"ft" (ios_settings.m:829-838, :575).
NSArray<NSString *> *OpenQ4_UnitsTitles(void) {
	return @[ OpenQ4_L("m"), OpenQ4_L("ft") ];
}
#endif

static const openq4Setting_t kSettings[] = {
	/*
	 * NO DESCRIPTION TEXT UNDER ANY ROW (D-106). The siblings do not have it
	 * and never did: vkQuake's settings cell is
	 * `UITableViewCellStyleDefault` with a bare `textLabel`
	 * (ios/shell/ios_settings.m:780-787) and quake3e's rows are label+control
	 * stack views (ios/shell/ios_settings.m:1503-1514). A row is named so that
	 * it needs no sentence — that is the whole convention, and the maintainer's
	 * 0.1.0.61 verdict was that ours had drifted off it.
	 *
	 * The three escape hatches the siblings DO use, and that this table keeps:
	 * the one-of-N picker still carries a sentence per OPTION (vkQuake
	 * ios_settings.m:462-470), a text row carries a placeholder, and a value
	 * readout on the right of a slider does the explaining
	 * (vkQuake ios_settings.m:909-983).
	 */
	// --- Aim -----------------------------------------------------------------
	/*
	 * Touch AND gamepad (D-109). These three rows used to carry cvar NULL and
	 * reach only the touch look path (openq4_ios_touch.m reads the stored
	 * values directly), so on a Vision Pro with a pad they moved and the pad's
	 * look speed did not change — the maintainer's 0.1.0.63 report. quake3e-ios scales
	 * both paths from the same two sliders (ios/shell/ios_input.m:514-515,
	 * ios_settings.m:295-299); here the cvar push carries the value to the pad
	 * half (in_padLookScaleX/Y multiply the pad look in UsercmdGen, overlay
	 * patch 0008) while touch keeps reading the stored value as before.
	 */
	{ "lookSensX",   "Look Sensitivity (Horizontal)",
	  "in_padLookScaleX", "Aim", 1.0f, 0.25f, 4.0f, OPENQ4_ROW_SLIDER },
	{ "lookSensY",   "Look Sensitivity (Vertical)",
	  "in_padLookScaleY", "Aim", 1.0f, 0.25f, 4.0f, OPENQ4_ROW_SLIDER },
	{ "invertLook",  "Invert Vertical Look",
	  "in_joystickInvertLook", "Aim", 0.0f, 0.0f, 1.0f, OPENQ4_ROW_SWITCH },
	/*
	 * Gyro aim (D-083). Four rows where there used to be one dead slider.
	 *
	 * The old row was "Gyro Aim" bound to `in_gyroSensitivity`, and it did
	 * nothing whatsoever. `in_gyro` is upstream's GAMEPAD gyro — SDL_SENSOR_GYRO
	 * on an opened SDL_Gamepad, fed to SDL3_QueueMouseDelta — so on a phone it
	 * pointed at a sensor that is not a gamepad's, through a mouse chain this
	 * port deliberately took its look input off, behind a cvar (`in_gyro`) that
	 * defaults to 0 and was never set. Retired, and the cvar binding dropped so
	 * upstream's Steam Deck path stays at its own default.
	 *
	 * The key is `gyroMode`, not the old `gyroAim`: a stored 0.5 from the dead
	 * slider must not come back as a mode. Anyone who moved that slider gets
	 * Off, which is what they had.
	 */
	{ "gyroMode",    "Gyro Aim",
	  NULL, "Aim", 0.0f, 0.0f, 2.0f, OPENQ4_ROW_CHOICE },
	// Per-axis, mirroring the touch pair above rather than inventing one scalar:
	// a phone turns about its long axis far more comfortably than it tilts, so
	// the two axes genuinely want different numbers. 100% = one view degree per
	// degree the device actually moves.
	{ "gyroSensX",   "Gyro Sensitivity (Horizontal)",
	  NULL, "Aim", 1.0f, 0.25f, 4.0f, OPENQ4_ROW_SLIDER },
	{ "gyroSensY",   "Gyro Sensitivity (Vertical)",
	  NULL, "Aim", 1.0f, 0.25f, 4.0f, OPENQ4_ROW_SLIDER },
	// Its own switch, not "Invert Vertical Look". Tilt-to-aim has two equally
	// defensible conventions (tilt up = look up, or the camera-lens one where it
	// looks down) and that is not the same preference as how a thumb drag should
	// behave.
	{ "gyroInvertPitch", "Invert Gyro Pitch",
	  NULL, "Aim", 0.0f, 0.0f, 1.0f, OPENQ4_ROW_SWITCH },
	// The qualifier goes in the NAME, parenthesised, which is how the siblings
	// carry one (vkQuake's "Turn Speed (Smooth)", ios_settings.m:619) — not in a
	// sentence underneath.
	{ "padWheelSpeed", "Weapon Wheel Speed (Gamepad)",
	  "in_padWheelSpeed", "Aim", 1.0f, 0.25f, 4.0f, OPENQ4_ROW_SLIDER },

	// --- Touch Controls ------------------------------------------------------
	{ "layoutEdit",  "Customize Touch Layout…",
	  NULL, "Touch Controls", 0.0f, 0.0f, 0.0f, OPENQ4_ROW_BUTTON },
	{ "touchOpacity","Control Opacity",
	  NULL, "Touch Controls", 0.55f, 0.15f, 1.0f, OPENQ4_ROW_SLIDER },
	{ "haptics",     "Haptics",
	  NULL, "Touch Controls", 1.0f, 0.0f, 2.0f, OPENQ4_ROW_CHOICE },
	/*
	 * Touch Controls — Auto / On / Off (D-106, the maintainer's wording for the row and
	 * for its three options).
	 *
	 * Replaces the "Always Show Touch Controls" SWITCH, which could only say
	 * "always" or "the default" and had no way to say "never": a player on a
	 * Vision Pro with a Backbone, or on a phone in a controller clip, had no row
	 * that turned the overlay off. Auto is the shipped behaviour — hidden
	 * whenever a pad drives the game — so nobody's install changes meaning.
	 *
	 * A SEGMENTED control, not a pushed picker: vkQuake's rule is that options
	 * whose names are self-evident get a UISegmentedControl in the cell
	 * (ROW_SEG, ios/shell/ios_settings.m:829-838) and only options that need a
	 * sentence each get the pushed list. Auto/On/Off needs no sentences.
	 *
	 * Migrated from the old boolean by the schema stamp below: old true -> On,
	 * old false or absent -> Auto.
	 */
	{ "touchMode",   "Touch Controls",
	  NULL, "Touch Controls", 0.0f, 0.0f, 2.0f, OPENQ4_ROW_SEG },
	{ "crouchDoubleTap","Double-Tap Crouch",
	  NULL, "Touch Controls", 1.0f, 0.0f, 1.0f, OPENQ4_ROW_SWITCH },
	{ "touchPanels", "Touch Panels Directly",
	  NULL, "Touch Controls", 1.0f, 0.0f, 1.0f, OPENQ4_ROW_SWITCH },

	// --- Display -------------------------------------------------------------
	{ "fov",         "Field of View",
	  "g_fov", "Display", 90.0f, 70.0f, 120.0f, OPENQ4_ROW_SLIDER },
	// Third cvar this slider has driven, and the first that is a whole-frame
	// control. r_brightness is dead under Vulkan (its tables go to an empty
	// GLimp_SetGamma). r_lightScale is alive but scales scene LIGHTING only, and
	// its engine default is 2 — so pointing the slider at it with a default of
	// 1.0 quietly ran the entire game at half light. r_iosBrightness is the
	// blended screen pass added in Session.cpp; see the comment there.
	// Default 1.5, not 1.0. Quake 4 is a dark game on a screen that is often
	// competing with a lit room, and the maintainer's judgement after using the working
	// control is that 150% is where a new install should start. A stored value
	// always wins, so this only moves people who have never touched the slider.
	{ "brightness",  "Brightness",
	  "r_iosBrightness", "Display", 1.5f, 0.5f, 2.0f, OPENQ4_ROW_SLIDER },
	{ "renderScale", "Render Resolution",
	  NULL, "Display", (float)OPENQ4_RENDER_SCALE_DEFAULT_INDEX, 0.0f, 4.0f, OPENQ4_ROW_CHOICE },
	// SMAA, and only SMAA. r_multiSamples is a placebo on the Vulkan backend --
	// vk_Backend.cpp forces parms.multiSamples to 0, so the balanced preset's
	// "4x MSAA" costs and buys nothing (D-073) and no iOS row may claim it.
	// Default OFF as of 2026-09-10 (the maintainer's call): the device round on 0.1.0.48
	// put the remaining SMAA draws at ~1.7 ms of a ~13 ms frame, and he judged
	// the edge quality not worth it on a phone-sized panel.
	{ "antiAlias",   "Anti-aliasing (SMAA)",
	  "r_postAA", "Display", 0.0f, 0.0f, 1.0f, OPENQ4_ROW_SWITCH },
	// vkQuake ios_settings.m:684 calls this exact switch "FPS Counter".
	{ "showFPS",     "FPS Counter",
	  "com_showFPS", "Display", 0.0f, 0.0f, 1.0f, OPENQ4_ROW_SWITCH },

	// --- Audio ---------------------------------------------------------------
	{ "soundVolume", "Game Volume",
	  "s_volume", "Audio", 0.7f, 0.0f, 1.0f, OPENQ4_ROW_SLIDER },
	{ "musicVolume", "Music Volume",
	  "s_musicVolume", "Audio", 0.5f, 0.0f, 1.0f, OPENQ4_ROW_SLIDER },
	{ "audioMode",   "Other App Audio",
	  NULL, "Audio", 0.0f, 0.0f, 4.0f, OPENQ4_ROW_CHOICE },

	// --- Gameplay ------------------------------------------------------------
	{ "alwaysRun",   "Always Run",
	  "in_alwaysRun", "Gameplay", 1.0f, 0.0f, 1.0f, OPENQ4_ROW_SWITCH },

	// --- Multiplayer ---------------------------------------------------------
	/*
	 * net_master1, not net_master0. Slot 0 is CVAR_ROM and carries the built-in
	 * default (master.quakehub.net) precisely because it is also the slot the
	 * client authorisation exchange is pinned to; the overlay makes the client
	 * query and accept replies from all five slots, so an address typed here is
	 * an ADDITION to the built-in master rather than a replacement for it.
	 *
	 * The row's own "host:port" placeholder is the explanation, which is the
	 * text-row escape hatch rather than a sentence underneath.
	 */
	{ "masterServer", "Extra Master Server",
	  "net_master1", "Multiplayer", 0.0f, 0.0f, 0.0f, OPENQ4_ROW_TEXT, "" },
	{ "directAddr",   "Direct Connect Address",
	  NULL, "Multiplayer", 0.0f, 0.0f, 0.0f, OPENQ4_ROW_TEXT, "" },
	{ "directConnect", "Connect…",
	  NULL, "Multiplayer", 0.0f, 0.0f, 0.0f, OPENQ4_ROW_BUTTON, NULL },

	// --- Demos ---------------------------------------------------------------
	/*
	 * The only part of the demo system the port adds. Everything else — the
	 * library, the browser, the transport, seek and speed — is upstream's and
	 * is reached from the main menu's Demos row (D-086). Recording is not: it
	 * is a console command with no menu anywhere, which on a device with no
	 * keyboard means it does not exist. One row fixes that.
	 *
	 * cvar == NULL: this is a command, not a setting, and it is queued onto the
	 * engine thread like every other command the sheet issues. The row's LABEL
	 * carries its state ("Stop Recording") — the siblings put a button's state
	 * in its title, never in a caption.
	 */
	{ "recordDemo",  "Record Demo",
	  NULL, "Demos", 0.0f, 0.0f, 0.0f, OPENQ4_ROW_BUTTON, NULL },

#if TARGET_OS_VISION
	// --- 3D ------------------------------------------------------------------
	/*
	 * The visionOS stereo panel (Phase 6, D-101/D-106; docs/stereo-design.md
	 * section 7). Row ORDER is the spec's, because the spec's order is the
	 * order a player tunes in: where the screen is, then how big, then how
	 * deep, then the room around it.
	 *
	 * Every length is stored in METRES whatever the Units row says — a stored
	 * value that changes meaning when a display preference changes is a bug
	 * waiting for the first player who switches it (q2repro
	 * SETTINGS-SPEC-FROM-VKQUAKE).
	 *
	 * cvar == NULL on all of them: these do not travel through
	 * OpenQ4_iOS_SetCvar. The panel geometry belongs to the compositor thread
	 * (OpenQ4Immersive.m) and the stereo values to renderer cvars that only
	 * exist on the visionOS lanes, so both go out through
	 * OpenQ4_Apply3DSettings() below, which is also what !xr3dtune drives.
	 *
	 * Reset is NOT a row: it is the button on this section's own header
	 * (D-106, copied from vkQuake ios_settings.m:1142-1176).
	 */
	{ "vp3dDist",    "Screen Distance",
	  NULL, "3D", 3.6f, 1.0f, 8.0f, OPENQ4_ROW_SLIDER },
	{ "vp3dWidth",   "Screen Width",
	  NULL, "3D", 5.5f, 1.2f, 8.0f, OPENQ4_ROW_SLIDER },
	{ "vp3dHeight",  "Screen Height",
	  NULL, "3D", 3.1f, 1.0f, 6.0f, OPENQ4_ROW_SLIDER },
	{ "vp3dPosH",    "Screen Position Height",
	  NULL, "3D", 0.0f, -1.5f, 10.0f, OPENQ4_ROW_SLIDER },
	/*
	 * Stereo Depth is a PERCENTAGE of the shipped eye separation, not a raw
	 * world distance: 100% is 2.5 world units, about a human IPD at Quake's
	 * scale. A percentage is the only form of this control anyone can reason
	 * about without knowing what a Quake unit is.
	 *
	 * 125% default and 300% ceiling are the maintainer's numbers from the 0.1.0.61
	 * headset round (D-106), replacing the 100%/320% this shipped with.
	 */
	{ "vp3dDepth",   "Stereo Depth",
	  NULL, "3D", 1.25f, 0.0f, 3.0f, OPENQ4_ROW_SLIDER },
	{ "vp3dConv",    "Crosshair Distance",
	  NULL, "3D", 240.0f, 32.0f, 512.0f, OPENQ4_ROW_SLIDER },
	/*
	 * Gun Depth is GONE as a row (D-106). The maintainer settled it on hardware at
	 * +0.39 and asked for it hardcoded; the number now lives in exactly one
	 * place, `r_stereo3dGunDepth`'s own default in overlay patch 0019, and the
	 * sheet does not push it at all. The cvar stays so `!xr3dtune` can still
	 * move it over the bridge for a future A/B.
	 */
	{ "vp3dRes",     "Panel Resolution",
	  NULL, "3D", (float)OPENQ4_PANEL_RES_DEFAULT_INDEX, 0.0f, 3.0f, OPENQ4_ROW_CHOICE },
	/*
	 * Foveation is GONE as a row too (D-106): the guide's directive was to ship
	 * it unconditional once validated, the maintainer's 0.1.0.61 verdict was "just
	 * leave on", and a switch nobody should touch is a row that only costs
	 * height. The compositor now asks for it whenever the device supports it.
	 */
	{ "vp3dDim",     "Surroundings Dimming",
	  NULL, "3D", 0.8f, 0.0f, 1.0f, OPENQ4_ROW_SLIDER },
	// vkQuake ios_settings.m:574 calls this exact switch "FPS on Panel".
	{ "vp3dPanelFPS", "FPS on Panel",
	  "com_showFPS", "3D", 0.0f, 0.0f, 1.0f, OPENQ4_ROW_SWITCH },
	// Segmented, as vkQuake's Units row is (ios_settings.m:575, ROW_SEG).
	{ "vp3dUnits",   "Units",
	  NULL, "3D", 1.0f, 0.0f, 1.0f, OPENQ4_ROW_SEG },
	{ "vp3dRecenter", "Recenter Screen",
	  NULL, "3D", 0.0f, 0.0f, 0.0f, OPENQ4_ROW_BUTTON, NULL },
#endif

	// --- Mods ----------------------------------------------------------------
	/*
	 * cvar == NULL on purpose. fs_game is CVAR_INIT and the filesystem builds
	 * its search paths inside common->Init(), so pushing it at any other moment
	 * does nothing; the choice is applied as a `+set fs_game` startup argument
	 * on the next cold launch instead (openq4_ios_mods.c, D-080). The row's
	 * VALUE says which mod the next launch will use, which is the fact the
	 * sentence under it used to carry.
	 */
	{ "activeMod",   "Active Mod",
	  NULL, "Mods", 0.0f, 0.0f, 0.0f, OPENQ4_ROW_MODS, "" },
};
static const int kSettingCount = (int)(sizeof(kSettings) / sizeof(kSettings[0]));

static const openq4Setting_t *FindSetting(const char *key) {
	for (int i = 0; i < kSettingCount; i++) {
		if (strcmp(kSettings[i].key, key) == 0) {
			return &kSettings[i];
		}
	}
	return NULL;
}

float OpenQ4_iOS_SettingFloat(const char *key, float fallback) {
	NSString *k = [NSString stringWithFormat:@"openq4.%s", key];
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	if ([d objectForKey:k] == nil) {
		const openq4Setting_t *s = FindSetting(key);
		return s ? s->defaultValue : fallback;
	}
	return [d floatForKey:k];
}

/*
 * Text settings. Same NSUserDefaults namespace as the float ones, a different
 * accessor because the value is a string; a row is one or the other, never both.
 */
NSString *OpenQ4_iOS_SettingString(const char *key) {
	const openq4Setting_t *s = FindSetting(key);
	NSString *k = [NSString stringWithFormat:@"openq4.%s", key];
	NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:k];
	if (v == nil) {
		v = (s != NULL && s->defaultText != NULL)
			? [NSString stringWithUTF8String:s->defaultText] : @"";
	}
	return v;
}

static void PushStringToEngine(const openq4Setting_t *s, NSString *value) {
	if (s == NULL || s->cvar == NULL) {
		return;
	}
	OpenQ4_iOS_SetCvar(s->cvar, value.UTF8String ? value.UTF8String : "");
}

void OpenQ4_iOS_SettingSetString(const char *key, const char *value) {
	const openq4Setting_t *s = FindSetting(key);
	if (s == NULL) {
		fprintf(stdout, "openQ4 settings: no such text setting '%s'\n", key);
		fflush(stdout);
		return;
	}
	NSString *v = (value != NULL) ? [NSString stringWithUTF8String:value] : @"";
	v = [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSString *k = [NSString stringWithFormat:@"openq4.%s", key];
	[NSUserDefaults.standardUserDefaults setObject:v forKey:k];
	// Written immediately, for the same reason the float path is: swipe-kill is
	// SIGKILL and anything merely queued is lost.
	[NSUserDefaults.standardUserDefaults synchronize];
	PushStringToEngine(s, v);
}

/*
 * "Connect" on the Multiplayer section. The address is whatever is in the text
 * row above it; the command crosses to the engine thread on the shell queue,
 * because idCmdSystem is not thread-safe and this runs on the main thread.
 */
bool OpenQ4_iOS_SettingsDirectConnect(void) {
	NSString *addr = OpenQ4_iOS_SettingString("directAddr");
	if (addr.length == 0) {
		fprintf(stdout, "openQ4 settings: direct connect with no address; nothing sent\n");
		fflush(stdout);
		return false;
	}
	OpenQ4_iOS_QueueConsoleCommand([NSString stringWithFormat:@"connect %@", addr].UTF8String);
	fprintf(stdout, "openQ4 settings: queued 'connect %s'\n", addr.UTF8String);
	fflush(stdout);
	return true;
}

static void PushToEngine(const openq4Setting_t *s, float value) {
	if (s == NULL || s->cvar == NULL) {
		return;
	}
	char buf[64];
	if (strcmp(s->key, "showFPS") == 0) {
		// com_showFPS is 0/1/2, and 1 only draws while a map is spawned with no
		// GUI up — which is why "on" appeared to do nothing. 2 is the always-on
		// path, and "on" should mean on.
		snprintf(buf, sizeof(buf), "%d", value > 0.5f ? 2 : 0);
	} else if (s->kind == OPENQ4_ROW_SWITCH) {
		snprintf(buf, sizeof(buf), "%d", value > 0.5f ? 1 : 0);
	} else {
		snprintf(buf, sizeof(buf), "%g", value);
	}
	OpenQ4_iOS_SetCvar(s->cvar, buf);
}

/*
 * Which AVAudioSession options the chosen "Other App Audio" mode wants.
 * Index order matches OpenQ4_AudioModeTitles().
 */
int OpenQ4_iOS_AudioModeIndex(void) {
	return (int)OpenQ4_iOS_SettingFloat("audioMode", 0.0f);
}

static void OpenQ4_ApplyRenderScale(void) {
	const int count = (int)(sizeof(kRenderScalePercents) / sizeof(kRenderScalePercents[0]));
	int idx = (int)OpenQ4_iOS_SettingFloat("renderScale", (float)OPENQ4_RENDER_SCALE_DEFAULT_INDEX);
	if (idx < 0 || idx >= count) {
		idx = OPENQ4_RENDER_SCALE_DEFAULT_INDEX;
	}
	OpenQ4_iOS_SetRenderScalePercent(kRenderScalePercents[idx]);
	// Undo what earlier builds archived. r_screenFraction is inert under the
	// Vulkan renderer but not silent any more — a leftover 60 from a "Battery
	// Saver" install would now warn on every launch about a setting the player
	// can no longer see.
	OpenQ4_iOS_SetCvar("r_screenFraction", "100");
}

/*
 * The Display row stores a choice INDEX, but a percentage is what anyone
 * measuring wants to type. Snap to the nearest offered step so the bridge and
 * the row can never disagree about which one is selected.
 */
void OpenQ4_iOS_SetRenderScaleSettingPercent(int percent) {
	const int count = (int)(sizeof(kRenderScalePercents) / sizeof(kRenderScalePercents[0]));
	int best = OPENQ4_RENDER_SCALE_DEFAULT_INDEX;
	int bestDistance = 1000;
	for (int i = 0; i < count; i++) {
		const int distance = abs(kRenderScalePercents[i] - percent);
		if (distance < bestDistance) {
			bestDistance = distance;
			best = i;
		}
	}
	OpenQ4_iOS_SettingSetFloat("renderScale", (float)best);
}

#if TARGET_OS_VISION
/*
 * Push the whole 3D section at the compositor and the renderer.
 *
 * All of it at once, on every change, rather than a switch per key: the panel
 * placement is three numbers the compositor only accepts together, the stereo
 * pair is two, and "all of them" is four calls — cheaper than the bug where one
 * row's handler is added and another's is forgotten. Called on every 3D row
 * change (live while dragging), on launch from OpenQ4_iOS_SettingsApply, and by
 * the Reset button after it clears the stored values.
 */
void OpenQ4_Apply3DSettings(void) {
	const float dist   = OpenQ4_iOS_SettingFloat("vp3dDist", 3.6f);
	const float width  = OpenQ4_iOS_SettingFloat("vp3dWidth", 5.5f);
	const float height = OpenQ4_iOS_SettingFloat("vp3dHeight", 3.1f);
	const float posH   = OpenQ4_iOS_SettingFloat("vp3dPosH", 0.0f);
	const float dim    = OpenQ4_iOS_SettingFloat("vp3dDim", 0.8f);
	OpenQ4_Immersive_SetPanel(dist, width * 0.5f, height * 0.5f);
	OpenQ4_Immersive_SetHeight(posH);
	OpenQ4_Immersive_SetDim(dim);

	// Stereo Depth is a percentage of the shipped 2.5-unit separation; the
	// engine cvar is in world units, and the conversion lives here so the stored
	// value stays the thing the slider shows.
	const float depth = OpenQ4_iOS_SettingFloat("vp3dDepth", 1.0f);
	const float conv  = OpenQ4_iOS_SettingFloat("vp3dConv", 240.0f);
	OpenQ4_Vision3D_Tune(depth * 2.5f, conv, NULL, NULL, NULL, NULL, NULL);
	/*
	 * Gun depth is deliberately NOT pushed (D-106). The maintainer settled it at +0.39
	 * on hardware and asked for it hardcoded, so the number lives in exactly
	 * one place — r_stereo3dGunDepth's own default in overlay patch 0019 — and
	 * this function pushing a stored value every time would both duplicate it
	 * and stamp on `!xr3dtune gun` the moment any other row moved.
	 */

	int idx = (int)OpenQ4_iOS_SettingFloat("vp3dRes", (float)OPENQ4_PANEL_RES_DEFAULT_INDEX);
	if (idx < 0 || idx >= (int)(sizeof(kPanelResWidths) / sizeof(kPanelResWidths[0]))) {
		idx = OPENQ4_PANEL_RES_DEFAULT_INDEX;
	}
	// 1920x1080 is the FLOOR, in the choice list and in the cvar's own minimum
	// (overlay patch 0019): the maintainer's 0.1.0.61 verdict was 1440p default with
	// 1080p as the minimum, so nothing below it is selectable or settable.
	OpenQ4_Vision3D_SetEyeSize(kPanelResWidths[idx], kPanelResHeights[idx]);
}

/*
 * Put the whole 3D section back to the shipped defaults. The 3D header's Reset
 * button is the only caller in the sheet; it is a function rather than a method
 * so the schema migration and the bridge can reach the same behaviour.
 */
void OpenQ4_Reset3DSettings(void) {
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	for (int i = 0; i < kSettingCount; i++) {
		if (strcmp(kSettings[i].section, "3D") != 0
				|| kSettings[i].kind == OPENQ4_ROW_BUTTON) {
			continue;
		}
		// Removed, not written back as the default: an absent key IS the
		// default everywhere else in this file, and writing one would pin
		// today's value against a future change to it.
		[d removeObjectForKey:[NSString stringWithFormat:@"openq4.%s", kSettings[i].key]];
	}
	[d synchronize];
	OpenQ4_Apply3DSettings();
	OpenQ4_iOS_SettingsApply();		// the cvar-backed rows in the section
	fprintf(stdout, "openQ4 settings: 3D section reset to defaults\n");
	fflush(stdout);
}

// Metres are what is stored; feet are only ever a rendering of them.
static NSString *OpenQ4_FormatLength(float metres) {
	if (OpenQ4_iOS_SettingFloat("vp3dUnits", 1.0f) < 0.5f) {
		return [NSString stringWithFormat:@"%.1f m", metres];
	}
	return [NSString stringWithFormat:@"%.1f ft", metres * 3.28084f];
}
#endif

void OpenQ4_iOS_SettingSetFloat(const char *key, float value) {
	NSString *k = [NSString stringWithFormat:@"openq4.%s", key];
	[NSUserDefaults.standardUserDefaults setFloat:value forKey:k];
	// Written immediately: iOS swipe-kill is SIGKILL, so anything merely queued
	// is lost exactly when the user quits the way users actually quit.
	[NSUserDefaults.standardUserDefaults synchronize];
	PushToEngine(FindSetting(key), value);
	// Shell-only settings reach the overlay through nothing else, so a change
	// to size, opacity or always-show has to be pushed at it explicitly.
	OpenQ4_iOS_TouchRefreshAppearance();
	if (strcmp(key, "renderScale") == 0) {
		OpenQ4_ApplyRenderScale();
	}
	if (strcmp(key, "audioMode") == 0) {
		// The session, not the gain, is what other apps hear (D-087). Apply it
		// on the tap; the 4 Hz healing poll is a safety net, not the mechanism.
		OpenQ4_iOS_AudioSessionRefresh();
	}
#if TARGET_OS_VISION
	// Live while dragging: the compositor recomputes the panel's placement from
	// the frozen head pose every frame, so a pushed value is visible on the next
	// one and the slider can be tuned by eye rather than by guess-and-release.
	if (strncmp(key, "vp3d", 4) == 0) {
		OpenQ4_Apply3DSettings();
	}
#endif
}

/*
 * One-shot schema migrations (D-106).
 *
 * A CHANGED DEFAULT DOES NOT MOVE AN INSTALL THAT ALREADY HAS A STORED VALUE —
 * that is the whole point of NSUserDefaults being the authority here, and it is
 * also why the maintainer's headset would have kept 0.1.0.61's stereo depth, panel size
 * and gun depth after this round changed all three. So the change of defaults
 * comes with a stamp: the stored schema version is compared against
 * OPENQ4_SETTINGS_SCHEMA, and each step below runs exactly once per install.
 *
 * Scoped, never a wipe: step 2 clears the 3D section and migrates one touch
 * row. Everything else a player has chosen — sensitivity, volumes, brightness,
 * layout — is untouched, and says so in the log.
 */
#define OPENQ4_SETTINGS_SCHEMA 2

static void OpenQ4_MigrateSettingsSchema(void) {
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	NSString *const kStamp = @"openq4.settingsSchema";
	const int have = ([d objectForKey:kStamp] != nil) ? (int)[d integerForKey:kStamp] : 0;
	if (have >= OPENQ4_SETTINGS_SCHEMA) {
		return;
	}

	if (have < 2) {
		/*
		 * Step 2a — the 3D section goes back to the shipped defaults once.
		 * Stereo Depth (100% -> 125%), Panel Resolution (the index list itself
		 * changed shape, so a stored index now means a different size) and Gun
		 * Depth (retired; the number lives in the cvar) all moved this round,
		 * and Foveation is no longer a setting at all.
		 *
		 * Removed, not written back as the default: an absent key IS the
		 * default everywhere else in this file.
		 */
		int cleared = 0;
		for (NSString *k in [d dictionaryRepresentation].allKeys) {
			if (![k hasPrefix:@"openq4.vp3d"]) { continue; }
			[d removeObjectForKey:k];
			cleared++;
		}

		/*
		 * Step 2b — "Always Show Touch Controls" (a switch) becomes "Touch
		 * Controls" (Auto/On/Off). Old true meant "show them even with a pad",
		 * which is now On; old false, and never-touched, are both Auto.
		 */
		const BOOL hadAlways = ([d objectForKey:@"openq4.touchAlways"] != nil);
		if (hadAlways) {
			const BOOL always = [d floatForKey:@"openq4.touchAlways"] > 0.5f;
			if (always) {
				[d setFloat:1.0f forKey:@"openq4.touchMode"];   // On
			}
			[d removeObjectForKey:@"openq4.touchAlways"];
		}
		fprintf(stdout,
				"openQ4 settings: schema %d -> 2 — cleared %d 3D key(s) so this "
				"build's defaults take effect; touchAlways %s. Nothing else changed.\n",
				have, cleared,
				hadAlways ? "migrated to touchMode" : "was never set");
	}

	[d setInteger:OPENQ4_SETTINGS_SCHEMA forKey:kStamp];
	[d synchronize];
	fflush(stdout);
}

void OpenQ4_iOS_SettingsApply(void) {
	OpenQ4_MigrateSettingsSchema();
	// Repair installs poisoned by the dB-vs-linear bug above. Those builds wrote
	// openq4.soundVolume = 0 into NSUserDefaults, and a stored 0 is
	// indistinguishable from a user who deliberately muted — except that the
	// slider could not reach anything else, since its whole range was wrong.
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	for (NSString *key in @[ @"openq4.soundVolume", @"openq4.musicVolume" ]) {
		if ([d objectForKey:key] != nil && [d floatForKey:key] <= 0.0f) {
			[d removeObjectForKey:key];
			fprintf(stdout, "openQ4 settings: cleared muted %s left by the dB-range bug\n",
					key.UTF8String);
		}
	}
	[d synchronize];

	for (int i = 0; i < kSettingCount; i++) {
		const openq4Setting_t *s = &kSettings[i];
		if (s->kind == OPENQ4_ROW_TEXT || s->kind == OPENQ4_ROW_MODS) {
			PushStringToEngine(s, OpenQ4_iOS_SettingString(s->key));
			continue;
		}
		PushToEngine(s, OpenQ4_iOS_SettingFloat(s->key, s->defaultValue));
	}
	OpenQ4_ApplyRenderScale();
#if TARGET_OS_VISION
	// The 3D section reaches the compositor and the renderer through its own
	// path, so the generic cvar loop above does not carry it.
	OpenQ4_Apply3DSettings();
#endif
	fprintf(stdout, "openQ4 settings: applied %d setting(s) to the engine\n", kSettingCount);
	fflush(stdout);
}

/* One place that knows which list belongs to which choice row. */
static NSArray<NSString *> *OpenQ4_ChoiceTitles(const char *key) {
	if (strcmp(key, "haptics") == 0)    {
		return @[ OpenQ4_L("Off"), OpenQ4_L("On"), OpenQ4_L("Fire Only") ];
	}
	if (strcmp(key, "gyroMode") == 0)   {
		return @[ OpenQ4_L("Off"), OpenQ4_L("While Aiming"), OpenQ4_L("Always") ];
	}
	if (strcmp(key, "renderScale") == 0) { return OpenQ4_ResolutionTitles(); }
#if TARGET_OS_VISION
	if (strcmp(key, "vp3dRes") == 0)   { return OpenQ4_PanelResTitles(); }
#endif
	return OpenQ4_AudioModeTitles();
}

/*
 * Segment titles for OPENQ4_ROW_SEG. They travel with the KEY rather than being
 * baked into the cell, which is vkQuake's shape once a second segmented row
 * existed (ios/shell/ios_settings.m:344-371).
 */
static NSArray<NSString *> *OpenQ4_SegTitles(const char *key) {
	if (strcmp(key, "touchMode") == 0) {
		return @[ OpenQ4_L("Auto"), OpenQ4_L("On"), OpenQ4_L("Off") ];
	}
#if TARGET_OS_VISION
	if (strcmp(key, "vp3dUnits") == 0) { return OpenQ4_UnitsTitles(); }
#endif
	return @[];
}
static NSArray<NSString *> *OpenQ4_ChoiceDetails(const char *key) {
	if (strcmp(key, "haptics") == 0) {
		return @[ OpenQ4_L("No haptic feedback."),
				  OpenQ4_L("A small tap on every button press."),
				  OpenQ4_L("A tap on the fire button only — useful there, noise elsewhere.") ];
	}
	if (strcmp(key, "gyroMode") == 0) {
		return @[ OpenQ4_L("The device's motion is ignored."),
				  OpenQ4_L("Only while a finger is down on the look area — coarse aim with the thumb, fine aim with the wrist."),
				  OpenQ4_L("Whenever you are in a map. Off in menus and cutscenes either way.") ];
	}
	if (strcmp(key, "renderScale") == 0) { return OpenQ4_ResolutionDetails(); }
#if TARGET_OS_VISION
	if (strcmp(key, "vp3dRes") == 0)   { return OpenQ4_PanelResDetails(); }
#endif
	return OpenQ4_AudioModeDetails();
}

/*
 * How a slider's value reads to a player. Volumes and sensitivities are
 * percentages because that is how people think about them; field of view is
 * degrees; anything else is a plain number.
 */
static NSString *OpenQ4_FormatSettingValue(const openq4Setting_t *st, float v) {
#if TARGET_OS_VISION
	// The three lengths and the height read in the chosen unit; depth and
	// dimming are percentages; convergence is world units, which is what the
	// bridge command and the design doc both speak.
	if (strcmp(st->key, "vp3dDist") == 0 || strcmp(st->key, "vp3dWidth") == 0
			|| strcmp(st->key, "vp3dHeight") == 0 || strcmp(st->key, "vp3dPosH") == 0) {
		return OpenQ4_FormatLength(v);
	}
	if (strcmp(st->key, "vp3dDepth") == 0 || strcmp(st->key, "vp3dDim") == 0) {
		return [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
	}
	if (strcmp(st->key, "vp3dConv") == 0) {
		return [NSString stringWithFormat:@"%.0f", v];
	}
	if (strcmp(st->key, "vp3dGun") == 0) {
		return (fabsf(v) < 0.005f) ? OpenQ4_L("On screen")
								   : [NSString stringWithFormat:@"%+.2f", v];
	}
#endif
	if (strcmp(st->key, "fov") == 0) {
		return [NSString stringWithFormat:@"%.0f\u00B0", v];
	}
	if (st->maxValue <= 1.01f) {
		return [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
	}
	if (strcmp(st->key, "lookSensX") == 0 || strcmp(st->key, "lookSensY") == 0 ||
		strcmp(st->key, "gyroSensX") == 0 || strcmp(st->key, "gyroSensY") == 0 ||
		strcmp(st->key, "brightness") == 0) {
		return [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
	}
	return [NSString stringWithFormat:@"%.2f", v];
}

#pragma mark - Choice submenu

/*
 * Is this row meaningful on the platform we are running on? (D-090.)
 *
 * visionOS has no gyroscope and no taptic engine, so the four gyro rows and the
 * haptics row would be controls for hardware that is not there — a slider that
 * demonstrably does nothing reads as a bug, which is the whole reason the dead
 * "Gyro Aim" slider was replaced in D-083 rather than left alone. The STORAGE is
 * untouched (the keys still exist and still default the same way), so a build
 * shared with iOS through the same NSUserDefaults suite loses nothing.
 */
static BOOL OpenQ4_SettingAvailableHere(const openq4Setting_t *st) {
#if TARGET_OS_VISION
	static const char *const kHiddenOnVision[] = {
		"gyroMode", "gyroSensX", "gyroSensY", "gyroInvertPitch", "haptics",
		// "FPS on Panel" in the 3D section drives the same cvar, and two rows
		// for one switch is how a settings sheet starts lying to people.
		"showFPS",
	};
	for (size_t i = 0; i < sizeof(kHiddenOnVision) / sizeof(kHiddenOnVision[0]); i++) {
		if (strcmp(st->key, kHiddenOnVision[i]) == 0) { return NO; }
	}
	return YES;
#else
	// The 3D section is the visionOS stereo panel and nothing else: on iOS its
	// rows would be controls for a compositor that does not exist. The STORAGE
	// is untouched, exactly as for the gyro rows above.
	if (strcmp(st->section, "3D") == 0) { return NO; }
	return YES;
#endif
}

#pragma mark - Pushed sub-page chrome

/* A sub-page's content view fills what the header row leaves. */
static void OpenQ4_PinToContent(UIView *view, UIView *content) {
	view.translatesAutoresizingMaskIntoConstraints = NO;
	[content addSubview:view];
	[NSLayoutConstraint activateConstraints:@[
		[view.topAnchor constraintEqualToAnchor:content.topAnchor],
		[view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		[view.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
	]];
}

/*
 * Every page pushed onto the settings stack, with its own way back (D-092).
 *
 * The stack's navigation bar is hidden (see OpenQ4_iOS_ShowSettingsSection) —
 * the sheet draws its own title row — so a pushed page used to have NO visible
 * control at all and relied on the interactive edge-swipe pop. That gesture does
 * not exist on visionOS: there is no screen edge to swipe from, gaze-and-pinch
 * is not a drag from off-frame, and the maintainer was stuck in the mod picker on
 * hardware with force-quit as the only way out.
 *
 * So the chrome is drawn rather than gestured, exactly as the root already does
 * it: "‹ Back" on the left, the page title in the middle, "Done" on the right.
 * It is a base class rather than a helper per page so that a sub-page added
 * later cannot forget it — subclasses put their content in `contentView` and
 * inherit the way out.
 */
@interface OpenQ4SubPageVC : UIViewController
/* Everything below the header row. Subclasses add their views here. */
@property (nonatomic, strong, readonly) UIView *contentView;
- (void)backTapped;   /* pops this page   — also the bridge's !settingsback */
- (void)doneTapped;   /* dismisses the sheet — also the bridge's !settingsdone */
@end

@implementation OpenQ4SubPageVC {
	UIView *_contentView;
}

- (UIView *)contentView { return _contentView; }

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];

	UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
	// "‹ " on the title itself, not a chevron image: one string, one tap target,
	// and it goes through the portable title setter (D-092) like every other.
	back.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
	OpenQ4_iOS_SetButtonTitle(back, [@"‹  " stringByAppendingString:OpenQ4_L("Back")]);
	[back addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];

	UILabel *title = [UILabel new];
	title.text = self.title ?: @"";
	title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
	title.textColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
	title.textAlignment = NSTextAlignmentCenter;

	UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
	done.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
	OpenQ4_iOS_SetButtonTitle(done, OpenQ4_L("Done"));
	[done addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];

	_contentView = [UIView new];

	for (UIView *v in @[ back, title, done, _contentView ]) {
		v.translatesAutoresizingMaskIntoConstraints = NO;
		[self.view addSubview:v];
	}
	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[back.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
		[back.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
		[done.centerYAnchor constraintEqualToAnchor:back.centerYAnchor],
		[done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
		[title.centerYAnchor constraintEqualToAnchor:back.centerYAnchor],
		[title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[title.leadingAnchor constraintGreaterThanOrEqualToAnchor:back.trailingAnchor constant:12],
		[title.trailingAnchor constraintLessThanOrEqualToAnchor:done.leadingAnchor constant:-12],
		[_contentView.topAnchor constraintEqualToAnchor:back.bottomAnchor constant:12],
		[_contentView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_contentView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[_contentView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];
}

- (void)backTapped {
	[self.navigationController popViewControllerAnimated:YES];
}

/* Dismisses the whole sheet: a pushed page forwards this to its presenter. */
- (void)doneTapped {
	[self dismissViewControllerAnimated:YES completion:nil];
}

@end

/*
 * A pushed list, one row per option, each with the sentence that explains it and
 * a checkmark on the current choice. Cycling through five modes by tapping one
 * row would make the player read the label five times to find out what the
 * options even are.
 */
@interface OpenQ4ChoiceVC : OpenQ4SubPageVC <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *settingKey;
@property (nonatomic, strong) NSArray<NSString *> *titles;
@property (nonatomic, strong) NSArray<NSString *> *details;
@property (nonatomic, assign) int selectedIndex;
@property (nonatomic, copy) void (^onPicked)(void);
@end

@implementation OpenQ4ChoiceVC {
	UITableView *_table;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_table = [[UITableView alloc] initWithFrame:CGRectZero
										  style:UITableViewStyleInsetGrouped];
	_table.dataSource = self;
	_table.delegate = self;
	_table.backgroundColor = UIColor.clearColor;
	_table.rowHeight = UITableViewAutomaticDimension;
	_table.estimatedRowHeight = 64;
	OpenQ4_PinToContent(_table, self.contentView);
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
	return (NSInteger)self.titles.count;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
											   reuseIdentifier:nil];
	c.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
	c.textLabel.text = self.titles[ip.row];
	c.textLabel.textColor = UIColor.whiteColor;
	c.detailTextLabel.text = (ip.row < (NSInteger)self.details.count) ? self.details[ip.row] : @"";
	c.detailTextLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
	c.detailTextLabel.numberOfLines = 0;
	c.accessoryType = (ip.row == self.selectedIndex)
		? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	c.tintColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
	return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	self.selectedIndex = (int)ip.row;
	OpenQ4_iOS_SettingSetFloat(self.settingKey.UTF8String, (float)ip.row);
	[t reloadData];
	if (self.onPicked) {
		self.onPicked();
	}
	[self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Mod picker

/*
 * The list of installed mods, discovered from Documents each time the row is
 * opened — a mod can appear between two visits to this screen (Files.app is
 * running alongside us) and a cached list would show a stale one.
 *
 * Selecting a mod stores its directory name and says, in as many words, that
 * nothing changes until openQ4 is restarted. It deliberately does NOT try to
 * switch live: the engine's own Mods menu does `fs_game` + `reloadEngine`, and
 * fs_game is CVAR_INIT — the filesystem's search paths are built inside
 * common->Init() and nothing short of a full engine reload rebuilds them.
 * D-080 has the reasoning; the short version is that a relaunch is one gesture
 * on this platform and a mid-session engine teardown is not worth its risk.
 */
@interface OpenQ4ModsVC : OpenQ4SubPageVC <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^onPicked)(void);
@end

@implementation OpenQ4ModsVC {
	UITableView *_table;
	NSArray<OpenQ4ModInfo *> *_mods;
	NSString *_chosen;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_mods = OpenQ4_iOS_ScanMods();
	_chosen = OpenQ4_iOS_SettingString("activeMod");
	_table = [[UITableView alloc] initWithFrame:CGRectZero
										  style:UITableViewStyleInsetGrouped];
	_table.dataSource = self;
	_table.delegate = self;
	_table.backgroundColor = UIColor.clearColor;
	_table.rowHeight = UITableViewAutomaticDimension;
	_table.estimatedRowHeight = 64;
	OpenQ4_PinToContent(_table, self.contentView);
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
	return (NSInteger)_mods.count + 1;   // row 0 is "None (base game)"
}

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
	if (_mods.count == 0) {
		return OpenQ4_L("No mods found. Copy a mod folder — the one containing mod.json — "
						"into the openQ4 folder in Files, next to q4base, then come back. "
						"Mods that ship their own game code cannot run on iOS.");
	}
	return OpenQ4_L("A mod is applied the next time openQ4 starts.");
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
											   reuseIdentifier:nil];
	c.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
	c.textLabel.textColor = UIColor.whiteColor;
	c.detailTextLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
	c.detailTextLabel.numberOfLines = 0;
	c.tintColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];

	NSString *dir = @"";
	if (ip.row == 0) {
		c.textLabel.text = OpenQ4_L("None (base game)");
		c.detailTextLabel.text = OpenQ4_L("Quake 4 exactly as it shipped.");
	} else {
		OpenQ4ModInfo *m = _mods[(NSUInteger)(ip.row - 1)];
		dir = m.dir;
		c.textLabel.text = m.name;
		c.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@", m.version, m.dir];
	}
	c.accessoryType = [dir isEqualToString:_chosen]
		? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	NSString *dir = (ip.row == 0) ? @"" : _mods[(NSUInteger)(ip.row - 1)].dir;
	OpenQ4_iOS_SettingSetString("activeMod", dir.UTF8String);
	_chosen = dir;
	[t reloadData];
	if (self.onPicked) {
		self.onPicked();
	}

	NSString *what = (dir.length == 0)
		? OpenQ4_L("openQ4 will start as the base game next time.")
		: [NSString stringWithFormat:OpenQ4_L("%@ will be loaded the next time openQ4 starts."),
									 _mods[(NSUInteger)(ip.row - 1)].name];
	UIAlertController *a =
		[UIAlertController alertControllerWithTitle:OpenQ4_L("Takes effect on next launch")
											message:[what stringByAppendingFormat:@"\n\n%@",
													 OpenQ4_L("Quit openQ4 (swipe it away from the app switcher) and open it again.")]
									 preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:OpenQ4_L("OK") style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - Settings sheet

/*
 * A grouped table, not a flat stack of sliders.
 *
 * The sections match the sibling ports (Aim, Touch Controls, Display, Audio,
 * Gameplay) so the muscle memory carries across, and every row that needs one
 * carries a sentence of explanation underneath. "Duck" and "mix" are jargon; a
 * player should read what the option does to their music.
 */
/*
 * A section header whose BACKGROUND spans the whole table, not just the frame
 * the table gives it (D-109).
 *
 * the maintainer's 0.1.0.63 report: the pinned "3D Settings | Reset" header was a
 * rectangle narrower than the widened sheet, its corners cutting into the rows
 * beside and under it. Measured on the visionOS simulator (this view's own log
 * line): in the 900 pt sheet a plain table hands the header x=24 w=820 — it
 * ends at 844 pt while the rows run on to ~886 pt — so the right end of every
 * row scrolling under the pinned header stuck out past the header's corner,
 * beside the Reset pill. Safe-area insets are 0 there; this is the visionOS
 * plain-table header layout itself. On iOS the header already spans the table
 * (logged too), so this changes nothing visible there.
 *
 * The header's own frame is left exactly where UIKit puts it (the label and the
 * Reset pill keep their margins); only the fill is widened, every layout pass,
 * to the table's full bounds converted into this view. clipsToBounds stays NO so
 * the fill can reach past the frame; the sheet's own corner mask clips it.
 *
 * It logs its frame against the table's bounds whenever either changes — the
 * charter's "a UIKit placement needs the view logging its own frame".
 */
@interface OpenQ4SectionHeaderView : UIView
@property (nonatomic, weak) UITableView *table;
@property (nonatomic, copy) NSString *logName;
@end

@implementation OpenQ4SectionHeaderView {
	UIView *_fill;
	CGRect  _lastFrameInTable;
	CGRect  _lastTableBounds;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = UIColor.clearColor;
		self.clipsToBounds = NO;
		_fill = [UIView new];
		_fill.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
		_fill.userInteractionEnabled = NO;
		[self insertSubview:_fill atIndex:0];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	UITableView *t = self.table;
	if (t == nil) {
		_fill.frame = self.bounds;
		return;
	}
	const CGRect tb = [t convertRect:t.bounds toView:self];
	_fill.frame = CGRectMake(tb.origin.x, 0, tb.size.width, self.bounds.size.height);
	[self sendSubviewToBack:_fill];

	const CGRect inTable = [self convertRect:self.bounds toView:t];
	const CGRect fillInTable = [self convertRect:_fill.frame toView:t];
	// Only the width and x matter for this check; y changes on every scroll
	// step and would flood the log.
	if (fabs(inTable.origin.x - _lastFrameInTable.origin.x) > 0.5
			|| fabs(inTable.size.width - _lastFrameInTable.size.width) > 0.5
			|| fabs(t.bounds.size.width - _lastTableBounds.size.width) > 0.5) {
		_lastFrameInTable = inTable;
		_lastTableBounds = t.bounds;
		const UIEdgeInsets sa = t.safeAreaInsets;
		const CGFloat sheetW = t.superview != nil ? t.superview.bounds.size.width : -1;
		fprintf(stdout,
				"openQ4 settings: header '%s' frame x=%.1f w=%.1f | fill x=%.1f w=%.1f | "
				"table w=%.1f (safe area L=%.1f R=%.1f) sheet w=%.1f | fill spans table: %s\n",
				self.logName.UTF8String ?: "?", inTable.origin.x, inTable.size.width,
				fillInTable.origin.x, fillInTable.size.width,
				t.bounds.size.width, sa.left, sa.right, sheetW,
				(fabs(fillInTable.origin.x) < 0.5
					&& fabs(fillInTable.size.width - t.bounds.size.width) < 0.5) ? "YES" : "NO");
		fflush(stdout);
	}
}
@end

@interface OpenQ4SettingsVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
/* Section to scroll to on appear, or nil for the top. The simulator cannot be
 * tapped or scrolled, so without this there is no way to photograph a section
 * that is below the fold — and a section nobody can screenshot is a section
 * nobody can produce an artifact for. */
@property (nonatomic, copy) NSString *scrollToSection;
@end

@implementation OpenQ4SettingsVC {
	UITableView    *_table;
	NSArray<NSString *> *_sections;
	NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *_rowsBySection;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];

	// Section order is the display order; built from the table so adding a row
	// never means editing two places.
	NSMutableArray<NSString *> *order = [NSMutableArray array];
	_rowsBySection = [NSMutableDictionary dictionary];
	for (int i = 0; i < kSettingCount; i++) {
		if (!OpenQ4_SettingAvailableHere(&kSettings[i])) { continue; }
		NSString *sec = [NSString stringWithUTF8String:kSettings[i].section];
		if (_rowsBySection[sec] == nil) {
			_rowsBySection[sec] = [NSMutableArray array];
			[order addObject:sec];
		}
		[_rowsBySection[sec] addObject:@(i)];
	}
	_sections = order;

	UILabel *title = [UILabel new];
	title.text = OpenQ4_L("openQ4 Settings");
	title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
	title.textColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];

	UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
	done.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
	OpenQ4_iOS_SetButtonTitle(done, OpenQ4_L("Done"));
	[done addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];

	/*
	 * PLAIN, not inset-grouped (D-106).
	 *
	 * the maintainer asked for the "3D Settings | Reset" header to stay with the 3D
	 * section as you scroll inside it and to be gone outside it — "like we did
	 * with the quake ports". That behaviour is UIKit's own: a PLAIN table
	 * floats the current section's header at the top of the viewport and swaps
	 * it for the next section's on the way past. A grouped or inset-grouped
	 * table scrolls its headers away with the rows, so vkQuake's inset-grouped
	 * sheet (ios/shell/ios_settings.m:753) cannot do it and relies on the
	 * SwiftUI bar above the table instead. The header VIEW below is vkQuake's;
	 * the pinning is what plain style adds to it.
	 *
	 * sectionHeaderTopPadding 0: iOS 15 added a gap above every plain header
	 * that reads as a hole in a dark sheet.
	 */
	_table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	_table.dataSource = self;
	_table.delegate = self;
	_table.backgroundColor = UIColor.clearColor;
	_table.separatorColor = [UIColor colorWithWhite:0.22 alpha:1.0];
	_table.sectionHeaderTopPadding = 0.0;
	_table.rowHeight = UITableViewAutomaticDimension;
	_table.estimatedRowHeight = 56;

	for (UIView *v in @[ title, done, _table ]) {
		v.translatesAutoresizingMaskIntoConstraints = NO;
		[self.view addSubview:v];
	}
	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
		[title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
		[done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
		[done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
		[_table.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
		[_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	if (self.scrollToSection.length == 0) {
		return;
	}
	// "Section" scrolls that section to the top; "Section#key" scrolls THAT ROW
	// to the top. A section is not fine-grained enough once it has more rows
	// than a screen: the 3D section's Foveation row (D-105) sits eight rows
	// down, and a section-only scroll photographs Screen Distance instead. The
	// simulator cannot be scrolled by hand, so a row nobody can photograph is a
	// row with no artifact.
	NSString *wantSection = self.scrollToSection;
	NSString *wantKey = nil;
	const NSRange hash = [wantSection rangeOfString:@"#"];
	if (hash.location != NSNotFound) {
		wantKey = [wantSection substringFromIndex:hash.location + 1];
		wantSection = [wantSection substringToIndex:hash.location];
	}
	const NSInteger idx = [_sections indexOfObject:wantSection];
	if (idx == NSNotFound) {
		fprintf(stdout, "openQ4 settings: no section named '%s'\n", wantSection.UTF8String);
		fflush(stdout);
		return;
	}
	NSInteger row = 0;
	if (wantKey.length > 0) {
		NSInteger found = NSNotFound;
		NSArray<NSNumber *> *rows = _rowsBySection[_sections[idx]];
		for (NSInteger r = 0; r < (NSInteger)rows.count; r++) {
			if (strcmp(kSettings[rows[r].intValue].key, wantKey.UTF8String) == 0) {
				found = r;
				break;
			}
		}
		if (found == NSNotFound) {
			fprintf(stdout, "openQ4 settings: no row '%s' in section '%s'\n",
					wantKey.UTF8String, wantSection.UTF8String);
			fflush(stdout);
		} else {
			row = found;
		}
	}
	[_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:idx]
				  atScrollPosition:UITableViewScrollPositionTop
						  animated:NO];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return (NSInteger)_sections.count; }

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)section {
	return (NSInteger)_rowsBySection[_sections[section]].count;
}

/*
 * Which sections carry their own Reset button. Keyed by TITLE, never by index
 * (vkQuake ios/shell/ios_settings.m:1131-1134): the section list is built from
 * the row table, so an index is a number that moves whenever a row moves.
 */
- (BOOL)sectionHasReset:(NSInteger)section {
#if TARGET_OS_VISION
	return [_sections[section] isEqualToString:@"3D"];
#else
	(void)section;
	return NO;
#endif
}

/*
 * A custom header view gets a COMPRESSED height unless heightForHeaderInSection
 * is implemented — vkQuake's first trap (ios_settings.m:1121-1130). 72 pt for a
 * plain title row, 92 pt where the Reset button lives.
 */
- (CGFloat)tableView:(UITableView *)t heightForHeaderInSection:(NSInteger)section {
	return [self sectionHasReset:section] ? 92.0 : 44.0;
}

- (UIView *)tableView:(UITableView *)t viewForHeaderInSection:(NSInteger)section {
	const BOOL withReset = [self sectionHasReset:section];
	OpenQ4SectionHeaderView *hv = [[OpenQ4SectionHeaderView alloc]
		initWithFrame:CGRectMake(0, 0, t.bounds.size.width, withReset ? 92 : 44)];
	// OPAQUE. A plain table's header floats OVER the rows, so a clear one shows
	// the rows sliding under the title — and the opaque fill spans the whole
	// table, not just the frame UIKit hands the header (D-109, see the class).
	hv.table = t;
	hv.logName = _sections[section];

	UILabel *l = [UILabel new];
	// Display only. _sections keeps the English names, because they are the
	// keys OpenQ4_iOS_ShowSettingsSection("Mods") and scrollToSection match
	// against. The 3D section's header reads "3D Settings", which is what
	// the maintainer named the header row.
	l.text = withReset ? OpenQ4_L("3D Settings") : OpenQ4_LS(_sections[section]);
	l.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
	l.textColor = UIColor.whiteColor;
	l.translatesAutoresizingMaskIntoConstraints = NO;
	[hv addSubview:l];

	if (!withReset) {
		[NSLayoutConstraint activateConstraints:@[
			[l.leadingAnchor constraintEqualToAnchor:hv.leadingAnchor constant:20],
			[l.bottomAnchor constraintEqualToAnchor:hv.bottomAnchor constant:-8],
		]];
		return hv;
	}

	// A REAL bordered/tinted pill, not a bare text button: on visionOS a bare
	// one is nearly impossible to gaze-pinch (vkQuake ios_settings.m:1147-1157,
	// and SETTINGS-SPEC-FROM-VKQUAKE.md:31-35).
	UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
	cfg.title = OpenQ4_L("Reset");
	cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 22, 10, 22);
	UIButton *reset = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
	reset.translatesAutoresizingMaskIntoConstraints = NO;
	[reset addTarget:self action:@selector(reset3DTapped)
	   forControlEvents:UIControlEventTouchUpInside];
	[hv addSubview:reset];
	// Anchor the BUTTON (the tallest thing here) with real clearance above the
	// first row and hang the label off its centre — pinning the label instead
	// lets the button overflow onto the row below by however much taller than
	// the text it is (vkQuake's second trap, ios_settings.m:1167-1170).
	[NSLayoutConstraint activateConstraints:@[
		[l.leadingAnchor constraintEqualToAnchor:hv.leadingAnchor constant:20],
		[reset.trailingAnchor constraintEqualToAnchor:hv.trailingAnchor constant:-20],
		[reset.bottomAnchor constraintEqualToAnchor:hv.bottomAnchor constant:-16],
		[reset.topAnchor constraintGreaterThanOrEqualToAnchor:hv.topAnchor constant:8],
		[l.centerYAnchor constraintEqualToAnchor:reset.centerYAnchor],
		[l.trailingAnchor constraintLessThanOrEqualToAnchor:reset.leadingAnchor constant:-12],
	]];
	return hv;
}

- (const openq4Setting_t *)settingAt:(NSIndexPath *)ip {
	const int idx = _rowsBySection[_sections[ip.section]][ip.row].intValue;
	return &kSettings[idx];
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	const openq4Setting_t *st = [self settingAt:ip];
	// Default style, no subtitle: the sheet has no per-row description text at
	// all any more (D-106; vkQuake ios/shell/ios_settings.m:780-787).
	UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
											   reuseIdentifier:nil];
	c.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
	c.textLabel.text = OpenQ4_L(st->label);
	c.textLabel.textColor = UIColor.whiteColor;
	c.selectionStyle = UITableViewCellSelectionStyleNone;
	// The Demos row is one button with two jobs, and which one it is doing is
	// exactly what a recording player needs to see (D-086). It says so in the
	// TITLE now that no row has a caption.
	if ((strcmp(st->key, "recordDemo") == 0) && OpenQ4_iOS_IsRecordingDemo()) {
		c.textLabel.text = OpenQ4_L("Stop Recording");
	}

	const float value = OpenQ4_iOS_SettingFloat(st->key, st->defaultValue);
	NSString *key = [NSString stringWithUTF8String:st->key];

	switch (st->kind) {
		case OPENQ4_ROW_SWITCH: {
			UISwitch *sw = [UISwitch new];
			sw.on = value > 0.5f;
			objc_setAssociatedObject(sw, "openq4.key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[sw addTarget:self action:@selector(switchChanged:)
				forControlEvents:UIControlEventValueChanged];
			c.accessoryView = sw;
			break;
		}
		case OPENQ4_ROW_SLIDER: {
			/*
			 * Slider plus a live readout, LAID OUT WITH CONSTRAINTS IN THE
			 * CONTENT VIEW — not as a fixed-size accessoryView (D-106, copied
			 * from vkQuake ios/shell/ios_settings.m:909-983, including its
			 * width constants and priority scheme).
			 *
			 * The old accessory was a rigid 210 pt box. A rigid box is why
			 * the maintainer's 0.1.0.61 verdict was "there's little room for sliders to
			 * be precise": the cell gives the accessory exactly what it asks
			 * for, so the slider could never grow into a wider sheet, and on a
			 * narrow one it crowded the title instead. Now the slider takes the
			 * width that is going (up to slMax), gives it back down to slMin
			 * before the title shrinks, and the readout keeps a fixed column.
			 */
#if TARGET_OS_VISION
			const CGFloat valW = 84, slMin = 170, slMax = 360, gap = 10, valFont = 16;
#else
			const CGFloat valW = 58, slMin = 120, slMax = 260, gap = 8, valFont = 14;
#endif
			UIView  *cv = c.contentView;
			UILabel *title = [UILabel new];
			title.text = c.textLabel.text;
			title.font = c.textLabel.font;
			title.textColor = c.textLabel.textColor;
			title.adjustsFontSizeToFitWidth = YES;   // shrink before truncating
			title.minimumScaleFactor = 0.7;
			title.lineBreakMode = NSLineBreakByTruncatingTail;
			c.textLabel.text = nil;  // the constrained title replaces the stock one

			UISlider *sl = [UISlider new];
			sl.minimumValue = st->minValue;
			sl.maximumValue = st->maxValue;
			sl.value = value;
			sl.minimumTrackTintColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
			UILabel *readout = [UILabel new];
			readout.font = [UIFont monospacedDigitSystemFontOfSize:valFont
															weight:UIFontWeightSemibold];
			readout.textColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
			readout.textAlignment = NSTextAlignmentRight;
			readout.text = OpenQ4_FormatSettingValue(st, value);

			objc_setAssociatedObject(sl, "openq4.key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			objc_setAssociatedObject(sl, "openq4.readout", readout, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			objc_setAssociatedObject(sl, "openq4.setting",
				[NSValue valueWithPointer:st], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[sl addTarget:self action:@selector(sliderChanged:)
				forControlEvents:UIControlEventValueChanged];

			for (UIView *sub in @[ title, sl, readout ]) {
				sub.translatesAutoresizingMaskIntoConstraints = NO;
				[cv addSubview:sub];
			}
			// The title holds its natural width but yields it under pressure:
			// the slider's slMin floor wins the argument.
			[title setContentHuggingPriority:UILayoutPriorityDefaultHigh + 1
									 forAxis:UILayoutConstraintAxisHorizontal];
			[title setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
												   forAxis:UILayoutConstraintAxisHorizontal];
			NSLayoutConstraint *slWide = [sl.widthAnchor constraintEqualToConstant:slMax];
			slWide.priority = UILayoutPriorityDefaultHigh;   // honoured when there is room
			NSLayoutConstraint *slBottom =
				[sl.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-6];
			slBottom.priority = UILayoutPriorityRequired - 1; // never fight UIKit's sizing pass
			[NSLayoutConstraint activateConstraints:@[
				[title.leadingAnchor constraintEqualToAnchor:cv.layoutMarginsGuide.leadingAnchor],
				[sl.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
															  constant:gap + 4],
				[sl.trailingAnchor constraintEqualToAnchor:readout.leadingAnchor constant:-gap],
				[sl.widthAnchor constraintGreaterThanOrEqualToConstant:slMin],
				[sl.widthAnchor constraintLessThanOrEqualToConstant:slMax],
				slWide,
				[readout.trailingAnchor constraintEqualToAnchor:cv.layoutMarginsGuide.trailingAnchor],
				[readout.widthAnchor constraintEqualToConstant:valW],
				[sl.topAnchor constraintEqualToAnchor:cv.topAnchor constant:6],
				slBottom,
				[sl.heightAnchor constraintGreaterThanOrEqualToConstant:30],
				[title.centerYAnchor constraintEqualToAnchor:sl.centerYAnchor],
				[readout.centerYAnchor constraintEqualToAnchor:sl.centerYAnchor],
				[title.topAnchor constraintGreaterThanOrEqualToAnchor:cv.topAnchor constant:4],
				[title.bottomAnchor constraintLessThanOrEqualToAnchor:cv.bottomAnchor constant:-4],
			]];
			break;
		}
		case OPENQ4_ROW_SEG: {
			NSArray<NSString *> *segs = OpenQ4_SegTitles(st->key);
			UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:segs];
			int idx = (int)lroundf(value);
			// Clamp before assigning: a stored index from an older build with
			// more segments is otherwise a silent out-of-range assignment.
			seg.selectedSegmentIndex =
				(idx >= 0 && idx < (int)seg.numberOfSegments) ? idx : (int)st->defaultValue;
			objc_setAssociatedObject(seg, "openq4.key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[seg addTarget:self action:@selector(segChanged:)
				forControlEvents:UIControlEventValueChanged];
			c.accessoryView = seg;
			break;
		}
		case OPENQ4_ROW_CHOICE: {
			// The parent row shows only the current choice. The explanations
			// live in the submenu, next to the option they describe, where they
			// are actually useful — five sentences stacked here would bury the
			// rest of the section.
			const int idx = (int)value;
			NSArray<NSString *> *titles = OpenQ4_ChoiceTitles(st->key);
			UILabel *cur = [UILabel new];
			cur.text = (idx >= 0 && idx < (int)titles.count) ? titles[idx] : @"-";
			cur.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
			cur.textColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
			[cur sizeToFit];
			c.accessoryView = cur;
			c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			c.selectionStyle = UITableViewCellSelectionStyleDefault;
			break;
		}
		case OPENQ4_ROW_BUTTON: {
			c.textLabel.textColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
			c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			c.selectionStyle = UITableViewCellSelectionStyleDefault;
			break;
		}
		case OPENQ4_ROW_MODS: {
			// Shows the mod that the NEXT launch will use, which is not
			// necessarily the one running now — that is the whole point of the
			// row, so the sentence under it says so.
			UILabel *cur = [UILabel new];
			cur.text = OpenQ4_iOS_ActiveModDisplayName();
			cur.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
			cur.textColor = [UIColor colorWithRed:0.62 green:0.80 blue:0.20 alpha:1.0];
			[cur sizeToFit];
			c.accessoryView = cur;
			c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			c.selectionStyle = UITableViewCellSelectionStyleDefault;
			break;
		}
		case OPENQ4_ROW_TEXT: {
			// A server address is typed, not dragged. Autocorrect and
			// autocapitalisation are off because both mangle a hostname, and the
			// URL keyboard puts "." and ":" where the thumbs are.
			UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 210, 30)];
			tf.text = OpenQ4_iOS_SettingString(st->key);
			tf.placeholder = OpenQ4_L("host:port");
			tf.textColor = UIColor.whiteColor;
			tf.textAlignment = NSTextAlignmentRight;
			tf.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
			tf.keyboardType = UIKeyboardTypeURL;
			tf.keyboardAppearance = UIKeyboardAppearanceDark;
			tf.autocorrectionType = UITextAutocorrectionTypeNo;
			tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
			tf.spellCheckingType = UITextSpellCheckingTypeNo;
			tf.returnKeyType = UIReturnKeyDone;
			tf.clearButtonMode = UITextFieldViewModeWhileEditing;
			tf.delegate = self;
			objc_setAssociatedObject(tf, "openq4.key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			c.accessoryView = tf;
			break;
		}
	}
	return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	const openq4Setting_t *st = [self settingAt:ip];
	[t deselectRowAtIndexPath:ip animated:YES];

	if (st->kind == OPENQ4_ROW_BUTTON && strcmp(st->key, "directConnect") == 0) {
		// Dismiss either way: with an address, because the connect happens
		// behind the sheet and the player wants to watch it; without one,
		// because leaving the sheet up with no feedback reads as a dead button.
		const bool sent = OpenQ4_iOS_SettingsDirectConnect();
		if (!sent) {
			UIAlertController *a =
				[UIAlertController alertControllerWithTitle:OpenQ4_L("No address")
													message:OpenQ4_L("Type a server address in the row above first.")
											 preferredStyle:UIAlertControllerStyleAlert];
			[a addAction:[UIAlertAction actionWithTitle:OpenQ4_L("OK") style:UIAlertActionStyleDefault handler:nil]];
			[self presentViewController:a animated:YES completion:nil];
			return;
		}
		[self dismissViewControllerAnimated:YES completion:nil];
		return;
	}
	if (st->kind == OPENQ4_ROW_BUTTON && strcmp(st->key, "recordDemo") == 0) {
		const BOOL wasRecording = OpenQ4_iOS_IsRecordingDemo() ? YES : NO;
		// `recordDemo` with no argument auto-names demos/demo%03i.demo under
		// fs_savepath, which on iOS is Documents — already visible in Files.
		OpenQ4_iOS_QueueConsoleCommand(wasRecording ? "stopRecording" : "recordDemo");
		// Dismiss: recording records what you PLAY, and the sheet is not it.
		[self dismissViewControllerAnimated:YES completion:nil];
		return;
	}
#if TARGET_OS_VISION
	if (st->kind == OPENQ4_ROW_BUTTON && strcmp(st->key, "vp3dRecenter") == 0) {
		// Does NOT dismiss: recentring is something a player does two or three
		// times in a row until the screen is where they want it, and a sheet
		// that closes after each one makes that a chore.
		OpenQ4_Immersive_Recenter();
		return;
	}
	if (st->kind == OPENQ4_ROW_BUTTON && strcmp(st->key, "vp3dReset") == 0) {
		NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
		for (int i = 0; i < kSettingCount; i++) {
			if (strcmp(kSettings[i].section, "3D") != 0
					|| kSettings[i].kind == OPENQ4_ROW_BUTTON) {
				continue;
			}
			// Removed, not written back as the default: an absent key IS the
			// default everywhere else in this file, and writing one would pin
			// today's value against a future change to it.
			[d removeObjectForKey:[NSString stringWithFormat:@"openq4.%s", kSettings[i].key]];
		}
		[d synchronize];
		OpenQ4_Apply3DSettings();
		OpenQ4_iOS_SettingsApply();		// the cvar-backed rows in the section
		[t reloadData];
		return;
	}
#endif
	if (st->kind == OPENQ4_ROW_BUTTON && strcmp(st->key, "layoutEdit") == 0) {
		// Dismiss first: the editor is the overlay itself, and it cannot be
		// reached from behind a modal sheet.
		[self dismissViewControllerAnimated:YES completion:^{
			OpenQ4_iOS_TouchBeginLayoutEdit();
		}];
		return;
	}
	if (st->kind == OPENQ4_ROW_MODS) {
		OpenQ4ModsVC *vc = [OpenQ4ModsVC new];
		vc.title = OpenQ4_L(st->label);
		vc.onPicked = ^{ [t reloadRowsAtIndexPaths:@[ ip ] withRowAnimation:UITableViewRowAnimationFade]; };
		[self.navigationController pushViewController:vc animated:YES];
		return;
	}
	if (st->kind == OPENQ4_ROW_CHOICE) {
		OpenQ4ChoiceVC *vc = [OpenQ4ChoiceVC new];
		vc.title = OpenQ4_L(st->label);
		vc.settingKey = [NSString stringWithUTF8String:st->key];
		vc.titles = OpenQ4_ChoiceTitles(st->key);
		vc.details = OpenQ4_ChoiceDetails(st->key);
		vc.selectedIndex = (int)OpenQ4_iOS_SettingFloat(st->key, st->defaultValue);
		vc.onPicked = ^{ [t reloadRowsAtIndexPaths:@[ ip ] withRowAnimation:UITableViewRowAnimationFade]; };
		[self.navigationController pushViewController:vc animated:YES];
	}
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
	[tf resignFirstResponder];
	return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
	NSString *key = objc_getAssociatedObject(tf, "openq4.key");
	if (key == nil) {
		return;
	}
	OpenQ4_iOS_SettingSetString(key.UTF8String, tf.text.UTF8String);
	// Show the trimmed value that was actually stored, not what was typed.
	tf.text = OpenQ4_iOS_SettingString(key.UTF8String);
}

- (void)switchChanged:(UISwitch *)sw {
	NSString *key = objc_getAssociatedObject(sw, "openq4.key");
	OpenQ4_iOS_SettingSetFloat(key.UTF8String, sw.isOn ? 1.0f : 0.0f);
}

- (void)segChanged:(UISegmentedControl *)seg {
	NSString *key = objc_getAssociatedObject(seg, "openq4.key");
	OpenQ4_iOS_SettingSetFloat(key.UTF8String, (float)seg.selectedSegmentIndex);
	// Units re-renders every length readout in the section, so the whole table
	// reloads rather than the one row (vkQuake ios_settings.m:988-999).
	if (strcmp(key.UTF8String, "vp3dUnits") == 0) {
		[_table reloadData];
	}
}

- (void)sliderChanged:(UISlider *)sl {
	NSString *key = objc_getAssociatedObject(sl, "openq4.key");
	OpenQ4_iOS_SettingSetFloat(key.UTF8String, sl.value);
	UILabel *readout = objc_getAssociatedObject(sl, "openq4.readout");
	NSValue *boxed = objc_getAssociatedObject(sl, "openq4.setting");
	if (readout != nil && boxed != nil) {
		readout.text = OpenQ4_FormatSettingValue((const openq4Setting_t *)boxed.pointerValue, sl.value);
	}
}

#if TARGET_OS_VISION
/*
 * The 3D section header's Reset (D-106). It was a row ("Reset 3D Settings")
 * until the maintainer asked for it on the header row; the behaviour is unchanged.
 */
- (void)reset3DTapped {
	OpenQ4_Reset3DSettings();
	[_table reloadData];
}
#endif

- (void)doneTapped {
	[self dismissViewControllerAnimated:YES completion:nil];
}

@end

/*
 * The window the sheet is presented over.
 *
 * `isKeyWindow` alone is not enough on visionOS (D-092): the sim's SwiftUI-
 * hosted window scene reports no key window at all while the engine is running,
 * and every settings entry point then bailed out with "no root view
 * controller" — the sheet simply could not be opened. Key window first (it is
 * the right answer when there is one, and it is what iOS has always used), then
 * any window of the active scene that has a root view controller.
 */
/*
 * The GAME window: the one whose view controller tree holds the engine's host
 * view controller. Preferred over the key window on visionOS (D-102): right
 * after an ORNAMENT button is tapped — which is the only way into this sheet
 * while the ImmersiveSpace is open — the key window can be the ornament's own
 * SwiftUI hosting window, and it has a root view controller, so the key-window
 * test above happily returns it and the sheet is presented over a pill. That
 * is vkQuake's scar (VKQ_iOS_GameWindow, same comment), and it is the shape of
 * "there's no 3D settings to adjust" on hardware when the gear plainly works on
 * a simulator that has no separate ornament window.
 *
 * Matched by CLASS NAME rather than by import: this file is shared with iOS and
 * the visionOS host view controller does not exist in that build.
 */
static bool OpenQ4_VCTreeHasHost(UIViewController *vc, int depth) {
	if (vc == nil || depth > 6) { return false; }
	const char *name = object_getClassName(vc);
	if (name != NULL && strstr(name, "OpenQ4HostViewController") != NULL) { return true; }
	for (UIViewController *child in vc.childViewControllers) {
		if (OpenQ4_VCTreeHasHost(child, depth + 1)) { return true; }
	}
	return OpenQ4_VCTreeHasHost(vc.presentedViewController, depth + 1);
}

static UIWindow *OpenQ4_SettingsHostWindow(void) {
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (!w.hidden && OpenQ4_VCTreeHasHost(w.rootViewController, 0)) { return w; }
		}
	}
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (w.isKeyWindow && w.rootViewController != nil) { return w; }
		}
	}
	UIWindowScene *ws = OpenQ4_iOS_ActiveWindowScene();
	for (UIWindow *w in ws.windows) {
		if (!w.hidden && w.rootViewController != nil) { return w; }
	}
	return nil;
}

/*
 * The settings sheet's navigation controller, or nil when it is not up.
 *
 * Remembered at presentation rather than re-derived (D-092). On visionOS a form
 * sheet gets a window of its OWN, so the moment the sheet is up the key window
 * is the sheet's — whose root view controller presents nothing — and walking
 * from the key window answered "the sheet is not up" while it was plainly on
 * screen. Weak, so it goes nil with the sheet; the walk stays as the fallback
 * for a sheet this process did not present.
 */
static __weak UINavigationController *g_settingsNav = nil;

static UINavigationController *OpenQ4_SettingsNav(void) {
	UINavigationController *remembered = g_settingsNav;
	if (remembered != nil && remembered.viewIfLoaded.window != nil) {
		return remembered;
	}
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			UIViewController *presented = w.rootViewController.presentedViewController;
			if ([presented isKindOfClass:UINavigationController.class]) {
				return (UINavigationController *)presented;
			}
		}
	}
	return nil;
}

void OpenQ4_iOS_ShowSettings(void) {
	OpenQ4_iOS_ShowSettingsSection(NULL);
}

/*
 * Close the sheet from code — the other half of OpenQ4_iOS_ShowSettingsSection,
 * and the one a scripted run needs: `!settings 3D` could open it and nothing
 * could shut it, so every screenshot after that point in a round-3 sim run had
 * the sheet floating over the panel.
 */
void OpenQ4_iOS_HideSettings(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		UINavigationController *nav = OpenQ4_SettingsNav();
		[nav dismissViewControllerAnimated:YES completion:nil];
	});
}

/*
 * Present the sheet and immediately push the mod list. Shares the presentation
 * with the sheet itself rather than duplicating it, so the thing photographed
 * is the thing a player reaches by tapping the row.
 */
void OpenQ4_iOS_ShowModPicker(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		OpenQ4_iOS_ShowSettingsSection("Mods");
		// After the presentation animation, push the list onto the same stack.
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			UINavigationController *presented = OpenQ4_SettingsNav();
			if (presented == nil) {
				fprintf(stdout, "openQ4 settings: the sheet is not up; no mod picker to push\n");
				fflush(stdout);
				return;
			}
			OpenQ4ModsVC *vc = [OpenQ4ModsVC new];
			vc.title = OpenQ4_L("Active Mod");
			[presented pushViewController:vc animated:YES];
		});
	});
}

void OpenQ4_iOS_SettingsBack(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIViewController *top = OpenQ4_SettingsNav().topViewController;
		if (![top isKindOfClass:OpenQ4SubPageVC.class]) {
			fprintf(stdout, "openQ4 settings: no sub-page is up; nothing to go back from\n");
			fflush(stdout);
			return;
		}
		// The button's action, not a private copy of it.
		[(OpenQ4SubPageVC *)top backTapped];
		fprintf(stdout, "openQ4 settings: back — popped to '%s'\n",
				OpenQ4_SettingsNav().topViewController.title.UTF8String ?: "(root)");
		fflush(stdout);
	});
}

void OpenQ4_iOS_SettingsDone(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		UINavigationController *nav = OpenQ4_SettingsNav();
		if (nav == nil) {
			fprintf(stdout, "openQ4 settings: the sheet is not up; nothing to dismiss\n");
			fflush(stdout);
			return;
		}
		UIViewController *top = nav.topViewController;
		if ([top respondsToSelector:@selector(doneTapped)]) {
			[top performSelector:@selector(doneTapped)];
		} else {
			[nav dismissViewControllerAnimated:YES completion:nil];
		}
		fprintf(stdout, "openQ4 settings: done — sheet dismissed\n");
		fflush(stdout);
	});
}

void OpenQ4_iOS_ShowSettingsSection(const char *section) {
	NSString *want = (section != NULL && section[0] != '\0')
		? [NSString stringWithUTF8String:section] : nil;
	dispatch_async(dispatch_get_main_queue(), ^{
		UIViewController *root = OpenQ4_SettingsHostWindow().rootViewController;
		if (root == nil) {
			fprintf(stderr, "openQ4 settings: no root view controller\n");
			return;
		}
		// Present from the TOPMOST presented controller: presenting from a
		// controller that is already presenting something is a silent no-op,
		// which on visionOS reads exactly like "the gear does nothing".
		while (root.presentedViewController != nil
				&& !root.presentedViewController.isBeingDismissed) {
			root = root.presentedViewController;
		}
		OpenQ4SettingsVC *vc = [OpenQ4SettingsVC new];
		vc.scrollToSection = want;
		// Wrapped so the choice submenus can be pushed rather than stacked as
		// modals; the bar is hidden because the sheet draws its own title row.
		UINavigationController *nav =
			[[UINavigationController alloc] initWithRootViewController:vc];
		nav.navigationBar.hidden = YES;
		g_settingsNav = nav;
		nav.modalPresentationStyle = UIModalPresentationFormSheet;
		/*
		 * The stock form-sheet width left the sliders no room to be precise
		 * with — the maintainer's 0.1.0.61 verdict, and vkQuake's own note against the
		 * same line (ios/shell/ios_settings.m:1370-1377, "Match the SwiftUI
		 * sheet's 900pt"). 900 x 760 is vkQuake's number on visionOS; the iOS
		 * lane gets the same treatment at phone scale, where a form sheet is
		 * only a sheet at all on the regular-width devices (a Pro Max in
		 * landscape, an iPad) — a compact-width phone presents full screen and
		 * ignores this.
		 */
#if TARGET_OS_VISION
		nav.preferredContentSize = CGSizeMake(900, 760);
#else
		nav.preferredContentSize = CGSizeMake(760, 620);
#endif
		[root presentViewController:nav animated:YES completion:nil];
	});
}

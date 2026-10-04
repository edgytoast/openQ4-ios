/*
 * openq4_ios_loc.m — see openq4_ios_loc.h.
 *
 * Deliberately NOT driven by the engine's `sys_lang`: onboarding runs before
 * common->Init() exists to ask, and there is no getter for it anyway. The iOS
 * locale is what UIKit already resolved for us, and it is the same NSLocale the
 * engine derives sys_lang from on first run (SDL_GetPreferredLocales), so the
 * shell and the engine agree without either consulting the other.
 */

#import <Foundation/Foundation.h>

#include "openq4_ios_loc.h"

NSString *OpenQ4_LS(NSString *key) {
	if (key.length == 0) {
		return @"";
	}
	// value:key, not value:nil. With a nil/empty value NSBundle returns the key
	// wrapped in the "no translation" markers under NSShowNonLocalizedStrings
	// and, more importantly, gives us no way to distinguish "absent" from
	// "translated to itself". Passing the English text as the value makes the
	// fallback the English text, by construction.
	return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil];
}

NSString *OpenQ4_L(const char *key) {
	if (key == NULL || key[0] == '\0') {
		return @"";
	}
	return OpenQ4_LS([NSString stringWithUTF8String:key]);
}

/*
 * D-114 — the engine's "this save cannot be loaded" dialog and the Load Game
 * list's old-save tag (Session.cpp Session_iOS_ExplainLoadRefusal,
 * Session_menu.cpp). pak0 has no such strings, so they live with the shell's
 * other localised text and the engine asks for them by number. UTF-8 for the
 * engine's TTF text, kept for the life of the process (the engine holds the
 * pointer across a frame; a language change needs a relaunch anyway, as it
 * does for the engine's own sys_lang).
 *
 * 2 carries one %s, the level's title, filled in by the engine.
 * 7 is the Load Game label of the autosave copy restartLevelFromSave keeps.
 */
const char *OpenQ4_iOS_SaveText(int which) {
	static const char *cache[9];
	if (which < 0 || which >= (int)(sizeof(cache) / sizeof(cache[0]))) {
		return "";
	}
	@synchronized ([NSBundle mainBundle]) {
		if (cache[which] == NULL) {
			NSString *s = nil;
			switch (which) {
			case 0: s = OpenQ4_L("Old version"); break;
			case 1: s = OpenQ4_L("Cannot Load Save"); break;
			case 2: s = OpenQ4_L("This save was made by an older version of openQ4 and cannot be restored. "
								 "Start %s again from the beginning, with the weapons and armor you had? "
								 "This replaces the level's autosave; a copy of it is kept in the list."); break;
			case 3: s = OpenQ4_L("This save was made on a different kind of device and cannot be loaded here."); break;
			case 4: s = OpenQ4_L("The level this save needs is not installed."); break;
			case 5: s = OpenQ4_L("This save is damaged or incomplete and cannot be loaded."); break;
			case 6: s = OpenQ4_L("This save was made by an older version of openQ4 and cannot be restored."); break;
			case 7: s = OpenQ4_L("Before restart"); break;
			case 8: s = OpenQ4_L("The level was not restarted: a copy of its autosave could not be kept, so nothing was changed. "
								 "If Load Game already lists nine \"Before restart\" copies of this level, delete one and try again."); break;
			}
			cache[which] = strdup(s != nil ? s.UTF8String : "");
		}
		return cache[which];
	}
}

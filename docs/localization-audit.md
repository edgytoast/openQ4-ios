# Localization audit (2026-09-13, read-only)

**Verdict.** The charter's `#str_` rule is honoured on the engine side by
construction (the demo-menu generator rewrites rects only; the overlay adds no
GUI strings), and the engine already boots in the device language: `sys_lang`
is derived from `SDL_GetPreferredLocales()` (NSLocale) on first run, and pak0
ships english / french / italian / spanish (`strings/*_openq4.lang` is
upstream's own additions file, fully translated). **Every string the PORT adds
is hardcoded English** — ~118 unique, zero `NSLocalizedString`, zero `.lproj`.

**Where.** `ios/shell/openq4_ios_settings.m` (~94: 28 row titles, 17 detail
sentences, 8 section headers, 16 option titles + 16 details, ~17 alerts/chrome);
`ios/shell/openq4_ios_onboarding.m` (~22, the highest-stakes screen — shown
before the engine exists, and it is the install instructions);
`openq4_ios_touch.m` (1, plus **zero accessibility labels** on five icon-only
buttons); `ios/Info.plist` (Bluetooth usage description).

**Recommended shape.** Drive the UIKit shell from the iOS locale (not
`sys_lang`: no getter exists, and onboarding runs before the engine). Four
`.lproj`s (en/fr/it/es — exactly pak0's languages) + `InfoPlist.strings`.
`kSettings` is a C table of `const char *`: keep the literals as keys and wrap
at the two read sites (~6 lines). The `section` field is also a lookup key
(`OpenQ4_iOS_ShowSettingsSection("Mods")`) — localise at display only.
`onboarding.m:132-134` concatenates fragments — make them whole sentences first.

**Reusable verbatim from pak0** (~22): Look/Gyro Sensitivity (`#str_229931`,
`#str_229965`), Invert (`#str_229933`), Brightness (`#str_200148`), Music
Volume (`#str_201006`), Master Volume (`#str_200154`), Off/On (`#str_41121/41120`),
OK/Cancel (`#str_104339/104340`), headers Display/Audio/Multiplayer/Mods/Demos/
Controls/Settings (`#str_229900/229901/200002/200010/41500/200083/200009`).
Engine strings are ALL CAPS and abbreviated for 640x480 — recase.

**Effort.** ~101 strings x 3 languages; ~55 x 3 (prose details + onboarding +
plist) genuinely want a native reader. Slices: (1) infrastructure + 22 reusable
+ InfoPlist, zero translation; (2) onboarding; (3) titles/options (~35, machine
+ review); (4) the 33 prose sentences — defer, English fallback is automatic.

**Strategic note.** About a third of the sheet duplicates rows the engine's own
localised settings menu already has. A touch-scaled front-end onto the engine's
settings registry (as the demo browser now is) would delete that debt rather
than translate it. Recorded as an open question.

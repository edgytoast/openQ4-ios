# Localization map — slice 1

Every non-English string the iOS shell ships, and where it came from. Slice 1
of `docs/localization-audit.md` (D-088) adds **no new translation**: each value
below was copied out of openQ4's own pak0 tables
(`vendor/openQ4/content/baseoq4/pak0/strings/{english,french,italian,spanish}_*.lang`),
which already carry the engine's UI in these four languages.

Engine strings are ALL CAPS and abbreviated for a 640x480 menu. The only
editing applied is recasing for a UIKit sheet, expanding an abbreviation back to
the word it abbreviates, and restoring accents that the caps convention drops
(`DESACTIVE` -> `Désactivé`). Where our row says more than pak0's does, the
"Deviation" column says exactly what was added or lost — that is the list a
native reader should check first in slice 3.

Files: `ios/Resources/{en,fr,it,es}.lproj/Localizable.strings`. Keys are the
English text; anything not listed here falls back to it at runtime.

| Our key | pak0 id | French | Italian | Spanish | Deviation |
|---|---|---|---|---|---|
| `Look Sensitivity (Horizontal)` | `#str_229931` | Sensibilité Regard (Horizontale) | Sensibilità Mira (Orizzontale) | Sensibilidad Mirada (Horizontal) | pak0 abbreviates for 640x480 ("Sensib. Regard"); expanded and the axis added |
| `Look Sensitivity (Vertical)` | `#str_229931` | Sensibilité Regard (Verticale) | Sensibilità Mira (Verticale) | Sensibilidad Mirada (Vertical) | as above |
| `Invert Vertical Look` | `#str_229933` | Inverser Regard | Inverti Mira | Invertir Mirada | pak0 says "Invert Look"; the "Vertical" qualifier is not carried |
| `Gyro Sensitivity (Horizontal)` | `#str_229965` | Sensibilité Gyro (Horizontale) | Sensibilità Giroscopio (Orizzontale) | Sensibilidad Giroscopio (Horizontal) | abbreviation expanded, axis added |
| `Gyro Sensitivity (Vertical)` | `#str_229965` | Sensibilité Gyro (Verticale) | Sensibilità Giroscopio (Verticale) | Sensibilidad Giroscopio (Vertical) | as above |
| `Brightness` | `#str_200148` | Luminosité | Luminosità | Brillo | verbatim |
| `Game Volume` | `#str_200154` | Volume principal | Volume globale | Volumen | pak0's "Master Volume"; ours is the same control under a shorter name |
| `Music Volume` | `#str_201006` | Volume musique | Volume musica | Volumen de Música | verbatim |
| `Off` | `#str_41121` | Désactivé | No | No | recased from ALL CAPS; French accents restored (pak0 caps drop them) |
| `On` | `#str_41120` | Activé | Sì | Sí | recased from ALL CAPS; accents restored |
| `OK` | `#str_104339` | OK | OK | Aceptar | verbatim |
| `Display` | `#str_229900` | Affichage | Schermo | Pantalla | recased |
| `Audio` | `#str_229901` | Audio | Audio | Audio | recased |
| `Multiplayer` | `#str_200002` | Multijoueur | Multigiocatore | Multijugador | recased |
| `Mods` | `#str_200010` | Mods | Mod | Mods | recased; Spanish pak0 has the abbreviation dot "MODS." — dropped |
| `Demos` | `#str_41500` | Démos | Demo | Demos | verbatim |
| `Touch Controls` | `#str_200083` | Commandes | Comandi | Controles | pak0's "Controls", recased; the "Touch" qualifier is not carried |
| `Settings` | `#str_200009` | Paramètres | Impostazioni | Ajustes | recased |
| `openQ4 Settings` | `#str_200009` | Paramètres openQ4 | Impostazioni openQ4 | Ajustes openQ4 | recased, with the product name appended |

## Not carried into slice 1

- `#str_104340` (Cancel — Annuler / Annulla / Cancelar). The shell has no
  Cancel button; the key would be dead weight in the table.
- Everything else in the sheet, onboarding and the touch overlay: ~100 strings
  with no pak0 equivalent, listed in `en.lproj/Localizable.strings` and shown in
  English in every language. Slices 2-4 of the audit.
- `InfoPlist.strings`: the Bluetooth purpose string is English in all four
  locales, deliberately (see the file's own header).


## Slices 2-3 (D-112, 2026-10-03)

Every key the shell reads now exists in all four tables, checked by
`scripts/check-localization.py` (keys collected from the code: `OpenQ4_L` call
sites, the `kSettings` table, SwiftUI and App Intents literals; fails on a
missing key, an `en` value that is not its key, a format-specifier mismatch, or
a dead key). The per-entry comment in each `.lproj` names the source:
`#str_NNNNN` (pak0, as slice 1), `#str_NNNNN + MT` (built around the pak0 term),
or `MT` (machine translation using pak0's words for the same concepts).

What a native reader should check first, in order:

1. **The onboarding screen** — it is the install instructions and the first
   thing a player reads. Especially the unpatched-install sentence and the
   interrupted-import note.
2. **Option sentences under pushed pickers** (render resolution, other-app
   audio, haptics, gyro aim, panel resolution). Slice 4 "prose" in the audit's
   terms, translated here anyway so a picker is never half English; flagged MT.
3. **Deviations from slice 1**: `Touch Controls` now carries its qualifier
   (`Commandes tactiles` / `Comandi touch` / `Controles táctiles`) — it names
   both the section and the Auto/On/Off row, next to pad and gyro rows, so the
   bare pak0 "Controls" was ambiguous.
4. **Terms pak0 has no word for**: Haptics (`Retour haptique` / `Feedback
   aptico` / `Respuesta háptica`), Stereo Depth, Surroundings Dimming, Extra
   Master Server.
5. **Format strings**: `%d`/`%@`/`%.1f` order is identical in every language
   (the check enforces it); French uses `Go` for GB and a space before `:`.

Known limits: App Shortcut *phrases* ("Play Quake 4 in openQ4") are English
only — they localise through a separate `AppShortcuts.strings` this round did
not add. The 3D option sentence "The default. 120 fps measured here…"
was translated without the name.

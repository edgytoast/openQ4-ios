# Mods on openQ4 for iOS / visionOS

**Data-only mods work. Mods that ship their own native game module can never
work on iOS — see [Native-module mods](#native-module-mods-never-on-ios).**

Verified on the lane-2 simulator (iPhone Air, iOS 27.0) on 2026-09-10 with a
purpose-built data-only mod, then on lane 1 (iPhone 17 Pro Max) the same day
with the **Settings > Mods** picker that ships the feature (D-080).
Evidence: `artifacts/sim/mods/` and `artifacts/sim/mods/picker/`.

**Short version for a player:** copy the mod folder into the openQ4 folder in
Files, open **Settings > Mods > Active Mod**, pick it, and restart openQ4.

---

## What the engine looks for

openQ4 discovers mods itself; the port adds nothing. From
`vendor/openQ4/src/framework/FileSystem.cpp`:

- A mod is a **directory** next to `q4base`/`baseoq4` under one of
  `fs_cdpath`, `fs_basepath`, `fs_savepath`. On iOS both `fs_savepath` and
  `fs_homepath` are the app's **Documents** directory — the one Files.app
  shows — so a mod dropped in Files lands in the right place with no extra
  step. (`fs_basepath`/`fs_cdpath` are the read-only app bundle.)
- The directory must contain **`mod.json`** (`OPENQ4_MOD_MANIFEST_FILENAME`).
  Without it the directory is not a mod and is ignored.
- Everything else in the directory is ordinary game data: `.pk4` archives and
  loose files, exactly as on desktop.

### mod.json

`FS_ParseModManifest` requires **all six** of these string fields. A missing
field, a trailing comma, or anything after the closing `}` makes the manifest
invalid and the mod is skipped with a `Skipping mod '<dir>': <reason>` warning.
Unknown keys are tolerated and ignored.

```json
{
  "name": "Strogghammer",
  "version": "1.0.0",
  "releaseDate": "2026-09-10",
  "website": "https://example.invalid/",
  "author": "your name",
  "requiredopenQ4Version": "0.1.0"
}
```

- `name` is what the Mods menu shows; `version` is shown beside it.
- `requiredopenQ4Version` must be `major.minor.patch` and is a **minimum**: the
  mod is skipped if the engine is older. This build's engine version is
  `OPENQ4_VERSION_BASE` (currently `0.1.010`, i.e. 0.1.10), so `"0.1.0"` is a
  safe floor.

### Layout

```
Documents/                 <- what Files.app shows for openQ4
  q4base/                  <- your retail Quake 4 data
  mymod/                   <- the mod directory (the app lowercases the name)
    mod.json
    zmymod_pak01.pk4
```

Files inside a `.pk4` override the base game **by path**: if your pk4 contains
`def/weapons/blaster.def`, the mod's copy replaces the retail file wholesale.
Decl overriding works because the mod's search path is inserted ahead of
`q4base`, and the *first* definition of a decl name wins
(`idDeclFile::LoadAndParse` skips a redefinition and warns). So **override the
whole file, do not add a second file that redeclares the same decl** — the
second one loses.

---

## Case sensitivity (the app handles it now)

The iOS container filesystem is **case-sensitive** where Windows and macOS are
not, and two separate rules used to bite. The first is now handled for you.

1. **The mod directory name must be entirely lowercase.** `ListMods` deletes
   every candidate directory for which `idStr::HasUpper()` is true, so a folder
   named `MyMod` or `StroggHammer` never appears in the Mods menu — with no
   warning at all.

   **The app now fixes this on every launch.** Before the engine starts, every
   directory under Documents that contains a `mod.json` is lowercased, along
   with everything inside it, and each rename is printed:

   ```
   openQ4 mods: renamed mod folder 'StroggHammer' -> 'strogghammer'
   openQ4 mods: renamed 'Def' -> 'def'
   openQ4 mods: renamed 'Mod.json' -> 'mod.json'
   openQ4 mods: normalised 1 mod folder(s), 5 name(s) lowercased, 0 conflict(s)
   ```

   Nothing is ever deleted: if the lowercase name is already taken by something
   else, the rename is refused and said out loud. Directories WITHOUT a
   `mod.json` — `q4base` above all — are not touched at all, and neither are
   the files the engine writes into a mod folder itself (`openQ4Config.cfg`,
   `savegames/`, `screenshots/`, `logs/`, `generated/`), which it would
   otherwise rewrite in mixed case on every exit for the normaliser to rename
   again on every launch. Dotfiles (`.DS_Store`) are skipped too.

2. Paths **inside** pk4s must match the case the engine asks for, which is
   lowercase. Windows-authored mods routinely have `Def/Weapons/Blaster.def`;
   nothing outside the archive can fix that, so repack the pk4 with lowercase
   paths.

Pak *extension* case is fine either way: `zMyMod_Pak01.PK4` loaded correctly
before the normaliser existed.

---

## How to install and run a mod

1. In Files.app, open **On My iPhone → openQ4** and copy the mod directory in
   beside `q4base`. Mixed case is fine; the app lowercases it on the next
   launch.
2. Confirm `mod.json` sits directly inside it and has all six fields.
3. Launch openQ4, open the settings sheet (the gear, top left), and go to
   **Mods → Active Mod**.
4. Pick the mod. The sheet says *"Takes effect on next launch"*, because it
   does — see below.
5. **Quit openQ4 and open it again.** The mod is now active.

To go back to the base game, pick **None (base game)** and relaunch.

The list shows only mods the engine would also accept: a `mod.json` that is not
valid JSON, or that is missing one of the six required string fields, is left
out and the reason is printed to the log (`openQ4 mods: skipping 'x': …`). A
mod that is selected and then deleted from Files shows as *"(missing)"* in the
row, and the next launch quietly starts the base game and says so in the log
rather than failing.

## DDS / BC7 texture-replacement packs (supported, not tested by us)

openQ4 accepts the same texture-replacement packs on iOS and visionOS as on
the desktop, and both devices report BC7/BPTC support. We do not ship, host,
or test one: the maintainer's verdict from a desktop 5090 is that the Quake 4 Hi Def
packs "make map loading much longer with not much visual improvement". If you
want one anyway:

- **Shape it as a mod.** A folder in Files beside `q4base` with a `mod.json`
  and a `.pk4` containing the pack's `dds/` tree (`dds/textures/…/name.dds`,
  mirroring the asset it replaces). A pk4 rather than loose `.dds` files,
  because the engine skips a loose `.dds` that is older than its source
  texture, and pk4 entries carry no timestamps to compare. Then pick the mod in
  **Settings → Mods → Active Mod** and relaunch, as for any other mod.
- **Leave `image_usePrecompressedTextures` at 1** (the default). `2` is
  BC7-only and discards the retail precompressed textures as well.
- **Expect longer loads and more memory.** The engine uploads every texture a
  level references at load, with no streaming and no cap. A 2K BC7 replacement
  is roughly 30x the size of the stock 512² DXT1 texture it replaces, and the
  iPhone has far less headroom than the Vision Pro. If a map fails to load
  with a pack active, that is why.
- **Diagnostics** in the console: `image_showPrecompressedTextures 1` then
  `reloadImages all` prints which file each image came from; `listImages`
  totals resident texture memory. Normal maps encoded for older openQ4 builds
  (`bc7enc -r2a`) render flat and must be re-encoded.

The full research behind this section is in `work/texture-packs-RESEARCH.md`.

---

## Known limitations on iOS

### `fs_game` alone drops openQ4's own runtime — the picker sets `fs_game_base` too

This one is invisible and it bit us. **openQ4 runs with `fs_game baseoq4` by
default**: its replacement UI, TTF fonts, GLSL, strings, bot files,
`openq4_defaults.cfg` and this port's `openq4_profile_ios.cfg` all live in the
gamedir `baseoq4`, and retail `q4base` is the BASE_GAMEDIR underneath it. So
`fs_game mymod` **replaces** baseoq4 rather than adding to it, and the search
path becomes `mymod → q4base` with every one of those gone.

The engine does not complain. Its baseoq4 MD5 gate is skipped precisely when
neither `fs_game` nor `fs_game_base` is `baseoq4`, and retail q4base ships a
`default.cfg` of its own — so the game boots, plays, and quietly uses the 2005
UI with none of the port's settings. Measured on lane 1: a mod launch execed
`default.cfg` alone where a base launch execs
`default.cfg + openq4_defaults.cfg + openq4_profile_ios.cfg`. Retail's
`default.cfg` also sets `si_gameType "DM"`, so the module loader picked
`game_mp` and the following `map` had to swap the whole game module.

**The fix is `fs_game_base`**, which is exactly the slot for it:
`FileSystem::Startup` sets up BASE_GAMEDIR, then `fs_game_base`, then
`fs_game`, so the mod still wins every file it overrides. The picker therefore
launches with:

```
+set fs_game <dir> +set fs_game_base baseoq4
```

With both set, the port's configs come back and the module loader picks
`game_sp` on the first launch of a fresh mod, with no reload at all. **If you
drive `fs_game` by hand from a command line, set `fs_game_base baseoq4` with
it.** Upstream's own Mods menu (`Session_menu.cpp`, `loadMod`) sets `fs_game`
alone and has the same hole — worth filing.

### Why the choice takes effect on the next launch

`fs_game` is `CVAR_INIT` and `FileSystem::Init` builds the search paths inside
`common->Init()`. There is exactly one moment in the process's life when a mod
can be chosen, and it is before the engine exists — so the shell stores the
choice in NSUserDefaults and appends `+set fs_game <dir> +set fs_game_base
baseoq4` to the arguments it hands `common->Init()` on the next cold launch.
(Overlay patch `0002-ios-display-link-main-loop` merges the shell's arguments
after the process's own argv, so a shipped app with no command line still gets
them, and NSUserDefaults wins over a development `+set` — the same "the setting
is the authority" rule that decides the SMAA default.)

The in-game **Mods** page in the engine's own menu still cannot switch mods: it
does `fs_game` + `reloadEngine`, and **`reloadEngine` is still fatal**, checked
again on this build after D-078 fixed the game-module swap:

```
============= ReloadEngine start =============
idRenderSystem::Shutdown()
[mvk-info] Destroying VkInstance for Vulkan version 1.3.334 ...
openQ4: fatal signal SIGTRAP (5), exiting without unsafe engine shutdown
openQ4: last renderer startup phase: unavailable (module renderer)
```

(`artifacts/sim/mods/picker/run-reloadengine-still-fatal.log`.) Use
**Settings > Mods**, which needs none of that.

`fs_game` is not archived, so typing `fs_game mymod` at the console is refused
("write protected"); the `set` command forces it through but changes nothing
until the filesystem restarts. Putting `set fs_game mymod` in
`openQ4Config.cfg` also does nothing — the config is exec'd well after
`FileSystem::Init`.

### The mod gets its own config and savegames

With a mod active the engine's write gamedir is the mod's folder, so
`openQ4Config.cfg`, `savegames/` and `screenshots/` live in
`Documents/<mod>/`, not `Documents/baseoq4/`. That is desktop behaviour, not an
iOS quirk: a campaign save made under a mod is not offered when you switch back
to the base game, and vice versa. The iOS settings sheet is unaffected — it
stores in NSUserDefaults and pushes into cvars after `common->Init()`, so
sensitivity, volume and the rest carry across mods.

### Native-module mods: never, on iOS

A mod that ships its own compiled game code — `gamex86.dll`, `game.so`,
`game_sp.dylib`, anything of that shape — **cannot ever run on iOS or
visionOS.** iOS will not execute a code page that was not signed into the app
bundle at build time, and a sideloaded app has no JIT and no ability to load
foreign binaries. This is an Apple platform rule, not a missing feature, and
there is no workaround, entitlement, or jailbreak-free trick that changes it.

If a mod's readme says it replaces the game DLL, it will not work here. Its
maps, textures, sounds, GUIs and def files may still load if you extract the
data-only parts, but any behaviour that lived in its code will not.

---

## Reference mod used for verification

`artifacts/sim/mods/strogghammer/` — a data-only mod built from retail data for
this round. It contains `mod.json` and one pk4 with three kinds of override:

| File | Kind | Change |
|------|------|--------|
| `def/weapons/blaster.def` | entityDef override | `fireRate .15 → .04`, `spread .2 → 0`, `flashColor` blue → red, `flashRadius 200 → 600`, `inv_name` → literal, plus a marker key `strogghammer_mod 1` |
| `materials/strogghammer.mtr` | **new** material decls | `gfx/guis/hud/strogghammer_banner`, `gfx/guis/hud/strogghammer_rule` |
| `guis/loading/generic.gui`, `guis/hud.gui` | GUI overrides | a banner drawn with those materials |

GUI gotcha worth knowing: windowDefs draw in **declaration order**, so anything
you add must be declared *after* the full-screen background windowDef or it is
painted over. The first attempt inserted the banner near the top of the file
and was invisible; moving it to the end of the `Desktop` block fixed it.

### Evidence

| Artifact | Shows |
|----------|-------|
| `mod-loadscreen.png` | `STROGGHAMMER MOD ACTIVE` banner over the real SP loadscreen of `game/mcc_2` |
| `base-loadscreen.png` | same map, no `fs_game` — no banner |
| `mod-printEntityDef.txt` | `weapon_blaster` with `fireRate ".04"`, `spread "0"`, `strogghammer_mod "1"`, sourced from `def/weapons/blaster.def:50` |
| `base-printEntityDef.txt` | the same decl back at stock `.15` / `.2`, no marker key |
| `mod-printMaterial.txt` | the mod's new material parsed by the engine |
| `mod-in-map.png` | in `game/mcc_2` with the mod loaded |
| `mod-engine.log`, `base-engine.log` | full engine logs for both runs |
| `reloadengine-fatal.log` | `reloadEngine` taking a SIGTRAP on iOS |

### Evidence for the picker (D-080), `artifacts/sim/mods/picker/`

| Artifact | Shows |
|----------|-------|
| `01-settings-row.png` | Settings > Mods > Active Mod, reading `Strogghammer 1.0.0` |
| `02-mod-picker-list.png` | the picker list: None (base game) + the mod, checkmark on the selection |
| `03-mod-active-mcc_1.png` | `STROGGHAMMER MOD ACTIVE` over the HUD in `game/mcc_1` after a relaunch |
| `04-base-mcc_1.png` | the same map and framing with None selected — no banner |
| `mod-printEntityDef.txt` / `base-printEntityDef.txt` | `fireRate ".04"` + `strogghammer_mod "1"` versus stock `.15` |
| `run-normalise-and-pick.log` | `StroggHammer/` and its four entries lowercased on launch |
| `run-fs_game-alone-no-baseoq4.log` | `fs_game` alone: one `execing default.cfg`, `game_mp`, a full `ReloadGameModule` |
| `run-fs_game_base-fresh-mod-config.log` | with `fs_game_base baseoq4`: all three configs exec'd, `game_sp`, no reload |
| `run-mod-active.log` / `run-base.log` | the two launches the screenshots came from |
| `run-reloadengine-still-fatal.log` | `reloadEngine` still SIGTRAPs after D-078 |

Reproduce (lane 2; the console bridge on :8774 may be held by another
session, so this drives everything through startup arguments instead):

```sh
UDID=$(xcrun simctl list devices available | sed -n 's/.*iPhone Air (\([0-9A-F-]*\)).*/\1/p' | head -1)   # any iOS 27 simulator
C=$(xcrun simctl get_app_container "$UDID" com.rebelancap.openq4 data)
cp -R artifacts/sim/mods/strogghammer "$C/Documents/"
xcrun simctl launch "$UDID" com.rebelancap.openq4 \
    +set fs_game strogghammer +set si_gameType singleplayer \
    +map game/mcc_2 +printEntityDef weapon_blaster
```

`+set si_gameType singleplayer` is required: without it a mod directory with no
archived config makes the loader pick `game_mp`, and the following `map` then
schedules the fatal module reload.

# Installing openQ4 on Apple Vision Pro

This is an iOS and visionOS port of [openQ4](https://github.com/themuffinator/openQ4), the open-source replacement for the Quake 4 engine and game binaries, running its Vulkan renderer natively on Metal through MoltenVK. On Apple Vision Pro it runs in a resizable 2D window, and a stereoscopic 3D mode puts the game on a world-locked screen in your room.

## What you need

- Apple Vision Pro on visionOS 2.5 or later
- Your own copy of Quake 4, patched to 1.4.2 (the Steam and GOG releases already are; a disc install needs the official 1.4.2 patch first)
- About 3.5 GB free on the headset: about 650 MB for the app and about 2.7 GB for your game data
- A game controller. The 2D window is played with one (the touch layer works with pinch when no controller is paired), and in 3D the in-game menu is display-only, so use the controller or go back to 2D to change settings.
- For the prebuilt app: SideStore on the headset, installed with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos)
- To build from source: see [Build from source](#build-from-source)

## Your game files

openQ4 ships with no Quake 4 game content. Besides the engine and game code, the app carries openQ4's own `baseoq4` runtime packs, which are part of the openQ4 project; they are why the app is large. You must own Quake 4 and supply your own retail `q4base` folder, patched to 1.4.2.

1. Open openQ4. On first launch, tap **Choose Quake 4 Folder** and pick your `q4base` (or the Quake 4 folder that contains it).
2. The app checks every pack against openQ4's table of official 1.4.2 checksums before copying anything, tells you what is missing or unpatched, and fixes upper/lower-case file names from a Windows install. Mission-pack maps and language packs are picked up if present.

You can also copy `q4base` into *On My Apple Vision Pro → openQ4* with the Files app, then tap **I Added Files — Check Again**.

Data-only mods (`.pk4` packs with a `mod.json`, or a plain mod folder) go next to `q4base`; choose one in *Settings → Mods → Active Mod*. Mods that ship their own compiled game code can't run. See [Mods](README.md#mods) in the README.

## Install the prebuilt app

1. Install SideStore on the headset with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos). SideStore and AltStore can't be installed on visionOS the usual way; iloader is what gets SideStore there.
2. In SideStore, go to *Sources → +* and paste either source, then install openQ4. "Quake ports" carries just the Quake family; "All ports" carries every rebelancap port.

   ```
   https://raw.githubusercontent.com/rebelancap/quake-ports/main/apps-visionos.json
   https://raw.githubusercontent.com/rebelancap/all-ports/main/apps-visionos.json
   ```

   openQ4 updates from the source when new versions ship.

To install by hand instead, download `openq4-*-visionOS.ipa` from the [latest release](https://github.com/rebelancap/openQ4-ios/releases/latest) and install it through SideStore or AltStore.

## Build from source

You need a Mac with Apple silicon and Xcode 27 with the visionOS platform installed, Homebrew's `xcodegen` and `cmake` (`brew install xcodegen cmake`), about 10 GB of free disk, and network access on the first build. Device builds need an Apple Developer account.

From a checkout of this repo:

```sh
cp scripts/signing.local.sh.example scripts/signing.local.sh   # then set OPENQ4_TEAM_ID to your team ID
scripts/build.sh visionos            # signed Apple Vision Pro build
scripts/build.sh visionos --public   # or: the release flavour (developer console compiled out)
```

`scripts/build.sh` runs every step in order: it fetches the pinned openQ4 and openQ4-game pair (`UPSTREAM.pin`) into `vendor/`, builds openQ4's `baseoq4` runtime packs with upstream's own pack tools, applies this port's patches, builds SDL3, OpenAL Soft and MoltenVK, then the engine, the game modules and the app. Use the `visionos-sim` lane for an unsigned Vision Pro Simulator build. Each step and the simulator test script are described in [Building from source](README.md#building-from-source).

## Notes

- **3D mode:** tap **3D** in the ornament under the window. Screen size, distance, height, stereo depth, crosshair distance and room dimming are in *3D Settings* (the gear). Tap **Exit** to return to the window.
- Multiplayer is openQ4 to openQ4 only (LAN, direct connect, and a server browser); it can't join retail Quake 4 servers. The Arena Campaign plays against bots offline.
- Apps sideloaded with a free Apple account expire after 7 days (paid developer accounts last a year). SideStore refreshes them in the background; if the app stops launching, open SideStore and let it re-sign.
- **Licences:** the engine, this port's code and its build scripts are GPLv3. The game modules come from [openQ4-game](https://github.com/themuffinator/openQ4-game), are derived from the Quake 4 SDK and remain under id Software's Quake 4 SDK EULA (non-commercial; Quake 4 required). See [`NOTICE.md`](NOTICE.md).
- This project is not affiliated with, endorsed by, or sponsored by id Software, Raven Software, Bethesda, or ZeniMax Media.

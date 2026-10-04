# Notice — what is licensed how

This repository is an iOS and visionOS port of
[openQ4](https://github.com/themuffinator/openQ4). It has the same two-part
licence split as upstream, and mirrors upstream's own distribution posture:
free sideload builds only — never sold, never on the App Store.

## The engine and this port's own code — GPLv3

The openQ4 engine, the overlay patches in `overlay/`, the iOS/visionOS app
shell in `ios/`, and the build scripts in `scripts/` are licensed under the
GNU General Public License v3.0 — see [`LICENSE`](LICENSE).

In upstream's words: "openQ4 engine code is licensed under the GNU General
Public License v3.0. ... Files retaining Doom 3 or Doom 3 BFG Edition headers
also retain their upstream notices and are accompanied by the corresponding
published Additional Terms" — those Additional Terms are in
[`licenses/openQ4/`](licenses/openQ4/).

## The game modules — Quake 4 SDK EULA, NOT the GPL

The single-player and multiplayer game modules (`game-sp`, `game-mp`) are
built from [openQ4-game](https://github.com/themuffinator/openQ4-game) and the
patches in `overlay/patches-game/`. In upstream's words: "The game-library code
in openQ4-game is derived from the Quake 4 SDK and remains subject to id
Software's SDK EULA." openQ4-game's own licence file states it is "licensed
under the QUAKE 4 Software Development Kit Limited Use License Agreement (EULA),
not the GNU GPL", and summarises the EULA's key points as: a limited,
non-exclusive licence from id Software; non-commercial distribution and use
limits unless separately authorised by id Software in writing; the full
version of QUAKE 4 is required to operate the SDK/game libraries; provided
"AS IS". The authoritative text is
[`licenses/openQ4-game/EULA.Development Kit.rtf`](licenses/openQ4-game/), with
openQ4-game's licence file beside it.

The patches in `overlay/patches-game/` modify that SDK-derived code and are
offered on the same terms as the code they modify.

## Game data

No Quake 4 game data is included in this repository or in any build of the
app. You supply your own 1.4.2-patched retail `q4base`. "Quake 4 assets remain
the property of id Software and ZeniMax Media." The app does ship openQ4's own
`baseoq4` runtime packs, which are part of the openQ4 engine project.

## Third-party components

The app statically links the following; each licence's full text is in
[`licenses/`](licenses/README.md), and the same directory is copied into every
app bundle.

| Component | Licence |
|---|---|
| SDL 3.4.10 | zlib |
| OpenAL Soft 1.25.2 | LGPL 2.1 (corresponding source: `licenses/openal-soft/SOURCE.md`) |
| MoltenVK 1.4.1, incl. SPIRV-Cross and cereal | Apache 2.0 (cereal: BSD 3-Clause) |
| volk, Vulkan Memory Allocator | MIT |
| Khronos Vulkan headers | Apache 2.0 OR MIT |
| stb_vorbis | MIT OR public domain |
| GLEW (GL-free build) | Modified BSD |

## Not affiliated

Like upstream: this project is independent and is not affiliated with,
endorsed by, or sponsored by id Software, Raven Software, Bethesda, or ZeniMax
Media.

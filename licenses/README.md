# Licences

The full text of every licence that applies to this app, one directory per
component. `NOTICE.md` at the repository root explains which part of the app
each one covers; this directory is also copied verbatim into the app bundle
(`openQ4.app/licenses/`), so every installed copy carries it.

Everything here except the two files listed below is copied, unmodified, from
the component's own source at the pinned version by `scripts/gen-licenses.sh`
(`scripts/gen-licenses.sh --check` proves it is current).

| Directory | Component | Licence |
|---|---|---|
| `openQ4/` | openQ4 engine | GNU GPL v3, plus the Doom 3 / Doom 3 BFG Additional Terms for files that keep those headers |
| `openQ4-game/` | openQ4-game (the SP and MP game modules) | Quake 4 SDK Limited Use License Agreement (EULA) — **not** the GPL |
| `SDL3/` | SDL 3.4.10 | zlib |
| `openal-soft/` | OpenAL Soft 1.25.2 (+ pffft, fmt, gsl, BSD-3 portions) | LGPL 2.1 — see `SOURCE.md` |
| `MoltenVK/` | MoltenVK 1.4.1 (static), including SPIRV-Cross | Apache 2.0 |
| `cereal/` | cereal (compiled into the static MoltenVK library) | BSD 3-Clause |
| `volk/` | volk | MIT |
| `VulkanMemoryAllocator/` | Vulkan Memory Allocator | MIT |
| `Vulkan-Headers/` | Khronos Vulkan headers | Apache 2.0 OR MIT |
| `stb_vorbis/` | stb_vorbis 1.22 | MIT OR public domain |
| `GLEW/` | GLEW (GL-free dedicated build) | Modified BSD |

## Texts not taken from a vendored tree

- `MoltenVK/LICENSE` — the project vendors only MoltenVK's prebuilt static
  xcframework, which carries no licence file. Fetched from
  `https://raw.githubusercontent.com/KhronosGroup/MoltenVK/v1.4.1/LICENSE`.
- `cereal/LICENSE` — cereal is header-only code compiled into
  `libMoltenVK.a` (its symbols are present there). Fetched from
  `https://raw.githubusercontent.com/USCiLab/cereal/master/LICENSE`.

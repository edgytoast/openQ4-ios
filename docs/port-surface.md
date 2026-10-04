# The iOS port surface

What actually has to change to run openQ4 on iOS, established by reading
upstream at pin `227ee810` (charter Phase 0.1). The headline is that the
surface is **small and well-bounded** — the engine is already abstracted behind
a renderer/window seam, and the platform layer is ten files.

Source lists here are not hand-maintained. Upstream ships a machine-readable
manifest, `tools/build/meson_sources.py`, which is the authority:

```sh
python3 tools/build/meson_sources.py --host-system darwin --platform-backend sdl3 \
    --target-kind client --emit engine --renderer module --include-game false   # 159 files
python3 tools/build/meson_sources.py --host-system darwin --platform-backend sdl3 \
    --emit renderer_vk --renderer module                                        # 72 files
```

Generate the Xcode project's sources from that, so a pin bump cannot rot the
project (charter Phase 1).

---

## 1. The renderer seam is already the right shape

The renderer never calls SDL directly. It goes through a vtable,
`renderWindowServices_t` (`src/renderer/RenderModuleAPI.h`), which the platform
layer fills in (`s_sdl3WindowServices`, `sdl3_backend.cpp:5935`). Window
creation, GL context, Vulkan surface, swap, and proc lookup are all behind it.

That means **the iOS work is confined to the platform layer**; the renderer and
its 71 SPIR-V shaders carry over untouched. This is the single most important
structural fact about this port, and it is why the Vulkan module built and ran
on MoltenVK on day one (D-010).

## 2. Platform layer — 10 files, 3 need iOS variants

The `darwin/sdl3/client` platform selection is exactly:

| File | iOS status |
|---|---|
| `src/sys/sys_local.cpp` | portable |
| `src/sys/posix/posix_main.cpp` | portable (POSIX; `dlopen` use is game-module only, see §4) |
| `src/sys/posix/posix_net.cpp` | portable (BSD sockets) |
| `src/sys/posix/posix_signal.cpp` | portable |
| `src/sys/posix/posix_syscon.cpp` | portable, but the terminal console is meaningless on iOS |
| `src/sys/posix/posix_threads.cpp` | portable (pthreads — the 1 kHz async-tic thread works as-is) |
| `src/sys/osx/macosx_misc.mm` | mostly portable, audit |
| **`src/sys/osx/macosx_sdl3_main.cpp`** | **must change — see §3** |
| **`src/sys/osx/macosx_compat.mm`** | **must change — uses CGL** |
| **`src/sys/osx/macosx_sdl3.cpp`** | **must change — uses CGDirectDisplay** |

`macosx_compat.mm` queries video RAM through **CGL**
(`CGLQueryRendererInfo`, `CGLDescribeRenderer`, `CGLRPVideoMemoryMegabytes`,
`CGDisplayIDToOpenGLDisplayMask`). CGL is OpenGL-only and does not exist on
iOS. `Sys_GetVideoRam()` needs a Metal-based answer there
(`MTLDevice.recommendedMaxWorkingSetSize`) — and note the engine feeds that
number into `Common_DetectMachineSpec`, so a wrong value silently changes the
default quality preset.

`macosx_sdl3.cpp` is 1.4 KB: `Sys_DisplayToUse` via `CGGetActiveDisplayList`,
plus a `QGL_Init` stub. iOS has one display; this is close to a no-op stub.

**Sizing (measured, not estimated).** All three files fail on their *first*
include, which masks what is behind them — so the 35 KB of `macosx_compat.mm`
looks alarming until you read its contents. It is overwhelmingly portable POSIX
path plumbing: `Sys_CopyExecutablePath`, `Sys_DirectoryExists`,
`Sys_PathIsSymlink`, `Sys_EnsureMacOSDirectoryTree`, `Sys_DirectoryIsWritable`,
`Sys_RoundSystemRamMegabytes`, and `Sys_AsyncThread` (plain pthreads). The
genuinely macOS-bound parts are small and enumerable:

| What | Where | iOS replacement |
|---|---|---|
| `AppKit` / `ApplicationServices` / `OpenGL.h` imports | all three files | `UIKit`; drop the GL import |
| Video RAM via CGL | `macosx_compat.mm` | `MTLDevice.recommendedMaxWorkingSetSize` — and note it feeds `Common_DetectMachineSpec`, so a wrong number silently changes the default quality preset |
| Home / save directory | `macosx_compat.mm` | the app sandbox (`Documents`), never `$HOME/Library/...` which resolves outside the sandbox on iOS |
| `CGGetActiveDisplayList` | `macosx_sdl3.cpp` | single-display stub |
| `NSWorkspace openURL:` | `macosx_misc.mm` | `UIApplication.open` |

That is hours of work, not days — which is the useful conclusion, and the reason
this section is worth its length.

## 3. The main loop is the one real architectural change

`src/sys/osx/macosx_sdl3_main.cpp` is 65 lines and ends in:

```c
while (1) {
    Sys_HandlePendingQuitSignal();
    common->Frame();
}
```

under `SDL_RunApp`. **This cannot work on iOS**, where the main thread must
return to the run loop or the watchdog kills the app. There is no
`SDL_AppInit`/`SDL_AppIterate` callback path anywhere in the tree.

The fix is small and proven in the sibling ports: SDL3 3.4.10 ships
**`SDL_SetiOSAnimationCallback`** (`include/SDL3/SDL_system.h`), which drives a
CADisplayLink and calls back per frame. vkQuake-ios uses exactly this. So the
iOS entry point registers `common->Frame()` as the animation callback and
returns, instead of looping.

That also lands the charter's pacing requirement for free: the display link
becomes the only pacer, which is what Phase 0.6 asks for.

**Related, and on our critical path:** upstream's
`Common_ThrottlePresentationFrame` (`com_maxfps`, default 240) sleeps then
**busy-spins** to hit a deadline. Against a display-link-driven loop on a
FIFO-only presentation stack that is pure battery burn, and it is where a
throttled process visibly piles up (MEASUREMENTS row 17). Expect to neutralize
it on iOS.

## 4. Game modules: the static path is structurally intact

Upstream loads `game-sp`/`game-mp` as `dlopen`'d dylibs with a single exported
`GetGameAPI` — no good on iOS, where all executable code must be signed into
the bundle.

But the classic idTech 4 static path was never removed, only made unreachable.
`idCommonLocal::LoadGameDLL` is wholly inside `#ifdef __DOOM_DLL__`
(`Common.cpp:5493`) with **no `#else` branch**, so with that macro undefined the
function collapses to:

```c
if ( game != NULL ) {
    game->Init();
}
```

…on a link-time global that the game code already defines
(`Game_local.cpp:339`: `idGame *game = &gameLocal;  // statically pointed at an
idGameLocal`, declared `extern idGame *game;` in `Game.h:384`).

`meson.build:1099` adds `-D__DOOM_DLL__` unconditionally, so there is no build
option to reach it.

> **CORRECTION (2026-08-07, D-014).** This section originally concluded that
> static linking was "a matter of build plumbing, not engine surgery". That was
> wrong. Undefining `__DOOM_DLL__` **silently disables BSE** — `AttachBSE`'s
> entire body is inside that guard (`Common.cpp:5401-5414`), so the effects
> system never attaches, with no error and no warning. It also changes what the
> game code *is*: without `GAME_DLL` the module's import globals are not
> compiled and game code binds engine globals directly, presuming one shared
> idlib, which is false here. The port ships **embedded signed dylibs**
> instead (D-014); the text below is retained as the analysis that led there.

Two complications for shipping *both* modules statically:

1. Upstream deliberately builds **two divergent idlib archives**
   (`game_idlib_library` vs `game_idlib_library_mp`) and notes that sharing one
   would be an ODR violation.
2. The modules are compiled `c++17` while the engine is `c++20`.

Single-player only is clean. SP + MP together needs symbol isolation — the
dhewm3-ios D-006 precedent (`ld -r` merge per module, exporting only its own
entry point) is the proven pattern.

The alternative — embedded signed frameworks inside the app bundle, preserving
upstream's loader untouched — remains worth spiking first (charter Phase 0.5),
because it keeps SP↔MP runtime switching and the ODR split exactly as upstream
intends them.

## 4b. Forbidden-API audit: clean

Scanning all 159 engine sources for APIs iOS bans or lacks
(`fork`, `exec*`, `system`, `posix_spawn`, `NSTask`, `dlopen`, `MAP_JIT`,
`PROT_EXEC` mappings, CGL, AppKit) returns only:

| Hit | File | Disposition |
|---|---|---|
| `posix_spawn` | `src/sys/osx/macosx_misc.mm` | already an iOS-variant file (§2) |
| `dlopen` | `src/sys/posix/posix_main.cpp` | game-module loader only — §4 |
| `dlopen` | `src/framework/RenderDoc.cpp` | RenderDoc capture integration; compile out on iOS |
| `CGL` | `src/sys/osx/macosx_compat.mm` | already an iOS-variant file (§2) |
| `NSWorkspace` | `src/sys/osx/macosx_misc.mm` | one call, `openURL:` → `UIApplication.open` |

**No `fork`, `exec*`, `system`, `NSTask`, `MAP_JIT`, or executable mappings
anywhere**, and no AppKit beyond that single `NSWorkspace` line. For a
20-year-old desktop engine lineage that is a remarkably clean bill of health,
and it means there is no hidden second front behind the four files in §2.

## 5. SDL3: build it with CMake, not openQ4's meson port

openQ4 vendors SDL3 3.4.10 as a meson subproject with a **hand-written meson
port** (`subprojects/packagefiles/sdl3/`). That port's uikit backend is an empty
stub (`src/video/uikit/meson.build` contains only `sources += files()`), and its
platform chain `error()`s on anything but windows/linux/darwin.

Upstream SDL3's *own* source tree, which the wrap downloads, has the complete
uikit video driver. So iOS SDL3 comes from SDL's own CMake build (the sibling
ports' proven route), not from openQ4's meson port. Nothing about the engine
depends on which build system produced `libSDL3.a`.

## 6. What is NOT a problem

- **Renderer and shaders** — carry over untouched (§1); 71 GLSL-450 shaders are
  precompiled to SPIR-V headers, so there is no retail-`.vfp` dependency and no
  shader toolchain needed at build time.
- **Vulkan 1.3 floor** — met by MoltenVK 1.4.1 (measured: 1.3.334, D-010).
- **BC/DXT textures** — available through MoltenVK, so retail Quake 4's DDS
  assets need no transcode (D-010).
- **Cinematics** — RoQ only, a self-contained software decoder, no external
  codec. Nothing to port.
- **Audio** — OpenAL Soft builds for iOS; EFX is a compile-time gate we already
  satisfy on the oracle (D-006).
- **Networking** — BSD sockets via `posix_net.cpp`.
- **Threads** — pthreads; the async-tic thread is portable.

## 7. Deep links — `openq4://` (D-096)

Both targets register the `openq4` URL scheme and route every incoming URL
through one C handler, `OpenQ4_iOS_HandleURL()` in `ios/shell/openq4_ios_url.m`.

| URL | effect |
|---|---|
| `openq4://` | just open the app |
| `openq4://map/<name>` | `map <name>` — e.g. `openq4://map/mp/q4dm1` |
| `openq4://connect/<host[:port]>` | `connect <host>` |
| `openq4://console/<percent-encoded command>` | one console line, **OTA builds only** |

- The command is queued, not executed inline, and runs once the engine is past
  `common->Init()` — which on iOS is also past onboarding. A URL that arrives at
  a cold launch therefore works: it waits through the ~1 minute of media load
  and then runs. Every URL is logged (`openQ4 url: …`), handled or refused.
- `map` and `connect` arguments are restricted to `A-Za-z0-9._-/:`; anything
  else is refused, because the engine's command buffer splits on `;` and a link
  is an input any web page can supply.
- `console` is gated exactly as the :8774 bridge is
  (`OpenQ4_iOS_BridgeEnabled()`): on in OTA builds, off in public ones unless
  `OPENQ4_CONSOLE_BRIDGE=1`.
- Diagnostics over the bridge: `!urlinfo` prints the live app-delegate class and
  whether our hooks are installed on it; `!url <url>` runs the parser without the
  OS in the way.
- **The OS asks first.** iOS 27 and visionOS 27 put up a system "Open in
  “openQ4”?" confirmation before delivering a URL to a running app; the link
  does nothing until the user taps Open. A cold launch (app not running) on iOS
  goes straight through.

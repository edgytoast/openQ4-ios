#!/usr/bin/env bash
# regen-patches.sh — regenerate overlay/patches/* from the live build tree.
#
# The build tree is where edits actually happen; this captures them back into
# reviewable patches. Run it after changing anything under build/src-ios, then
# re-run sync-overlay.sh to prove the patches reproduce the tree from pristine.
#
# The patch groups below are hand-assigned, because grouping edits by intent is
# what makes them reviewable and no tool can infer that. But the *set* of edited
# files is discovered by diffing the trees, and any file that is edited without
# being assigned to a group is a hard error. Without that check the two lists
# drift silently: an edit to a file nobody remembered to list still builds,
# because the build tree already contains it, and only vanishes later when a
# pin bump re-syncs from pristine — long after anyone would connect the two.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# patch-name : space-separated file list.
#
# A patch may name several files, but a file belongs to exactly one patch — so
# a file edited for two unrelated reasons gets a patch named for both rather
# than a name that quietly describes only half of what it carries.
# NOT named GROUPS: that is a bash special variable holding the current user's
# Unix group IDs, and assigning an array to it silently does nothing — the
# assignment appears to work and every lookup then misses.
PATCH_GROUPS=(
	"0001-ios-platform-layer.patch:src/sys/osx/macosx_compat.mm src/sys/osx/macosx_misc.mm src/sys/osx/macosx_sdl3.cpp src/sys/osx/macosx_sys.h"
	"0002-ios-display-link-main-loop.patch:src/sys/osx/macosx_sdl3_main.cpp"
	"0003-ios-static-renderer-module.patch:src/renderer/RendererModule.cpp"
	"0004-ios-static-module-glue.patch:src/renderer/RendererGLModule.cpp"
	"0005-sdl3-backend-ios-input-text-mouse-gui-safe-area-and-screen-parms.patch:src/sys/sdl3/sdl3_backend.cpp"
	"0006-honour-missing-bc-texture-support-skip-image-source-times-and-keep-persistent-images.patch:src/renderer/Image_load.cpp"
	"0007-ios-common-quality-tier-profile-and-3d-safe-module-swap.patch:src/framework/Common.cpp"
	"0008-ios-touch-look-absolute-degrees-and-pad-look-scale.patch:src/framework/UsercmdGen.cpp"
	"0009-ios-session-focus-pacifier-brightness-and-continue.patch:src/framework/Session.cpp"
	"0010-menu-model-list-internet-refresh-and-save-refusal.patch:src/framework/Session_menu.cpp"
	"0011-cache-case-insensitive-dir-listings.patch:src/framework/FileSystem.cpp src/framework/FileSystem.h"
	"0012-openal-drain-latched-errors-and-latch-efx-failure.patch:src/sound/OpenAL/AL_SoundVoice.cpp src/sound/OpenAL/AL_SoundHardware.cpp"
	"0013-announce-engine-initiated-exit.patch:src/sys/posix/posix_main.cpp"
	"0014-cache-zip-entry-on-seek.patch:src/framework/File.cpp src/framework/File.h"
	"0015-name-loading-assets-for-the-sampler.patch:src/framework/DeclManager.cpp src/renderer/ModelManager.cpp"
	"0016-ios-game-side-audio-ducking.patch:src/sound/snd_emitter.cpp"
	"0017-ios-diagnostics-safe-area.patch:src/framework/Console.cpp"
	"0018-name-glyphs-that-rasterise-empty.patch:src/renderer/tr_fontTTF.cpp"
	# 0019 also carries the Phase 6 visionOS stereo block (D-100): the
	# r_stereo3d cvar, the per-slot offscreen present images, the
	# no-acquire/no-present frame path and the vkGetMTLTextureMVK accessor,
	# all inside #if defined( OPENQ4_VISIONOS_3D ). The round brief called it
	# "patch 0027", and it is not one, for the reason stated at the top of this
	# table and already lived once in 0026: the whole change lands in
	# vk_GuiExecutor.cpp, a file belongs to exactly one patch, and splitting
	# one file's diff across two patch files is not something this harness (or
	# `patch`) can round-trip. A separate patch would have needed a new source
	# file, and a new file is not representable here either — the edited-file
	# discovery below walks vendor/openQ4, so a file that exists only in the
	# build tree is invisible to it and `diff` would fail on the missing
	# pristine side. Grep the patch for OPENQ4_VISIONOS_3D to review it alone.
	"0019-vulkan-backend-timers-live-swapchain-extent-and-stereo-present.patch:src/renderer/Vulkan/vk_GuiExecutor.cpp src/renderer/Vulkan/vk_Backend.cpp"
	"0020-vulkan-warn-inert-screen-fraction.patch:src/renderer/RenderSystem.cpp"
	"0021-vulkan-swapchain-extent-recreate-accounting-and-open-batch-retire.patch:src/renderer/Vulkan/VulkanDevice.cpp src/renderer/Vulkan/VulkanDevice.h"
	"0022-build-string-names-the-apple-platform.patch:src/sys/sys_public.h"
	# The GPU pass-timing instrument lives in 0019 with the CPU stage timers it
	# extends; these two files only carry its call sites (the shadow atlas is
	# rendered from inside the interaction pass, and the caster passes are the
	# render passes worth counting), and a file belongs to exactly one patch.
	"0023-vulkan-gpu-timing-markers-in-lights-and-shadows.patch:src/renderer/Vulkan/vk_Interactions.cpp src/renderer/Vulkan/vk_ShadowMap.cpp"
	"0024-internet-master-servers.patch:src/framework/async/AsyncNetwork.cpp src/framework/async/AsyncClient.cpp"
	"0025-vid-restart-under-a-renderer-module.patch:src/renderer/RenderSystem_init.cpp"
	# The MSAA capture-resolve fix (D-094). Its storage half lives here; the
	# VK_Exec_CopyRender call site is in vk_GuiExecutor.cpp, which belongs to
	# 0019 — a file belongs to exactly one patch, so the hunk rides along there
	# rather than splitting the file across two groups.
	"0026-vulkan-resolve-multisampled-capture-source.patch:src/renderer/Vulkan/vk_Image.cpp src/renderer/Vulkan/vk_Image.h"
	# Phase 6 round 3 (D-101): where the EYE enters the shared render front end —
	# the post-translation in R_SetViewMatrix and the off-axis skew in
	# R_SetupProjection, plus the r_stereo3dSeparation/Convergence cvars and the
	# R_Stereo_* entry points idSessionLocal::UpdateScreen drives the pair from.
	# All of it inside #if defined( OPENQ4_VISIONOS_3D ). This one IS its own
	# patch, unlike the round-2 block: it is a different file from 0019's, and a
	# file belongs to exactly one patch. The other two halves of the round ride
	# in the patches that already own their files — the doubling loop in 0009
	# (Session.cpp) and the present pairs, eye extent and weapon skew in 0019
	# (vk_GuiExecutor.cpp, vk_Backend.cpp).
	"0027-stereo-eye-in-the-render-front-end.patch:src/renderer/tr_main.cpp"
	# D-112: sound-driven rumble follows the shader's own shakeData envelope
	# instead of the OpenAL voice's GetAmplitude() stub (always 1.0). The
	# counters that measure it ride in 0005, which owns sdl3_backend.cpp.
	"0028-rumble-follows-the-shake-envelope.patch:src/sound/snd_world.cpp"
)

# The same table for the SECOND pristine upstream, vendor/openQ4-game (D-070).
#
# Paths are relative to the gamelibs STAGE root, and only src/game and
# src/mpgame are ours: the stage also carries mirrored copies of the ENGINE's
# idlib/renderer/ui/sys/bse/MayaImport, which are already patched by the engine
# overlay and would otherwise show up here as a second, bogus set of edits.
GAME_PATCH_GROUPS=(
	"0001-in-world-gui-touch-ray.patch:src/game/Player.cpp src/mpgame/Player.cpp"
	"0002-pad-rumble-on-fire-and-damage.patch:src/game/PlayerView.cpp src/mpgame/PlayerView.cpp"
)

CLAIMED=""
for g in "${PATCH_GROUPS[@]}"; do
	CLAIMED="$CLAIMED ${g#*:}"
done

echo "==> checking every edited file is assigned to a patch"
# -q so identical files cost nothing; the tree is ~2500 files.
EDITED="$(cd vendor/openQ4 && find src -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.mm' -o -name '*.m' \) -print | sort | while read -r f; do
	if [ -f "$ROOT/build/src-ios/$f" ] && ! cmp -s "$ROOT/vendor/openQ4/$f" "$ROOT/build/src-ios/$f"; then
		echo "$f"
	fi
done)"

# Space-separated form for the substring checks below; $EDITED is one file per
# line, and a newline is not a space as far as a case pattern is concerned.
EDITED_SP=" $(echo $EDITED) "

UNASSIGNED=""
for f in $EDITED; do
	case " $CLAIMED " in
		*" $f "*) ;;
		*) UNASSIGNED="$UNASSIGNED$f"$'\n' ;;
	esac
done
if [ -n "$UNASSIGNED" ]; then
	echo "FATAL: these files differ from pristine but belong to no patch group:" >&2
	printf '  %s\n' $UNASSIGNED >&2
	echo "Add each to a PATCH_GROUPS entry in $0 — an unassigned edit is lost on the next sync." >&2
	exit 1
fi

# The reverse rot: a group naming a file that no longer differs produces an
# empty patch, which applies cleanly forever and hides that the change is gone.
for g in "${PATCH_GROUPS[@]}"; do
	for f in ${g#*:}; do
		case "$EDITED_SP" in
			*" $f "*) ;;
			*) echo "FATAL: ${g%%:*} claims $f, but it is identical to pristine" >&2; exit 1 ;;
		esac
	done
done

emit() { # <out-dir> <pristine-root> <edited-root> <patch-name> <file>...
	local outdir="$1" pristine="$2" edited="$3"
	local out="$outdir/$4"; shift 4
	: > "$out"
	for f in "$@"; do
		set +e
		diff -u "$pristine/$f" "$edited/$f" \
			| sed -e "1s|^--- .*|--- a/$f|" -e "2s|^+++ .*|+++ b/$f|" >> "$out"
		local rc=${PIPESTATUS[0]}
		set -e
		# diff: 0 = same, 1 = differs, >1 = it could not read a file.
		[ "$rc" -le 1 ] || { echo "FATAL: diff failed on $f" >&2; exit 1; }
	done
	echo "  $(basename "$out")  ($(wc -l < "$out" | tr -d ' ') lines)"
}

echo "==> regenerating overlay patches"
for g in "${PATCH_GROUPS[@]}"; do
	emit overlay/patches vendor/openQ4 build/src-ios "${g%%:*}" ${g#*:}
done

# --- the game repo, same discipline (D-070) ---------------------------------
#
# Same checks, second tree. The staged tree is what the game modules actually
# compile from, so it is where a game-side edit is made and where it has to be
# captured back from — and an edit left only there is destroyed by the very next
# sync-overlay.sh run, which rebuilds the stage from pristine.
GAME_STAGE="build/src-ios/.tmp/gamelibs_stage"
if [ ! -d "$GAME_STAGE/src/game" ]; then
	echo "FATAL: no gamelibs stage at $GAME_STAGE — run scripts/sync-overlay.sh first" >&2
	exit 1
fi
mkdir -p overlay/patches-game

GAME_CLAIMED=""
for g in "${GAME_PATCH_GROUPS[@]}"; do
	GAME_CLAIMED="$GAME_CLAIMED ${g#*:}"
done

echo "==> checking every edited game file is assigned to a patch"
GAME_EDITED="$(cd vendor/openQ4-game && find src/game src/mpgame -type f \( -name '*.cpp' -o -name '*.h' \) -print | sort | while read -r f; do
	if [ -f "$ROOT/$GAME_STAGE/$f" ] && ! cmp -s "$ROOT/vendor/openQ4-game/$f" "$ROOT/$GAME_STAGE/$f"; then
		echo "$f"
	fi
done)"
GAME_EDITED_SP=" $(echo $GAME_EDITED) "

GAME_UNASSIGNED=""
for f in $GAME_EDITED; do
	case " $GAME_CLAIMED " in
		*" $f "*) ;;
		*) GAME_UNASSIGNED="$GAME_UNASSIGNED$f"$'\n' ;;
	esac
done
if [ -n "$GAME_UNASSIGNED" ]; then
	echo "FATAL: these game files differ from pristine but belong to no patch group:" >&2
	printf '  %s\n' $GAME_UNASSIGNED >&2
	echo "Add each to a GAME_PATCH_GROUPS entry in $0 — an unassigned edit is lost on the next sync." >&2
	exit 1
fi

for g in "${GAME_PATCH_GROUPS[@]}"; do
	for f in ${g#*:}; do
		case "$GAME_EDITED_SP" in
			*" $f "*) ;;
			*) echo "FATAL: ${g%%:*} claims $f, but it is identical to pristine" >&2; exit 1 ;;
		esac
	done
done

echo "==> regenerating game overlay patches"
for g in "${GAME_PATCH_GROUPS[@]}"; do
	emit overlay/patches-game vendor/openQ4-game "$GAME_STAGE" "${g%%:*}" ${g#*:}
done

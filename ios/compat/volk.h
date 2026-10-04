/*
 * volk.h — iOS shim replacing the volk meta-loader (DECISIONS D-013).
 *
 * WHY THIS EXISTS
 *
 * openQ4's Vulkan renderer calls Vulkan through volk, which declares its
 * function pointers as globals named exactly like the Vulkan entry points
 * (`PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;`). On iOS, MoltenVK is
 * linked STATICALLY and exports real functions of those same names. In one flat
 * symbol namespace the two cannot coexist:
 *
 *   as-is:        the linker merges volk's pointer into MoltenVK's function and
 *                 volk then loads through it as data —
 *                 "ld: fixup error (kind=arm64_lo12) at '_volkInitialize'+0xAC,
 *                  target '_vkGetInstanceProcAddr' not 8-byte aligned"
 *   -fno-common:  414 honest duplicate symbols
 *
 * Neither side can yield. SDL locates static MoltenVK with
 * dlsym(RTLD_DEFAULT, "vkGetInstanceProcAddr"), so MoltenVK must own that name.
 *
 * The resolution is to remove the meta-loader instead: with MoltenVK linked in,
 * every entry point already resolves directly, so a loader has nothing to do.
 * This header is placed earlier in the include path than src/external/volk, and
 * every `#include "volk.h"` site resolves here instead. No upstream file is
 * edited, and volk.c is simply not compiled on iOS.
 *
 * WHY THIS IS SAFE (measured, not assumed)
 *
 *   - openQ4 uses exactly four volk entry points — volkInitialize,
 *     volkInitializeCustom, volkLoadInstance, volkLoadDevice — all of which are
 *     pure no-ops once symbols resolve directly.
 *   - It never uses VolkDeviceTable / volkLoadDeviceTable, so no per-device
 *     dispatch optimisation is lost. (Zero hits across the whole tree.)
 *   - All 97 distinct vk* entry points the renderer calls are present in the
 *     shipped MoltenVK ios-arm64 archive (which exports 545).
 *   - VMA is already loader-agnostic here (VMA_STATIC_VULKAN_FUNCTIONS=0,
 *     VMA_DYNAMIC_VULKAN_FUNCTIONS=1) and is fed vkGetInstanceProcAddr /
 *     vkGetDeviceProcAddr explicitly — under this shim those are MoltenVK's real
 *     functions, which is exactly what VMA wants.
 *
 * The macOS oracle keeps using real volk, so it stays bit-identical to upstream.
 */

#ifndef OPENQ4_IOS_VOLK_SHIM_H_
#define OPENQ4_IOS_VOLK_SHIM_H_

/*
 * Deliberately WITHOUT VK_NO_PROTOTYPES: we want the real prototypes so calls
 * bind directly to MoltenVK's statically linked functions.
 */
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The four volk entry points openQ4 calls. Each is a no-op: there is nothing to
 * load, because the entry points are already bound at link time.
 *
 * volkInitializeCustom is only reached from the macOS dlopen ladder in
 * VulkanDevice.cpp, which is #if defined(MACOS_X) — it is kept here so the
 * signature exists if that gating ever changes.
 */
static inline VkResult volkInitialize(void) {
	return VK_SUCCESS;
}

static inline void volkInitializeCustom(PFN_vkGetInstanceProcAddr handler) {
	(void)handler;
}

static inline void volkLoadInstance(VkInstance instance) {
	(void)instance;
}

static inline void volkLoadInstanceOnly(VkInstance instance) {
	(void)instance;
}

static inline void volkLoadDevice(VkDevice device) {
	(void)device;
}

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_VOLK_SHIM_H_ */

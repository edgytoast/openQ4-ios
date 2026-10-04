/*
 * OpenQ4Immersive.m — visionOS 3D panel render loop (CompositorServices).
 * Phase 6 round 3, D-100 + D-101. STEREO: the engine publishes a PAIR of images
 * per frame (left eye and right eye, same game time) and view 0 samples the
 * left while view 1 samples the right.
 *
 * visionOS cannot show real-time stereo in a normal 2D window; per-eye drawable
 * textures and the ARKit head pose come from CompositorServices, and this file
 * owns that loop. The architecture is vkQuake-ios D-026 -> D-030 -> D-039,
 * ported:
 *
 *   1. The engine renders its COMPLETE composite (scene + HUD + menus +
 *      console) into an offscreen present image instead of the window
 *      swapchain (r_stereo3d, overlay 0019's OPENQ4_VISIONOS_3D block). Under
 *      MoltenVK that VkImage IS a MTLTexture, so
 *      OpenQ4_VK3D_PresentMTLTexture() is a zero-copy hand-off.
 *   2. This loop copies that image into its OWN mip-mapped texture on ITS OWN
 *      queue (so copy and sample are coherent), then draws one world-locked
 *      screen quad per cp_view. The head pose PLACES the screen; it never
 *      drives the camera (charter Phase 6, settled law).
 *
 * Loop shape that must not be "simplified" (all three cost a sibling a round):
 *   - No frame pacing (cp_frame_predict_timing + cp_time_wait_until) and the
 *     presented frame is silently never displayed.
 *   - No per-frame ARKit device anchor on the drawable and likewise.
 *   - A NULL/withheld drawable INVALIDATES the frame: abandon it. Calling
 *     cp_frame_end_submission() on it to look tidy is API misuse that
 *     CompositorServices answers with __BUG_IN_CLIENT__ and an abort.
 *   - The depth texture must be written, or the compositor cannot reproject.
 */

#import "OpenQ4Immersive.h"

#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>
#import <mach/mach_time.h>

#import "../shell/openq4_ios_blackbox.h"

// --- engine bridge (overlay 0019, OPENQ4_VISIONOS_3D) ------------------------
// Acquire/Release, not a bare "give me the texture": the engine hands over only
// images whose Vulkan fence has signalled, and holds off reusing or destroying
// one until the Metal blit that reads it has COMPLETED (D-100 addendum).
// Round 3: a PAIR, acquired and released together. Half a pair is never handed
// over, so the compositor cannot mix eyes from two different game times — the
// one stereo artefact a viewer cannot adapt to.
extern int	 OpenQ4_VK3D_AcquirePresentPair(void **left, void **right, int *slot);
extern void	 OpenQ4_VK3D_ReleasePresentPair(int slot);
extern int	 OpenQ4_VK3D_Enabled(void);
extern int	 OpenQ4_VK3D_Frames(void);
extern void	 OpenQ4_VK3D_PresentSize(int *width, int *height);
extern void	 OpenQ4_VK3D_SyncStats(int *notReady, int *stalls, int *overruns,
									 int *halfPairs);
extern void	 OpenQ4_VK3D_PublishStats(int *submitted, int *published,
									  int *pubLatencyP50, int *superseded);
extern void	 OpenQ4_VK3D_EyeStats(int *eyeL, int *eyeR, int *pairs);

// Shell reconcile on Crown/system dismissal (OpenQ4Vision3D.m).
extern void OpenQ4_Vision3D_ImmersiveEnded(void);

volatile int openq4_immStop = 0;
volatile int openq4_immRunning = 0;

// --- panel placement ---------------------------------------------------------
// Defaults are vkQuake's shipped values (docs/stereo-design.md §7, Q-031's
// default). Round 3 puts them behind the settings sheet.
static float openq4_screenDist	= 3.6f;		// metres from the captured head position
static float openq4_screenHalfW	= 2.75f;	// half-width, metres
static float openq4_screenHalfH	= 1.55f;	// half-height, metres
static float openq4_screenHeight = 0.0f;	// metres above eye level

void OpenQ4_Immersive_SetPanel(float dist, float halfW, float halfH) {
	if (dist >= 1.0f && dist <= 8.0f) { openq4_screenDist = dist; }
	if (halfW >= 0.6f && halfW <= 4.0f) { openq4_screenHalfW = halfW; }
	if (halfH >= 0.4f && halfH <= 3.0f) { openq4_screenHalfH = halfH; }
}

void OpenQ4_Immersive_SetHeight(float h) {
	if (h >= -1.5f && h <= 10.0f) { openq4_screenHeight = h; }
}

// Surroundings dimming: a per-eye fullscreen black layer with this alpha, drawn
// UNDER the panel so it darkens the room and not the game. The 2.2 curve is
// vkQuake's (D-030): a linear alpha slider reads as "nothing happens" for the
// first two thirds of its travel, because perceived brightness is not linear in
// alpha.
static float openq4_dimLevel = 0.0f;
static float openq4_dimSetting = 0.0f;

void OpenQ4_Immersive_SetDim(float dim) {
	if (dim < 0.0f) { dim = 0.0f; }
	if (dim > 1.0f) { dim = 1.0f; }
	openq4_dimSetting = dim;
	openq4_dimLevel = 1.0f - powf(1.0f - dim, 2.2f);
}

float OpenQ4_Immersive_Dim(void) { return openq4_dimSetting; }

void OpenQ4_Immersive_GetPanel(float *dist, float *halfW, float *halfH, float *height) {
	if (dist != NULL)   { *dist = openq4_screenDist; }
	if (halfW != NULL)  { *halfW = openq4_screenHalfW; }
	if (halfH != NULL)  { *halfH = openq4_screenHalfH; }
	if (height != NULL) { *height = openq4_screenHeight; }
}

static bool			 openq4_haveAnchor = false;
static simd_float4x4 openq4_frozenHead;

void OpenQ4_Immersive_Recenter(void) {
	openq4_haveAnchor = false;	// next tracked frame re-captures the head pose
}

// --- diagnostics -------------------------------------------------------------
// Written on the compositor thread, read from the bridge's socket thread. They
// are ints and doubles reported for a human, not consumed for control flow, so
// plain stores are honest enough; nothing branches on them.
static OpenQ4ImmersiveStats openq4_stats;

#define OPENQ4_COMP_SAMPLES 240
static double	openq4_compSamples[OPENQ4_COMP_SAMPLES];
static int		openq4_compCount;
static int		openq4_compCursor;

static int openq4_cmp_double(const void *a, const void *b) {
	const double x = *(const double *)a, y = *(const double *)b;
	return (x < y) ? -1 : (x > y) ? 1 : 0;
}

static void OpenQ4_Immersive_Percentiles(double *p50, double *p95) {
	double sorted[OPENQ4_COMP_SAMPLES];
	const int n = openq4_compCount;
	if (n <= 0) {
		*p50 = *p95 = 0.0;
		return;
	}
	memcpy(sorted, openq4_compSamples, (size_t)n * sizeof(double));
	qsort(sorted, (size_t)n, sizeof(double), openq4_cmp_double);
	*p50 = sorted[(n * 50) / 100];
	*p95 = sorted[(n * 95) / 100 >= n ? n - 1 : (n * 95) / 100];
}

void OpenQ4_Immersive_GetStats(OpenQ4ImmersiveStats *out) {
	if (out == NULL) { return; }
	*out = openq4_stats;
	OpenQ4_Immersive_Percentiles(&out->compP50, &out->compP95);
	OpenQ4_VK3D_PresentSize(&out->eyeW, &out->eyeH);
	OpenQ4_VK3D_SyncStats(&out->notReady, &out->stalls, &out->overruns,
						  &out->halfPairs);
	OpenQ4_VK3D_PublishStats(&out->submitted, &out->published,
							 &out->pubLatency, &out->superseded);
	OpenQ4_VK3D_EyeStats(&out->eyeL, &out->eyeR, &out->pairs);
	out->dim = openq4_dimSetting;
}

// --- world-lock math ---------------------------------------------------------
static simd_float4x4 openq4_translate(float x, float y, float z) {
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[3] = simd_make_float4(x, y, z, 1.0f);
	return m;
}

static simd_float4x4 openq4_scale(float x, float y, float z) {
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[0].x = x;
	m.columns[1].y = y;
	m.columns[2].z = z;
	return m;
}

// The panel is placed from the FROZEN head pose, recomputed every frame so live
// tuning of distance/size moves it; it is never re-derived from the live head,
// which is what "world-locked, never head-driven" means.
static simd_float4x4 openq4_make_screen_anchor(simd_float4x4 originFromDevice) {
	simd_float3 headPos = originFromDevice.columns[3].xyz;
	simd_float3 fwd = -originFromDevice.columns[2].xyz;	// gaze forward
	fwd.y = 0.0f;										// level: no pitch, no roll
	const float len = simd_length(fwd);
	fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;

	simd_float3 pos = headPos + fwd * openq4_screenDist;
	pos.y += openq4_screenHeight;
	simd_float3 normal = simd_normalize(headPos - pos);
	simd_float3 up = simd_make_float3(0, 1, 0);
	simd_float3 right = simd_normalize(simd_cross(up, normal));
	up = simd_cross(normal, right);

	simd_float4x4 m;
	m.columns[0] = simd_make_float4(right, 0.0f);
	m.columns[1] = simd_make_float4(up, 0.0f);
	m.columns[2] = simd_make_float4(normal, 0.0f);
	m.columns[3] = simd_make_float4(pos, 1.0f);
	return m;
}

// --- the panel quad ----------------------------------------------------------
// srgbDecode: the engine image is UNORM holding display-ready (sRGB-encoded)
// values. When the drawable wants linear input the shader linearises, or the
// compositor encodes a second time and the panel washes out (vkQuake's fix).
// Alpha is forced to 1 (quake3e's stereo rule) and depth is written, because
// the compositor reprojects on depth and drops frames it cannot reproject.
static NSString *const kOpenQ4QuadShader =
	@"#include <metal_stdlib>\n"
	 "using namespace metal;\n"
	 "struct VOut { float4 pos [[position]]; float2 uv; };\n"
	 "vertex VOut oq4_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
	 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
	 "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
	 "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
	 "  return o;\n"
	 "}\n"
	 "fragment float4 oq4_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
	 "                       constant float& srgbDecode [[buffer(0)]]) {\n"
	 "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
	 "  float4 c = tex.sample(s, in.uv);\n"
	 "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
	 "  return float4(c.rgb, 1.0);\n"
	 "}\n"
	 // Surroundings dimming: a clip-space fullscreen triangle, black at the
	 // given alpha, drawn UNDER the panel so it blends over passthrough only.
	 "vertex float4 oq4_dim_vs(uint vid [[vertex_id]]) {\n"
	 "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
	 "  return float4(p[vid], 0.9999, 1.0);\n"
	 "}\n"
	 "fragment float4 oq4_dim_fs(constant float& dim [[buffer(0)]]) {\n"
	 "  return float4(0.0, 0.0, 0.0, dim);\n"
	 "}\n"
	 // LAYERED variants (D-105). With `.layered` layout the drawable is ONE
	 // array texture carrying ONE multi-layer rate map, and a render pass per
	 // slice rasterizes every eye with layer 0's map — the right-eye fisheye
	 // the foveation guide names as trap 1. The fix is a SINGLE pass over the
	 // array texture in which each draw names its own layer through
	 // render_target_array_index, which is what makes the rasterizer pick that
	 // layer's rate map. Two extra functions, no other change: the quad is the
	 // whole of this renderer, so the "single layered pass" the guide calls a
	 // much bigger change for a scene renderer is four lines here.
	 "struct VOutL { float4 pos [[position]]; float2 uv;\n"
	 "               uint layer [[render_target_array_index]]; };\n"
	 "vertex VOutL oq4_vs_layered(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]],\n"
	 "                            constant uint& layer [[buffer(1)]]) {\n"
	 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
	 "  VOutL o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
	 "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
	 "  o.layer = layer;\n"
	 "  return o;\n"
	 "}\n"
	 "fragment float4 oq4_fs_layered(VOutL in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
	 "                               constant float& srgbDecode [[buffer(0)]]) {\n"
	 "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
	 "  float4 c = tex.sample(s, in.uv);\n"
	 "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
	 "  return float4(c.rgb, 1.0);\n"
	 "}\n"
	 "struct DOutL { float4 pos [[position]]; uint layer [[render_target_array_index]]; };\n"
	 "vertex DOutL oq4_dim_vs_layered(uint vid [[vertex_id]], constant uint& layer [[buffer(1)]]) {\n"
	 "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
	 "  DOutL o; o.pos = float4(p[vid], 0.9999, 1.0); o.layer = layer;\n"
	 "  return o;\n"
	 "}\n"
	 "fragment float4 oq4_dim_fs_layered(DOutL in [[stage_in]], constant float& dim [[buffer(0)]]) {\n"
	 "  (void)in;\n"
	 "  return float4(0.0, 0.0, 0.0, dim);\n"
	 "}\n";

static id<MTLRenderPipelineState> openq4_pipeline;
static id<MTLDepthStencilState>	  openq4_depthState;
static id<MTLRenderPipelineState> openq4_dimPipeline;
static id<MTLDepthStencilState>	  openq4_dimDepthState;
// The layered-pass pair (D-105); nil until they compile, and the loop only
// takes the layered path when both are live.
static id<MTLRenderPipelineState> openq4_pipelineLayered;
static id<MTLRenderPipelineState> openq4_dimPipelineLayered;

static void OpenQ4_Immersive_BuildPipeline(id<MTLDevice> dev, MTLPixelFormat colorFmt,
										   MTLPixelFormat depthFmt) {
	NSError *err = nil;
	id<MTLLibrary> lib = [dev newLibraryWithSource:kOpenQ4QuadShader options:nil error:&err];
	if (lib == nil) {
		OpenQ4_iOS_BlackBox("xr3d: panel shader compile FAILED: %s",
							err.localizedDescription.UTF8String);
		return;
	}
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"oq4_vs"];
	pd.fragmentFunction = [lib newFunctionWithName:@"oq4_fs"];
	pd.colorAttachments[0].pixelFormat = colorFmt;
	pd.depthAttachmentPixelFormat = depthFmt;
	openq4_pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
	if (openq4_pipeline == nil) {
		OpenQ4_iOS_BlackBox("xr3d: panel pipeline FAILED: %s", err.localizedDescription.UTF8String);
		return;
	}
	MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
	dd.depthCompareFunction = MTLCompareFunctionAlways;	// only the quad is drawn
	dd.depthWriteEnabled = YES;							// real depth so the compositor reprojects it
	openq4_depthState = [dev newDepthStencilStateWithDescriptor:dd];

	// The dim layer: alpha-blended fullscreen triangle at far depth, drawn
	// before the panel so the panel is never dimmed by it.
	MTLRenderPipelineDescriptor *dp = [MTLRenderPipelineDescriptor new];
	dp.vertexFunction = [lib newFunctionWithName:@"oq4_dim_vs"];
	dp.fragmentFunction = [lib newFunctionWithName:@"oq4_dim_fs"];
	dp.colorAttachments[0].pixelFormat = colorFmt;
	dp.colorAttachments[0].blendingEnabled = YES;
	dp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	dp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	dp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	dp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
	dp.depthAttachmentPixelFormat = depthFmt;
	openq4_dimPipeline = [dev newRenderPipelineStateWithDescriptor:dp error:&err];
	if (openq4_dimPipeline == nil) {
		OpenQ4_iOS_BlackBox("xr3d: dim pipeline FAILED: %s", err.localizedDescription.UTF8String);
	}
	MTLDepthStencilDescriptor *dd2 = [MTLDepthStencilDescriptor new];
	dd2.depthCompareFunction = MTLCompareFunctionAlways;
	dd2.depthWriteEnabled = YES;	// deep depth: the compositor reprojects it far away
	openq4_dimDepthState = [dev newDepthStencilStateWithDescriptor:dd2];

	// Layered variants, for a `.layered` drawable with foveation on. Built
	// unconditionally (they cost one compile at entry) so the path is never
	// half-present when the headset hands over a layered drawable.
	MTLRenderPipelineDescriptor *lp = [MTLRenderPipelineDescriptor new];
	lp.vertexFunction = [lib newFunctionWithName:@"oq4_vs_layered"];
	lp.fragmentFunction = [lib newFunctionWithName:@"oq4_fs_layered"];
	lp.colorAttachments[0].pixelFormat = colorFmt;
	lp.depthAttachmentPixelFormat = depthFmt;
	// MANDATORY when a vertex function writes render_target_array_index: Metal
	// refuses the pipeline with "inputPrimitiveTopology is not specified"
	// otherwise, which the simulator gate caught before any headset could.
	lp.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
	openq4_pipelineLayered = [dev newRenderPipelineStateWithDescriptor:lp error:&err];
	if (openq4_pipelineLayered == nil) {
		OpenQ4_iOS_BlackBox("xr3d: LAYERED panel pipeline FAILED: %s",
							err.localizedDescription.UTF8String);
	}
	MTLRenderPipelineDescriptor *ldp = [MTLRenderPipelineDescriptor new];
	ldp.vertexFunction = [lib newFunctionWithName:@"oq4_dim_vs_layered"];
	ldp.fragmentFunction = [lib newFunctionWithName:@"oq4_dim_fs_layered"];
	ldp.colorAttachments[0].pixelFormat = colorFmt;
	ldp.colorAttachments[0].blendingEnabled = YES;
	ldp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	ldp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	ldp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	ldp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
	ldp.depthAttachmentPixelFormat = depthFmt;
	ldp.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
	openq4_dimPipelineLayered = [dev newRenderPipelineStateWithDescriptor:ldp error:&err];
	if (openq4_dimPipelineLayered == nil) {
		OpenQ4_iOS_BlackBox("xr3d: LAYERED dim pipeline FAILED: %s",
							err.localizedDescription.UTF8String);
	}

	OpenQ4_iOS_BlackBox("xr3d: panel pipeline built (colorFmt=%lu depthFmt=%lu layeredOk=%d)",
						(unsigned long)colorFmt, (unsigned long)depthFmt,
						(openq4_pipelineLayered != nil && openq4_dimPipelineLayered != nil) ? 1 : 0);
}

// The loop's OWN sampling copies of the engine images, one per eye. Mip-mapped:
// the panel downsamples the game frame onto its angular footprint, so a mip
// chain is what removes minification shimmer (vkQuake D-030's crispness lever).
//
// Copies, and not the engine textures directly, is what lets the engine reclaim
// a pair the instant the blit completes instead of waiting for the sample — and
// it is what stops the second eye's render from overwriting the first eye
// before it has been drawn (vkQuake D-030).
static id<MTLTexture> openq4_panelCopy[2];

// --- one panel view ----------------------------------------------------------
/*
 * One eye's draws, inside whatever pass the caller opened. Two callers:
 *
 *   - the DEDICATED path opens a pass per view (its own texture, its own rate
 *     map) and calls this once with layered=NO;
 *   - the LAYERED path opens ONE pass over the array texture with
 *     renderTargetArrayLength = views and calls this once per view with
 *     layered=YES and layer = the view's slice, so each draw rasterizes with
 *     its OWN layer of the single multi-layer rate map.
 *
 * Everything else — viewport, dim layer, projection, srgb decode — is identical
 * between them, which is the point of having one function: the fisheye trap is
 * about WHICH map rasterizes the draw, and nothing else about the draw changes.
 */
static void OpenQ4_Immersive_DrawPanelView(id<MTLRenderCommandEncoder> enc,
										   cp_drawable_t drawable, cp_view_t view, size_t v,
										   MTLViewport vp, simd_float4x4 model,
										   simd_float4x4 originFromDevice, float srgbDecode,
										   BOOL layered, uint32_t layer) {
	// Foveation contract: rasterize in the view's LOGICAL viewport; the rate map
	// compresses it to physical.
	[enc setViewport:vp];

	// Surroundings dimming, UNDER the panel: drawn first, so the game frame is
	// never dimmed by it and only the room is.
	const float dimNow = openq4_dimLevel;
	id<MTLRenderPipelineState> dimPipe = layered ? openq4_dimPipelineLayered : openq4_dimPipeline;
	if (dimNow > 0.003f && dimPipe != nil) {
		[enc setRenderPipelineState:dimPipe];
		[enc setDepthStencilState:openq4_dimDepthState];
		if (layered) { [enc setVertexBytes:&layer length:sizeof(layer) atIndex:1]; }
		[enc setFragmentBytes:&dimNow length:sizeof(dimNow) atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	}

	// View 0 is the left eye and view 1 the right — the only ordering
	// CompositorServices defines, and the one the engine's pair is built in. A
	// drawable that reports a single view (the simulator) shows the left eye in
	// it, which is mono and correct: there is no second eye to be wrong about.
	id<MTLTexture> eyeTex = openq4_panelCopy[(v == 1) ? 1 : 0];
	if (eyeTex == nil) { eyeTex = openq4_panelCopy[0]; }
	id<MTLRenderPipelineState> pipe = layered ? openq4_pipelineLayered : openq4_pipeline;
	if (eyeTex != nil && pipe != nil) {
		const simd_float4x4 deviceFromEye = cp_view_get_transform(view);
		const simd_float4x4 eyeFromOrigin =
			simd_inverse(simd_mul(originFromDevice, deviceFromEye));
		simd_float4x4 proj = matrix_identity_float4x4;
		if (__builtin_available(visionOS 2.0, *)) {
			proj = cp_drawable_compute_projection(
				drawable, cp_axis_direction_convention_right_up_back, v);
		}
		const simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, model));

		[enc setRenderPipelineState:pipe];
		[enc setDepthStencilState:openq4_depthState];
		[enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
		if (layered) { [enc setVertexBytes:&layer length:sizeof(layer) atIndex:1]; }
		[enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
		[enc setFragmentTexture:eyeTex atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	}
}

// --- the fidelity report -----------------------------------------------------
/*
 * Documents/oq4-3d-fidelity.log — vkQuake's supersample report (its
 * vp3d-fidelity.log, VKQImmersive.m) with round 4's rate-map facts added.
 *
 * It answers the ONE question the foveation change raises that a verdict cannot:
 * is the engine's per-eye image big enough to feed the fovea? The compositor
 * hands the panel a footprint in drawable pixels; the engine renders
 * r_stereo3dWidth x r_stereo3dHeight into it. Above 1.0x the panel is
 * supersampling (crisp); below it, the engine image is the limit and no amount
 * of foveation will sharpen it — which is exactly when Panel Resolution is the
 * knob rather than the toggle. Written once per entry into 3D, to Documents so
 * the Files app on the headset can read it back without a cable.
 *
 * With foveation ON the drawable's logical (screen) size is larger than the
 * physical allocation, and the fovea is drawn at close to the logical rate:
 * screen/physical is therefore the foveation factor, and it is printed as such.
 */
static bool openq4_fidelityLogged = false;

static void OpenQ4_Immersive_LogFidelity(cp_drawable_t drawable, id<MTLTexture> gameTex) {
	if (openq4_fidelityLogged || gameTex == nil) { return; }

	cp_view_t			view = cp_drawable_get_view(drawable, 0);
	const MTLViewport	vp = cp_view_texture_map_get_viewport(cp_view_get_view_texture_map(view));
	// FOV from the projection matrix: cp_view_get_tangents is deprecated AND
	// traps on visionOS 2.0 (vkQuake). m00 = 2/(l+r), so 1/m00 is the mean
	// horizontal tangent — exact for a symmetric frustum and under 1% off for
	// the Vision Pro's slight cant, which is plenty for a sampling check.
	simd_float4x4 proj = matrix_identity_float4x4;
	if (__builtin_available(visionOS 2.0, *)) {
		proj = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, 0);
	}
	const double m00 = fabs(proj.columns[0].x), m11 = fabs(proj.columns[1].y);
	const double fovH = (m00 > 1e-6) ? 2.0 * atan(1.0 / m00) : 0.0;
	const double fovV = (m11 > 1e-6) ? 2.0 * atan(1.0 / m11) : 0.0;
	if (vp.width < 1.0 || vp.height < 1.0 || fovH < 1e-4 || fovV < 1e-4) { return; }

	const double pxPerRadH = vp.width / fovH, pxPerRadV = vp.height / fovV;
	const double panAngH = 2.0 * atan(openq4_screenHalfW / openq4_screenDist);
	const double panAngV = 2.0 * atan(openq4_screenHalfH / openq4_screenDist);
	const double footH = panAngH * pxPerRadH, footV = panAngV * pxPerRadV;
	const double ssH = (footH > 1.0) ? gameTex.width / footH : 0.0;
	const double ssV = (footV > 1.0) ? gameTex.height / footV : 0.0;

	const size_t rmCount = cp_drawable_get_rasterization_rate_map_count(drawable);
	NSString *rmapLine = @"Rasterization rate map: NONE (foveation off or unsupported)\n";
	if (rmCount > 0) {
		id<MTLRasterizationRateMap> map = cp_drawable_get_rasterization_rate_map(drawable, 0);
		if (map != nil) {
			const MTLSize scr = map.screenSize;
			const MTLSize phys = [map physicalSizeForLayer:0];
			rmapLine = [NSString stringWithFormat:
				@"Rasterization rate maps: %zu   layers(map 0): %lu\n"
				 "  screen (logical) %lu x %lu  ->  physical %lu x %lu\n"
				 "  FOVEATION FACTOR: %.2fx H, %.2fx V  (logical/physical; >1 means the\n"
				 "  fovea is drawn at a higher rate than the uniform allocation would allow)\n",
				rmCount, (unsigned long)map.layerCount,
				(unsigned long)scr.width, (unsigned long)scr.height,
				(unsigned long)phys.width, (unsigned long)phys.height,
				phys.width ? (double)scr.width / (double)phys.width : 0.0,
				phys.height ? (double)scr.height / (double)phys.height : 0.0];
		}
	}

	NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
					  firstObject];
	NSString *report = [NSString stringWithFormat:
		@"openQ4 Vision Pro 3D fidelity report (D-105)\n"
		 "============================================\n"
		 "Compositor drawable (per eye, logical): %.0f x %.0f px  (%.1f MP)\n"
		 "Views: %zu   layout: %s\n"
		 "%@"
		 "\n"
		 "Per-eye FOV: %.1f deg H x %.1f deg V   (%.1f px/deg H)\n"
		 "Game render target (per eye): %lu x %lu px  (%.1f MP)\n"
		 "Panel angular size: %.1f deg H x %.1f deg V   (%.1f m wide at %.1f m)\n"
		 "Panel footprint in drawable: %.0f x %.0f px\n"
		 "\n"
		 "SUPERSAMPLE RATIO: %.2fx H, %.2fx V   (%s)\n"
		 "  >1.0 = the engine renders MORE pixels than the panel footprint shows and the\n"
		 "         compositor downfilters them (crisp). <1.0 = the engine image is the\n"
		 "         limit: raise Panel Resolution, because foveation cannot invent detail\n"
		 "         the engine never drew.\n"
		 "\n"
		 "Note: the drawable above is the system-vended render target, NOT the physical\n"
		 "~3660x3200/eye micro-OLED panel — the compositor lens-warps the drawable onto\n"
		 "the panel for every app. Past ~2x the footprint there is nothing left to see.\n",
		(double)vp.width, (double)vp.height, vp.width * vp.height / 1e6,
		cp_drawable_get_view_count(drawable),
		openq4_stats.dedicated ? "dedicated" : "layered",
		rmapLine,
		fovH * 180.0 / M_PI, fovV * 180.0 / M_PI, pxPerRadH * M_PI / 180.0,
		(unsigned long)gameTex.width, (unsigned long)gameTex.height,
		gameTex.width * gameTex.height / 1e6,
		panAngH * 180.0 / M_PI, panAngV * 180.0 / M_PI,
		(double)(openq4_screenHalfW * 2.0f), (double)openq4_screenDist,
		footH, footV,
		ssH, ssV, (ssH >= 1.0 && ssV >= 1.0) ? "supersampling" : "UNDERSAMPLING"];

	[report writeToFile:[docs stringByAppendingPathComponent:@"oq4-3d-fidelity.log"]
			 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	OpenQ4_iOS_BlackBox("xr3d: fidelity — drawable %.0fx%.0f/eye, eye image %lux%lu, "
						"footprint %.0fx%.0f, supersample %.2fx/%.2fx, rmaps=%zu",
						(double)vp.width, (double)vp.height,
						(unsigned long)gameTex.width, (unsigned long)gameTex.height,
						footH, footV, ssH, ssV, rmCount);
	openq4_fidelityLogged = true;
}

static double OpenQ4_Immersive_NowMs(void) {
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) { mach_timebase_info(&tb); }
	return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom / 1.0e6;
}

void OpenQ4_Immersive_Run(cp_layer_renderer_t layer_renderer) {
	openq4_immStop = 0;
	openq4_immRunning = 1;
	int notifyEnded = 0;	// only a system/Crown dismissal reconciles via Ended

	id<MTLCommandQueue> queue = nil;
	openq4_panelCopy[0] = nil;
	openq4_panelCopy[1] = nil;
	openq4_haveAnchor = false;	// re-centre the screen on every entry
	openq4_fidelityLogged = false;	// one report per entry into 3D
	openq4_pipelineLayered = nil;
	openq4_dimPipelineLayered = nil;
	memset(&openq4_stats, 0, sizeof(openq4_stats));
	openq4_compCount = 0;
	openq4_compCursor = 0;
	double lastFrameMs = 0.0;
	int lastEngineFrame = -1;

	// ARKit world tracking for the head pose: the compositor reprojects each
	// frame with the device anchor, and a frame without one may never display.
	ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
	ar_world_tracking_provider_t	  wtp = ar_world_tracking_provider_create(wtc);
	ar_session_t					  arSession = ar_session_create();
	ar_data_providers_t				  providers = ar_data_providers_create_with_data_providers(wtp, NULL);
	ar_session_run(arSession, providers);

	OpenQ4_iOS_BlackBox("xr3d: compositor loop started (ARKit world tracking running)");

	int running = 1;
	while (running) {
		if (openq4_immStop) {
			OpenQ4_iOS_BlackBox("xr3d: stop requested, exiting cleanly (frames=%d)",
								openq4_stats.frames);
			running = 0;
			continue;
		}
		switch (cp_layer_renderer_get_state(layer_renderer)) {
			case cp_layer_renderer_state_paused:
				cp_layer_renderer_wait_until_running(layer_renderer);
				continue;
			case cp_layer_renderer_state_invalidated:
				OpenQ4_iOS_BlackBox("xr3d: layer invalidated, exiting loop (frames=%d)",
									openq4_stats.frames);
				openq4_stats.invalidated++;
				notifyEnded = 1;	// Crown dismiss: reconcile shell + SwiftUI state
				running = 0;
				continue;
			case cp_layer_renderer_state_running:
			default:
				break;
		}

		// This thread has no run loop and therefore no autorelease pool.
		@autoreleasepool {
			cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
			if (frame == NULL) { continue; }

			// A failed timing prediction invalidates the frame; every further
			// call on it, cp_frame_end_submission included, is API misuse.
			cp_frame_timing_t timing = cp_frame_predict_timing(frame);
			if (timing == NULL) { continue; }
			cp_frame_start_update(frame);
			cp_frame_end_update(frame);
			// Pace to the compositor cadence, or the loop free-runs and the
			// frames it presents are not displayed.
			cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));

			cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			// The singular query_drawable: available since 1.0 (the plural is 26.0-only).
			cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
			if (drawable == NULL) {
				// Abandon it. See the file header.
				openq4_stats.withheld++;
				if (openq4_stats.withheld == 1) {
					OpenQ4_iOS_BlackBox("xr3d: compositor withheld a drawable at frame %d — "
										"frame abandoned (never end_submission on a miss)",
										openq4_stats.frames);
				}
				continue;
			}

			if (queue == nil) {
				// The queue MUST come from the DRAWABLE's device; a queue from
				// MTLCreateSystemDefaultDevice aborts on a mismatch.
				id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
				queue = [t0.device newCommandQueue];
				OpenQ4_Immersive_BuildPipeline(t0.device, t0.pixelFormat,
											   cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
				openq4_stats.drawableW = (int)t0.width;
				openq4_stats.drawableH = (int)t0.height;
				OpenQ4_iOS_BlackBox("xr3d: drawable %lux%lu views=%zu colorFmt=%lu rateMaps=%zu",
									(unsigned long)t0.width, (unsigned long)t0.height,
									cp_drawable_get_view_count(drawable),
									(unsigned long)t0.pixelFormat,
									cp_drawable_get_rasterization_rate_map_count(drawable));
			}

			// Head pose at this frame's presentation time -> reprojection.
			const CFTimeInterval presTime = cp_time_to_cf_time_interval(
				cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
			ar_device_anchor_t anchor = ar_device_anchor_create();
			const ar_device_anchor_query_status_t anchorStatus =
				ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
			cp_drawable_set_device_anchor(drawable, anchor);
			openq4_stats.anchorOk = (anchorStatus == ar_device_anchor_query_status_success) ? 1 : 0;

			// Anchor the screen once tracking has CONVERGED: the first frames
			// report a near-identity pose, which puts the panel on the floor.
			if (!openq4_haveAnchor && anchorStatus == ar_device_anchor_query_status_success
					&& openq4_stats.frames > 30) {
				openq4_frozenHead = ar_device_anchor_get_origin_from_anchor_transform(anchor);
				openq4_haveAnchor = true;
				OpenQ4_iOS_BlackBox("xr3d: screen anchored at head (%.2f,%.2f,%.2f)",
									openq4_frozenHead.columns[3].x, openq4_frozenHead.columns[3].y,
									openq4_frozenHead.columns[3].z);
			}

			id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];

			// Copy the engine's present PAIR into this loop's own mip-mapped
			// textures, on THIS queue, so the later samples are coherent with
			// them. Both eyes come from one acquire and are released together:
			// they are one frame at one game time and the compositor must never
			// hold half of one.
			int			   srcSlot = -1;
			void		  *rawL = NULL, *rawR = NULL;
			const int	   gotPair = OpenQ4_VK3D_AcquirePresentPair(&rawL, &rawR, &srcSlot);
			if (gotPair) {
				id<MTLTexture> src[2] = { (__bridge id<MTLTexture>)rawL,
										  (__bridge id<MTLTexture>)rawR };
				id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
				for (int e = 0; e < 2; e++) {
					if (src[e] == nil) { continue; }
					if (openq4_panelCopy[e] == nil
							|| openq4_panelCopy[e].width != src[e].width
							|| openq4_panelCopy[e].height != src[e].height
							|| openq4_panelCopy[e].pixelFormat != src[e].pixelFormat) {
						MTLTextureDescriptor *td =
							[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src[e].pixelFormat
																			   width:src[e].width
																			  height:src[e].height
																		   mipmapped:YES];
						td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
						td.storageMode = MTLStorageModePrivate;
						openq4_panelCopy[e] = [src[e].device newTextureWithDescriptor:td];
					}
					[blit copyFromTexture:src[e] toTexture:openq4_panelCopy[e]];
					if (openq4_panelCopy[e].mipmapLevelCount > 1) {
						[blit generateMipmapsForTexture:openq4_panelCopy[e]];
					}
				}
				[blit endEncoding];
				// The engine may not touch this pair again — nor destroy it —
				// until the GPU has finished the blits above. Encoding them is
				// not finishing them, so the release rides the command buffer's
				// completion handler and nothing else.
				[commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
					(void)cb;
					OpenQ4_VK3D_ReleasePresentPair(srcSlot);
				}];
				// pairs counts engine pairs CONSUMED, not compositor frames
				// drawn: when the engine is slower than the compositor the same
				// pair is sampled twice and that is not a new pair. (The
				// ENGINE's own published count is reported separately, and the
				// two together say which side is ahead.)
				const int engineFrames = OpenQ4_VK3D_Frames();
				if (engineFrames != lastEngineFrame) {
					lastEngineFrame = engineFrames;
					openq4_stats.consumed++;
				}
			}

			id<MTLTexture> probe = cp_drawable_get_color_texture(drawable, 0);
			const size_t views = cp_drawable_get_view_count(drawable);
			const size_t rmCount = cp_drawable_get_rasterization_rate_map_count(drawable);
			openq4_stats.views = (int)views;
			openq4_stats.rateMaps = (int)rmCount;
			openq4_stats.foveation = (rmCount > 0) ? 1 : 0;

			// Which layout the compositor actually GRANTED, read off the views'
			// own texture maps rather than believed from what was requested:
			// layered = every view in one array texture, dedicated = a texture
			// each. D-100 asked for .dedicated and the headset reported
			// layered, so the loop decides from the drawable, every frame.
			BOOL layeredDrawable = NO;
			if (views > 1) {
				const size_t t0 = cp_view_texture_map_get_texture_index(
					cp_view_get_view_texture_map(cp_drawable_get_view(drawable, 0)));
				const size_t t1 = cp_view_texture_map_get_texture_index(
					cp_view_get_view_texture_map(cp_drawable_get_view(drawable, 1)));
				layeredDrawable = (t0 == t1);
			}
			openq4_stats.dedicated = layeredDrawable ? 0 : 1;
			// The layered path is only taken when there is a rate map to get
			// wrong: without foveation a pass per slice is correct and simpler,
			// and it is the path three rounds have been verified on.
			const BOOL useLayeredPass = layeredDrawable && rmCount > 0
				&& openq4_pipelineLayered != nil && openq4_dimPipelineLayered != nil;
			openq4_stats.fovLayered = useLayeredPass ? 1 : 0;
			if (layeredDrawable && rmCount > 0 && !useLayeredPass) {
				// Loud, once: this is the right-eye fisheye about to happen.
				static int warned = 0;
				if (!warned) {
					warned = 1;
					OpenQ4_iOS_BlackBox("xr3d: WARNING — layered foveated drawable but the "
										"layered pipelines did not build; the right eye will "
										"rasterize with layer 0's rate map (fisheye). Turn the "
										"Foveation row off.");
				}
			}
			if (rmCount > 0) {
				id<MTLRasterizationRateMap> map0 = cp_drawable_get_rasterization_rate_map(drawable, 0);
				if (map0 != nil) {
					const MTLSize scr = map0.screenSize;
					const MTLSize phys = [map0 physicalSizeForLayer:0];
					openq4_stats.rmapScreenW = (int)scr.width;
					openq4_stats.rmapScreenH = (int)scr.height;
					openq4_stats.rmapPhysW = (int)phys.width;
					openq4_stats.rmapPhysH = (int)phys.height;
				}
			} else {
				openq4_stats.rmapScreenW = openq4_stats.rmapScreenH = 0;
				openq4_stats.rmapPhysW = openq4_stats.rmapPhysH = 0;
			}

			const simd_float4x4 placement = openq4_haveAnchor
				? openq4_make_screen_anchor(openq4_frozenHead)
				: openq4_translate(0.0f, 0.0f, -openq4_screenDist);
			const simd_float4x4 model =
				simd_mul(placement, openq4_scale(openq4_screenHalfW, openq4_screenHalfH, 1.0f));
			const simd_float4x4 originFromDevice =
				ar_device_anchor_get_origin_from_anchor_transform(anchor);

			float srgbDecode = 0.0f;
			if (openq4_panelCopy[0] != nil) {
				const MTLPixelFormat sf = openq4_panelCopy[0].pixelFormat, df = probe.pixelFormat;
				const BOOL srcEncoded = (sf == MTLPixelFormatBGRA8Unorm || sf == MTLPixelFormatRGBA8Unorm);
				const BOOL dstLinear = (df == MTLPixelFormatBGRA8Unorm_sRGB
										|| df == MTLPixelFormatRGBA8Unorm_sRGB
										|| df == MTLPixelFormatRGBA16Float);
				srgbDecode = (srcEncoded && dstLinear) ? 1.0f : 0.0f;
			}

			if (useLayeredPass) {
				/*
				 * LAYERED + FOVEATION: ONE pass over the array texture, with
				 * renderTargetArrayLength = views and the single multi-layer
				 * rate map attached. Each view's draw names its layer through
				 * render_target_array_index, so the rasterizer uses THAT
				 * layer's map. A pass per slice cannot: it always rasterizes
				 * with layer 0's map while the compositor unwarps each eye with
				 * its own, and the right eye becomes a head-coupled fisheye
				 * (foveation guide, trap 1 — it cost Ship of Harkinian a device
				 * round; it does not get to cost this port one).
				 */
				cp_view_t			  v0 = cp_drawable_get_view(drawable, 0);
				cp_view_texture_map_t t0map = cp_view_get_view_texture_map(v0);
				const size_t		  texIdx = cp_view_texture_map_get_texture_index(t0map);

				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, texIdx);
				pass.colorAttachments[0].loadAction = MTLLoadActionClear;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
				pass.rasterizationRateMap =
					cp_drawable_get_rasterization_rate_map(drawable, texIdx < rmCount ? texIdx : 0);
				pass.renderTargetArrayLength = views;
				id<MTLTexture> depthTex = cp_drawable_get_depth_texture(drawable, texIdx);
				if (depthTex != nil) {
					pass.depthAttachment.texture = depthTex;
					pass.depthAttachment.loadAction = MTLLoadActionClear;
					pass.depthAttachment.storeAction = MTLStoreActionStore;
					pass.depthAttachment.clearDepth = 1.0;
				}

				id<MTLRenderCommandEncoder> enc =
					[commandBuffer renderCommandEncoderWithDescriptor:pass];
				for (size_t v = 0; v < views; v++) {
					cp_view_t			  view = cp_drawable_get_view(drawable, v);
					cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
					const MTLViewport	  vp = cp_view_texture_map_get_viewport(tmap);
					const uint32_t		  layer =
						(uint32_t)cp_view_texture_map_get_slice_index(tmap);
					OpenQ4_Immersive_DrawPanelView(enc, drawable, view, v, vp, model,
												   originFromDevice, srgbDecode, YES, layer);
				}
				[enc endEncoding];
			} else {
				for (size_t v = 0; v < views; v++) {
					// Layout-agnostic per-view targeting through the view's
					// texture map. NEVER hardcode texture 0 / slice v: with
					// .dedicated each view has its own texture AND its own rate
					// map, and attaching the wrong one is the fisheye trap.
					cp_view_t			  view = cp_drawable_get_view(drawable, v);
					cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
					const size_t		  texIdx = cp_view_texture_map_get_texture_index(tmap);
					const size_t		  slice = cp_view_texture_map_get_slice_index(tmap);
					const MTLViewport	  vp = cp_view_texture_map_get_viewport(tmap);

					MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
					pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, texIdx);
					pass.colorAttachments[0].slice = slice;
					pass.colorAttachments[0].loadAction = MTLLoadActionClear;
					pass.colorAttachments[0].storeAction = MTLStoreActionStore;
					pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
					// The dedicated path's whole point: map[texIdx] is THIS
					// view's own rate map. With no foveation the count is 0 and
					// this is a no-op.
					if (rmCount > 0) {
						pass.rasterizationRateMap =
							cp_drawable_get_rasterization_rate_map(drawable,
																   texIdx < rmCount ? texIdx : 0);
					}
					id<MTLTexture> depthTex = cp_drawable_get_depth_texture(drawable, texIdx);
					if (depthTex != nil) {
						pass.depthAttachment.texture = depthTex;
						pass.depthAttachment.slice = slice;
						pass.depthAttachment.loadAction = MTLLoadActionClear;
						pass.depthAttachment.storeAction = MTLStoreActionStore;
						pass.depthAttachment.clearDepth = 1.0;
					}

					id<MTLRenderCommandEncoder> enc =
						[commandBuffer renderCommandEncoderWithDescriptor:pass];
					OpenQ4_Immersive_DrawPanelView(enc, drawable, view, v, vp, model,
												   originFromDevice, srgbDecode, NO, 0);
					[enc endEncoding];
				}
			}

			// One-shot, and only once the engine image exists to measure.
			OpenQ4_Immersive_LogFidelity(drawable, openq4_panelCopy[0]);

			cp_drawable_encode_present(drawable, commandBuffer);
			[commandBuffer commit];

			openq4_stats.frames++;
			const double now = OpenQ4_Immersive_NowMs();
			if (lastFrameMs > 0.0) {
				openq4_compSamples[openq4_compCursor] = now - lastFrameMs;
				openq4_compCursor = (openq4_compCursor + 1) % OPENQ4_COMP_SAMPLES;
				if (openq4_compCount < OPENQ4_COMP_SAMPLES) { openq4_compCount++; }
			}
			lastFrameMs = now;

			if (openq4_stats.frames == 3 || (openq4_stats.frames % 600) == 0) {
				int eyeL = 0, eyeR = 0, pairs = 0;
				OpenQ4_VK3D_EyeStats(&eyeL, &eyeR, &pairs);
				OpenQ4_iOS_BlackBox("xr3d: frame %d — eye %lux%lu pairs=%d eyeL=%d eyeR=%d "
									"views=%d withheld=%d srgbDecode=%.0f dim=%.2f",
									openq4_stats.frames,
									(unsigned long)(openq4_panelCopy[0] ? openq4_panelCopy[0].width : 0),
									(unsigned long)(openq4_panelCopy[0] ? openq4_panelCopy[0].height : 0),
									pairs, eyeL, eyeR, (int)views,
									openq4_stats.withheld, srgbDecode, openq4_dimSetting);
			}

			cp_frame_end_submission(frame);
		}	// @autoreleasepool
	}

	openq4_panelCopy[0] = nil;
	openq4_panelCopy[1] = nil;
	if (notifyEnded) {
		OpenQ4_Vision3D_ImmersiveEnded();	// Crown/system dismissal path only
	}
	openq4_immRunning = 0;					// signal the shell LAST, after cleanup
}

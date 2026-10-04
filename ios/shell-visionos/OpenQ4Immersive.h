/*
 * OpenQ4Immersive.h — the CompositorServices render loop for the visionOS 3D
 * panel (Phase 6, D-100 + D-101). Round 3 is STEREO: the engine publishes a
 * PAIR of images per frame and view 0 samples the left eye, view 1 the right.
 *
 * Shape and every hard-won detail come from vkQuake-ios
 * ios/shell-visionos/VKQImmersive.m (its D-026/D-030/D-039) — this is a port of
 * a working loop, not a fresh one.
 */

#import <CompositorServices/CompositorServices.h>

// Entry point for the thread the CompositorLayer closure spawns. Blocks running
// the frame loop until the layer is invalidated or openq4_immStop is set.
void OpenQ4_Immersive_Run(cp_layer_renderer_t layer_renderer);

// Graceful-shutdown handshake: the shell sets openq4_immStop and waits for
// openq4_immRunning to clear BEFORE dismissing the space, so the render thread
// never touches a layer renderer SwiftUI is tearing down.
extern volatile int openq4_immStop;
extern volatile int openq4_immRunning;

// Live panel tuning (metres), driven by the settings sheet and !xr3dtune. All
// of it takes effect on the NEXT compositor frame — the placement is recomputed
// from the frozen head pose every frame, so a slider is live while dragging.
void OpenQ4_Immersive_SetPanel(float dist, float halfW, float halfH);
void OpenQ4_Immersive_SetHeight(float h);
void OpenQ4_Immersive_SetDim(float dim);
float OpenQ4_Immersive_Dim(void);
void OpenQ4_Immersive_GetPanel(float *dist, float *halfW, float *halfH, float *height);
void OpenQ4_Immersive_Recenter(void);

// Counters behind `!xr3diag` (docs/stereo-design.md §7). Any pointer may be NULL.
typedef struct OpenQ4ImmersiveStats_s {
	int		frames;			// cp_frames submitted
	int		withheld;		// drawables the compositor withheld
	int		invalidated;	// layer-invalidated exits
	int		consumed;		// distinct engine pairs this loop actually sampled
	int		pairs;			// pairs the ENGINE published
	int		eyeL, eyeR;		// per-eye renders; they must advance together
	float	dim;			// surroundings dimming, 0..1 as the slider stores it
	int		anchorOk;		// device anchor query succeeded on the last frame
	int		views;			// cp_drawable view count
	int		dedicated;		// 1 = dedicated layout (a texture per view)
	int		foveation;		// rasterization rate maps present
	int		rateMaps;
	int		fovLayered;		// 1 = the layered rate-map path (one multi-layer map)
	int		rmapScreenW, rmapScreenH;	// granted rate map: logical (screen) size
	int		rmapPhysW, rmapPhysH;		// ... and the physical size it compresses to
	int		drawableW, drawableH;
	int		eyeW, eyeH;		// engine present-image size
	int		notReady;		// fence polls that found the GPU not yet finished
	int		submitted;		// engine frames rendered into a present image
	int		published;		// of those, the ones that reached the panel
	int		pubLatency;		// engine frames from submit to publish, p50 (-1 = none yet)
	int		superseded;		// finished frames a newer one replaced before publish
	int		stalls;			// engine frames that waited for a free present image
	int		overruns;		// engine frames that found none even after waiting
	int		halfPairs;		// right eyes that fell back to the window
	double	compP50, compP95;	// compositor frame interval, ms
} OpenQ4ImmersiveStats;

void OpenQ4_Immersive_GetStats(OpenQ4ImmersiveStats *out);

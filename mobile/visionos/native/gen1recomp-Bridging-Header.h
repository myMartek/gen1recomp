//  Bridging header for the visionOS app targets.
//
//  The Swift shell reaches liblove through a deliberately tiny C surface.
//  Everything else -- LOVE's C++ types, the Lua state, Metal objects -- stays
//  on the other side of it. This follows the same discipline as
//  mobile/ios/patch_love_src.py, which reaches its Swift bridges through the
//  ObjC runtime so that liblove never has to link Swift.

#ifndef GEN1RECOMP_BRIDGING_HEADER_H
#define GEN1RECOMP_BRIDGING_HEADER_H

#include <stdbool.h>

/// Render into an offscreen backbuffer instead of looking for a layer to
/// present to. Must be called before love_visionos_boot(); on visionOS there
/// is no CAMetalLayer for a fully immersive app to present into.
void love_visionos_setHeadless(bool headless);
bool love_visionos_getHeadless(void);

/// Brings SDL's video and event subsystems up. MUST run on the main thread:
/// SDL's video init reaches into UIKit, which asserts a main-run-loop barrier.
void love_visionos_prepareOnMainThread(void);

/// Runs LOVE on the calling thread. Does not return.
int love_visionos_boot(void);

/// The offscreen backbuffer LOVE has been drawing into, as an id<MTLTexture>.
/// NULL before the first setMode, or when not running headless.
void *love_visionos_virtualScreenTexture(void);

/// Hands the compositor's layer renderer to love.xr. Until Lua claims it the
/// host keeps drawing; see love_visionos_xrClaimed.
void love_visionos_setLayerRenderer(void *layerRenderer);

/// True while Lua owns the frame loop. The host's renderer must stand down:
/// two loops calling cp_frame_* on one layer is a race.
bool love_visionos_xrClaimed(void);

/// LOVE's save directory, once the filesystem module is up. Empty before that.
/// This is the only reliable answer to "where do I put a ROM".
const char *love_visionos_saveDirectory(void);

#endif /* GEN1RECOMP_BRIDGING_HEADER_H */

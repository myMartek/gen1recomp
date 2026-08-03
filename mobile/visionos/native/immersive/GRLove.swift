//  Booting LÖVE inside the visionOS shell, and getting at what it drew.
//
//  LÖVE runs headless here: no layer, no presented window. Every frame lands
//  in an offscreen "virtual screen" texture, which is what both presentations
//  consume -- the flat window shows it directly, and in VR the voxel mod maps
//  it onto in-world geometry (CompositorServices has no equivalent of the
//  OpenXR quad layer the mod uses for menus on Windows).

import Foundation
import Metal
import os

enum GRLove {

    static let log = Logger(subsystem: "com.gen1recomp.xr", category: "love")

    private static var booted = false

    /// Starts LÖVE on its own thread. Safe to call more than once.
    ///
    /// Its own thread because love_visionos_boot() never returns: LÖVE owns
    /// that thread's run loop for the lifetime of the app, exactly as it does
    /// on iOS. The main thread stays free for SwiftUI and UIKit.
    @MainActor
    static func bootOnce() {
        guard !booted else { return }
        booted = true

        love_visionos_setHeadless(true)

        // On the main thread, before LÖVE's own thread exists: SDL's video
        // init calls into UIKit, and BoardServices traps if that happens
        // anywhere else.
        love_visionos_prepareOnMainThread()

        let thread = Thread {
            log.notice("booting LÖVE (headless)")
            _ = love_visionos_boot()
            log.error("love_visionos_boot returned, which it is not supposed to do")
        }
        thread.name = "love"
        // LÖVE's Lua call depth is not shallow, and 512 KiB (the default for a
        // secondary thread) is not enough headroom for it.
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The texture LÖVE is drawing into, once it has set a mode.
    static var virtualScreen: MTLTexture? {
        guard let raw = love_visionos_virtualScreenTexture() else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? MTLTexture
    }

    /// Sample the virtual screen and report what is actually in it.
    ///
    /// This exists because "the app runs and does not crash" turned out, more
    /// than once in this port, to be perfectly compatible with "it renders
    /// nothing anyone can see". A texture full of a single colour is the
    /// signature of a clear with no draw after it; a spread of distinct
    /// colours means LÖVE genuinely drew a frame.
    static func describeVirtualScreen() -> String {
        guard let tex = virtualScreen else { return "virtual screen: not created yet" }

        let w = tex.width, h = tex.height
        guard w > 0, h > 0 else { return "virtual screen: empty (\(w)x\(h))" }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        pixels.withUnsafeMutableBytes { buf in
            tex.getBytes(buf.baseAddress!,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, w, h),
                         mipmapLevel: 0)
        }

        var distinct = Set<UInt32>()
        var nonBlack = 0
        for y in stride(from: 0, to: h, by: max(1, h / 64)) {
            for x in stride(from: 0, to: w, by: max(1, w / 64)) {
                let i = y * bytesPerRow + x * 4
                let px = UInt32(pixels[i]) << 24 | UInt32(pixels[i+1]) << 16
                       | UInt32(pixels[i+2]) << 8 | UInt32(pixels[i+3])
                distinct.insert(px)
                if pixels[i] > 8 || pixels[i+1] > 8 || pixels[i+2] > 8 { nonBlack += 1 }
            }
        }
        return "virtual screen: \(w)x\(h) \(tex.pixelFormat.rawValue), "
             + "\(distinct.count) distinct colours, \(nonBlack) non-black samples"
    }
}

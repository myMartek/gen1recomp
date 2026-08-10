//  Booting LÖVE inside the visionOS shell, and getting at what it drew.
//
//  LÖVE runs headless here: no layer, no presented window. Every frame lands
//  in an offscreen "virtual screen" texture, which is what both presentations
//  consume -- the flat window shows it directly, and in VR the voxel mod maps
//  it onto in-world geometry (CompositorServices has no equivalent of the
//  OpenXR quad layer the mod uses for menus on Windows).

import ARKit
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
    ///
    /// Cached after the first success. The lookup behind it walks LÖVE's
    /// module registry and does a dynamic_cast, from a thread that is not
    /// LÖVE's -- doing that every frame was both wasteful and racy, and an
    /// occasional nil made the view present a cleared black frame instead of
    /// the game. Alternating black and picture is precisely the flicker that
    /// caused. The texture is created once in setMode and never replaced.
    private static var cachedScreen: MTLTexture?
    private static var cachedRaw: UnsafeMutableRawPointer?
    private static var wantsFreshScreen = false

    /// Tells the cache that LÖVE is about to build a new screen.
    ///
    /// "Created once and never replaced" holds for a run, and an engine
    /// restart (the language switch) ends one run and starts another. Without
    /// this the window keeps presenting the texture the previous LÖVE drew
    /// into -- which nothing writes to any more, so every menu comes up black
    /// while the game behind it renders fine. That is not a caching detail; it
    /// is the whole visible symptom.
    static func invalidateVirtualScreen() {
        wantsFreshScreen = true
    }

    static var virtualScreen: MTLTexture? {
        if !wantsFreshScreen, let cached = cachedScreen { return cached }
        guard let raw = love_visionos_virtualScreenTexture() else {
            // Mid-restart there is no screen at all for a few frames. The last
            // one is dead but it is a picture; nil here would be a black flash
            // on every switch.
            return cachedScreen
        }
        if wantsFreshScreen {
            // The SAME pointer means the new run has not called setMode yet.
            // Accepting it would re-cache the dead texture and leave the
            // window black for good, which is the bug this exists to avoid.
            if raw == cachedRaw { return cachedScreen }
            wantsFreshScreen = false
        }
        cachedRaw = raw
        cachedScreen = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? MTLTexture
        return cachedScreen
    }

    /// Asks for hand tracking and world sensing, once, at app start.
    ///
    /// ARKit grants nothing implicitly: ar_session_run starts a provider
    /// whether or not its permission exists, and an unauthorised one simply
    /// produces no anchors -- no error, no prompt, no hands.
    ///
    /// At START rather than when the game claims the frame loop, which is
    /// where it first sat. Asking mid-session puts a system dialog over the
    /// world the moment someone turns VR on, and a reflexive dismissal
    /// disables hand tracking for the rest of the run. Asking here costs one
    /// prompt on first launch and nothing afterwards.
    ///
    /// The session is temporary on purpose: authorization belongs to the app,
    /// not to the session that asked, so love.xr's own session inherits it.
    static func requestTrackingAuthorization() {
        Task.detached(priority: .utility) {
            let session = ARKitSession()
            let results = await session.requestAuthorization(for: [.handTracking, .worldSensing])
            for (type, status) in results {
                log.notice("ARKit authorization \(String(describing: type), privacy: .public): \(String(describing: status), privacy: .public)")
            }
        }
    }

    /// LÖVE's Metal command queue.
    ///
    /// Every presentation of the virtual screen encodes on this queue rather
    /// than one of its own. Metal keeps command buffers on a single queue in
    /// commit order and gives no ordering whatsoever between two queues, so a
    /// reader with its own queue could sample the texture in the gap between
    /// LÖVE's clear and LÖVE's draws and come away with an empty frame. That
    /// is the flicker, and sharing the queue removes it rather than making it
    /// rarer.
    ///
    /// Cached like the texture above, and for the same reason: the lookup
    /// behind it walks LÖVE's module registry from a thread that is not
    /// LÖVE's.
    private static var cachedQueue: MTLCommandQueue?

    static var commandQueue: MTLCommandQueue? {
        if let cached = cachedQueue { return cached }
        guard let raw = love_visionos_commandQueue() else { return nil }
        cachedQueue = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? MTLCommandQueue
        return cachedQueue
    }

    /// Where LÖVE writes. Empty until its filesystem module is up.
    static var saveDirectory: String {
        String(cString: love_visionos_saveDirectory())
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

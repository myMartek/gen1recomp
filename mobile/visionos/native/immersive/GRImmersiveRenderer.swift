//  The CompositorServices frame loop.
//
//  Draws LÖVE's virtual screen as a world-locked panel: ARKit supplies the
//  device anchor, CompositorServices supplies one view transform and one
//  projection per eye, and the panel stays where it was put while the player
//  looks around.
//
//  The eventual job of this file is to hand the drawable textures to the voxel
//  mod so it renders the world itself, per eye, instead of a flat panel. The
//  panel is not throwaway though -- CompositorServices has no equivalent of
//  the OpenXR quad layer the mod uses for menus and the Pokédex screen on
//  Windows, so this is how that comes back.

import ARKit
import CompositorServices
import Metal
import simd

private extension Duration {
    /// CompositorServices deals in Clock.Instants, ARKit's queryDeviceAnchor
    /// wants seconds. This is the bridge between them.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) * 1e-18
    }
}

final class GRImmersiveRenderer {

    private let layerRenderer: LayerRenderer
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    private var panelPipeline: MTLRenderPipelineState?
    private var pipelineFormat: MTLPixelFormat = .invalid
    private var depthFormat: MTLPixelFormat = .invalid
    private var depthState: MTLDepthStencilState?

    private struct PanelUniforms {
        var modelViewProjection: matrix_float4x4
        var halfSize: SIMD2<Float>
    }

    #if targetEnvironment(simulator)
    private var eyePipeline: MTLRenderPipelineState?
    private var eyePipelineFormat: MTLPixelFormat = .invalid
    private var eyeDepthFormat: MTLPixelFormat = .invalid

    private struct FlatUniforms {
        var uvScale: SIMD2<Float>
    }
    #endif

    /// Where the panel hangs, captured from the head on the first tracked
    /// frame rather than fixed in world space.
    ///
    /// A constant was wrong twice, in opposite directions, because ARKit's
    /// world origin is not in the same place on the simulator as on the
    /// device: y = 1.35 floated a metre above eye level in the simulator, and
    /// y = 0 sat on the floor on a real Vision Pro. Rather than guess a third
    /// time, this places the panel at the height the head actually is, two
    /// metres along the direction it is actually facing -- correct wherever
    /// the origin happens to be.
    private var panelCentre: SIMD3<Float>?
    private var panelYaw: Float = 0

    private let panelDistance: Float = 2.0
    /// Sized by HEIGHT, not width: the game frame is portrait, so driving the
    /// size from the width made a panel nearly three metres tall -- taller
    /// than the field of view at two metres away.
    private let panelHeight: Float = 1.3

    init?(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        // The compositor's device, not MTLCreateSystemDefaultDevice(): the
        // textures we render into belong to it.
        self.device = layerRenderer.device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
    }

    func run() {
        // World tracking has to be running before the first device anchor
        // query, and the query is what makes the panel world-locked rather
        // than welded to the player's face.
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                GRLove.log.error("ARKit world tracking failed to start: \(error, privacy: .public)")
            }
        }

        while true {
            switch layerRenderer.state {
            case .paused:
                // The space is open but not being presented. Block rather than
                // spin.
                layerRenderer.waitUntilRunning()
            case .running:
                // Lua owns the loop once the mod turns VR on. Both of us
                // calling cp_frame_* on one layer would race, so this stands
                // down entirely rather than trying to interleave.
                if love_visionos_xrClaimed() {
                    usleep(4000)
                } else {
                    renderFrame()
                }
            case .invalidated:
                return
            @unknown default:
                return
            }
        }
    }

    private var loggedGeometry = false

    /// States, once, whether this is actually stereo -- and how much.
    ///
    /// "Is it really stereo?" is not a question to answer by looking, because
    /// the panel is a flat quad and flat things look flat in correct stereo
    /// too. It is a question about numbers: two views, two eye transforms, and
    /// a separation between them of roughly an interpupillary distance. If the
    /// separation were zero the two eyes would be receiving the same picture
    /// no matter how the rest of the pipeline behaved.
    private func logGeometryOnce(drawable: LayerRenderer.Drawable,
                                 originFromDevice: simd_float4x4,
                                 viewCount: Int,
                                 layered: Bool) {
        guard !loggedGeometry, viewCount > 0 else { return }
        loggedGeometry = true

        var separation: Float = -1
        if viewCount >= 2 {
            let a = (originFromDevice * drawable.views[0].transform).columns.3
            let b = (originFromDevice * drawable.views[1].transform).columns.3
            separation = simd_length(SIMD3<Float>(a.x - b.x, a.y - b.y, a.z - b.z))
        }

        let line = "stereo geometry: views=\(viewCount)"
            + " colorTextures=\(drawable.colorTextures.count)"
            + " layout=\(layered ? "layered" : "dedicated")"
            + " eyeSeparation=" + String(format: "%.4f m", separation)

        GRLove.log.notice("\(line, privacy: .public)")
        // Also to stdout: `devicectl device process launch --console` bridges
        // that to the terminal, and this Mac's `log` has no way to stream from
        // the device at all -- so the os.Logger line above is, in practice,
        // write-only.
        print(line)
    }

    private func pipeline(for format: MTLPixelFormat, depth: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = panelPipeline, pipelineFormat == format, depthFormat == depth { return p }
        guard let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "gr_panel_vertex"),
              let ffn = library.makeFunction(name: "gr_panel_fragment")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = format
        desc.depthAttachmentPixelFormat = depth
        panelPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        pipelineFormat = format
        depthFormat = depth

        // Reverse-Z: CompositorServices wants 1 at the near plane and 0 at the
        // far one, so "closer" is "greater" and the buffer clears to 0.
        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .greater
        dsd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dsd)

        return panelPipeline
    }

    #if targetEnvironment(simulator)
    /// The same fullscreen blit the flat window uses, aimed at an eye texture.
    ///
    /// Deliberately not the panel pipeline: what the mod hands over here is a
    /// picture already drawn through this eye's own frustum, so it belongs
    /// across the whole view and nowhere else. Putting it on the world-locked
    /// quad instead -- which is what this did first -- shows a correct VR frame
    /// as a poster on a wall: it fills a fraction of the field, and turning the
    /// head slides the poster instead of moving through the scene.
    private func eyeBlitPipeline(for format: MTLPixelFormat,
                                 depth: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = eyePipeline, eyePipelineFormat == format, eyeDepthFormat == depth { return p }
        guard let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "gr_flat_vertex"),
              let ffn = library.makeFunction(name: "gr_flat_fragment")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = format
        desc.depthAttachmentPixelFormat = depth
        eyePipeline = try? device.makeRenderPipelineState(descriptor: desc)
        eyePipelineFormat = format
        eyeDepthFormat = depth
        return eyePipeline
    }

    /// Hands the mod the camera it cannot ask for itself.
    ///
    /// The mod does not own the frame loop in the simulator, so it holds no
    /// drawable and knows neither where the head is nor how wide the frustum.
    /// This loop holds both. Published every frame, consumed by love.xr.views
    /// -- which then runs exactly the arithmetic it runs on the device.
    private func publishSimView(drawable: LayerRenderer.Drawable,
                                originFromDevice: simd_float4x4) {
        guard let view = drawable.views.first,
              let colour = drawable.colorTextures.first else { return }
        let proj = drawable.computeProjection(viewIndex: 0)
        // For an off-centre frustum P[0][0] = 2n/(r-l) and P[2][0] = (r+l)/(r-l),
        // which rearranges to these. Same four lines as wrap_XR's device path,
        // and they have to stay the same four lines.
        let tanRight = ( 1 + proj.columns.2.x) / proj.columns.0.x
        let tanLeft  = (-1 + proj.columns.2.x) / proj.columns.0.x
        let tanUp    = ( 1 + proj.columns.2.y) / proj.columns.1.y
        let tanDown  = (-1 + proj.columns.2.y) / proj.columns.1.y


        love_visionos_setSimView(0, 1, originFromDevice, view.transform,
                                 tanLeft, tanRight, tanUp, tanDown,
                                 UInt32(colour.width), UInt32(colour.height))
    }
    #endif

    private func renderFrame() {
        // Atomic handover with love.xr. A plain poll in run() is not enough:
        // Lua can claim the layer while this function sleeps until optimal
        // input time, leaving two clients to query the same compositor frame.
        guard love_visionos_beginHostFrame() else { return }
        defer { love_visionos_endHostFrame() }

        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        // A FRAME WITH NOTHING TO PRESENT IS ABANDONED, NOT SUBMITTED.
        //
        // This used to open and immediately close a submission on the way out,
        // to avoid leaving the compositor holding a frame nobody finished. It
        // is the wrong way to let go: a submission for a frame that never
        // queried a drawable is a client error, and CompositorServices does
        // not return an error for it -- it aborts the process.
        //
        //   Thread gen1recomp.compositor
        //     cp_frame_start_submission
        //     __BUG_IN_CLIENT__ -> abort()
        //
        // Which is what pressing the Digital Crown did: a space on its way out
        // stops handing out timing and drawables, both guards below fired, and
        // the app took itself down instead of ending the session. Returning is
        // what Apple's own loop does, and releasing the frame is what gives it
        // back.
        guard let timing = frame.predictTiming() else { return }
        // Sleeping until the optimal input time is what keeps the head pose
        // fresh: everything sampled after this is closer to the moment the
        // frame is actually shown.
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        // xrOS 26 can provide built-in and capture targets together. The old
        // queryDrawable() aborts for a foveated quality-1 layer; the array API
        // must be queried before submission starts.
        let drawables = frame.queryDrawables()
        guard let drawable = drawables.first(where: { $0.target == .builtIn })
                ?? drawables.first else { return }

        frame.startSubmission()

        // Anchor the frame to where the device will be when it is displayed,
        // not where it is now. Handing it to the drawable also lets the
        // compositor reproject if we miss the deadline.
        let presentTime = LayerRenderer.Clock.Instant.epoch
            .duration(to: timing.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: presentTime)
        drawable.deviceAnchor = deviceAnchor

        // LÖVE's queue when it has one, because this frame samples the virtual
        // screen for the panel and LÖVE writes that texture from its own
        // thread. Metal orders command buffers within a queue by commit order
        // and does not order across queues at all, so encoding here on a queue
        // of our own can read the texture in the window between LÖVE's clear
        // and LÖVE's draws -- an empty panel, now and then, which is what the
        // flicker was. `queue` (the compositor device's own) still covers the
        // frames drawn before LÖVE's graphics module is up.
        //
        // Same device either way: LÖVE's Metal backend takes the compositor's,
        // and textures cannot be shared across MTLDevices in any case -- the
        // panel has been sampling this one all along.
        //
        // Submission has already begun here, so this one must end it.
        guard let commandBuffer = (GRLove.commandQueue ?? queue).makeCommandBuffer()
        else {
            frame.endSubmission()
            return
        }

        let screen = GRLove.virtualScreen

        // In the SIMULATOR, show what the mod rendered rather than the flat
        // virtual screen. It cannot present for itself there -- see
        // love_visionos_simEyeTexture -- so it draws its VR frame into a
        // texture and this loop, which does still get drawables, puts it up.
        #if targetEnvironment(simulator)
        var modEye: MTLTexture? = nil
        if let raw = love_visionos_simEyeTexture() {
            modEye = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? MTLTexture
        }
        #endif
        let originFromDevice = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        #if targetEnvironment(simulator)
        publishSimView(drawable: drawable, originFromDevice: originFromDevice)
        #endif

        // One view per EYE, not one per texture.
        //
        // These are the same number only under the `dedicated` layout, which
        // gives a plain 2D texture per eye. Under `layered` there is a single
        // texture with one array slice per eye, so iterating the textures runs
        // the loop once, writes slice 0, and leaves the right eye untouched --
        // both eyes then show the same picture, which is mono wearing a stereo
        // costume and looks exactly like "it feels flat". GRApp asks for
        // dedicated and falls back to layered, so this has to hold for both.
        let viewCount = drawable.views.count
        let layered = drawable.colorTextures.count < viewCount

        logGeometryOnce(drawable: drawable, originFromDevice: originFromDevice,
                        viewCount: viewCount, layered: layered)

        for index in 0..<viewCount {
            let target = drawable.colorTextures[layered ? 0 : index]

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            // Selects this eye's slice of the array texture; 0 and ignored
            // when each eye has a texture of its own.
            pass.colorAttachments[0].slice = layered ? index : 0
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            // Black. This was magenta while "no frame yet" needed to be
            // unmistakable, then a near-black with a little blue in it -- and
            // that little blue is visible: it draws a faint lit rectangle
            // around the panel in a room that is otherwise off. Nothing is
            // gained by not being black here.
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1.0)

            // The depth attachment is NOT optional. A drawable carries one per
            // view and the compositor reprojects against it; submitting a frame
            // that never wrote depth is a client error, and on device it aborts
            // the process inside cp_frame_end_submission. (The simulator does
            // not reproject, which is why it tolerated this.)
            var depthTexture: MTLTexture? = nil
            if !drawable.depthTextures.isEmpty {
                depthTexture = drawable.depthTextures[layered ? 0 : index]
                pass.depthAttachment.texture = depthTexture
                pass.depthAttachment.slice = layered ? index : 0
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                // 0 is the far plane under reverse-Z.
                pass.depthAttachment.clearDepth = 0.0
            }

            let rateMap = drawable.rasterizationRateMaps.isEmpty ? nil
                : drawable.rasterizationRateMaps[
                    min(layered ? 0 : index, drawable.rasterizationRateMaps.count - 1)]
            pass.rasterizationRateMap = rateMap

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            if let rateMap {
                let size = rateMap.screenSize
                encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                                width: Double(size.width),
                                                height: Double(size.height),
                                                znear: 0, zfar: 1))
            }

            // The mod's own frame, across the whole view: it was drawn through
            // this eye's frustum, so there is nothing left to place it in.
            //
            // No depth state, and so no depth written: the compositor does not
            // reproject in the simulator (see the depth attachment note above),
            // and there is no meaningful per-pixel depth to give it for a
            // picture that arrives already flattened.
            #if targetEnvironment(simulator)
            if let eye = modEye {
                if let blit = eyeBlitPipeline(for: target.pixelFormat,
                                              depth: depthTexture?.pixelFormat ?? .invalid) {
                    var flat = FlatUniforms(uvScale: SIMD2<Float>(1, 1))
                    encoder.setRenderPipelineState(blit)
                    encoder.setFragmentTexture(eye, index: 0)
                    encoder.setFragmentBytes(&flat,
                                             length: MemoryLayout<FlatUniforms>.stride,
                                             index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                encoder.endEncoding()
                continue
            }
            #endif

            // Drawn again: with the launcher dismissed during immersion this
            // is the only thing in the space. It is softer than the native
            // window and not as well reprojected -- that trade is deliberate,
            // and it goes away when the voxel mod renders the world per eye.
            if let screen,
               let pipeline = pipeline(for: target.pixelFormat,
                                       depth: depthTexture?.pixelFormat ?? .invalid),
               index < drawable.views.count {

                let view = drawable.views[index]
                // originFromDevice * deviceFromView gives where this eye is in
                // the world; the inverse is what takes world space to eye space.
                let worldFromView = originFromDevice * view.transform
                let viewMatrix = worldFromView.inverse
                let projection = drawable.computeProjection(viewIndex: index)

                // Placed once, on the first frame with a real head pose, and
                // then left alone: a panel that chased the head would defeat
                // the whole point of world-locking it.
                if panelCentre == nil, deviceAnchor != nil {
                    let headPos = SIMD3<Float>(originFromDevice.columns.3.x,
                                               originFromDevice.columns.3.y,
                                               originFromDevice.columns.3.z)
                    // -Z of the head transform is where the player is looking.
                    let fwd = -SIMD3<Float>(originFromDevice.columns.2.x,
                                            0,
                                            originFromDevice.columns.2.z)
                    let len = simd_length(fwd)
                    let dir = len > 0.001 ? fwd / len : SIMD3<Float>(0, 0, -1)
                    panelCentre = headPos + dir * panelDistance
                    // The quad's normal is +Z, so it has to be turned to face
                    // BACK along the view direction. Using dir itself yields a
                    // 180-degree turn for the common case of looking down -Z,
                    // which shows the quad's back face -- and with no culling
                    // that reads as the whole picture being mirrored.
                    panelYaw = atan2(-dir.x, -dir.z)
                }
                guard let centre = panelCentre else { encoder.endEncoding(); continue }

                // Turned to face where the player was looking when it was
                // placed, so it is square-on rather than edge-on.
                var model = matrix_identity_float4x4
                let c = cos(panelYaw), sn = sin(panelYaw)
                model.columns.0 = SIMD4<Float>( c, 0, -sn, 0)
                model.columns.2 = SIMD4<Float>(sn, 0,   c, 0)
                model.columns.3 = SIMD4<Float>(centre, 1)

                let width = panelHeight * Float(screen.width) / Float(screen.height)
                var uniforms = PanelUniforms(
                    modelViewProjection: projection * viewMatrix * model,
                    halfSize: SIMD2(width * 0.5, panelHeight * 0.5))

                encoder.setRenderPipelineState(pipeline)
                if let depthState { encoder.setDepthStencilState(depthState) }
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<PanelUniforms>.stride, index: 0)
                encoder.setFragmentTexture(screen, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            encoder.endEncoding()
        }

        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        frame.endSubmission()
    }
}

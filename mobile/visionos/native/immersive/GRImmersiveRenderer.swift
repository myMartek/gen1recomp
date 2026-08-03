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

    /// Where the panel hangs, in ARKit world space: straight ahead, level with
    /// the eyes, far enough not to feel pressed against your face.
    ///
    /// y = 0 because ARKit's world origin on visionOS sits at the device's
    /// height when the session starts, NOT on the floor. (Placing it at 1.35
    /// first put the panel a metre and a bit above eye level, which is how
    /// this was established.) That matches OpenXR's LOCAL space, which is what
    /// the mod's VRRig already assumes -- so the mod's anchoring maths carries
    /// over unchanged.
    private let panelCentre = SIMD3<Float>(0, 0, -2.0)
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

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        // Sleeping until the optimal input time is what keeps the head pose
        // fresh: everything sampled after this is closer to the moment the
        // frame is actually shown.
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()

        // No drawable means this frame is not to be rendered. Return WITHOUT
        // endSubmission: the compositor treats "submission ended but nothing
        // presented" as a client error and aborts the process with
        // BUG IN CLIENT. (The simulator tolerated it; a real Vision Pro does
        // not, which is how this was found.)
        guard let drawable = frame.queryDrawable() else { return }

        // Anchor the frame to where the device will be when it is displayed,
        // not where it is now. Handing it to the drawable also lets the
        // compositor reproject if we miss the deadline.
        let presentTime = LayerRenderer.Clock.Instant.epoch
            .duration(to: timing.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: presentTime)
        drawable.deviceAnchor = deviceAnchor

        // Same rule as above: nothing to present, so nothing to end.
        guard let commandBuffer = queue.makeCommandBuffer() else { return }

        let screen = GRLove.virtualScreen
        let originFromDevice = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        for index in 0..<drawable.colorTextures.count {
            let target = drawable.colorTextures[index]

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            // Near-black rather than magenta now that there is real content:
            // this is the room around the panel, and it should not glow.
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1.0)

            // The depth attachment is NOT optional. A drawable carries one per
            // view and the compositor reprojects against it; submitting a frame
            // that never wrote depth is a client error, and on device it aborts
            // the process inside cp_frame_end_submission. (The simulator does
            // not reproject, which is why it tolerated this.)
            var depthTexture: MTLTexture? = nil
            if index < drawable.depthTextures.count {
                depthTexture = drawable.depthTextures[index]
                pass.depthAttachment.texture = depthTexture
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                // 0 is the far plane under reverse-Z.
                pass.depthAttachment.clearDepth = 0.0
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }

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

                // The panel faces -Z, which is the direction the player is
                // looking at world origin, so no rotation is needed.
                var model = matrix_identity_float4x4
                model.columns.3 = SIMD4<Float>(panelCentre, 1)

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

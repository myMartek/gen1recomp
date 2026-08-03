//  The CompositorServices frame loop.
//
//  Right now it does the smallest thing that proves the pipeline end to end:
//  clears both eye drawables to a solid colour. That is deliberately the first
//  milestone -- if this shows, then the immersive space, the layer renderer,
//  the Metal device, the drawable textures and the present path are all
//  working, and everything after it is LÖVE's rendering rather than visionOS
//  plumbing.
//
//  The eventual job of this file is to hand the drawable textures to
//  love.xr.eyeCanvas() and let the voxel mod draw into them directly.

import CompositorServices
import Metal
import QuartzCore

final class GRImmersiveRenderer {

    private let layerRenderer: LayerRenderer
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    /// Built on first use, because it needs the drawable's pixel format and
    /// that is not known until a frame exists.
    private var screenPipeline: MTLRenderPipelineState?
    private var pipelineFormat: MTLPixelFormat = .invalid

    private struct ScreenUniforms { var uvScale: SIMD2<Float> }

    init?(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        // Take the device the compositor gave us rather than
        // MTLCreateSystemDefaultDevice(): textures have to come from the same
        // device the drawables live on.
        self.device = layerRenderer.device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
    }

    /// Runs until the layer is invalidated. Called on its own thread.
    func run() {
        while true {
            switch layerRenderer.state {
            case .paused:
                // Not an error: the space is open but not being presented
                // (the player looked away, the system took over). Block
                // rather than spin.
                layerRenderer.waitUntilRunning()
            case .running:
                renderFrame()
            case .invalidated:
                return
            @unknown default:
                return
            }
        }
    }

    /// Pipeline for drawing LÖVE's virtual screen into a drawable.
    private func screenPipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = screenPipeline, pipelineFormat == format { return p }
        guard let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "gr_screen_vertex"),
              let ffn = library.makeFunction(name: "gr_screen_fragment")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = format
        screenPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        pipelineFormat = format
        return screenPipeline
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        // Scene state that must be settled before input is sampled would go
        // here. Nothing yet.
        frame.endUpdate()

        // Sleeping until the optimal input time is what keeps head pose as
        // fresh as possible: everything sampled after this point is closer to
        // the moment the frame is actually shown.
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()
        guard let drawable = frame.queryDrawable() else {
            frame.endSubmission()
            return
        }

        guard let commandBuffer = queue.makeCommandBuffer() else {
            frame.endSubmission()
            return
        }

        let screen = GRLove.virtualScreen

        // One pass per color texture. Under the `dedicated` layout that is one
        // per eye; under `layered` it is a single array texture. Driving it off
        // the drawable's own count keeps this correct either way.
        for index in 0..<drawable.colorTextures.count {
            let target = drawable.colorTextures[index]

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            // Magenta only shows through if LÖVE has not produced a frame yet.
            // Nothing in the game is this colour, so it is unambiguous.
            pass.colorAttachments[0].clearColor =
                MTLClearColor(red: 0.85, green: 0.0, blue: 0.55, alpha: 1.0)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }

            if let screen, let pipeline = screenPipeline(for: target.pixelFormat) {
                // Fit the source inside the target without distorting it. The
                // game frame is portrait and the eye buffers are not, so
                // stretching would be very obvious.
                let srcAspect = Float(screen.width) / Float(screen.height)
                let dstAspect = Float(target.width) / Float(target.height)
                var uniforms = ScreenUniforms(uvScale: srcAspect > dstAspect
                    ? SIMD2(1.0, srcAspect / dstAspect)
                    : SIMD2(dstAspect / srcAspect, 1.0))

                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(screen, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ScreenUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            encoder.endEncoding()
        }

        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        frame.endSubmission()
    }
}

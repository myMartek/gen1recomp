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

        // One pass per color texture. Under the `dedicated` layout that is one
        // per eye; under `layered` it is a single array texture. Driving it off
        // the drawable's own count keeps this correct either way.
        for index in 0..<drawable.colorTextures.count {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.colorTextures[index]
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            // Magenta: nothing in the game is this colour, so if it appears
            // it is unambiguously this code and not a stale frame.
            pass.colorAttachments[0].clearColor =
                MTLClearColor(red: 0.85, green: 0.0, blue: 0.55, alpha: 1.0)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.endEncoding()
            }
        }

        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        frame.endSubmission()
    }
}

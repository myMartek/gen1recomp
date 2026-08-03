//  LÖVE's virtual screen, shown flat in the launcher window.
//
//  The same texture the immersive space maps onto a panel. That is the point:
//  flat and VR are two views of one frame, not two renderers. Not pressing
//  "Enter VR" is what "play in 2D" means.
//
//  What this does NOT give you is input. In this app SDL owns no window, so
//  LÖVE receives no touches or clicks -- the picture is live, the game is not
//  yet playable here. That is the input work, and until it lands the separate
//  flat build (Pocket Sim 2D) is the one to actually play.

import MetalKit
import SwiftUI

struct GRScreenView: UIViewRepresentable {

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.framebufferOnly = true
        view.isOpaque = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // 30 fps: this is a mirror of a frame LÖVE already produced, and
        // driving it at display rate would burn power redrawing an unchanged
        // texture.
        view.preferredFramesPerSecond = 30
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {

        let device: MTLDevice?
        private let queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var pipelineFormat: MTLPixelFormat = .invalid

        private struct FlatUniforms { var uvScale: SIMD2<Float> }

        override init() {
            // The system default device, not the compositor's: this view has
            // no compositor. On a Vision Pro there is one GPU, so the virtual
            // screen texture is usable from both.
            device = MTLCreateSystemDefaultDevice()
            queue = device?.makeCommandQueue()
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        private func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
            if let p = pipeline, pipelineFormat == format { return p }
            guard let device,
                  let library = device.makeDefaultLibrary(),
                  let vfn = library.makeFunction(name: "gr_flat_vertex"),
                  let ffn = library.makeFunction(name: "gr_flat_fragment")
            else { return nil }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = format
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
            pipelineFormat = format
            return pipeline
        }

        func draw(in view: MTKView) {
            // Nothing to show yet: return WITHOUT presenting, so the window
            // keeps whatever it last had. Presenting a cleared frame here is
            // what turns "LÖVE is still starting" into a black flash.
            guard let screen = GRLove.virtualScreen else { return }

            guard let queue,
                  let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
            else { return }

            if let pipeline = pipeline(for: view.colorPixelFormat) {

                // Fit without distorting: the game frame is portrait and the
                // window generally is not.
                let src = Float(screen.width) / Float(screen.height)
                let dst = Float(view.drawableSize.width) / Float(max(view.drawableSize.height, 1))
                var uniforms = FlatUniforms(uvScale: src > dst
                    ? SIMD2(1.0, src / dst)
                    : SIMD2(dst / src, 1.0))

                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(screen, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlatUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

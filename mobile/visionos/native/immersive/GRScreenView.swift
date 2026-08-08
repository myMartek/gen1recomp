//  LÖVE's virtual screen, shown flat in the launcher window.
//
//  The same texture the immersive space maps onto a panel. That is the point:
//  flat and VR are two views of one frame, not two renderers. Not pressing
//  "Enter VR" is what "play in 2D" means.
//
//  Input reaches it too, now. SDL owns no window in this app, so none of
//  LÖVE's own paths are connected; the drag below queues into love.xr and Lua
//  drains it (love_visionos_pointer). That is what makes the save editor
//  usable here -- it is all pointer and has no gamepad affordance at all.
//
//  A DragGesture with minimumDistance 0 rather than a tap: the editor's
//  sliders and its map browser want the whole press-move-release, and a tap
//  gesture reports only the end of one.

import MetalKit
import SwiftUI

struct GRScreenView: View {

    /// Whether the current drag has already sent its press. SwiftUI reports a
    /// drag as a stream of changes with no separate "began", so the first one
    /// is the press and the rest are moves.
    @State private var pressed = false

    var body: some View {
        GeometryReader { geo in
            GRScreenSurface()
                // Without this the gesture only lands on drawn pixels, and the
                // letterbox bars beside a portrait game are not drawn pixels.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard let p = Self.virtualPoint(v.location, in: geo.size) else { return }
                            love_visionos_pointer(Float(p.x), Float(p.y), pressed ? 0 : 1)
                            pressed = true
                        }
                        .onEnded { v in
                            // Falls back to the last in-bounds point rather
                            // than dropping the release: a finger that leaves
                            // the picture still let go of the button.
                            let p = Self.virtualPoint(v.location, in: geo.size)
                            love_visionos_pointer(Float(p?.x ?? -1), Float(p?.y ?? -1), 2)
                            pressed = false
                        }
                )
        }
    }

    /// A point in the view, in virtual-screen pixels -- or nil when it lands
    /// on the letterbox. This inverts exactly what gr_flat_fragment does:
    /// uv = (n - 0.5) * uvScale + 0.5, with the same uvScale GRScreenSurface
    /// computes, so the pixel under the finger is the pixel under the cursor.
    static func virtualPoint(_ p: CGPoint, in size: CGSize) -> CGPoint? {
        guard let screen = GRLove.virtualScreen, size.width > 0, size.height > 0
        else { return nil }
        let src = Float(screen.width) / Float(screen.height)
        let dst = Float(size.width) / Float(size.height)
        let scale = src > dst ? SIMD2<Float>(1.0, src / dst)
                              : SIMD2<Float>(dst / src, 1.0)
        let n = SIMD2<Float>(Float(p.x / size.width), Float(p.y / size.height))
        let uv = (n - 0.5) * scale + 0.5
        guard uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 else { return nil }
        return CGPoint(x: CGFloat(uv.x) * CGFloat(screen.width),
                       y: CGFloat(uv.y) * CGFloat(screen.height))
    }
}

struct GRScreenSurface: UIViewRepresentable {

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
        /// Only a fallback. The queue actually used is LÖVE's -- see `draw`.
        private let ownQueue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var pipelineFormat: MTLPixelFormat = .invalid

        private struct FlatUniforms { var uvScale: SIMD2<Float> }

        override init() {
            // The system default device, not the compositor's: this view has
            // no compositor. On a Vision Pro there is one GPU, so the virtual
            // screen texture is usable from both.
            device = MTLCreateSystemDefaultDevice()
            ownQueue = device?.makeCommandQueue()
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

            // LÖVE's queue, not ours. It writes this texture from its own
            // thread, and Metal orders command buffers only WITHIN a queue --
            // between two queues there is no ordering at all, so sampling from
            // a queue of our own could land between LÖVE's clear and LÖVE's
            // draws and show an empty frame. Intermittently: the flicker.
            //
            // ownQueue should not be reachable -- the queue is made in the
            // Metal backend's constructor and the texture only later in
            // setMode, so anything holding a virtual screen has a queue. It
            // is here so a future reordering degrades to the old flickering
            // behaviour rather than to a window that stops updating at all.
            guard let queue = GRLove.commandQueue ?? ownQueue,
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

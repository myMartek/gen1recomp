//  The visionOS shell.
//
//  One app, two presentations: a plain window and a fully immersive space,
//  switched at runtime and remembered across launches.
//
//  The two are not mutually exclusive -- visionOS lets an app keep rendering
//  its own windows even at .full immersion, and Apple's own Metal template
//  pairs a WindowGroup with a full ImmersiveSpace. We close the launcher
//  anyway once the world is up, because a control panel floating in front of
//  the game is not what anyone wants to play through. It comes back the
//  moment immersion ends, by whatever route -- the button here, a Digital
//  Crown press, or the system.

import CompositorServices
import SwiftUI

// MARK: - Immersive scene

struct GRImmersiveContent: CompositorContent {

    var model: GRAppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: GRLayerConfiguration()) { @MainActor layerRenderer in
            // The frame loop owns this thread for the lifetime of the space.
            // 8 MiB rather than the 512 KiB default because this thread will
            // eventually be running LÖVE, whose Lua call depth is not shallow.
            // Hand the layer to love.xr straight away. The mod claims it when
            // its VR row goes on; until then the host's renderer below keeps
            // drawing, so turning VR off leaves something on screen rather
            // than nothing.
            love_visionos_setLayerRenderer(Unmanaged.passUnretained(layerRenderer as AnyObject).toOpaque())

            let model = self.model
            let thread = Thread {
                if let renderer = GRImmersiveRenderer(layerRenderer) {
                    renderer.run()
                }
                // run() only returns once the layer is invalidated, which is
                // the one signal that covers every way out of immersion --
                // including a Digital Crown press, which never touches our UI.
                //
                // Withdraw THIS layer from love.xr: it is dead, and until it
                // is withdrawn love.xr keeps reporting it as present. Lua then
                // goes on claiming a frame loop that can never produce a frame
                // -- while the host stands down for exactly that claim, so the
                // space stays black -- and holds textures belonging to
                // drawables that no longer exist.
                //
                // Conditional on it still being the current one, because this
                // runs as the thread winds down and the NEXT space may already
                // have installed its layer by then. Clearing unconditionally
                // wipes the new one and nothing ever draws again.
                love_visionos_clearLayerRenderer(
                    Unmanaged.passUnretained(layerRenderer as AnyObject).toOpaque())
                Task { @MainActor in model.immersiveSpaceEnded() }
            }
            thread.name = "gen1recomp.compositor"
            thread.stackSize = 8 << 20
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }
}

struct GRLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        // FOVEATION IS ON.
        //
        // It buys drawable quality -- render quality above the default is only
        // permitted on a foveated layer -- and it costs a coordinate system:
        // the eye textures then hold a non-uniformly packed image whose dense
        // region follows the gaze, and every pass that addresses the frame by
        // screen position has to decode it. The renderer carries both paths,
        // so this is a one-line choice.
        //
        // It was off for a long stretch while the water's screen-space
        // reflection was chased, on the theory that the packing was what kept
        // the trees out of the lake. It was not, and turning it off is what
        // actually broke them: updateRateLookups allocates the decode table
        // unconditionally and fills it only where the drawable offers a
        // rasterization rate map, so an UNFOVEATED layer left it holding
        // uninitialised private memory -- and handed it out anyway. Every UV
        // run through it landed on one texel, which is why the reflection's
        // source came back from the device as a single flat colour while the
        // flat window's held the scene.
        //
        // That is fixed where it belongs (g_eyeRateValid in wrap_XR.mm), and
        // the fix is what makes this switch safe in either position.
        let foveated = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveated
        if foveated {
            // 1.0, which is what this was before foveation was switched off.
            //
            // It was briefly lowered to 0.6 when 1.0 killed the app with
            // signal 9 on the first foveated frame -- but that was before two
            // allocations were corrected: the world view was being derived
            // from the LOGICAL eye size (nine times the area to mesh), and the
            // water's mirror was 93 MB an eye rather than 18. Roughly 300 MB
            // between them. With those gone the original figure fits again.
            configuration.maxRenderQuality = LayerRenderer.RenderQuality(rawValue: 1.0)
            // NO FLIPPED MAPS.
            //
            // These existed to cancel the mod's own clip-space Y flip, which
            // is gone -- lib/Voxel3D.lua no longer premultiplies it on Metal,
            // and every compensation that paired with it came out with it.
            // Asked for and used here, it is one flip too many and the whole
            // world renders upside down.
            configuration.generateFlippedRasterizationRateMaps = false
        }
        print("[xr] layer defaults: quality \(capabilities.defaultRenderQuality.rawValue), "
              + "minimumNear \(capabilities.supportedMinimumNearPlaneDistance)m")

        let layoutOptions: LayerRenderer.Capabilities.SupportedLayoutsOptions =
            foveated ? [.foveationEnabled] : []
        let supported = capabilities.supportedLayouts(options: layoutOptions)
        // `dedicated` gives one plain 2D texture per eye, which is exactly the
        // shape VoxelScene's existing two-canvas stereo path already produces.
        // `shared` would hand back one double-wide texture, and every pass in
        // the mod that works in canvas pixels would silently be wrong.
        configuration.layout = supported.contains(.dedicated) ? .dedicated : .layered
    }
}

// The launcher window's view lives in GRLauncher.swift: on visionOS it is
// the game's whole front end (src/core/NativeShell.lua stands down for it),
// which made it too much to keep as a section of the app entry point.

// MARK: - App

@main
struct GRApp: App {

    @State private var model = GRAppModel()

    var body: some Scene {
        WindowGroup(id: GRAppModel.launcherWindowID) {
            // The controller page stands IN PLACE of the launcher when it is
            // asked for, rather than beside it: it is opened to learn a pad,
            // not on the way to playing, and the engine behind the launcher
            // would otherwise be booting a world nobody is going to look at.
            if GRControllerSetupView.wanted {
                GRControllerSetupView()
            } else {
                GRLauncherView()
                    .environment(model)
            }
        }
        // Portrait: the game frame is 1080x1920, and a landscape window
        // letterboxes it down to a stamp.
        .defaultSize(width: 560, height: 900)

        ImmersiveSpace(id: "world") {
            GRImmersiveContent(model: model)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        // Hides the system's own overlays over this space -- the Home
        // indicator and the affordance a look-up-and-pinch opens Control
        // Centre with.
        //
        // It does NOT disable the gestures themselves, and nothing can: the
        // Digital Crown and the look-up pinch are how a person leaves an app
        // that has gone wrong, so visionOS reserves them and offers no key or
        // API to take them away. What this buys is that the affordance is not
        // sitting in the view inviting the pinch; what it cannot buy is a
        // pinch aimed at where it used to be.
        //
        // So if a gesture of ours collides with one of theirs, ours has to
        // move. The fist is the likely one.
        .persistentSystemOverlays(.hidden)
    }
}

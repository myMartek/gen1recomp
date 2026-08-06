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
        // Higher drawable quality on Vision Pro requires foveation. The voxel
        // scene itself stays in a conventional linear scratch image; love.xr's
        // final Metal pass applies the drawable's eye-tracked rate map, so the
        // screen-space water and sky shaders never see warped coordinates.
        let foveated = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveated
        if foveated {
            configuration.maxRenderQuality = LayerRenderer.RenderQuality(rawValue: 1.0)
            // LÖVE's canvas convention is vertically opposite Metal's final
            // drawable convention. The scene uses the flipped map in its
            // intermediary targets; the native final pass uses the regular.
            configuration.generateFlippedRasterizationRateMaps = true
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
            GRLauncherView()
                .environment(model)
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

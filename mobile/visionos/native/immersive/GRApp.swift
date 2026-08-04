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
        // Foveation off deliberately. A variable rasterization rate map warps
        // screen space, and the voxel mod's water ray march, sky dither grid
        // and tilt-shift pass all reason in screen pixels -- enabling it means
        // fixing those three first. Revisit once the port renders correctly.
        configuration.isFoveationEnabled = false

        let supported = capabilities.supportedLayouts(options: [])
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
    }
}

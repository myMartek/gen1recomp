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
            let model = self.model
            let thread = Thread {
                if let renderer = GRImmersiveRenderer(layerRenderer) {
                    renderer.run()
                }
                // run() only returns once the layer is invalidated, which is
                // the one signal that covers every way out of immersion --
                // including a Digital Crown press, which never touches our UI.
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

// MARK: - Launcher window

struct GRLauncherView: View {

    @Environment(GRAppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var loveStatus = "virtual screen: waiting for LÖVE…"

    var body: some View {
        VStack(spacing: 24) {
            Text("gen1recomp")
                .font(.system(size: 44, weight: .bold))

            Text(statusText)
                .font(.title3)
                .foregroundStyle(.secondary)

            Button(action: toggle) {
                Text(model.immersiveState == .open ? "Leave VR" : "Enter VR")
                    .font(.title2)
                    .frame(maxWidth: 260)
                    .padding(.vertical, 6)
            }
            .disabled(model.immersiveState == .inTransition)

            Text("The mode you are in is restored on the next launch.")
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Text(loveStatus)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(.secondary)
                .task {
                    // Poll rather than wait on a signal: LÖVE sets its mode
                    // some way into boot, and there is no callback for it yet.
                    while !Task.isCancelled {
                        let s = GRLove.describeVirtualScreen()
                        if s != loveStatus {
                            loveStatus = s
                            GRLove.log.notice("\(s, privacy: .public)")
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
        }
        .padding(48)
        .task {
            // LÖVE comes up as soon as the app does, independently of which
            // presentation is showing: both the window and the immersive space
            // consume the same virtual screen, so neither owns its lifetime.
            GRLove.bootOnce()

            // Hand the window actions to the model. Whatever ends immersion --
            // possibly the Digital Crown, with no view of ours involved --
            // needs to be able to bring this window back, and by then there is
            // no launcher view left to read the environment from.
            model.openWindowAction = { openWindow(id: $0) }
            model.dismissWindowAction = { dismissWindow(id: $0) }

            // Restore the last mode once per launch. Guarded because .task can
            // re-run when the view is recreated, and a second openImmersiveSpace
            // while one is already open is an error rather than a no-op.
            guard !model.didRestoreOnLaunch else { return }
            model.didRestoreOnLaunch = true
            if model.wantsImmersiveOnLaunch { await open() }
        }
    }

    private var statusText: String {
        switch model.immersiveState {
        case .open:         return "Immersive"
        case .closed:       return "Windowed"
        case .inTransition: return "Switching…"
        }
    }

    private func toggle() {
        Task { @MainActor in
            switch model.immersiveState {
            case .open:
                model.immersiveState = .inTransition
                await dismissImmersiveSpace()
                // The renderer's invalidation callback also fires and calls
                // immersiveSpaceEnded(), which re-opens the window. Leaving
                // the bookkeeping to that one place keeps this path and the
                // Crown path identical.
            case .closed:
                await open()
            case .inTransition:
                break
            }
        }
    }

    private func open() async {
        model.immersiveState = .inTransition
        switch await openImmersiveSpace(id: model.immersiveSpaceID) {
        case .opened:
            model.immersiveState = .open
            model.wantsImmersiveOnLaunch = true
            // Get the flat window out of the way once the world is up. It is
            // not gone for good: leaving immersion brings it straight back.
            dismissWindow(id: GRAppModel.launcherWindowID)
        case .userCancelled, .error:
            // The space did not open, so do not persist a mode the app cannot
            // actually come back to -- otherwise a one-off failure makes every
            // subsequent launch try and fail the same way.
            model.immersiveState = .closed
            model.wantsImmersiveOnLaunch = false
        @unknown default:
            model.immersiveState = .closed
            model.wantsImmersiveOnLaunch = false
        }
    }
}

// MARK: - App

@main
struct GRApp: App {

    @State private var model = GRAppModel()

    var body: some Scene {
        WindowGroup(id: GRAppModel.launcherWindowID) {
            GRLauncherView()
                .environment(model)
        }
        .defaultSize(width: 720, height: 460)

        ImmersiveSpace(id: "world") {
            GRImmersiveContent(model: model)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

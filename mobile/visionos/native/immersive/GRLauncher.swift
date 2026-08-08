//  The launcher, as a real window.
//
//  On visionOS the game's own launcher never runs: src/core/NativeShell.lua
//  stands in for it and this draws it instead. That is not decoration. The
//  Lua launcher is a 160x144 arcade panel meant for a monitor and a mouse; in
//  a headset it would be a small picture of a menu floating on a quad, with
//  none of the focus, placement, pointer or accessibility behaviour the system
//  gives a window for free.
//
//  Two phases in one window, because they are the same window to the player:
//  the picker until a game is chosen, and the game itself afterwards. The flag
//  lives on the model rather than here -- entering immersion dismisses this
//  window and re-creates it on the way back, and a launcher that reappeared on
//  top of a running game would be worse than no window at all.

import SwiftUI
import UniformTypeIdentifiers

struct GRLauncherView: View {

    @Environment(GRAppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var shell = GRShell()
    @State private var loveStatus = "starting…"
    @State private var showRomPicker = false
    /// Which game a save import is for. Its picker hangs on the saves section
    /// rather than here -- SwiftUI presents ONE .fileImporter per view, and a
    /// second one beside the ROM picker simply never appeared.
    /// Which game a picked save belongs to, and whether the picker is up.
    /// These are deliberately two variables: SwiftUI clears the isPresented
    /// binding on dismissal BEFORE running the completion handler, so a target
    /// derived from that binding is always nil by the time the file arrives.
    @State private var importInto: String?
    @State private var showSavePicker = false
    @State private var romMessage = ""
    @State private var pads = GRControllers()
    /// The save the player asked to export; presenting the share sheet.
    @State private var exportURL: URL?
    /// version + slot awaiting a yes. Deleting a save cannot be undone.
    @State private var pendingDelete: (String, String)?
    /// nil means "follow the default" -- see `selected`.
    @State private var selectedID: String?

    var body: some View {
        Group {
            if model.bootedVersion == nil {
                picker
            } else {
                player
            }
        }
        .padding(24)
        .onChange(of: shell.exportFile) { _, file in
            guard let file, !file.isEmpty else { return }
            exportURL = URL(fileURLWithPath: file)
        }
        .sheet(item: Binding(
            get: { exportURL.map { GRExportItem(url: $0) } },
            set: { if $0 == nil { exportURL = nil } }
        )) { item in
            GRShareSheet(url: item.url)
        }
        .confirmationDialog("Delete this save?",
                            isPresented: Binding(
                                get: { pendingDelete != nil },
                                set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let (v, s) = pendingDelete { shell.deleteSlot(version: v, slot: s) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .fileImporter(isPresented: $showRomPicker,
                      allowedContentTypes: GRRomImport.contentTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { romMessage = GRRomImport.accept(url) }
            case .failure(let error):
                romMessage = "Import cancelled: \(error.localizedDescription)"
            }
        }
        .task {
            // LÖVE comes up as soon as the app does, independently of which
            // presentation is showing: both the window and the immersive space
            // consume the same virtual screen, so neither owns its lifetime.
            GRLove.bootOnce()
            // Before anything needs them, so the prompt lands on the launcher
            // rather than over the game.
            GRLove.requestTrackingAuthorization()
            pads.start()
            shell.start()

            // Hand the window actions to the model. Whatever ends immersion --
            // possibly the Digital Crown, with no view of ours involved --
            // needs to be able to bring this window back, and by then there is
            // no launcher view left to read the environment from.
            model.openWindowAction = { openWindow(id: $0) }
            model.dismissWindowAction = { dismissWindow(id: $0) }

            guard !model.didRestoreOnLaunch else { return }
            model.didRestoreOnLaunch = true

            // Every launch starts here, deliberately. Restoring into immersion
            // sounded convenient and in practice meant any problem in the
            // immersive path was inescapable: the app came back up inside it,
            // with no window, every time.
            model.markImmersiveSessionEnded()
            model.wantsImmersiveOnLaunch = false

            // A way in without hands, for automated looking-at.
            //
            // Off unless something asks for it by name -- pass
            // `-GRAutoImmersive YES` on the launch command line -- so nothing
            // about the ordinary run changes. It exists because the one thing
            // that cannot be checked from a terminal is what the headset
            // SHOWS, and in the simulator it can be: boot, enter, screenshot.
            // Without it every look costs somebody putting a headset on.
            if UserDefaults.standard.bool(forKey: "GRAutoImmersive") {
                // Play, not merely open. Opening the space alone leaves LOVE
                // with no world, so nothing ever claims the frame loop and the
                // space sits empty -- which looks exactly like a broken
                // renderer and is not one.
                //
                // Waits for the first snapshot, because the version list is
                // what says which game has a ROM.
                for _ in 0..<60 where !shell.hasState {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                let want = UserDefaults.standard.string(forKey: "GRAutoVersion")
                let game = shell.games.first { $0.id == want }
                    ?? shell.games.first { $0.ready }
                if let game { play(game.id) }
            }
        }
    }

    // MARK: - Phase 1: pick a game

    /// The version showing in the dropdown. Nil until the first snapshot
    /// arrives, then the first game whose ROM is in -- so a fresh install with
    /// only Red imported opens on Red rather than on an unplayable Blue.
    private var selected: GRGame? {
        if let id = selectedID, let g = shell.games.first(where: { $0.id == id }) {
            return g
        }
        return shell.games.first(where: { $0.ready }) ?? shell.games.first
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Pocket Sim")
                    .font(.largeTitle.weight(.semibold))

                if !shell.hasState {
                    // The game publishes its first snapshot a moment into
                    // boot. Saying so beats an empty list that reads as
                    // "nothing is installed".
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Waiting for the game to start…")
                            .foregroundStyle(.secondary)
                    }
                } else if let game = selected {
                    versionRow(game)
                    savesSection(game)
                    // Above the lists, not below them. Mods and settings grow
                    // without bound -- the settings alone are nine rows -- and
                    // the one thing the player came here to press must not be
                    // the one thing they have to scroll to find.
                    startRow(game)
                    if !shell.mods.isEmpty { modList }
                    if !shell.settings.isEmpty { settingsList }
                }

                if !shell.debugToast.isEmpty {
                    Text(shell.debugToast)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }

                if !romMessage.isEmpty {
                    Text(romMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One dropdown instead of a card per game.
    ///
    /// The three versions are alternatives, not three things to do, and giving
    /// each its own Play button repeated the same control three times over --
    /// which is also why the start button lives once, at the bottom, and reads
    /// the selection.
    private func versionRow(_ game: GRGame) -> some View {
        HStack {
            Text("Game").font(.title2.weight(.medium))
            Spacer()
            Picker("Game", selection: Binding(
                get: { game.id },
                set: { selectedID = $0 }
            )) {
                ForEach(shell.games) { g in
                    // Unimported versions stay in the list rather than being
                    // hidden: "Blue is missing its ROM" is useful, "Blue does
                    // not exist" is not.
                    Text(g.ready ? g.title : "\(g.title) — no ROM").tag(g.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func savesSection(_ game: GRGame) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save").font(.title2.weight(.medium))

            if !game.ready {
                Text("Import this game's ROM to play it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if (game.slots ?? []).isEmpty {
                Text("No saves yet — starting will begin a new game.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(game.slots ?? []) { slot in
                    Button {
                        shell.setSlot(version: game.id, slot: slot.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: slot.id == game.activeSlot
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(slot.id == game.activeSlot
                                                 ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.title)
                                Text(slot.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Housekeeping, out of the way of the choice
                            // itself. Export is NOT in here as well as beside
                            // it -- one action, one place.
                            Menu {
                                Button(role: .destructive) {
                                    pendingDelete = (game.id, slot.id)
                                } label: { Label("Delete", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)

                            if slot.exists {
                                Button {
                                    shell.exportSlot(version: game.id, slot: slot.id)
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }

                HStack(spacing: 16) {
                    Button("New save") { shell.newSlot(version: game.id) }
                    Button("Import save…") {
                        importInto = game.id
                        showSavePicker = true
                    }
                }
                .font(.callout)
            }
        }
        .fileImporter(isPresented: $showSavePicker,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            let version = importInto
            importInto = nil
            guard let version, case .success(let urls) = result,
                  let url = urls.first else { return }
            romMessage = shell.importSlot(version: version, from: url)
                ? "Save imported." : "That save could not be read."
        }
    }

    private func startRow(_ game: GRGame) -> some View {
        HStack(spacing: 16) {
            if game.ready {
                Button("Play in VR") { play(game.id) }
                    .buttonStyle(.borderedProminent)
            }
            Button(game.ready ? "Replace ROM…" : "Import ROM…") {
                showRomPicker = true
            }
        }
        .font(.title3)
        .padding(.top, 4)
    }

    private var modList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mods").font(.title2.weight(.medium))

            ForEach(shell.mods) { mod in
                Toggle(isOn: Binding(
                    get: { mod.enabled },
                    set: { shell.setMod(mod.id, enabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(mod.name)
                            if let badge = mod.badge, !badge.isEmpty {
                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.tertiary, in: Capsule())
                            }
                            if let v = mod.version {
                                Text(v).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        // The launcher's own verdict on whether this mod can
                        // run -- dependencies, conflicts. Passed through, not
                        // recomputed, so it cannot disagree with the game.
                        if let detail = mod.statusDetail, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    /// The OPTIONS rows that mean anything before a game is running.
    ///
    /// Each is a menu, not a cycler: the Lua menu steps through values with
    /// Left/Right because a d-pad is all it has, and reproducing that here
    /// would mean tapping a row six times to reach the seventh value.
    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings").font(.title2.weight(.medium))

            ForEach(shell.settings) { setting in
                HStack {
                    Text(setting.label)
                    Spacer()
                    Picker(setting.label, selection: Binding(
                        get: { setting.currentLabel },
                        set: { label in
                            guard let c = setting.choices.first(where: { $0.label == label })
                            else { return }
                            shell.setOption(setting.id, value: c.value)
                        }
                    )) {
                        ForEach(setting.choices) { choice in
                            Text(choice.label).tag(choice.label)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Phase 2: the game

    private var player: some View {
        VStack(spacing: 16) {
            GRScreenView()
                .frame(minHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(action: toggle) {
                Text(model.immersiveState == .open ? "Leave VR" : "Enter VR")
                    .frame(maxWidth: 180)
            }
            .font(.title3)
            .disabled(model.immersiveState == .inTransition)

            // What the controller is and what it is sending. Press a button
            // that does nothing in the game and its real name appears here --
            // the only way to tell "not mapped" from "not arriving".
            VStack(spacing: 2) {
                ForEach(pads.devices, id: \.self) { Text($0) }
                if !pads.recent.isEmpty {
                    Text(pads.recent.joined(separator: "  "))
                        .foregroundStyle(.primary)
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.secondary)

            Text(loveStatus)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .task {
                    // Polled: LÖVE sets its mode some way into boot and there
                    // is no callback for it yet.
                    while !Task.isCancelled {
                        let s = GRLove.describeVirtualScreen()
                        if s != loveStatus { loveStatus = s }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
        }
    }

    // MARK: - Actions

    private var statusText: String {
        switch model.immersiveState {
        case .open:         return "Immersive"
        case .closed:       return "Windowed"
        case .inTransition: return "Switching…"
        }
    }

    /// Boot the chosen game and go straight into it.
    ///
    /// The boot command and the immersive space are started together on
    /// purpose: the player pressed Play wearing a headset, and stopping at a
    /// flat window first would be a step nobody asked for. LÖVE keeps loading
    /// while the space opens, and the host renderer holds the space until the
    /// mod claims the frame loop, so there is no window where nothing is on
    /// screen.
    private func play(_ version: String) {
        model.bootedVersion = version
        shell.boot(version: version)
        shell.stop()
        Task { await open() }
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
            model.markImmersiveSessionStarted()
            // Dismissed again, as in the build where the controller worked.
            // Keeping it open gave a sharper picture but left a focusable
            // window competing for the pad, and playable beats pretty.
            dismissWindow(id: GRAppModel.launcherWindowID)
        case .userCancelled, .error:
            // Do not persist a mode the app cannot come back to, or a one-off
            // failure makes every later launch try and fail the same way.
            model.immersiveState = .closed
            model.wantsImmersiveOnLaunch = false
        @unknown default:
            model.immersiveState = .closed
            model.wantsImmersiveOnLaunch = false
        }
    }
}

// MARK: - Exporting a save

/// A URL that can be a `.sheet(item:)` -- which needs identity, and a URL on
/// its own does not carry one.
struct GRExportItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system's own share sheet, which is the whole export.
///
/// Nothing is packaged or converted on the way out: the file handed over is
/// the save exactly as the game writes it, so what comes back through Import
/// is a file the game already knows how to read. Saving it to Files, mailing
/// it, or dropping it on a Mac are all the same gesture to the player, and
/// none of them is ours to build.
struct GRShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}

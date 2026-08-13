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

/// One literal rather than a concatenation inside the view: SwiftUI bodies are
/// type-checked as a single expression, and a `+` chain of strings in there is
/// a well-known way to push that past its time limit. It is also the key the
/// .strings files are written against, so it has to match them byte for byte.
private let languageWarning =
    "The language is part of a mod, and mods are loaded when the game starts. "
    + "The running game has to end for the change to take effect. Nothing is "
    + "saved automatically -- save first if you want to keep your progress."

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
    /// The Pokémon Stadium cartridge picker, and whatever went wrong with it.
    @State private var showStadiumPicker = false
    @State private var stadiumMessage = ""
    /// A language the player has chosen but not yet paid for.
    ///
    /// The language is a mod, and mods merge once at load -- so changing it
    /// with a game in memory means ending that game. That is not something to
    /// do behind somebody's back on a menu pick, so the choice waits here
    /// until it is confirmed, and the picker keeps showing the old value in
    /// the meantime (its binding reads the shell, which has not been told).
    @State private var pendingLanguage: GRSetting.Choice?
    @State private var showHelp = false
    @State private var showControllerSetup = false
    @State private var pads = GRControllers()
    /// The save the player asked to export; presenting the share sheet.
    @State private var exportURL: URL?
    /// version + slot awaiting a yes. Deleting a save cannot be undone.
    @State private var pendingDelete: (String, String)?
    /// nil means "follow the default" -- see `selected`.
    @State private var selectedID: String?

    var body: some View {
        Group {
            if shell.editing {
                editor
            } else if model.bootedVersion == nil {
                picker
            } else {
                player
            }
        }
        .padding(24)
        .onChange(of: shell.exportFile) { _, file in
            guard let file, !file.isEmpty else { return }
            exportURL = URL(fileURLWithPath: file)
            // Taken. Leaving it set means this sheet returns every time the
            // launcher is rebuilt, and the Crown rebuilds it.
            shell.exportTaken()
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
                guard let url = urls.first else { break }
                // Copy, then ask the engine to decode it now. What it makes of
                // the file -- progress, or a refusal with the reason -- comes
                // back through the snapshot and is drawn by importRow, so this
                // only has to report a copy that did not happen.
                if let failure = GRRomImport.accept(url) {
                    romMessage = failure
                } else {
                    romMessage = ""
                    shell.importRom()
                }
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
                Text("Gen1 Vision")
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
                    // Above the saves: while a cartridge is being decoded it is
                    // the only thing happening, and afterwards it is where the
                    // reason for a refusal is.
                    if let state = shell.importing { importRow(state) }
                    savesSection(game)
                    // Above the lists, not below them. Mods and settings grow
                    // without bound -- the settings alone are nine rows -- and
                    // the one thing the player came here to press must not be
                    // the one thing they have to scroll to find.
                    startRow(game)
                    // Behind the debug gate (ten presses on a save slot). On
                    // this build the one mod that matters is not optional --
                    // it IS the app -- so the list is a developer's row, and
                    // an inviting switch that turns the voxel world off is not
                    // something to put in a player's way.
                    if shell.debug && !shell.mods.isEmpty { modList }
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
                    Text(g.ready ? g.title : tr("game.noRom", g.title)).tag(g.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func savesSection(_ game: GRGame) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(trKey("section.saves")).font(.title2.weight(.medium))

            if !game.ready {
                Text("Import this game's ROM to play it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if (game.slots ?? []).isEmpty {
                Text("No saves yet — starting will begin a new game.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // The buttons belong here too. They used to live only in the
                // branch below, so somebody who had just imported a cartridge
                // and had no saves yet was told there were none and offered no
                // way to bring one in -- which is exactly the moment a save
                // from another device would be carried over.
                saveButtons(game)
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
                                if slot.exists {
                                    Button {
                                        shell.editSlot(version: game.id, slot: slot.id)
                                    } label: { Label(trKey("Edit save…"), systemImage: "slider.horizontal.3") }
                                }
                                Button(role: .destructive) {
                                    pendingDelete = (game.id, slot.id)
                                } label: { Label(trKey("Delete"), systemImage: "trash") }
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

                saveButtons(game)
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
                ? tr("Save imported.") : tr("That save could not be read.")
        }
    }

    private func saveButtons(_ game: GRGame) -> some View {
        HStack(spacing: 16) {
            Button("New save") { shell.newSlot(version: game.id) }
            Button("Import save…") {
                importInto = game.id
                showSavePicker = true
            }
        }
        .font(.callout)
    }

    /// What the engine is doing with the cartridge, while it does it.
    ///
    /// The import used to happen on the NEXT launch, so this view had nothing
    /// to show and the app asked for a restart instead. It also had nothing to
    /// say when a file was refused -- and a refused ROM looks precisely like an
    /// accepted one that has not been decoded yet.
    @ViewBuilder
    private func importRow(_ state: GRImport) -> some View {
        HStack(spacing: 12) {
            if state.isWorking {
                ProgressView(value: min(max(state.progress ?? 0, 0), 1))
                    .frame(width: 120)
            } else {
                Image(systemName: state.failed
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.failed ? Color.orange : Color.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.status ?? "")
                // The reason, when there is one. A refusal names the hash it
                // found and what it expected, which is the only way anybody
                // finds out their dump is a patched one.
                if let detail = state.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func startRow(_ game: GRGame) -> some View {
        HStack(spacing: 16) {
            if game.ready {
                Button("Play in VR") { play(game.id) }
                    .buttonStyle(.borderedProminent)
            }
            Button(trKey(game.ready ? "Replace ROM…" : "Import ROM…")) {
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
    /// The Pokémon Stadium cartridge, and what it is worth.
    ///
    /// Under the settings rather than beside the Game Boy import, because it
    /// is optional and because the row it unlocks -- Battles -- is directly
    /// above it. When the models are built that row appears on its own; until
    /// then this says what is missing and offers to take it, which is the
    /// whole of the arrangement.
    ///
    /// Its picker hangs HERE, on this subview, for the reason the saves picker
    /// hangs on its own: SwiftUI presents ONE .fileImporter per view, and a
    /// second beside the ROM picker simply never appears.
    private var stadiumRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("stadium.title")
                    Text(stadiumDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(shell.stadium?.isInstalled == true
                       ? tr("stadium.replace") : tr("stadium.import")) {
                    showStadiumPicker = true
                }
                .buttonStyle(.borderless)
                // Nothing to press while it is building: a second cartridge
                // handed in mid-build would be read into the set the first one
                // is still writing.
                .disabled(shell.stadium?.isBuilding == true)
            }
            if shell.stadium?.isBuilding == true {
                // Determinate once the build knows its own size, and a spinner
                // until then -- a bar sitting at zero says "stuck", which is
                // the one thing this is not.
                if let fraction = shell.stadium?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if !stadiumMessage.isEmpty {
                Text(stadiumMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fileImporter(isPresented: $showStadiumPicker,
                      allowedContentTypes: GRStadiumImport.contentTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { break }
                // Only the copy is this side's business. Whether the file is a
                // cartridge the mod can read is the MOD's answer, and it gives
                // it on the next start -- which is also when the models are
                // built, so there is nothing to report here in the meantime.
                if let failure = GRStadiumImport.accept(url) {
                    stadiumMessage = failure
                } else {
                    stadiumMessage = ""
                    // Straight into the build, here in the launcher. Waiting
                    // for a game to be started and walked into would be a
                    // strange thing to ask of somebody who just handed over
                    // the cartridge.
                    shell.buildStadium()
                }
            case .failure(let error):
                stadiumMessage = tr("stadium.cancelled", error.localizedDescription)
            }
        }
    }

    /// The three things this row can be saying, in the order a player meets
    /// them: no cartridge, one waiting to be built from, models ready.
    private var stadiumDetail: LocalizedStringKey {
        if let error = shell.stadium?.error, !error.isEmpty {
            return LocalizedStringKey(error)
        }
        if shell.stadium?.isBuilding == true { return "stadium.building" }
        if shell.stadium?.isInstalled == true { return "stadium.ready" }
        if shell.stadium?.isPending == true { return "stadium.pending" }
        return "stadium.absent"
    }

    /// Left/Right because a d-pad is all it has, and reproducing that here
    /// would mean tapping a row six times to reach the seventh value.
    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Settings").font(.title2.weight(.medium))
                Spacer()
                // Next to the settings rather than in a toolbar: this window
                // has no toolbar, and the controls are the one thing a player
                // goes looking for BEFORE they play rather than after.
                Button {
                    showHelp = true
                } label: {
                    Label(tr("help.title"), systemImage: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                // The controller page, reachable without a launch flag.
                //
                // It began as flag-only, ported that way from the SM64 port --
                // but a flag is set from a Mac over a tunnel, and the tunnel is
                // exactly what is not there when somebody sits down with a new
                // pad. A button costs one line in a row nobody reads twice.
                Button {
                    showControllerSetup = true
                } label: {
                    Label("Controller", systemImage: "gamecontroller")
                }
                .buttonStyle(.borderless)
            }

            ForEach(shell.settings) { setting in
                HStack {
                    Text(trKey(setting.label))
                    Spacer()
                    Picker(setting.label, selection: Binding(
                        get: { setting.currentLabel },
                        set: { label in
                            guard let c = setting.choices.first(where: { $0.label == label })
                            else { return }
                            // The language costs the running game (mods merge
                            // at load), so it asks first. Everything else
                            // applies on the pick, as it always has.
                            if setting.id == "language", shell.booted {
                                pendingLanguage = c
                                return
                            }
                            shell.setOption(setting.id, value: c.value)
                        }
                    )) {
                        ForEach(setting.choices) { choice in
                            Text(trKey(choice.label)).tag(choice.label)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            stadiumRow
        }
        .sheet(isPresented: $showHelp) { GRHelpView() }
        .sheet(isPresented: $showControllerSetup) { GRControllerSetupView() }
        .confirmationDialog(
            tr("Change the language?"),
            isPresented: Binding(get: { pendingLanguage != nil },
                                 set: { if !$0 { pendingLanguage = nil } }),
            titleVisibility: .visible
        ) {
            Button(tr("End the game and switch"), role: .destructive) {
                if let choice = pendingLanguage { switchLanguage(to: choice) }
            }
            Button(tr("Keep playing"), role: .cancel) { pendingLanguage = nil }
        } message: {
            Text(tr(languageWarning))
        }
    }

    /// Applies a language and gets the engine to a state where it can take it:
    /// the simulation closes and the engine reloads.
    ///
    /// In that order, and both are needed. Closing the space alone leaves the
    /// game in memory, where Play resumes it and the new mod set is never
    /// merged; reloading alone would tear the world down underneath a player
    /// who is still standing in it.
    private func switchLanguage(to choice: GRSetting.Choice) {
        pendingLanguage = nil
        Task { @MainActor in
            if model.immersiveState == .open {
                model.immersiveState = .inTransition
                await dismissImmersiveSpace()
            }
            // The engine comes back at the launcher, so the window must not
            // think a game is still loaded -- otherwise the next language
            // change would ask this same question about a game that is gone.
            model.bootedVersion = nil
            // The new run builds a new screen texture, and the window caches
            // the old one for the life of a run. Without this it presents the
            // dead one and every menu draws black.
            GRLove.invalidateVirtualScreen()
            // ONE command, carrying the setting: see restartEngine.
            shell.restartEngine(applying: ("language", choice.value))
        }
    }

    // MARK: - The save editor
    //
    // Native, and reading from the engine. The editor's own immediate-mode UI
    // is not drawn here at all -- it runs headless and publishes what it
    // holds (src/core/NativeEditor.lua), so the rules stay in one place and
    // the face is a real window: system placement, focus, text fields and
    // VoiceOver, none of which a picture of a tool on a quad can offer.
    private var editor: some View {
        GREditorView()
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
                Text(trKey(model.immersiveState == .open ? "Leave VR" : "Enter VR"))
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

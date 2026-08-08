//  The save editor, drawn by SwiftUI.
//
//  Layout only. Every control sends one Ops verb and every value shown came
//  back from one -- see GREditor.swift for why none of the rules live here.
//
//  Six tabs, the same six the engine's own editor has, because they are the
//  same editor: party, boxes, items, trainer, events, dex, map.

import SwiftUI

struct GREditorView: View {

    @State private var editor = GREditor()

    /// The tab comes from the engine, not from a @State here. It is the same
    /// reasoning as every other value on this screen: one place holds it, both
    /// faces read it -- and a tab that only existed inside SwiftUI could not
    /// be opened onto, restored, or walked by a scripted run.
    private var tab: Tab {
        Tab(rawValue: (editor.state?.tab ?? "party").capitalized) ?? .party
    }

    enum Tab: String, CaseIterable, Identifiable {
        case party = "Party"
        case boxes = "Boxes"
        case items = "Items"
        case trainer = "Trainer"
        case events = "Events"
        case dex = "Dex"
        case map = "Map"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Picker("Tab", selection: Binding(
                get: { tab },
                set: { editor.setTab($0.rawValue.lowercased()) }
            )) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if let s = editor.state {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .party:   PartyTab(editor: editor, s: s)
                        case .boxes:   BoxesTab(editor: editor, s: s)
                        case .items:   ItemsTab(editor: editor, s: s)
                        case .trainer: TrainerTab(editor: editor, s: s)
                        case .events:  EventsTab(editor: editor, s: s)
                        case .dex:     DexTab(editor: editor, s: s)
                        case .map:     MapTab(editor: editor, s: s)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                statusBar(s)
            } else {
                Spacer()
                Text("Opening the save…").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .task { editor.start() }
        .onDisappear { editor.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Save Editor").font(.title2.bold())
                if let s = editor.state {
                    Text("\(s.player.isEmpty ? "—" : s.player) · \(s.version.uppercased()) \(s.slot)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let s = editor.state, s.dirty {
                Text("Unsaved").font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.orange.opacity(0.25), in: Capsule())
            }
            Button("Save") { editor.save() }
                .disabled(!(editor.state?.dirty ?? false))
            Button("Reload") { editor.reloadFile() }
            Button("Close") { editor.close() }
        }
    }

    private func statusBar(_ s: GREditorState) -> some View {
        HStack(spacing: 10) {
            Circle().fill(s.valid ? .green : .red).frame(width: 8, height: 8)
            Text(s.status.isEmpty ? (s.valid ? "Save validates clean" : "Save would not validate")
                                  : s.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }
}

// MARK: - Shared pieces

/// A label with a stepper either side. The engine owns the clamping, so this
/// never guards the range itself -- pressing + at the cap comes back as a
/// refusal in the status line, which is the honest answer.
private struct GRStepRow: View {
    let title: String
    let value: String
    var steps: [Int] = [-1, 1]
    let onStep: (Int) -> Void

    var body: some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Text(value).font(.body.monospaced()).frame(width: 90, alignment: .leading)
            Spacer()
            ForEach(steps, id: \.self) { d in
                Button(d > 0 ? "+\(d)" : "\(d)") { onStep(d) }
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct GRSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.bold()).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Party

private struct PartyTab: View {
    let editor: GREditor
    let s: GREditorState

    private var mons: [GRMon] { s.party ?? [] }
    private var selected: GRMon? { mons.first { $0.index == s.selectedParty } }

    var body: some View {
        GRSection(title: "Party \(mons.count)/\(s.partyMax)") {
            ForEach(mons) { mon in
                Button {
                    editor.selectParty(mon.index)
                } label: {
                    HStack {
                        Text("#\(mon.index)").foregroundStyle(.secondary).frame(width: 34)
                        Text(mon.displayName).bold()
                        Spacer()
                        Text("Lv\(mon.level)")
                        Text("HP \(mon.hp)/\(mon.stats.hp)").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .background(mon.index == s.selectedParty
                            ? Color.accentColor.opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Add mon") { editor.partyAdd() }
                Button(s.armed == "party-remove" ? "Confirm remove?" : "Remove",
                       role: .destructive) { editor.partyRemove() }
                Button("Move up") { editor.partyMove(-1) }
                Button("Move down") { editor.partyMove(1) }
            }
        }

        if let mon = selected {
            GRSection(title: "Inspector — \(mon.displayName)") {
                GRStepRow(title: "Species", value: mon.species, steps: [-1, 1]) {
                    editor.stepSpecies($0)
                }
                Menu("Pick species…") {
                    ForEach((s.speciesCatalog ?? []).prefix(60), id: \.self) { id in
                        Button(id) { editor.setSpecies(id) }
                    }
                }
                GRStepRow(title: "Level", value: "\(mon.level)", steps: [-10, -1, 1, 10]) {
                    editor.setLevel(max(1, min(100, mon.level + $0)))
                }
                Divider()
                dvRow("HP", "hp", mon.dvs.hp)
                dvRow("Attack", "attack", mon.dvs.attack)
                dvRow("Defense", "defense", mon.dvs.defense)
                dvRow("Speed", "speed", mon.dvs.speed)
                dvRow("Special", "special", mon.dvs.special)
                Divider()
                Text("Stats  HP \(mon.stats.hp) · Atk \(mon.stats.attack) · Def \(mon.stats.defense) · Spd \(mon.stats.speed) · Spc \(mon.stats.special)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Divider()
                ForEach(mon.moves, id: \.slot) { move in
                    HStack {
                        Text("Move \(move.slot)").frame(width: 110, alignment: .leading)
                        Text(move.id.isEmpty ? "—" : move.id).font(.body.monospaced())
                        Spacer()
                        Text("PP \(move.pp)").foregroundStyle(.secondary)
                        Button("Cycle") { editor.cycleMove(move.slot) }
                        Button("Clear") { editor.clearMove(move.slot) }
                    }
                }
                HStack {
                    Button("Reset moves") { editor.resetMoves() }
                    Button("Heal") { editor.healMon() }
                }
            }
        }
    }

    private func dvRow(_ title: String, _ key: String, _ value: Int) -> some View {
        GRStepRow(title: "DV \(title)", value: "\(value)", steps: [-1, 1]) {
            editor.setDv(key, value + $0)
        }
    }
}

// MARK: - Boxes

private struct BoxesTab: View {
    let editor: GREditor
    let s: GREditorState

    var body: some View {
        GRSection(title: "Box \(s.box.selected)/\(s.box.count)") {
            HStack {
                Button("Previous") { editor.stepBox(-1) }
                Button("Next") { editor.stepBox(1) }
                Spacer()
                Text("\((s.box.mons ?? []).count) stored").foregroundStyle(.secondary)
            }
            ForEach(s.box.mons ?? []) { mon in
                Button {
                    editor.selectBoxSlot(mon.index)
                } label: {
                    HStack {
                        Text("#\(mon.index)").foregroundStyle(.secondary).frame(width: 34)
                        Text(mon.displayName).bold()
                        Spacer()
                        Text("Lv\(mon.level)")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .background(mon.index == s.box.slot
                            ? Color.accentColor.opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Add to box") { editor.boxAdd() }
                Button("Withdraw") { editor.withdraw() }
                Button("Deposit") { editor.deposit() }
                // Two presses: Ops arms destructive verbs and commits on the
                // second within its own window, so the label follows the
                // engine rather than a timer of ours.
                Button(s.armed == "box-release" ? "Confirm release?" : "Release",
                       role: .destructive) { editor.release() }
            }
        }
    }
}

// MARK: - Items

private struct ItemsTab: View {
    let editor: GREditor
    let s: GREditorState
    @State private var query = ""

    var body: some View {
        GRSection(title: "Bag") {
            ForEach(s.bag ?? []) { row in
                HStack {
                    Text(row.id).font(.body.monospaced())
                    Spacer()
                    Text("x\(row.count)").foregroundStyle(.secondary)
                    Button("−") { editor.bagAdjust(row.id, -1) }
                    Button("+") { editor.bagAdjust(row.id, 1) }
                    Button("Drop", role: .destructive) { editor.bagDrop(row.id) }
                }
            }
            if (s.bag ?? []).isEmpty { Text("Empty").foregroundStyle(.secondary) }
        }

        GRSection(title: "PC storage") {
            ForEach(s.pc ?? []) { row in
                HStack {
                    Text(row.id).font(.body.monospaced())
                    Spacer()
                    Text("x\(row.count)").foregroundStyle(.secondary)
                    Button("−") { editor.pcAdjust(row.id, -1) }
                    Button("+") { editor.pcAdjust(row.id, 1) }
                    Button("Drop", role: .destructive) { editor.pcDrop(row.id) }
                }
            }
            if (s.pc ?? []).isEmpty { Text("Empty").foregroundStyle(.secondary) }
        }

        GRSection(title: "Add an item") {
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.query(item: query) }
                Button("Filter") { editor.query(item: query) }
            }
            ForEach((s.itemCatalog ?? []).prefix(40), id: \.self) { id in
                HStack {
                    Text(id).font(.body.monospaced())
                    Spacer()
                    Button("To bag") { editor.addToBag(id) }
                    Button("To PC") { editor.addToPc(id) }
                }
            }
        }
    }
}

// MARK: - Trainer

private struct TrainerTab: View {
    let editor: GREditor
    let s: GREditorState
    @State private var playerName = ""
    @State private var rivalName = ""

    var body: some View {
        // The names Gen 1 keeps on the trainer card. Committed on Set rather
        // than on every keystroke: each one is a command and a file write on
        // the other side, and a name typed a letter at a time would be ten of
        // them.
        GRSection(title: "Names") {
            HStack {
                Text("Player").frame(width: 90, alignment: .leading)
                TextField(s.player, text: $playerName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.setPlayerName(playerName) }
                Button("Set") { editor.setPlayerName(playerName) }
            }
            HStack {
                Text("Rival").frame(width: 90, alignment: .leading)
                TextField(s.rival, text: $rivalName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.setRivalName(rivalName) }
                Button("Set") { editor.setRivalName(rivalName) }
            }
            Text("Up to \(s.nameMax) characters; the game has no lower case.")
                .font(.caption).foregroundStyle(.secondary)
        }

        GRSection(title: "Money") {
            GRStepRow(title: "Money", value: "$\(s.money)",
                      steps: [-1000, -100, 100, 1000]) { editor.addMoney($0) }
            Button("Max ($\(s.moneyMax))") { editor.maxMoney() }
        }

        GRSection(title: "Badges") {
            ForEach(s.badges ?? []) { badge in
                Toggle(badge.id, isOn: Binding(
                    get: { badge.on },
                    set: { _ in editor.toggleBadge(badge.id) }))
            }
        }
    }
}

// MARK: - Events

private struct EventsTab: View {
    let editor: GREditor
    let s: GREditorState
    @State private var query = ""

    var body: some View {
        GRSection(title: "Event flags — \(s.events.total)") {
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.query(event: query) }
                Button("Filter") { editor.query(event: query) }
                Button(s.armed == "clear-flags" ? "Confirm clear?" : "Clear all",
                       role: .destructive) { editor.clearTable("flags") }
            }
            ForEach((s.events.rows ?? []).prefix(60)) { row in
                Toggle(row.name, isOn: Binding(
                    get: { row.on },
                    set: { editor.setFlag(row.name, $0) }))
                .font(.caption.monospaced())
            }
        }
    }
}

// MARK: - Dex

private struct DexTab: View {
    let editor: GREditor
    let s: GREditorState
    @State private var query = ""

    var body: some View {
        GRSection(title: "Pokédex — \(s.dex.seen) seen, \(s.dex.owned) owned") {
            HStack {
                Button("See all") { editor.dexSeeAll() }
                Button("Own all") { editor.dexOwnAll() }
                Button("Stamp from party") { editor.dexStamp() }
                Button(s.armed == "dex-clear" ? "Confirm clear?" : "Clear",
                       role: .destructive) { editor.dexClear() }
            }
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.query(item: query) }
                Button("Filter") { editor.query(item: query) }
            }
            ForEach((s.dex.rows ?? []).prefix(60)) { row in
                HStack {
                    Text(row.id).font(.caption.monospaced())
                    Spacer()
                    Toggle("Seen", isOn: Binding(get: { row.seen },
                                                 set: { editor.dexSeen(row.id, $0) }))
                        .labelsHidden()
                    Text("seen").font(.caption2).foregroundStyle(.secondary)
                    Toggle("Owned", isOn: Binding(get: { row.owned },
                                                  set: { editor.dexOwned(row.id, $0) }))
                        .labelsHidden()
                    Text("owned").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Map

private struct MapTab: View {
    let editor: GREditor
    let s: GREditorState
    @State private var query = ""
    @State private var cellX = 0
    @State private var cellY = 0

    var body: some View {
        GRSection(title: "Where the player is") {
            Text("Player: \(s.map.playerAt)").font(.body.monospaced())
            Text("Last outdoor: \(s.map.lastOutdoor.isEmpty ? "—" : s.map.lastOutdoor)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("Last heal: \(s.map.lastHeal.isEmpty ? "—" : s.map.lastHeal)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }

        GRSection(title: "Pick a map — \(s.map.total)") {
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.query(map: query) }
                Button("Filter") { editor.query(map: query) }
            }
            Text("Selected: \(s.map.selected.isEmpty ? "—" : s.map.selected)")
                .font(.body.monospaced())
            ForEach((s.map.rows ?? []).prefix(30), id: \.self) { id in
                Button(id) { editor.selectMap(id) }
                    .buttonStyle(.plain)
                    .font(.caption.monospaced())
                    .foregroundStyle(id == s.map.selected ? Color.accentColor : .primary)
            }
        }

        GRSection(title: "Cell") {
            // The engine's own map tab gets this from a click on a drawn map;
            // here it is two numbers, because a tile grid in a headset window
            // would be a picture of a map inside a window that is already one.
            HStack {
                Stepper("X \(cellX)", value: $cellX, in: 0...255)
                Stepper("Y \(cellY)", value: $cellY, in: 0...255)
                Button("Set cell") { editor.setCell(cellX, cellY) }
            }
            Text("Cell in the engine: (\(s.map.cellX), \(s.map.cellY))")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                Button("Put player here") { editor.setPlayerHere() }
                Button("Set last outdoor") { editor.setLastOutdoor() }
                Button("Set last heal") { editor.setLastHeal() }
            }
        }
    }
}

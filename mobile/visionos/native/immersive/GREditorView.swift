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
                ForEach(Tab.allCases) { Text(trKey($0.rawValue)).tag($0) }
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
            Button(trKey("action.save")) { editor.save() }
                .disabled(!(editor.state?.dirty ?? false))
            Button("Reload") { editor.reloadFile() }
            Button("Close") { editor.close() }
        }
    }

    private func statusBar(_ s: GREditorState) -> some View {
        HStack(spacing: 10) {
            Circle().fill(s.valid ? .green : .red).frame(width: 8, height: 8)
            // The engine's own status line when there is one; it is written
            // in the engine's language and passes through untouched.
            Text(s.status.isEmpty
                 ? tr(s.valid ? "Save validates clean" : "Save would not validate")
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
    @State private var picking = false

    private var mons: [GRMon] { s.party ?? [] }
    private var selected: GRMon? { mons.first { $0.index == s.selectedParty } }

    var body: some View {
        GRSection(title: tr("party.count", mons.count, s.partyMax)) {
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
                Button(trKey(s.armed == "party-remove" ? "Confirm remove?" : "Remove"),
                       role: .destructive) { editor.partyRemove() }
                Button("Move up") { editor.partyMove(-1) }
                Button("Move down") { editor.partyMove(1) }
            }
        }

        if let mon = selected {
            GRSection(title: tr("inspector.for", mon.displayName)) {
                GRStepRow(title: tr("Species"), value: mon.species, steps: [-1, 1]) {
                    editor.stepSpecies($0)
                }
                // A SHEET, not a menu. The list is 151 long and the menu it
                // used to be was cut at 60 to stay usable -- which is why it
                // stopped somewhere in the J's, on the one control whose job
                // is to reach any of them. A sheet can hold the whole list
                // and carry a search field.
                Button(trKey("Pick species…")) { picking = true }
                    .sheet(isPresented: $picking) {
                        GRSpeciesPicker(all: s.speciesCatalog ?? []) { id in
                            editor.setSpecies(id)
                            picking = false
                        }
                    }
                GRStepRow(title: tr("Level"), value: "\(mon.level)", steps: [-10, -1, 1, 10]) {
                    editor.setLevel(max(1, min(100, mon.level + $0)))
                }
                Divider()
                dvRow("dv.hp", "hp", mon.dvs.hp)
                dvRow("dv.attack", "attack", mon.dvs.attack)
                dvRow("dv.defense", "defense", mon.dvs.defense)
                dvRow("dv.speed", "speed", mon.dvs.speed)
                dvRow("dv.special", "special", mon.dvs.special)
                Divider()
                Text("Stats  HP \(mon.stats.hp) · Atk \(mon.stats.attack) · Def \(mon.stats.defense) · Spd \(mon.stats.speed) · Spc \(mon.stats.special)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Divider()
                ForEach(mon.moves, id: \.slot) { move in
                    HStack {
                        Text(tr("move.slot", move.slot)).frame(width: 110, alignment: .leading)
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

    private func dvRow(_ label: String, _ key: String, _ value: Int) -> some View {
        GRStepRow(title: tr(label), value: "\(value)", steps: [-1, 1]) {
            editor.setDv(key, value + $0)
        }
    }
}

// MARK: - Boxes

private struct BoxesTab: View {
    let editor: GREditor
    let s: GREditorState

    var body: some View {
        GRSection(title: tr("box.count", s.box.selected, s.box.count)) {
            HStack {
                Button("Previous") { editor.stepBox(-1) }
                Button("Next") { editor.stepBox(1) }
                Spacer()
                Text(tr("box.stored", (s.box.mons ?? []).count)).foregroundStyle(.secondary)
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
                Button(trKey(s.armed == "box-release" ? "Confirm release?" : "Release"),
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
        GRSection(title: tr("Bag")) {
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

        GRSection(title: tr("PC storage")) {
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

        GRSection(title: tr("Add an item")) {
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
        GRSection(title: tr("Names")) {
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
            Text(tr("name.limit", s.nameMax))
                .font(.caption).foregroundStyle(.secondary)
        }

        GRSection(title: tr("Money")) {
            GRStepRow(title: tr("Money"), value: "$\(s.money)",
                      steps: [-1000, -100, 100, 1000]) { editor.addMoney($0) }
            Button(tr("money.max", "$\(s.moneyMax)")) { editor.maxMoney() }
        }

        GRSection(title: tr("Badges")) {
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
        GRSection(title: tr("events.count", s.events.total)) {
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.query(event: query) }
                Button("Filter") { editor.query(event: query) }
                Button(trKey(s.armed == "clear-flags" ? "Confirm clear?" : "Clear all"),
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
        GRSection(title: tr("dex.counts", s.dex.seen, s.dex.owned)) {
            HStack {
                Button("See all") { editor.dexSeeAll() }
                Button("Own all") { editor.dexOwnAll() }
                Button("Stamp from party") { editor.dexStamp() }
                Button(trKey(s.armed == "dex-clear" ? "Confirm clear?" : "Clear"),
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
        GRSection(title: tr("Where the player is")) {
            Text(tr("map.player", s.map.playerAt)).font(.body.monospaced())
            Text(tr("map.lastOutdoor", s.map.lastOutdoor.isEmpty ? "—" : s.map.lastOutdoor))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(tr("map.lastHeal", s.map.lastHeal.isEmpty ? "—" : s.map.lastHeal))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }

        GRSection(title: tr("map.pick", s.map.total)) {
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.query(map: query) }
                Button("Filter") { editor.query(map: query) }
            }
            Text(tr("map.selected", s.map.selected.isEmpty ? "—" : s.map.selected))
                .font(.body.monospaced())
            ForEach((s.map.rows ?? []).prefix(30), id: \.self) { id in
                Button(id) { editor.selectMap(id) }
                    .buttonStyle(.plain)
                    .font(.caption.monospaced())
                    .foregroundStyle(id == s.map.selected ? Color.accentColor : .primary)
            }
        }

        GRSection(title: tr("Cell")) {
            // The engine's own map tab gets this from a click on a drawn map;
            // here it is two numbers, because a tile grid in a headset window
            // would be a picture of a map inside a window that is already one.
            HStack {
                Stepper("X \(cellX)", value: $cellX, in: 0...255)
                Stepper("Y \(cellY)", value: $cellY, in: 0...255)
                Button("Set cell") { editor.setCell(cellX, cellY) }
            }
            Text(tr("map.cell", s.map.cellX, s.map.cellY))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                Button("Put player here") { editor.setPlayerHere() }
                Button("Set last outdoor") { editor.setLastOutdoor() }
                Button("Set last heal") { editor.setLastHeal() }
            }
        }
    }
}


// MARK: - Picking a species

/// The whole species list, in Pokédex order, with a search field.
///
/// Filtered here rather than over the bridge: the list is small, it is
/// already in hand, and a round trip per keystroke would make typing feel
/// like waiting. Matching is on the number as well as the name, so "25" finds
/// Pikachu and "pika" does too.
private struct GRSpeciesPicker: View {
    let all: [GRSpecies]
    let choose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [GRSpecies] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return all }
        return all.filter {
            $0.id.localizedCaseInsensitiveContains(q) || String($0.dex).hasPrefix(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(shown) { sp in
                Button { choose(sp.id) } label: {
                    HStack {
                        Text(sp.dex > 0 ? String(format: "#%03d", sp.dex) : "—")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(sp.id)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query)
            .navigationTitle(trKey("Pick species…"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(trKey("Cancel")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

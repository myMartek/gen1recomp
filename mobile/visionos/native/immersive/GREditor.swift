//  The save editor's state, as the engine reports it.
//
//  A mirror, not a model. Every value here was computed by
//  tools/save-editor/Ops.lua and every button below sends one of its verbs
//  back; nothing in this file decides what a legal save is. That is deliberate
//  and it is the whole reason the editor is worth having in two faces at once:
//  the Gen-1 stat formulas, the XP curves, the item and badge tables and the
//  "save validates clean" check are hard, they already exist, and a second
//  implementation in Swift would be a second set of answers to the same
//  questions -- one of which would be wrong.
//
//  src/core/NativeEditor.lua publishes native_editor.json; commands go back
//  down the same channel the launcher uses, prefixed `ed.`.

import Foundation
import Observation

// MARK: - What the snapshot carries

struct GRMove: Decodable, Hashable {
    let slot: Int
    let id: String
    let pp: Int
}

struct GRStats: Decodable, Hashable {
    let hp: Int
    let attack: Int
    let defense: Int
    let speed: Int
    let special: Int
}

struct GRMon: Decodable, Hashable, Identifiable {
    let index: Int
    let species: String
    let nickname: String
    let level: Int
    let hp: Int
    let ot: String
    let exp: Int
    let moves: [GRMove]
    let dvs: GRStats
    let stats: GRStats

    var id: Int { index }
    var displayName: String { nickname.isEmpty ? species : nickname }
}

/// A species with its Pokédex number, in dex order -- the order the game
/// lists them in, which is not the order their ids sort in.
struct GRSpecies: Decodable, Hashable, Identifiable {
    let id: String
    let dex: Int
    var label: String { dex > 0 ? String(format: "#%03d  %@", dex, id) : id }
}

/// A move the inspected species gets by itself: `level` is the level it comes
/// at (1 for a starting move), or 0 when it arrives by TM or HM instead.
struct GRLearnable: Decodable, Hashable, Identifiable {
    let id: String
    let level: Int
    let tm: Bool
}

struct GRItemRow: Decodable, Hashable, Identifiable {
    let id: String
    let count: Int
}

struct GRBadge: Decodable, Hashable, Identifiable {
    let id: String
    let on: Bool
}

struct GRDexRow: Decodable, Hashable, Identifiable {
    let id: String
    let seen: Bool
    let owned: Bool
}

struct GRDex: Decodable, Hashable {
    let seen: Int
    let owned: Int
    let total: Int
    let rows: [GRDexRow]?
}

struct GREventRow: Decodable, Hashable, Identifiable {
    let name: String
    let on: Bool
    var id: String { name }
}

struct GREvents: Decodable, Hashable {
    let total: Int
    let rows: [GREventRow]?
}

struct GRBox: Decodable, Hashable {
    let count: Int
    let selected: Int
    let slot: Int
    let mons: [GRMon]?
}

struct GRMapState: Decodable, Hashable {
    let selected: String
    let cellX: Int
    let cellY: Int
    let total: Int
    let rows: [String]?
    let playerAt: String
    let lastOutdoor: String
    let lastHeal: String
}

/// Lists arrive as `nil` when empty -- Lua's encoder cannot tell an empty
/// array from an empty object, so NativeEditor omits them rather than writing
/// a `{}` this decoder would reject.
struct GREditorState: Decodable {
    let ready: Bool
    let tab: String
    let path: String
    let version: String
    let slot: String
    let dirty: Bool
    let status: String
    let armed: String
    let valid: Bool
    let player: String
    let rival: String
    let nameMax: Int
    let money: Int
    let moneyMax: Int
    let selectedParty: Int
    let party: [GRMon]?
    let partyMax: Int
    let box: GRBox
    let bag: [GRItemRow]?
    let pc: [GRItemRow]?
    let badges: [GRBadge]?
    let dex: GRDex
    let events: GREvents
    let itemCatalog: [String]?
    let speciesCatalog: [GRSpecies]?
    let moveCatalog: [String]?
    let learnable: [GRLearnable]?
    let map: GRMapState
    let page: Int
}

// MARK: - The mirror

@MainActor
@Observable
final class GREditor {

    private(set) var state: GREditorState?
    /// True once a snapshot has landed, so the view can say "opening…" rather
    /// than "no save".
    var isOpen: Bool { state != nil }

    private var pollTask: Task<Void, Never>?

    private var saveDirectory: URL? {
        let path = GRLove.saveDirectory
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private var stateURL: URL? { saveDirectory?.appending(path: "native_editor.json") }
    private var commandURL: URL? { saveDirectory?.appending(path: "native_shell_cmd.json") }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                // Faster than the launcher's poll: this is a tool being
                // operated, and every tap here changes a number the operator
                // is looking at.
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        state = nil
    }

    private func reload() {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GREditorState.self, from: data)
        else { return }
        state = decoded
    }

    // MARK: - Verbs
    //
    // One method per Ops verb, and nothing else. A method that did arithmetic
    // on a value before sending it would be deciding something, and deciding
    // is the other side's job.

    func send(_ verb: String, _ extra: [String: Any] = [:]) {
        guard let url = commandURL else { return }
        var command: [String: Any] = extra
        command["action"] = "ed." + verb
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        // Atomic, like the launcher's: NativeShell deletes what it finds, and
        // a half-written file decodes to nothing and is thrown away.
        try? data.write(to: url, options: .atomic)
    }

    func save()   { send("save") }
    func reloadFile() { send("reload") }
    func close()  { send("close") }

    func selectParty(_ i: Int) { send("selectParty", ["index": i]) }
    func partyAdd()            { send("partyAdd") }
    func partyRemove()         { send("partyRemove") }
    func partyMove(_ d: Int)   { send("partyMove", ["delta": d]) }

    func setLevel(_ l: Int)              { send("setLevel", ["level": l]) }
    func setSpecies(_ id: String)        { send("setSpecies", ["id": id]) }
    func stepSpecies(_ d: Int)           { send("stepSpecies", ["delta": d]) }
    func setDv(_ key: String, _ v: Int)  { send("setDv", ["key": key, "value": v]) }
    func cycleMove(_ slot: Int)          { send("cycleMove", ["slot": slot]) }
    func setMove(_ slot: Int, _ id: String) { send("setMove", ["slot": slot, "id": id]) }
    func clearMove(_ slot: Int)          { send("clearMove", ["slot": slot]) }
    func resetMoves()                    { send("resetMoves") }
    func healMon()                       { send("healMon") }

    func selectBox(_ i: Int)     { send("selectBox", ["index": i]) }
    func stepBox(_ d: Int)       { send("stepBox", ["delta": d]) }
    func selectBoxSlot(_ i: Int) { send("selectBoxSlot", ["index": i]) }
    func boxAdd()                { send("boxAdd") }
    func withdraw()              { send("withdraw") }
    func deposit()               { send("deposit") }
    func release()               { send("release") }

    func setPlayerName(_ v: String) { send("setPlayerName", ["value": v]) }
    func setRivalName(_ v: String)  { send("setRivalName", ["value": v]) }
    func addMoney(_ d: Int)                 { send("addMoney", ["delta": d]) }
    func maxMoney()                         { send("maxMoney") }
    func addToBag(_ id: String)             { send("addToBag", ["id": id]) }
    func bagAdjust(_ id: String, _ d: Int)  { send("bagAdjust", ["id": id, "delta": d]) }
    func bagDrop(_ id: String)              { send("bagDrop", ["id": id]) }
    func addToPc(_ id: String)              { send("addToPc", ["id": id]) }
    func pcAdjust(_ id: String, _ d: Int)   { send("pcAdjust", ["id": id, "delta": d]) }
    func pcDrop(_ id: String)               { send("pcDrop", ["id": id]) }
    func toggleBadge(_ id: String)          { send("toggleBadge", ["id": id]) }

    func setFlag(_ name: String, _ on: Bool) { send("setFlag", ["name": name, "on": on]) }
    func clearTable(_ key: String)           { send("clearTable", ["key": key]) }

    func dexSeen(_ id: String, _ on: Bool)  { send("dexSeen", ["id": id, "on": on]) }
    func dexOwned(_ id: String, _ on: Bool) { send("dexOwned", ["id": id, "on": on]) }
    func dexStamp()  { send("dexStamp") }
    func dexSeeAll() { send("dexSeeAll") }
    func dexOwnAll() { send("dexOwnAll") }
    func dexClear()  { send("dexClear") }

    func selectMap(_ id: String)     { send("selectMap", ["id": id]) }
    func setCell(_ x: Int, _ y: Int) { send("setCell", ["x": x, "y": y]) }
    func setPlayerHere()  { send("setPlayerHere") }
    func setLastOutdoor() { send("setLastOutdoor") }
    func setLastHeal()    { send("setLastHeal") }

    func query(item: String? = nil, event: String? = nil, map: String? = nil) {
        var extra: [String: Any] = [:]
        if let item { extra["item"] = item }
        if let event { extra["event"] = event }
        if let map { extra["map"] = map }
        send("query", extra)
    }
    func page(_ offset: Int) { send("page", ["page": offset]) }
    func setTab(_ name: String) { send("tab", ["tab": name]) }
}

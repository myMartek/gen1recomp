//  The launcher's data, as the game sees it.
//
//  On visionOS the Lua launcher never runs (src/core/NativeShell.lua stands in
//  its place), so the window here IS the launcher: pick a game, turn mods on
//  and off, then play. This type is the half that talks to the game.
//
//  It talks through two small JSON files in LÖVE's save directory rather than
//  a C bridge. The reasoning is written out in NativeShell.lua; the short
//  version is that a bridge would have to touch Lua state from this thread
//  while LÖVE is mid-frame on its own, and a file needs no lock because each
//  side only ever reads what the other has finished writing.
//
//  Lua stays the authority on everything here. Whether a ROM is imported is a
//  question about cache markers and per-version prefixes, and answering it a
//  second time in Swift would mean two answers that drift apart the first time
//  that layout moves.

import Foundation
import Observation

struct GRSlot: Identifiable, Equatable, Decodable {
    let id: String
    /// The player's own name for this slot, if they gave it one.
    let label: String?
    /// The trainer name inside the save. Nil for a registered but empty slot.
    let name: String?
    let exists: Bool
    let badges: Int?
    let timeText: String?
    let dexCount: Int?

    /// The same meta line the Lua launcher prints under a save row.
    var summary: String {
        guard exists else { return "Empty slot" }
        var parts: [String] = []
        if let b = badges { parts.append("\(b) badge\(b == 1 ? "" : "s")") }
        if let d = dexCount { parts.append("\(d) seen") }
        if let t = timeText { parts.append(t) }
        return parts.joined(separator: " · ")
    }

    var title: String {
        if let l = label, !l.isEmpty { return l }
        if let n = name, !n.isEmpty { return n }
        return exists ? "Save \(id)" : "New game"
    }
}

struct GRGame: Identifiable, Equatable, Decodable {
    let id: String
    let title: String
    /// Whether this version's ROM has been imported. False means the picker
    /// offers an import instead of a Play button.
    let ready: Bool
    let slots: [GRSlot]?
    let activeSlot: String?
}

struct GRMod: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let version: String?
    let badge: String?
    let description: String?
    let enabled: Bool
    /// The launcher's own word for whether this mod can actually run --
    /// dependencies satisfied, no conflicts. Passed through rather than
    /// recomputed.
    let status: String?
    let statusDetail: String?
    let experimental: Bool?
}

/// One OPTIONS row, as the game describes it.
///
/// The value is deliberately untyped here: a setting is a number, a boolean or
/// a string depending on the row, and the game already knows which. Rendering
/// only needs the label to show and the value to send back, so this stores
/// both as opaque JSON and never has to agree with Lua about types.
struct GRSetting: Identifiable, Equatable, Decodable {
    let id: String
    let label: String
    let value: GRJSONValue
    let choices: [Choice]

    struct Choice: Equatable, Decodable, Identifiable {
        let value: GRJSONValue
        let label: String
        var id: String { label }
    }

    var currentLabel: String {
        choices.first { $0.value == value }?.label ?? "—"
    }
}

/// Just enough JSON to carry a settings value through unexamined.
enum GRJSONValue: Equatable, Decodable {
    case bool(Bool)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Bool before number: JSONDecoder will happily read `true` as 1.
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    var json: Any {
        switch self {
        case .bool(let b):   return b
        case .number(let d): return d == d.rounded() ? Int(d) : d
        case .string(let s): return s
        }
    }
}

private struct GRShellState: Decodable {
    let games: [GRGame]
    let mods: [GRMod]
    let settings: [GRSetting]?
}

@MainActor
@Observable
final class GRShell {

    private(set) var games: [GRGame] = []
    private(set) var mods: [GRMod] = []
    private(set) var settings: [GRSetting] = []
    /// False until the first snapshot lands, which is what tells the view to
    /// say "starting…" rather than "no games found".
    private(set) var hasState = false

    private var pollTask: Task<Void, Never>?

    private var saveDirectory: URL? {
        let path = GRLove.saveDirectory
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private var stateURL: URL? { saveDirectory?.appending(path: "native_shell.json") }
    private var commandURL: URL? { saveDirectory?.appending(path: "native_shell_cmd.json") }

    // MARK: - Reading

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                // Twice the publisher's interval. The launcher is a menu; a
                // fifth of a second between a toggle and its confirmation is
                // below what anyone notices, and polling faster only costs
                // battery on a device worn on the face.
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func reload() {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GRShellState.self, from: data)
        else { return }

        // Assigned only on change: @Observable republishes on every write, and
        // an identical list ten times a second would rebuild the view for
        // nothing.
        if decoded.games != games { games = decoded.games }
        if decoded.mods != mods { mods = decoded.mods }
        let incoming = decoded.settings ?? []
        if incoming != settings { settings = incoming }
        if !hasState { hasState = true }
    }

    // MARK: - Writing

    private func send(_ command: [String: Any]) {
        guard let url = commandURL,
              let data = try? JSONSerialization.data(withJSONObject: command)
        else { return }
        // Atomic: NativeShell polls this path and deletes what it finds, and a
        // half-written file would decode to nothing and be thrown away.
        try? data.write(to: url, options: .atomic)
    }

    func setMod(_ id: String, enabled: Bool) {
        // Answer in the UI now, and let the next snapshot confirm it. The
        // round trip is two polls, which is long enough for a toggle to feel
        // like it did not take.
        if let i = mods.firstIndex(where: { $0.id == id }) {
            let m = mods[i]
            mods[i] = GRMod(id: m.id, name: m.name, version: m.version,
                            badge: m.badge, description: m.description,
                            enabled: enabled, status: m.status,
                            statusDetail: m.statusDetail,
                            experimental: m.experimental)
        }
        send(["action": "setMod", "id": id, "enabled": enabled])
    }

    func setOption(_ id: String, value: GRJSONValue) {
        // Optimistic, like setMod: the round trip is two polls, and a picker
        // that snapped back for a fifth of a second would read as broken.
        if let i = settings.firstIndex(where: { $0.id == id }) {
            let s = settings[i]
            settings[i] = GRSetting(id: s.id, label: s.label, value: value,
                                    choices: s.choices)
        }
        send(["action": "setOption", "id": id, "value": value.json])
    }

    /// Which save the chosen game continues from.
    ///
    /// Applied through SaveData.setActiveSlot on the Lua side, which is what
    /// the title screen's CONTINUE already reads -- so this is the same choice
    /// the player would have made in the game, made a screen earlier.
    func setSlot(version: String, slot: String) {
        send(["action": "setSlot", "version": version, "slot": slot])
    }

    func newSlot(version: String) {
        send(["action": "newSlot", "version": version])
    }

    /// Boots a game. The Lua side clears its own launcher flag and never
    /// returns here, so this is one-way.
    func boot(version: String) {
        send(["action": "boot", "version": version])
    }
}

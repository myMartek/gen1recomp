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
    /// Where the save file sits, for the share sheet. Nil for a slot that has
    /// never been written.
    let path: String?

    /// The same meta line the Lua launcher prints under a save row.
    var summary: String {
        guard exists else { return tr("Empty slot") }
        var parts: [String] = []
        // Two badge keys rather than a .stringsdict: English needs the plural
        // and German does not (one Orden, two Orden), which two keys say in
        // one line each.
        if let b = badges { parts.append(tr(b == 1 ? "slot.badges.one" : "slot.badges.other", b)) }
        if let d = dexCount { parts.append(tr("slot.seen", d)) }
        if let t = timeText { parts.append(t) }
        return parts.joined(separator: " · ")
    }

    var title: String {
        if let l = label, !l.isEmpty { return l }
        if let n = name, !n.isEmpty { return n }
        return exists ? tr("slot.save", id) : tr("New game")
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
    let exportFile: String?
    let editing: Bool?
}

@MainActor
@Observable
final class GRShell {

    /// The one shell the app runs with, so lifecycle code that is not a view
    /// can reach it. Set on init; there is never a second.
    static weak var shared: GRShell?

    private(set) var games: [GRGame] = []
    private(set) var mods: [GRMod] = []
    private(set) var settings: [GRSetting] = []
    /// False until the first snapshot lands, which is what tells the view to
    /// say "starting…" rather than "no games found".
    private(set) var hasState = false
    /// Set once an export has been written; the launcher watches it.
    private(set) var exportFile: String?

    /// True while the engine's save editor owns the screen.
    ///
    /// Read from the snapshot rather than assumed here, so the window follows
    /// the engine even when something other than this view asked for it -- a
    /// command written straight into the channel, which is how the editor is
    /// driven under test.
    private(set) var editing = false

    private var pollTask: Task<Void, Never>?

    init() { GRShell.shared = self }

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

        if (decoded.editing ?? false) != editing { editing = decoded.editing ?? false }

        // Assigned only on change: @Observable republishes on every write, and
        // an identical list ten times a second would rebuild the view for
        // nothing.
        if decoded.games != games { games = decoded.games }
        if decoded.mods != mods { mods = decoded.mods }
        let incoming = decoded.settings ?? []
        if incoming != settings { settings = incoming }
        if decoded.exportFile != exportFile { exportFile = decoded.exportFile }
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
        countDebugTap(slot)
    }

    // ---------------------------------------------------------- debug gate

    /// Shown briefly when the gate opens; the launcher renders it if set.
    var debugToast: String = ""

    private var tapSlot: String = ""
    private var tapCount = 0
    private var tapStarted = Date.distantPast

    /// Ten presses on ONE save slot inside twenty seconds.
    ///
    /// The headset build hides every mod row -- they parameterise a look the
    /// port has settled, and the mod is not optional here -- but hiding is not
    /// deleting, and a port under development needs its knobs reachable. This
    /// is the way back in: deliberate enough that nobody finds it by accident,
    /// cheap enough to do while wearing the device.
    private func countDebugTap(_ slot: String) {
        let now = Date()
        if slot != tapSlot || now.timeIntervalSince(tapStarted) > 20 {
            tapSlot = slot
            tapCount = 0
            tapStarted = now
        }
        tapCount += 1
        guard tapCount >= 10 else { return }
        tapCount = 0
        send(["action": "setDebug", "on": true])
        debugToast = "Debug mode on"
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.debugToast = ""
        }
    }

    /// Stands the Lua launcher back up after immersion ends.
    ///
    /// The game keeps its place in memory and is simply not updated while the
    /// shell is active; a later START boots it afresh, which is what the
    /// launcher has always done.
    func returnToLauncher() {
        send(["action": "toLauncher"])
    }

    /// Asks for a slot as a vanilla .sav; the path arrives in the next
    /// snapshot as `exportFile`, which the launcher then shares.
    func exportSlot(version: String, slot: String) {
        exportFile = nil
        send(["action": "exportSlot", "version": version, "id": slot])
    }

    /// Removes a save. Destructive and unrecoverable, so the view asks first.
    func deleteSlot(version: String, slot: String) {
        send(["action": "deleteSlot", "version": version, "id": slot])
    }

    /// Takes a file the player picked and makes a save of it.
    ///
    /// Copied into LOVE's own save directory first, under a name of ours, so
    /// the Lua side reads it through love.filesystem like everything else --
    /// a security-scoped URL from the picker is not something it could open.
    func importSlot(version: String, from url: URL) -> Bool {
        guard let dir = saveDirectory else { return false }
        let name = "import_\(version).sav"
        let dest = dir.appending(path: name)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try data.write(to: dest)
        } catch {
            return false
        }
        send(["action": "importSlot", "version": version, "file": name])
        return true
    }

    /// Hands a slot to the engine's own save editor. The picture in the
    /// launcher window becomes the editor, and its Close brings this back.
    func editSlot(version: String, slot: String) {
        // No optimism here. The snapshot is the authority on whether the
        // editor has the screen, and guessing ahead of it would show an empty
        // picture for the one case that matters -- the command not arriving.
        send(["action": "editSlot", "version": version, "slot": slot])
    }

    /// Acknowledges an export the window has presented. The field is a
    /// one-shot; without this it stays in the snapshot and the sheet reopens
    /// every time the launcher is rebuilt -- which is what leaving immersion
    /// with the Crown does.
    func exportTaken() {
        exportFile = nil
        send(["action": "exportTaken"])
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

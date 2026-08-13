//  Learning a controller by being shown one.
//
//  Ported from the SM64 port's ControllerSetupView, where guessing what a pad
//  calls its buttons cost more evenings than anything else: element keys were
//  inferred from display names, and sticks went dead because "left stick" is
//  not what the device answers to. This asks the device instead. One prompt at
//  a time, the press is caught as it happens, and what comes out is the
//  controller's own words -- the names a binding will actually accept.
//
//  Behind a launch flag, and when the flag is set it stands IN PLACE of the
//  launcher. A page that records every button pressed is a strange thing to
//  stumble into, and the point of opening it is not to play.
//
//    GEN1VISION_CONTROLLERSETUP=1   or   -controller-setup

import GameController
import SwiftUI

@MainActor
@Observable
final class GRControllerProbe {

    /// One thing to press, and what the controller said when it was pressed.
    struct Step: Identifiable {
        let id = UUID()
        let prompt: String
        let hint: String
        var aliases: [String] = []
        var value: String = ""
        var seen: Bool { !aliases.isEmpty }
    }

    private(set) var steps: [Step]
    private(set) var at = 0
    private(set) var controllerName = ""
    private(set) var identity: [String: String] = [:]
    private(set) var everything: [String] = []
    private(set) var exported: String?
    private(set) var savedTo: String?

    /// What is there, and what has arrived. Two different failures look alike
    /// from the outside -- a pad the system never vends, and a pad whose
    /// presses go somewhere else -- and only one of them is about windows.
    private(set) var found: [String] = []
    private(set) var events = 0
    private(set) var lastSeen = "-"
    private(set) var elementCount = 0
    /// Whatever is not resting, as it happens, so a pad reporting something
    /// this does not count as a press is still visible.
    private(set) var liveValues: [String] = []

    /// All of them, not the first of them: the list is in whatever order the
    /// system likes, and a capture screen is exactly where two pads are
    /// connected at once.
    private var pads: [GCController] = []
    private var watching: [String: Float] = [:]
    /// Frames to ignore after something was taken down, so a release or a
    /// stick springing back past centre is not read as a second press.
    private var settle = 0
    private var poll: Timer?
    private var sweeper: Timer?

    init() {
        func s(_ p: String, _ h: String) -> Step { Step(prompt: p, hint: h) }
        // The order somebody holding a pad would go through it. Anything a
        // given controller does not have is skipped rather than invented.
        steps = [
            s("A", "Confirm -- the button the game uses for A"),
            s("B", "Cancel -- the one beside it"),
            s("START", "Opens the menu"),
            s("SELECT", "The small one next to START"),
            s("D-pad up", "The cross, upwards"),
            s("D-pad down", "The cross, downwards"),
            s("D-pad left", "The cross, to the left"),
            s("D-pad right", "The cross, to the right"),
            s("Left stick up", "Walking, all the way up"),
            s("Left stick down", "Walking, all the way down"),
            s("Left stick left", "Walking, all the way left"),
            s("Left stick right", "Walking, all the way right"),
            s("Right stick left", "Turning the view, to the left"),
            s("Right stick right", "Turning the view, to the right"),
            s("Left shoulder", "L, if it has one"),
            s("Right shoulder", "R, if it has one"),
            s("Left trigger", "The trigger underneath, left"),
            s("Right trigger", "The trigger underneath, right"),
            s("Anything left over", "Any button not asked for -- home, capture, whatever it has"),
        ]
    }

    var done: Bool { at >= steps.count }
    var current: Step? { done ? nil : steps[at] }

    // MARK: - Listening

    func begin() {
        // Keep hearing them when this window is not the thing in front. On
        // visionOS a window in the room is rarely what the system considers
        // foremost.
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)

        for name in [Notification.Name.GCControllerDidConnect,
                     .GCControllerDidBecomeCurrent,
                     .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.attach() }
                }
        }
        attach()

        // Re-read rather than only waited for: a pad already paired when this
        // opened raises no notification at all.
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        }
        sweeper = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
    }

    func end() {
        poll?.invalidate()
        sweeper?.invalidate()
        poll = nil
        sweeper = nil
    }

    private func attach() {
        let all = GCController.controllers()
        found = all.map { pad in
            let name = pad.vendorName ?? "?"
            let ext = pad.extendedGamepad != nil ? "extended" : "no extended"
            let profile = pad.physicalInputProfile
            let kind = String(describing: type(of: profile))
            return "\(name) - \(pad.productCategory) - \(ext) - \(kind) - \(profile.elements.count) elements"
        }
        guard !all.isEmpty else {
            controllerName = "No controller connected"
            pads = []
            return
        }
        guard all.count != pads.count else { return }
        pads = all
        controllerName = all.compactMap(\.vendorName).joined(separator: ", ")
        // Every one of them. Naming only the first is how a report comes out
        // headed with one pad while every press in it came from another.
        identity = [:]
        for (i, pad) in all.enumerated() {
            let who = pad.vendorName ?? "controller \(i)"
            for (key, value) in Self.describe(pad) {
                identity["\(who) / \(key)"] = value
            }
        }
        everything = all.flatMap { Self.allElements($0) }
        watching = allValues()
    }

    private func allValues() -> [String: Float] {
        var out: [String: Float] = [:]
        for pad in pads {
            let who = pad.vendorName ?? "?"
            for (alias, value) in profileValues(pad) {
                out["\(who) / \(alias)"] = value
            }
        }
        return out
    }

    /// Every element's value right now, by the alias it answers to.
    ///
    /// Two families, and a pad answers to whichever it was built for. The older
    /// one -- button, axis, direction pad -- is what most controllers vend. The
    /// newer one describes an element by what it can DO, and its values live
    /// one level in: a button has a pressed input, a direction pad a pair of
    /// axes. Reading only the first finds elements and no values at all, which
    /// looks exactly like a dead pad.
    private func profileValues(_ pad: GCController) -> [String: Float] {
        var out: [String: Float] = [:]
        for (alias, element) in pad.physicalInputProfile.elements {
            if let b = element as? GCControllerButtonInput { out[alias] = b.value }
            else if let a = element as? GCControllerAxisInput { out[alias] = a.value }
            else if let d = element as? GCControllerDirectionPad {
                out[alias + " .x"] = d.xAxis.value
                out[alias + " .y"] = d.yAxis.value
            }
        }
        if !out.isEmpty { return out }

        for element in pad.input.elements {
            let key = element.aliases.sorted().first ?? String(describing: type(of: element))
            if let b = element as? GCButtonElement {
                out[key] = b.pressedInput.value
            } else if let a = element as? GCAxisElement {
                if let abs = a.absoluteInput { out[key] = abs.value }
            } else if let d = element as? GCDirectionPadElement {
                out[key + " .x"] = d.xyAxes.value.x
                out[key + " .y"] = d.xyAxes.value.y
            } else if let sw = element as? GCSwitchElement {
                out[key] = Float(sw.positionInput.position)
            }
        }
        return out
    }

    /// Big enough not to catch a resting stick or a fingernail.
    private static let deflection: Float = 0.6

    private func sweep() {
        guard !pads.isEmpty else { return }
        let now = allValues()
        if settle > 0 { settle -= 1 }
        elementCount = now.count
        liveValues = now
            .filter { abs($0.value) > 0.15 }
            .sorted { $0.key < $1.key }
            .prefix(8)
            .map { "\($0.key) = \(String(format: "%.2f", $0.value))" }
        defer { watching = now }
        guard !watching.isEmpty else { return }

        // The moment it goes DOWN, not the moment it comes back up. Counting
        // movement counts both, so one press writes itself into the step that
        // was current when it went down and into the next one when it came up.
        var bestAlias = ""
        var bestValue: Float = 0
        for (alias, value) in now {
            let before = watching[alias] ?? 0
            guard abs(value) >= Self.deflection, abs(before) < Self.deflection else { continue }
            if abs(value) > abs(bestValue) { bestAlias = alias; bestValue = value }
        }
        guard !bestAlias.isEmpty else { return }
        // And nothing at all for a moment afterwards.
        guard settle <= 0 else { return }
        settle = 12

        events += 1
        lastSeen = "\(bestAlias) = \(String(format: "%.2f", bestValue))"
        guard !done else { return }
        var step = steps[at]
        step.aliases = [bestAlias]
        step.value = String(format: "%.2f", bestValue)
        steps[at] = step
        at += 1
    }

    // MARK: - Moving about

    func back() {
        guard at > 0 else { return }
        // Long enough to have let go of whatever was pressed on the way here,
        // or the release writes the step straight back in.
        settle = 20
        at -= 1
        steps[at].aliases = []
        steps[at].value = ""
    }

    func skip() {
        guard !done else { return }
        at += 1
    }

    func startOver() {
        for i in steps.indices {
            steps[i].aliases = []
            steps[i].value = ""
        }
        at = 0
        exported = nil
        savedTo = nil
    }

    // MARK: - What the controller is

    private static func describe(_ pad: GCController) -> [String: String] {
        var out: [String: String] = [:]
        out["vendorName"] = pad.vendorName ?? ""
        out["productCategory"] = pad.productCategory
        out["isAttachedToDevice"] = pad.isAttachedToDevice ? "true" : "false"
        out["playerIndex"] = String(pad.playerIndex.rawValue)
        out["hasExtendedGamepad"] = pad.extendedGamepad != nil ? "true" : "false"
        out["hasMicroGamepad"] = pad.microGamepad != nil ? "true" : "false"
        out["hasHaptics"] = pad.haptics != nil ? "true" : "false"
        out["hasMotion"] = pad.motion != nil ? "true" : "false"
        out["hasBattery"] = pad.battery != nil ? "true" : "false"
        out["profileType"] = String(describing: type(of: pad.physicalInputProfile))
        return out
    }

    /// Every alias the profile answers to. This is the list that matters when
    /// writing the binding afterwards: the names it will actually accept,
    /// rather than the ones one might expect it to.
    private static func allElements(_ pad: GCController) -> [String] {
        pad.physicalInputProfile.elements
            .map { alias, element in
                let name = element.localizedName ?? ""
                let kind = String(describing: type(of: element))
                return "\(alias)  ->  \(kind)  \"\(name)\""
            }
            .sorted()
    }

    // MARK: - Handing it over

    func export() {
        var lines: [String] = ["# Controller mapping", ""]
        lines.append("## Identity")
        for key in identity.keys.sorted() { lines.append("\(key): \(identity[key] ?? "")") }
        lines.append("")
        lines.append("## Mapping")
        for step in steps {
            if step.seen {
                lines.append("\(step.prompt): \(step.aliases.joined(separator: ", ")) | \(step.value)")
            } else {
                lines.append("\(step.prompt): skipped")
            }
        }
        lines.append("")
        lines.append("## Every element the profile answers to")
        lines.append(contentsOf: everything)

        let text = lines.joined(separator: "\n")
        exported = text

        // Written down as well as shown. A page of this read off a screen in a
        // headset and typed out again is how transcription mistakes get into a
        // binding, which is the one place they are hardest to find later. The
        // save directory, because that is the one this app can hand back.
        if let dir = GRRomImport.saveDirectory {
            let url = dir.appendingPathComponent("controller-mapping.txt")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                savedTo = url.path
            }
        }
    }
}

struct GRControllerSetupView: View {

    @State private var probe = GRControllerProbe()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Controller mapping").font(.title2.weight(.medium))

                VStack(alignment: .leading, spacing: 4) {
                    Text(probe.controllerName.isEmpty ? "Looking…" : probe.controllerName)
                        .font(.headline)
                    ForEach(probe.found, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(probe.elementCount) elements · \(probe.events) presses · last \(probe.lastSeen)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

                if let step = probe.current {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Press: \(step.prompt)").font(.title3.weight(.semibold))
                        Text(step.hint).font(.callout).foregroundStyle(.secondary)
                        Text("\(probe.at + 1) of \(probe.steps.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    Text("All done. Export it.").font(.title3.weight(.semibold))
                }

                if !probe.liveValues.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moving now").font(.caption.weight(.semibold))
                        ForEach(probe.liveValues, id: \.self) { line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                HStack {
                    Button("Back") { probe.back() }.disabled(probe.at == 0)
                    Button("Skip") { probe.skip() }.disabled(probe.done)
                    Button("Start over") { probe.startOver() }
                    Spacer()
                    Button("Export") { probe.export() }.buttonStyle(.borderedProminent)
                }

                if let path = probe.savedTo {
                    Text("Saved to \(path)").font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(probe.steps) { step in
                        HStack(alignment: .top) {
                            Text(step.prompt).frame(width: 150, alignment: .leading)
                            Text(step.seen ? step.aliases.joined(separator: ", ") : "—")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(step.seen ? .primary : .secondary)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

                if let text = probe.exported {
                    Text(text).font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .onAppear { probe.begin() }
        .onDisappear { probe.end() }
    }
}

extension GRControllerSetupView {
    /// Only when asked for at launch. When it is asked for, this stands in
    /// place of the launcher: opening it is not a step on the way to playing.
    static var wanted: Bool {
        ProcessInfo.processInfo.environment["GEN1VISION_CONTROLLERSETUP"] != nil
            || ProcessInfo.processInfo.arguments.contains("-controller-setup")
    }
}

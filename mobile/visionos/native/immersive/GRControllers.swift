//  What the controller actually is, and what it is actually sending.
//
//  Mapping work on this platform is otherwise guesswork: the engine binds a
//  small set of names (a, b, start, back, the d-pad) on the recognised-gamepad
//  path and a handful of numbered indices on the raw-joystick one, and which
//  of those a DualSense lands on through SDL's GameController backend is not
//  something to assume. This reports the device and names each element as it
//  is pressed, so a button that does nothing in the game can be identified
//  rather than guessed at.
//
//  It also underpins the spatial-controller work: the PSVR2 Sense pair
//  identifies through GCDevice.productCategory, and this is where that becomes
//  visible.

import GameController
import Observation

@Observable
@MainActor
final class GRControllers {

    /// One line per connected device: name, category, profile class.
    private(set) var devices: [String] = []

    /// The elements pressed since the last press, newest first. Kept short --
    /// this is a read-out, not a log.
    private(set) var recent: [String] = []

    private var observers: [NSObjectProtocol] = []

    func start() {
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        GCController.startWirelessControllerDiscovery()
    }

    private func refresh() {
        devices = GCController.controllers().map { pad in
            let category = pad.productCategory
            let profile = pad.extendedGamepad != nil ? "extended" : "other"
            return "\(pad.vendorName ?? "?") · \(category) · \(profile)"
        }
        for pad in GCController.controllers() { observe(pad) }
    }

    private func observe(_ pad: GCController) {
        // physicalInputProfile rather than a concrete profile class: it exposes
        // every element as a string-keyed dictionary, which is exactly what is
        // needed to find out what a button is CALLED without knowing in
        // advance which profile the device presents.
        let profile = pad.physicalInputProfile
        for (name, element) in profile.buttons {
            element.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.note(name) }
            }
        }
        for (name, dpad) in profile.dpads {
            dpad.valueChangedHandler = { [weak self] _, x, y in
                guard abs(x) > 0.5 || abs(y) > 0.5 else { return }
                Task { @MainActor in self?.note("\(name) \(x > 0.5 ? "→" : x < -0.5 ? "←" : "")\(y > 0.5 ? "↑" : y < -0.5 ? "↓" : "")") }
            }
        }
    }

    private func note(_ name: String) {
        recent.removeAll { $0 == name }
        recent.insert(name, at: 0)
        if recent.count > 6 { recent.removeLast() }
    }
}

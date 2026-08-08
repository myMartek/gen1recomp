//  Shared state for the visionOS shell: which presentation the player is in,
//  and remembering it across launches.
//
//  visionOS lets a window and an ImmersiveSpace coexist -- including at .full
//  immersion, where the app may keep rendering its own windows if it wants to.
//  So "flat" and "VR" are not two builds or two apps here: they are one app
//  with the immersive space open or closed, switched at runtime.

import SwiftUI

@Observable
@MainActor
final class GRAppModel {

    /// Mirrors SwiftUI's immersive space lifecycle. The in-between state
    /// matters: openImmersiveSpace and dismissImmersiveSpace are async, and a
    /// second toggle arriving mid-transition would otherwise desynchronise the
    /// model from the actual scene.
    enum ImmersiveState {
        case closed
        case inTransition
        case open
    }

    let immersiveSpaceID = "world"

    var immersiveState: ImmersiveState = .closed

    /// Whether the player was in VR when they last quit. Restored on the next
    /// launch so the app comes back the way they left it.
    ///
    /// UserDefaults rather than the game's own save data on purpose: this has
    /// to be readable before LÖVE has booted, because the immersive space
    /// should open as part of coming up rather than visibly popping in a
    /// second later. The mod's own VR options row stays the source of truth
    /// for what the *game* does once it is running; this is only the shell's
    /// memory of how to present it.
    private static let lastModeKey = "GRLastModeImmersive"

    var wantsImmersiveOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Self.lastModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastModeKey) }
    }

    // MARK: - Not restoring into a broken state

    /// Set while the immersive space is open, cleared when it closes cleanly.
    ///
    /// If it is still set at launch, the previous session ended while immersed
    /// without ever closing the space -- a crash, or a force quit. Restoring
    /// into immersion then would drop the player straight back into whatever
    /// was broken, with no window to escape from, and the same thing would
    /// happen on every subsequent launch. So a session that did not end
    /// cleanly always comes back windowed.
    private static let immersiveActiveKey = "GRImmersiveSessionActive"

    private var immersiveSessionActive: Bool {
        get { UserDefaults.standard.bool(forKey: Self.immersiveActiveKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.immersiveActiveKey)
            // Written straight away rather than at the next synchronisation
            // point: the whole purpose of this flag is to survive a process
            // that is about to die unexpectedly.
            UserDefaults.standard.synchronize()
        }
    }

    /// True when the last run ended while immersed without closing the space.
    let previousSessionEndedBadly: Bool = UserDefaults.standard.bool(forKey: "GRImmersiveSessionActive")

    func markImmersiveSessionStarted() { immersiveSessionActive = true }
    func markImmersiveSessionEnded()   { immersiveSessionActive = false }

    /// Set once the first launch-time restore has been attempted, so that
    /// re-rendering the launcher view cannot trigger it again.
    var didRestoreOnLaunch = false

    /// The game version the native launcher has booted, or nil while it is
    /// still showing.
    ///
    /// On visionOS the Lua launcher never runs -- src/core/NativeShell.lua
    /// stands in for it -- so this window IS the launcher until a game is
    /// picked, and the game view afterwards. The distinction lives here rather
    /// than in the view because the window is dismissed on entering immersion
    /// and rebuilt when it comes back, and a launcher that reappeared over a
    /// running game would be worse than no window at all.
    var bootedVersion: String?

    // MARK: - Window control

    static let launcherWindowID = "launcher"

    /// SwiftUI's window actions, stashed by the launcher view.
    ///
    /// They have to be held rather than read from the environment at the point
    /// of use, because the code that needs to re-open the window runs when
    /// there is no launcher view left to read an environment from: the window
    /// is closed while immersed, and what brings it back is the immersive
    /// space ending. The actions stay valid regardless -- they are bound to
    /// the scene, not to the view that happened to hand them over.
    var openWindowAction: ((String) -> Void)?
    var dismissWindowAction: ((String) -> Void)?

    /// Called when the immersive space has gone away, by whichever route --
    /// our own button, a Digital Crown press, or the system tearing it down.
    ///
    /// The Crown is the reason this exists as a callback rather than being
    /// handled purely in the button: the player can always leave immersion
    /// without touching our UI, and if we only updated state in the button we
    /// would be left claiming to be immersed with no window to fix it from.
    func immersiveSpaceEnded() {
        immersiveState = .closed
        wantsImmersiveOnLaunch = false
        markImmersiveSessionEnded()
        openWindowAction?(Self.launcherWindowID)
        // BACK TO THE FRONT PAGE, not to the game seen flat.
        //
        // Leaving immersion used to reopen this window over a booted game,
        // which shows the 1080x1920 frame as a poster on the wall -- a view
        // nobody chose and cannot do much with. Leaving a world should land
        // where entering it did: the picker, with the saves on it.
        //
        // Both halves are needed. Clearing bootedVersion is what this window
        // draws from; the Lua side has to stand its launcher back up, or the
        // START button would send a command nobody is listening for.
        bootedVersion = nil
        GRShell.shared?.returnToLauncher()
    }
}

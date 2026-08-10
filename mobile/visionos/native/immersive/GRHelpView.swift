//  How the game is played, in the window that starts it.
//
//  Two schemes, and a player only ever has one of them in front of them: bare
//  hands, or a controller. So they are TABS rather than one long list -- a
//  reader looking for "how do I open the menu" should not have to work out
//  which half of a page applies to what they are holding.
//
//  Written against the gestures the mod actually reports (lib/VRCS.lua) and
//  the mapping it drives (lib/VR.lua). When one of those changes this file is
//  wrong, and wrong help is worse than none: it is the only description of the
//  controls anywhere in the app.

import SwiftUI

/// One row: what you do, and what happens.
private struct GRControl: Identifiable {
    let gesture: String
    let action: String
    /// Optional qualifier -- "diorama only", "in menus". Kept separate from
    /// the action so it can be styled as the aside it is.
    var note: String? = nil
    var id: String { gesture + action }
}

private struct GRControlGroup: Identifiable {
    let title: String
    let controls: [GRControl]
    var id: String { title }
}

// MARK: - The two schemes

private let handGroups: [GRControlGroup] = [
    GRControlGroup(title: "help.group.moving", controls: [
        GRControl(gesture: "help.hand.leftThumb",
                  action: "help.action.walk",
                  note: "help.note.tilt"),
        GRControl(gesture: "help.hand.rightThumb",
                  action: "help.action.turn",
                  note: "help.note.step"),
        GRControl(gesture: "help.hand.leftThumbMenu",
                  action: "help.action.cursor",
                  note: "help.note.menuOnly"),
    ]),
    GRControlGroup(title: "help.group.buttons", controls: [
        GRControl(gesture: "help.hand.rightIndex", action: "help.action.a"),
        GRControl(gesture: "help.hand.rightMiddle", action: "help.action.b"),
        GRControl(gesture: "help.hand.rightRing", action: "help.action.start"),
        GRControl(gesture: "help.hand.leftRing", action: "help.action.select"),
    ]),
    GRControlGroup(title: "help.group.table", controls: [
        GRControl(gesture: "help.hand.middlePinch",
                  action: "help.action.dragTable",
                  note: "help.note.dioramaOnly"),
        GRControl(gesture: "help.hand.bothMiddle",
                  action: "help.action.turnScale",
                  note: "help.note.dioramaOnly"),
    ]),
]

private let padGroups: [GRControlGroup] = [
    GRControlGroup(title: "help.group.moving", controls: [
        GRControl(gesture: "help.pad.leftStick", action: "help.action.walk"),
        GRControl(gesture: "help.pad.rightStickX",
                  action: "help.action.turn",
                  note: "help.note.firstPersonOnly"),
    ]),
    GRControlGroup(title: "help.group.buttons", controls: [
        GRControl(gesture: "help.pad.ab", action: "help.action.ab"),
        GRControl(gesture: "help.pad.trigger", action: "help.action.start"),
        GRControl(gesture: "help.pad.select", action: "help.action.view"),
        GRControl(gesture: "help.pad.stickClick", action: "help.action.view"),
    ]),
    GRControlGroup(title: "help.group.table", controls: [
        GRControl(gesture: "help.pad.rightStickY",
                  action: "help.action.zoom",
                  note: "help.note.dioramaOnly"),
        GRControl(gesture: "help.pad.grip",
                  action: "help.action.dragTable",
                  note: "help.note.dioramaOnly"),
    ]),
]

// MARK: - The view

struct GRHelpView: View {

    private enum Scheme: String, CaseIterable, Identifiable {
        case hands, controller
        var id: String { rawValue }
        var label: String {
            self == .hands ? "help.tab.hands" : "help.tab.controller"
        }
    }

    @State private var scheme: Scheme = .hands
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("", selection: $scheme) {
                        ForEach(Scheme.allCases) { s in
                            Text(tr(s.label)).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(tr(scheme == .hands ? "help.intro.hands"
                                             : "help.intro.controller"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(scheme == .hands ? handGroups : padGroups) { group in
                        section(group)
                    }
                }
                .padding(20)
                .frame(maxWidth: 620, alignment: .leading)
            }
            .navigationTitle(tr("help.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { dismiss() }
                }
            }
        }
    }

    private func section(_ group: GRControlGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr(group.title))
                .font(.headline)
                .padding(.bottom, 2)
            VStack(spacing: 0) {
                ForEach(group.controls) { control in
                    row(control)
                    if control.id != group.controls.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func row(_ control: GRControl) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            // The gesture leads, because that is what a reader has in their
            // hand and is looking for. The action answers it.
            Text(tr(control.gesture))
                .font(.body.weight(.medium))
                .frame(maxWidth: 210, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(control.action))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = control.note {
                    Text(tr(note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

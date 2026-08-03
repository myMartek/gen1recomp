//  Getting a cartridge dump into the app.
//
//  The engine finds a ROM by scanning its own save directory for a .gb/.gbc,
//  preferring one called picked_rom.gb (src/import/RomImporter.lua). So this
//  does not need a bridge into LÖVE at all: copy the file the player chose to
//  that name and the importer picks it up, verifies its SHA-1 and decodes it.
//
//  On iOS the engine reaches a picker through love.system.pickFile, a native
//  bridge in the LÖVE tree. Doing the same here would mean porting that bridge
//  and the SwiftUI shell would still have to own the picker, so this is the
//  shorter path to the same place.

import SwiftUI
import UniformTypeIdentifiers

enum GRRomImport {

    /// LÖVE's save directory: `Library/Application Support/<identity>`.
    ///
    /// NOT Documents. On Apple platforms LÖVE resolves COMMONPATH_APP_SAVEDIR
    /// from COMMONPATH_USER_APPDATA, which is Application Support
    /// (Filesystem.cpp; apple::USER_DIRECTORY_APPSUPPORT), and appends the
    /// identity directly because the game is fused. Assuming the iOS
    /// Documents convention instead put a ROM somewhere the engine never
    /// looks, and it reported "no ROM imported" while the file sat there.
    static var saveDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent("pokemon-love2d", isDirectory: true)
    }

    static var romPresent: Bool {
        guard let dir = saveDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        return names.contains { $0.lowercased().hasSuffix(".gb") || $0.lowercased().hasSuffix(".gbc") }
    }

    /// Copies a picked file in as picked_rom.gb. Returns a message to show.
    static func accept(_ source: URL) -> String {
        guard let dir = saveDirectory else { return "No save directory." }

        // A file from the document picker lives outside the sandbox until
        // asked for; without this the read fails with a permission error that
        // looks like a missing file.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try Data(contentsOf: source)
            // Named picked_rom.gb because that is what the importer looks for
            // first; the extension does not have to match the original, since
            // the engine identifies the ROM by SHA-1 rather than by name.
            let dest = dir.appendingPathComponent("picked_rom.gb")
            try data.write(to: dest, options: .atomic)
            return "Imported \(source.lastPathComponent) (\(data.count / 1024) KB). Restart to decode it."
        } catch {
            return "Import failed: \(error.localizedDescription)"
        }
    }

    /// .gb and .gbc are not system-declared types, so they are matched by
    /// filename extension.
    static var contentTypes: [UTType] {
        [UTType(filenameExtension: "gb"), UTType(filenameExtension: "gbc")]
            .compactMap { $0 } + [.data]
    }
}

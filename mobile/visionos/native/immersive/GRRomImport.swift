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

    /// `Documents/<identity>` -- LÖVE's save directory, and what
    /// love.filesystem.getDirectoryItems("") enumerates. The identity has to
    /// match conf.lua's t.identity.
    static var saveDirectory: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first
        else { return nil }
        return docs.appendingPathComponent("pokemon-love2d", isDirectory: true)
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

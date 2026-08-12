//  Getting a Pokémon Stadium cartridge into the app.
//
//  The mod builds its battle models out of that game's own data, and ships
//  none of it -- the same arrangement the Game Boy ROM already has here. It
//  looks for a cartridge in `baseroms/` inside LÖVE's save directory
//  (DramaticShapeVoxelMod/lib/StadiumInstall.lua) and builds from it once, on
//  the loading screen of the next start.
//
//  So this is a copy and nothing more, exactly like GRRomImport: put the file
//  where the mod looks, and let the mod be the authority on whether it is a
//  cartridge it can read.

import SwiftUI
import UniformTypeIdentifiers

enum GRStadiumImport {

    /// Where the mod looks. A subfolder of the same save directory the Game
    /// Boy ROM lands in -- see GRRomImport.saveDirectory for why that is
    /// Application Support and not Documents.
    static var romDirectory: URL? {
        GRRomImport.saveDirectory?.appendingPathComponent("baseroms",
                                                          isDirectory: true)
    }

    /// The three byte orders an N64 dump comes in. The mod normalises them on
    /// load, so all three are accepted as they are.
    private static let extensions = ["z64", "n64", "v64"]

    /// Copies a picked cartridge into `baseroms/`. Returns nil when that
    /// worked, or a message to show when it did not.
    ///
    /// Copied rather than read into memory and written back: these are 32 to
    /// 64 MB, and there is no reason for any of it to pass through the app's
    /// own heap.
    static func accept(_ source: URL) -> String? {
        guard let dir = romDirectory else { return "No save directory." }

        let ext = source.pathExtension.lowercased()
        // Refused HERE rather than copied under a name that lies about it.
        // The mod picks its file by extension and normalises the byte order
        // from it, so a .n64 renamed .z64 would be read back-to-front and
        // fail as "not a cartridge" -- a long way from the actual mistake.
        guard extensions.contains(ext) else {
            return "That is not a cartridge dump: expected .z64, .n64 or .v64."
        }

        // A file from the document picker lives outside the sandbox until
        // asked for; without this the read fails with a permission error that
        // looks like a missing file.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            // Any cartridge already in there goes first. The mod builds from
            // whichever it finds, so leaving two behind means the models come
            // from whichever the filesystem happened to list first -- and a
            // player who just imported a different dump would have no way to
            // tell which one they got. Only files in this folder, only the
            // three cartridge extensions: nothing else is touched.
            if let existing = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for name in existing
                where extensions.contains((name as NSString).pathExtension.lowercased()) {
                    try? FileManager.default.removeItem(
                        at: dir.appendingPathComponent(name))
                }
            }
            let dest = dir.appendingPathComponent("stadium.\(ext)")
            try FileManager.default.copyItem(at: source, to: dest)
            return nil
        } catch {
            return "Import failed: \(error.localizedDescription)"
        }
    }

    /// None of the three are system-declared types, so they are matched by
    /// filename extension.
    static var contentTypes: [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) } + [.data]
    }
}

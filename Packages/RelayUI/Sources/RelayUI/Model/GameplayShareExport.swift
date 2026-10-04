// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(macOS)
import Foundation

enum GameplayShareExport {
    /// Disk-backed copying keeps long recordings out of memory. Stage on the
    /// destination volume before replacing an owner-confirmed existing file.
    static func copy(from source: URL, to destination: URL) throws {
        try withExtendedLifetime(GameplayShareLease(url: source)) {
            let manager = FileManager.default
            let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                            appropriateFor: destination, create: true)
            defer { try? manager.removeItem(at: directory) }
            let staged = directory.appendingPathComponent(source.lastPathComponent)
            try manager.copyItem(at: source, to: staged)
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var writeError: Error?
            coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
                do {
                    if manager.fileExists(atPath: target.path) {
                        _ = try manager.replaceItemAt(target, withItemAt: staged, options: .usingNewMetadataOnly)
                    } else {
                        try manager.moveItem(at: staged, to: target)
                    }
                } catch { writeError = error }
            }
            if let error = coordinationError { throw error }
            if let error = writeError { throw error }
        }
    }
}
#endif

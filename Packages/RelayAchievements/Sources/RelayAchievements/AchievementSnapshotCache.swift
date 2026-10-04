// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import RelayDomain

/// A disposable cache of RA-owned data, never canonical Relay progress and
/// never a sync payload. Tokens and passwords cannot be represented here.
actor AchievementSnapshotCache {
    private let directory: URL
    private var generation = UUID()
    private var file: URL?
    init(directory: URL) { self.directory = directory }

    func open(username: String) -> (UUID, [GameID: AchievementGame]) {
        generation = UUID()
        let digest = SHA256.hash(data: Data(username.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent(digest + ".json")
        guard let file, let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: file),
              let games = try? JSONDecoder().decode([GameID: AchievementGame].self, from: data) else { return (generation, [:]) }
        return (generation, games)
    }

    func save(_ games: [GameID: AchievementGame], generation expected: UUID) {
        guard generation == expected, let file else { return }
        let recent = games.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(200)
        let values = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        guard let bytes = try? JSONEncoder().encode(values), bytes.count <= 16 * 1024 * 1024 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true
            try folder.setResourceValues(resources)
            try bytes.write(to: file, options: .atomic)
        } catch { /* A disposable cache failure must never affect play or unlock delivery. */ }
    }

    func clear() {
        generation = UUID()
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}

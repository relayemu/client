// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayDomain
import RelayLibrary
import RelayPersistence
@testable import RelayTitleCatalog

final class RealDumpQualificationTests: XCTestCase {
    private static let cartridgeExtensions: Set<String> = ["gb", "gbc", "gba", "nds", "sms", "gg", "nes", "sfc", "smc", "pce", "ws", "wsc"]

    /// One import unit per cartridge file, one per disc folder (its cue and every file it may reference).
    private func units(in corpus: URL) throws -> [[URL]] {
        let fm = FileManager.default
        var units: [[URL]] = []
        for entry in try fm.contentsOfDirectory(at: corpus, includingPropertiesForKeys: [.isDirectoryKey]).sorted(by: { $0.path < $1.path }) {
            if (try entry.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                let members = try fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
                let discs = members.filter { ["cue", "chd", "m3u"].contains($0.pathExtension.lowercased()) }
                if !discs.isEmpty {
                    units.append(members.filter { ["cue", "chd", "m3u", "bin", "sbi"].contains($0.pathExtension.lowercased()) })
                } else {
                    units += members.filter { Self.cartridgeExtensions.contains($0.pathExtension.lowercased()) }.map { [$0] }
                }
            } else if Self.cartridgeExtensions.contains(entry.pathExtension.lowercased()) {
                units.append([entry])
            }
        }
        return units
    }

    func testRealDumpsImportWithCatalogTitles() async throws {
        guard let path = ProcessInfo.processInfo.environment["RELAY_ROM_CORPUS"] else {
            throw XCTSkip("Set RELAY_ROM_CORPUS to a folder of your own dumps to run this qualification.")
        }
        // RELAY_ROM_LIBRARY keeps the library at <path>/Library, which a Debug app opens with --relay-library-root <path>.
        let kept = ProcessInfo.processInfo.environment["RELAY_ROM_LIBRARY"].map { URL(fileURLWithPath: $0).appendingPathComponent("Library") }
        let root = kept ?? FileManager.default.temporaryDirectory.appendingPathComponent("relay-dump-qualification-\(UUID().uuidString)")
        defer { if kept == nil { try? FileManager.default.removeItem(at: root) } }
        let location = LibraryLocation(rootURL: root)
        try location.createDirectories()
        let store = kept == nil ? try SQLiteLibraryStore.inMemory() : try SQLiteLibraryStore.open(at: location.databaseURL)
        let importer = GameImporter(store: store, location: location, metadataProvider: TitleCatalogProvider(catalog: try TitleCatalog.bundled()))

        var rows: [[String: String]] = []
        for unit in try units(in: URL(fileURLWithPath: path)) {
            let started = Date()
            let report = await importer.importFiles(unit)
            for outcome in report.outcomes {
                var row = ["source": outcome.displayName, "seconds": String(format: "%.2f", Date().timeIntervalSince(started))]
                switch outcome.result {
                case .added(let game, _):
                    let metadata = try await store.games.metadata(for: game.id)
                    let digests = try await store.games.lookupDigests(for: game.contentFingerprint)
                    row["result"] = metadata == nil ? "unmatched" : "matched"
                    row["system"] = game.systemID.rawValue
                    row["title"] = game.title
                    row["region"] = metadata?.region ?? ""
                    row["coverKey"] = metadata?.coverKey ?? ""
                    row["sha1"] = digests?.sha1 ?? ""
                    row["discSerial"] = digests?.discSerial ?? ""
                    if let key = metadata?.coverKey { XCTAssertTrue(CoverKey.isValid(key), key) }
                case .duplicate(let existing): row["result"] = "duplicate of \(existing.title)"
                default: row["result"] = String(describing: outcome.result)
                }
                rows.append(row)
                print("RELAY-DUMP \(row["result"]!) | \(row["system"] ?? "-") | \(row["title"] ?? "-") | \(row["region"] ?? "") | serial \(row["discSerial"] ?? "") | \(outcome.displayName)")
            }
        }
        let matched = rows.filter { $0["result"] == "matched" }.count, added = rows.filter { $0["system"] != nil }.count
        print("RELAY-DUMP summary: \(rows.count) sources, \(added) games added, \(matched) matched by the catalog")
        if let output = ProcessInfo.processInfo.environment["RELAY_ROM_REPORT"] {
            let data = try JSONSerialization.data(withJSONObject: ["revision": try TitleCatalog.bundled().revision, "rows": rows],
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: output))
        }
        XCTAssertGreaterThan(added, 0, "no game imported from \(path)")
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CryptoKit
import RelayDomain
@testable import RelayLibrary

final class TitleBackfillTests: XCTestCase {
    var root: URL!
    var store: InMemoryLibraryStore!
    var location: LibraryLocation!
    override func setUp() async throws {
        root = try TestSupport.temporaryDirectory()
        store = InMemoryLibraryStore()
        location = LibraryLocation(rootURL: root.appendingPathComponent("Library"))
        try location.createDirectories()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func fixture(_ name: String) -> URL {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        return repo.appendingPathComponent("Tests/Fixtures/ROMs/relay-gb-counter/\(name)")
    }
    private func sha1(_ url: URL) throws -> String {
        Insecure.SHA1.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testBackfillRenamesDefaultTitlesSkipsRenamedAndCloudOnlyGames() async throws {
        let importer = GameImporter(store: store, location: location)
        let report = await importer.importFiles([fixture("relay-gb-counter.gb"), fixture("relay-gbc-counter.gbc")])
        var games = report.addedGames
        XCTAssertEqual(games.count, 2)
        games[1].title = "Mine"
        try await store.games.update(games[1])
        let cloudOnly = Game(systemID: .gameBoyAdvance, title: "Cloud", contentFingerprint: try ContentFingerprint(sha256: Array(repeating: 9, count: 32)), addedAt: Date())
        try await store.games.insert(cloudOnly, files: [])

        let provider = DigestProvider(entries: [
            try sha1(fixture("relay-gb-counter.gb")): MetadataCandidate(title: "Counter"),
            try sha1(fixture("relay-gbc-counter.gbc")): MetadataCandidate(title: "Colour Counter"),
        ])
        let applier = MetadataApplier(store: store, location: location, provider: provider, artworkStore: ArtworkStore(location: location))
        let result = await TitleBackfill(applier: applier, store: store).run()
        XCTAssertEqual(result, TitleBackfill.Report(examined: 3, matched: 2, renamed: 1))
        let first = try await store.games.game(id: games[0].id)
        let second = try await store.games.game(id: games[1].id)
        XCTAssertEqual(first?.title, "Counter")
        XCTAssertEqual(second?.title, "Mine")

        let again = await TitleBackfill(applier: applier, store: store).run()
        XCTAssertEqual(again.renamed, 0, "idempotent")
    }

    func testRunOnceIsScopedToTheLibraryAndItsRevision() async throws {
        _ = await GameImporter(store: store, location: location).importFiles([fixture("relay-gb-counter.gb")])
        let provider = DigestProvider(entries: [try sha1(fixture("relay-gb-counter.gb")): MetadataCandidate(title: "Counter")])
        let backfill = TitleBackfill(applier: MetadataApplier(store: store, location: location, provider: provider,
                                                              artworkStore: ArtworkStore(location: location)), store: store)
        let marker = location.metadataBackfillMarkerURL
        XCTAssertTrue(marker.path.hasPrefix(location.rootURL.path), "the marker travels with the library")
        let first = await backfill.runOnce(revision: "catalog@r1", marker: marker)
        XCTAssertEqual(first?.renamed, 1)
        let repeated = await backfill.runOnce(revision: "catalog@r1", marker: marker)
        XCTAssertNil(repeated, "already done for this revision")
        let updated = await backfill.runOnce(revision: "catalog@r2", marker: marker)
        XCTAssertEqual(updated?.examined, 1, "a new catalog revision reruns")
    }

    func testGateHoldsTheBackfillWhilePaused() async throws {
        _ = await GameImporter(store: store, location: location).importFiles([fixture("relay-gb-counter.gb")])
        let gate = ActivityGate()
        await gate.setPaused(true)
        let applier = MetadataApplier(store: store, location: location, provider: DigestProvider(entries: [:]), artworkStore: ArtworkStore(location: location))
        let task = Task { await TitleBackfill(applier: applier, store: store, gate: gate).run() }
        try await Task.sleep(for: .milliseconds(100))
        let games = try await store.games.allGames()
        XCTAssertEqual(games.count, 1)
        let digests = try await store.games.lookupDigests(for: games[0].contentFingerprint)
        XCTAssertNil(digests, "nothing is read while gameplay holds the gate")
        await gate.setPaused(false)
        let report = await task.value
        XCTAssertEqual(report.examined, 1)
    }
}

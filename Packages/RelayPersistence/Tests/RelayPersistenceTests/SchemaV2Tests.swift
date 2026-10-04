// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class SchemaV2Tests: XCTestCase {
    func testV1DatabaseMigratesToV2KeepingData() async throws {
        let url = try Fixtures.temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let game = Fixtures.game(seed: 1, title: "Old")
        let session = PlaySession(gameID: game.id, coreID: "mgba", startedAt: Date(timeIntervalSince1970: 100)).ended(at: Date(timeIntervalSince1970: 130))
        // Build a genuine v1 database with the v1-only migrator and raw v1 rows.
        do {
            var config = Configuration(); config.foreignKeysEnabled = true
            let pool = try DatabasePool(path: url.path, configuration: config)
            try Schema.makeMigrator(upTo: 1).migrate(pool)
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO game (id, system_id, title, content_fingerprint, added_at) VALUES (?, ?, ?, ?, ?)",
                               arguments: [game.id.description, "gba", "Old", game.contentFingerprint.canonicalString, 1_700_000_000_000])
                try db.execute(sql: "INSERT INTO game_file (id, game_id, role, fingerprint, size_in_bytes, original_file_name, location_root, location_path) VALUES (?, ?, 'primary', ?, 10, 'old.gba', 'managedLibrary', ?)",
                               arguments: [GameFileID().description, game.id.description, game.contentFingerprint.canonicalString, "Games/\(game.id)/old.gba"])
                try db.execute(sql: "INSERT INTO play_session (id, game_id, core_id, started_at, ended_at) VALUES (?, ?, 'mgba', 100000, 130000)",
                               arguments: [session.id.description, game.id.description])
                XCTAssertFalse(try db.columns(in: "game").contains { $0.name == "is_favorite" })
            }
            try pool.close()
        }

        let store = try SQLiteLibraryStore.open(at: url)
        defer { try? store.close() }
        XCTAssertEqual(try store.appliedMigrations(), Schema.migrationIdentifiers)
        let migrated = try await store.games.game(id: game.id)
        XCTAssertEqual(migrated?.title, "Old")
        XCTAssertEqual(migrated?.isFavorite, false)
        let sessions = try await store.playHistory.sessions(for: game.id, limit: 5)
        XCTAssertEqual(sessions.first?.id, session.id)
        XCTAssertNil(sessions.first?.screenshotLocation)
        let metadata = try await store.games.metadata(for: game.id)
        XCTAssertNil(metadata)
        // v2 features work on the migrated database.
        var fav = migrated!; fav.isFavorite = true
        try await store.games.update(fav)
        let favorites = try await store.games.games(matching: GameQuery(favoritesOnly: true))
        XCTAssertEqual(favorites.map(\.id), [game.id])
    }
}

final class LibraryQueryTests: XCTestCase {
    var store: SQLiteLibraryStore!
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var alpha: Game!, beta: Game!, gamma: Game!

    override func setUp() async throws {
        store = try SQLiteLibraryStore.inMemory()
        alpha = Fixtures.game(seed: 1, title: "Alpha Quest", addedAt: t0)
        beta = Fixtures.game(seed: 2, title: "beta_blast", addedAt: t0.addingTimeInterval(10))
        gamma = Fixtures.game(seed: 3, title: "Gamma", addedAt: t0.addingTimeInterval(20))
        for g in [alpha!, beta!, gamma!] { try await store.games.insert(g, files: [Fixtures.primaryFile(for: g)]) }
    }

    func testRecentlyAddedOrdersByImportTimeNewestFirst() async throws {
        let recent = try await store.games.recentlyAdded(limit: 2)
        XCTAssertEqual(recent.map(\.title), ["Gamma", "beta_blast"])
        // Same timestamp → stable by id.
        let twin = Fixtures.game(seed: 4, title: "Twin", addedAt: t0.addingTimeInterval(20))
        try await store.games.insert(twin, files: [Fixtures.primaryFile(for: twin)])
        let top = try await store.games.recentlyAdded(limit: 2)
        XCTAssertEqual(Set(top.map(\.id)), [gamma.id, twin.id])
        XCTAssertEqual(top.map(\.id), [gamma.id, twin.id].sorted { $0.description < $1.description })
    }

    func testFavoritesAndSystemFilter() async throws {
        var fav = beta!; fav.isFavorite = true
        try await store.games.update(fav)
        let favorites = try await store.games.games(matching: GameQuery(favoritesOnly: true))
        XCTAssertEqual(favorites.map(\.id), [beta.id])
        let gba = try await store.games.games(matching: GameQuery(systemID: .gameBoyAdvance))
        XCTAssertEqual(gba.count, 3)
        let none = try await store.games.games(matching: GameQuery(systemID: "nes"))
        XCTAssertEqual(none, [])
        let counts = try await store.games.gameCountsBySystem()
        XCTAssertEqual(counts, [.gameBoyAdvance: 3])
    }

    func testSearchMatchesTitleMetadataAndSystemNameCaseInsensitively() async throws {
        try await store.games.upsertMetadata(GameMetadata(gameID: alpha.id, alternateTitles: ["Quest of Alphas"], developer: "Ember Works",
                                                          publisher: "Warm Games", source: "test", matchedAt: t0))
        func expect(_ q: String, _ titles: [String], _ note: String = "", line: UInt = #line) async throws {
            let found = try await store.games.games(matching: GameQuery(text: q)).map(\.title)
            XCTAssertEqual(found, titles, note, line: line)
        }
        try await expect("ALPHA", ["Alpha Quest"])
        try await expect("blast", ["beta_blast"])
        try await expect("ember", ["Alpha Quest"], "developer")
        try await expect("warm", ["Alpha Quest"], "publisher")
        try await expect("alphas", ["Alpha Quest"], "alternate title")
        try await expect("game boy", ["Alpha Quest", "beta_blast", "Gamma"], "system name")
        try await expect("GBA", ["Alpha Quest", "beta_blast", "Gamma"], "system short name")
        try await expect("zzz", [])
        try await expect("%", [], "LIKE wildcards are escaped")
        try await expect("_blast", ["beta_blast"], "underscore is literal")
        try await expect("   ", ["Alpha Quest", "beta_blast", "Gamma"], "blank query = no filter")
    }

    func testMetadataRoundTripAndCascade() async throws {
        let artwork = try ContentLocation(root: .managedLibrary, relativePath: "Artwork/\(alpha.id)/cover.png")
        let m = GameMetadata(gameID: alpha.id, alternateTitles: ["A", "B"], developer: "D", publisher: "P", releaseYear: 1999,
                             genre: "RPG", region: "JP", summary: "S", artworkLocation: artwork, source: "test", matchedAt: t0)
        try await store.games.upsertMetadata(m)
        let stored = try await store.games.metadata(for: alpha.id)
        XCTAssertEqual(stored, m)
        var changed = m; changed.summary = "S2"
        try await store.games.upsertMetadata(changed)
        let again = try await store.games.metadata(for: alpha.id)
        XCTAssertEqual(again?.summary, "S2")
        let ghost = GameID()
        await XCTAssertThrowsErrorAsync(try await store.games.upsertMetadata(GameMetadata(gameID: ghost, source: "t", matchedAt: t0))) {
            XCTAssertEqual($0 as? LibraryError, .gameNotFound(ghost))
        }
        try await store.games.deleteGame(id: alpha.id)
        let gone = try await store.games.metadata(for: alpha.id)
        XCTAssertNil(gone)
    }

    func testPlaySessionScreenshotRoundTrip() async throws {
        let shot = try ContentLocation(root: .managedLibrary, relativePath: "Screenshots/\(alpha.id)/last.png")
        let session = PlaySession(gameID: alpha.id, coreID: "mgba", startedAt: t0, endedAt: t0.addingTimeInterval(5), screenshotLocation: shot)
        try await store.playHistory.record(session)
        let last = try await store.playHistory.lastPlayed()
        XCTAssertEqual(last?.latestSession.screenshotLocation, shot)
    }
}

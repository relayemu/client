// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class CoverDownloadSchemaTests: XCTestCase {
    private let coverKey = "gba/" + String(repeating: "c", count: 64)

    func testMigrationEightIsTheCoverDownloadCache() {
        XCTAssertEqual(Schema.migrationIdentifiers[7], "v8-cover-art-downloads")
    }

    func testUpgradeFromSevenKeepsMetadataAndAddsTheMissCache() async throws {
        let url = try Fixtures.temporaryDatabaseURL()
        let game = Fixtures.game(seed: 80)
        do {
            let pool = try DatabasePool(path: url.path)
            try Schema.makeMigrator(upTo: 7).migrate(pool)
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO game (id,system_id,title,content_fingerprint,added_at,updated_at) VALUES (?,'gba','Kept',?,1000,2000)",
                               arguments: [game.id.description, game.contentFingerprint.canonicalString])
                try db.execute(sql: "INSERT INTO game_metadata (game_id,alternate_titles,source,matched_at,cover_key) VALUES (?,'[]','title-catalog',3000,?)",
                               arguments: [game.id.description, self.coverKey])
            }
            try pool.close()
        }
        let store = try SQLiteLibraryStore.open(at: url)
        let metadata = try await store.games.metadata(for: game.id)
        XCTAssertEqual(metadata?.coverKey, coverKey)
        let missed = try await store.games.coverMissedAt(key: coverKey)
        XCTAssertNil(missed)
    }

    func testArtworkLocationUpdateTouchesNothingElse() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let game = Fixtures.game(seed: 81)
        try await store.games.insert(game, files: [])
        let metadata = GameMetadata(gameID: game.id, region: "Europe", coverKey: coverKey, source: "title-catalog",
                                    matchedAt: Date(timeIntervalSince1970: 5))
        try await store.games.upsertMetadata(metadata)

        let cover = try LibraryLocation.catalogCoverLocation(gameID: game.id, format: .heic)
        try await store.games.setArtworkLocation(cover, for: game.id)
        var expected = metadata
        expected.artworkLocation = cover
        let withCover = try await store.games.metadata(for: game.id)
        XCTAssertEqual(withCover, expected)

        try await store.games.setArtworkLocation(nil, for: game.id)
        let cleared = try await store.games.metadata(for: game.id)
        XCTAssertEqual(cleared, metadata)

        // No metadata row: nothing to point at, nothing created.
        let bare = Fixtures.game(seed: 82)
        try await store.games.insert(bare, files: [])
        try await store.games.setArtworkLocation(cover, for: bare.id)
        let none = try await store.games.metadata(for: bare.id)
        XCTAssertNil(none)
    }

    func testCoverMissRoundTrip() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let unknown = try await store.games.coverMissedAt(key: coverKey)
        XCTAssertNil(unknown)
        try await store.games.recordCoverMiss(key: coverKey, at: Date(timeIntervalSince1970: 100))
        try await store.games.recordCoverMiss(key: coverKey, at: Date(timeIntervalSince1970: 200))
        let latest = try await store.games.coverMissedAt(key: coverKey)
        XCTAssertEqual(latest, Date(timeIntervalSince1970: 200))
    }
}

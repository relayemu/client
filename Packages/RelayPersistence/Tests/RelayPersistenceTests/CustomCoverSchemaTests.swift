// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class CustomCoverSchemaTests: XCTestCase {
    func testMigrationNineIsTheCustomCoverTable() {
        XCTAssertEqual(Schema.migrationIdentifiers[8], "v9-cover-art-custom-covers")
    }

    func testUpgradeFromEightKeepsDataAndStartsWithoutCovers() async throws {
        let url = try Fixtures.temporaryDatabaseURL()
        let game = Fixtures.game(seed: 90)
        do {
            let pool = try DatabasePool(path: url.path)
            try Schema.makeMigrator(upTo: 8).migrate(pool)
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO game (id,system_id,title,content_fingerprint,added_at,updated_at) VALUES (?,'gba','Kept',?,1000,2000)",
                               arguments: [game.id.description, game.contentFingerprint.canonicalString])
                try db.execute(sql: "INSERT INTO cover_miss (cover_key, missed_at) VALUES ('gba/x', 5)")
            }
            try pool.close()
        }
        let store = try SQLiteLibraryStore.open(at: url)
        let kept = try await store.games.game(id: game.id)
        XCTAssertEqual(kept?.title, "Kept")
        let missed = try await store.games.coverMissedAt(key: "gba/x")
        XCTAssertNotNil(missed)
        let none = try await store.games.customCover(for: game.id)
        XCTAssertNil(none)
    }

    func testCoverAndResetRoundTripAndFollowTheGame() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let game = Fixtures.game(seed: 91), other = Fixtures.game(seed: 92)
        try await store.games.insert(game, files: [])
        try await store.games.insert(other, files: [])

        let chosen = CustomCover(gameID: game.id, fingerprint: Fixtures.fingerprint(93), sizeInBytes: 81_234,
                                 updatedAt: Date(timeIntervalSince1970: 1_000))
        try await store.games.setCustomCover(chosen)
        let stored = try await store.games.customCover(for: game.id)
        XCTAssertEqual(stored, chosen)

        let reset = CustomCover(gameID: game.id, fingerprint: nil, sizeInBytes: 0, updatedAt: Date(timeIntervalSince1970: 2_000))
        try await store.games.setCustomCover(reset)
        let cleared = try await store.games.customCover(for: game.id)
        XCTAssertEqual(cleared, reset)
        XCTAssertEqual(cleared?.isCleared, true)

        let second = CustomCover(gameID: other.id, fingerprint: Fixtures.fingerprint(94), sizeInBytes: 10,
                                 updatedAt: Date(timeIntervalSince1970: 3_000))
        try await store.games.setCustomCover(second)
        let all = try await store.games.customCovers()
        XCTAssertEqual(Set(all), [reset, second])

        try await store.games.deleteGame(id: other.id)
        let afterDelete = try await store.games.customCovers()
        XCTAssertEqual(afterDelete, [reset])
    }

    func testUnknownGameIsRefused() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let cover = CustomCover(gameID: GameID(), fingerprint: Fixtures.fingerprint(95), sizeInBytes: 1, updatedAt: Date())
        do {
            try await store.games.setCustomCover(cover)
            XCTFail("a cover for a game that does not exist must be refused")
        } catch LibraryError.gameNotFound {}
    }
}

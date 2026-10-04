// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class SchemaV3Tests: XCTestCase {
    func testV2DatabaseMigratesToV3AndOldSessionsHaveNoPausedTime() async throws {
        let url = try Fixtures.temporaryDatabaseURL()
        let game = Fixtures.game(seed: 3)
        let session = PlaySessionID()
        do {
            var config = Configuration(); config.foreignKeysEnabled = true
            let pool = try DatabasePool(path: url.path, configuration: config)
            try Schema.makeMigrator(upTo: 2).migrate(pool)
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO game (id, system_id, title, content_fingerprint, added_at, is_favorite) VALUES (?, ?, ?, ?, ?, 0)",
                               arguments: [game.id.description, "gba", "Old", game.contentFingerprint.canonicalString, 1_700_000_000_000])
                try db.execute(sql: "INSERT INTO play_session (id, game_id, core_id, started_at, ended_at) VALUES (?, ?, 'mgba', 100000, 160000)",
                               arguments: [session.description, game.id.description])
                XCTAssertFalse(try db.columns(in: "play_session").contains { $0.name == "paused_ms" })
            }
            try pool.close()
        }
        let store = try SQLiteLibraryStore.open(at: url)
        defer { try? store.close() }
        XCTAssertTrue(try store.appliedMigrations().contains("v3-phase4-play"))
        let sessions = try await store.playHistory.sessions(for: game.id, limit: 5)
        XCTAssertEqual(sessions.first?.pausedDuration, 0)
        XCTAssertEqual(sessions.first?.duration, 60)
        let entry = try await store.playHistory.lastPlayed()
        XCTAssertEqual(entry?.totalPlayDuration, 60)
    }

    func testPausedTimeIsPersistedAndExcludedFromTotals() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let game = Fixtures.game(seed: 4)
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var session = PlaySession(gameID: game.id, coreID: "mgba", startedAt: start)
        try await store.playHistory.record(session)
        session.pausedDuration = 25
        session = session.ended(at: start.addingTimeInterval(100))
        try await store.playHistory.record(session)
        let back = try await store.playHistory.sessions(for: game.id, limit: 1).first
        XCTAssertEqual(back?.pausedDuration, 25)
        XCTAssertEqual(back?.duration, 75)
        let entry = try await store.playHistory.lastPlayed()
        XCTAssertEqual(entry?.totalPlayDuration, 75)

        // Paused time can never make a session negative.
        var odd = PlaySession(gameID: game.id, coreID: "mgba", startedAt: start.addingTimeInterval(1000), pausedDuration: 500)
        odd = odd.ended(at: start.addingTimeInterval(1010))
        try await store.playHistory.record(odd)
        XCTAssertEqual(odd.duration, 0)
        let total = try await store.playHistory.lastPlayed()
        XCTAssertEqual(total?.totalPlayDuration, 75)
    }
}

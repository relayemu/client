// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  columns backfilled for existing rows, revision graph tables, journal, meta,
//  tombstones, deferred records, content descriptors.

import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class SchemaV4Tests: XCTestCase {
    func testV3DatabaseMigratesToV4KeepingDataAndMintingIdentity() async throws {
        let url = try Fixtures.temporaryDatabaseURL()
        let game = Fixtures.game(seed: 3)
        let session = PlaySessionID()
        let state = SaveStateID()
        do {
            var config = Configuration(); config.foreignKeysEnabled = true
            let pool = try DatabasePool(path: url.path, configuration: config)
            try Schema.makeMigrator(upTo: 3).migrate(pool)
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO game (id, system_id, title, content_fingerprint, added_at, is_favorite) VALUES (?, ?, ?, ?, ?, 1)",
                               arguments: [game.id.description, "gba", "Old", game.contentFingerprint.canonicalString, 1_700_000_000_000])
                try db.execute(sql: "INSERT INTO play_session (id, game_id, core_id, started_at, ended_at, paused_ms) VALUES (?, ?, 'mgba', 100000, 160000, 0)",
                               arguments: [session.description, game.id.description])
                try db.execute(sql: """
                    INSERT INTO save_state (id, game_id, core_id, core_version, format_version, kind, created_at, location_root, location_path)
                    VALUES (?, ?, 'mgba', '0.10.3', 1, 'manual', 150000, 'managedLibrary', ?)
                    """, arguments: [state.description, game.id.description, "Saves/\(game.id)/states/\(state).relaystate"])
                XCTAssertFalse(try db.tableExists("sync_journal"))
            }
            try pool.close()
        }
        let store = try SQLiteLibraryStore.open(at: url, deviceKind: .iPad)
        defer { try? store.close() }
        XCTAssertTrue(try store.appliedMigrations().contains("v4-phase5-sync"))
        let identity = try await store.syncStore.identity()
        XCTAssertEqual(identity.deviceKind, .iPad)

        let migrated = try await store.games.game(id: game.id)
        XCTAssertEqual(migrated?.updatedAt, migrated?.addedAt, "updated_at backfilled from added_at")
        XCTAssertEqual(migrated?.isFavorite, true)

        let sessions = try await store.playHistory.sessions(for: game.id, limit: 5)
        XCTAssertEqual(sessions.first?.installationID, identity.installationID, "old sessions were played here")
        XCTAssertEqual(sessions.first?.deviceKind, .iPad)
        XCTAssertEqual(sessions.first?.origin, .local)

        let states = try await store.saves.saveStates(for: game.id)
        XCTAssertEqual(states.first?.stateCompatibilityVersion, "0.10.3", "compatibility version backfilled from the core version")
        XCTAssertEqual(states.first?.formatVersion, 1)
        XCTAssertEqual(states.first?.installationID, identity.installationID)
        XCTAssertNil(states.first?.batteryRevisionID)

        // Identity is stable across reopen.
        try store.close()
        let reopened = try SQLiteLibraryStore.open(at: url, deviceKind: .mac)
        let again = try await reopened.syncStore.identity()
        XCTAssertEqual(again.installationID, identity.installationID)
        XCTAssertEqual(again.deviceKind, .iPad, "the kind recorded at migration time stays")
        let pending = try await reopened.syncStore.journal.pendingCount()
        XCTAssertEqual(pending, 0, "migration journals nothing; enablement does")
        try reopened.close()
    }

    func testFreshDatabaseHasEveryPhaseFiveTable() throws {
        let store = try SQLiteLibraryStore.inMemory()
        try store.writer.read { db in
            for table in ["battery_revision", "battery_head", "sync_journal", "sync_meta", "sync_tombstone", "sync_deferred", "game_content"] {
                XCTAssertTrue(try db.tableExists(table), table)
            }
            XCTAssertTrue(try db.columns(in: "game").contains { $0.name == "updated_at" })
            XCTAssertTrue(try db.columns(in: "save_state").contains { $0.name == "battery_revision_id" })
        }
    }
}

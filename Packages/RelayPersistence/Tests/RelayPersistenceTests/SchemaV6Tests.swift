// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class SchemaV6Tests: XCTestCase {
    func testLegacyReimportMigrationKeepsOwnedHistoryAndConvertsDeletionReceipts() async throws {
        let url = try Fixtures.temporaryDatabaseURL()
        let active = Fixtures.game(seed: 70), initial = Fixtures.game(seed: 71)
        let retired = Fixtures.fingerprint(72)
        let source = InstallationID(), state = SaveStateID(), orphan = SaveStateID(), queued = SaveStateID()
        let session = PlaySessionID(), revision = BatteryRevisionID()
        do {
            let pool = try DatabasePool(path: url.path)
            try Schema.makeMigrator(upTo: 5).migrate(pool)
            try await pool.write { db in
                for game in [active, initial] {
                    try db.execute(sql: "INSERT INTO game (id,system_id,title,content_fingerprint,added_at,updated_at) VALUES (?,'gba','Legacy',?,1000,2000)",
                        arguments: [game.id.description, game.contentFingerprint.canonicalString])
                }
                for fp in [active.contentFingerprint, retired] {
                    try db.execute(sql: "INSERT INTO sync_tombstone VALUES ('game',?,3000,?)", arguments: [fp.canonicalString, source.description])
                }
                try db.execute(sql: "INSERT INTO sync_tombstone VALUES ('state',?,3000,?)", arguments: [orphan.description, source.description])
                try db.execute(sql: """
                    INSERT INTO battery_revision (id,game_id,created_at,data_fingerprint,size_in_bytes,installation_id,device_kind,location_root,location_path,origin)
                    VALUES (?,?,4000,?,4,?,'ipad','managedLibrary','Saves/revision','remote')
                    """, arguments: [revision.description, active.id.description, active.contentFingerprint.canonicalString, source.description])
                try db.execute(sql: """
                    INSERT INTO save_state (id,game_id,core_id,core_version,format_version,kind,created_at,location_root,location_path,state_compat_version,battery_revision_id,installation_id,device_kind,origin)
                    VALUES (?,?,'mgba','1',2,'auto',5000,'managedLibrary','Saves/state','1',?,?,'ipad','remote')
                    """, arguments: [state.description, active.id.description, revision.description, source.description])
                try db.execute(sql: "INSERT INTO play_session (id,game_id,core_id,started_at,installation_id,device_kind,origin) VALUES (?,?,'mgba',6000,?,'ipad','remote')",
                    arguments: [session.description, active.id.description, source.description])
                for game in [active, initial] {
                    try db.execute(sql: "INSERT INTO game_content (fingerprint,size_in_bytes,file_name,system_id,uploaded_at) VALUES (?,4,'game.gba','gba',7000)",
                        arguments: [game.contentFingerprint.canonicalString])
                }
                try db.execute(sql: "INSERT INTO sync_journal (sequence,kind,key,operation,created_at) VALUES (40,'saveState',?,'delete',8000)", arguments: [queued.description])
                try db.execute(sql: "INSERT INTO sync_journal (sequence,kind,key,operation,created_at) VALUES (41,'gameEntry',?,'upsert',8000)", arguments: [active.contentFingerprint.canonicalString])
            }
            try pool.close()
        }
        let store = try SQLiteLibraryStore.open(at: url)
        defer { try? store.close() }
        let migrated = try await store.games.game(id: active.id)
        let untouched = try await store.games.game(id: initial.id)
        XCTAssertEqual(migrated?.generation, 1)
        XCTAssertEqual(migrated?.addedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(untouched?.generation, 0)
        let retiredBarrier = try await store.syncStore.retiredGeneration(for: retired)
        XCTAssertEqual(retiredBarrier, 0)
        let states = try await store.saves.saveStates(for: active.id)
        let revisions = try await store.saves.batteryRevisions(for: active.id)
        let sessions = try await store.playHistory.sessions(for: active.id, limit: 5)
        XCTAssertEqual(states.first?.generation, 1); XCTAssertEqual(states.first?.installationID, source)
        XCTAssertEqual(states.first?.batteryRevisionID, revision)
        XCTAssertEqual(revisions.first?.generation, 1); XCTAssertEqual(revisions.first?.installationID, source)
        XCTAssertEqual(sessions.first?.generation, 1); XCTAssertEqual(sessions.first?.installationID, source)
        let oldContent = try await store.syncStore.contentDescriptor(for: active.contentFingerprint)
        let initialContent = try await store.syncStore.contentDescriptor(for: initial.contentFingerprint)
        XCTAssertNil(oldContent); XCTAssertEqual(initialContent?.generation, 0)
        let orphanTombstone = try await store.syncStore.tombstone(for: .saveState(orphan))
        let queuedTombstone = try await store.syncStore.tombstone(for: .saveState(queued))
        XCTAssertNil(orphanTombstone?.gameFingerprint); XCTAssertNotNil(orphanTombstone)
        XCTAssertNotNil(queuedTombstone)
        let journal = try await store.syncStore.journal.pending(limit: 10)
        XCTAssertEqual(journal.map(\.id), [40, 41])
        XCTAssertEqual(journal.map(\.intent), [.tombstone(.saveState(queued)), .gameEntry(active.contentFingerprint, generation: 1)])
    }
}

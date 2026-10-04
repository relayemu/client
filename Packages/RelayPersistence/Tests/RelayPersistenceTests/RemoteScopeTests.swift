// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class RemoteScopeTests: XCTestCase {
    private let relay = "provider.relay.account.a"
    private let another = "provider.relay.account.b"
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func descriptor(_ name: String) -> GameContentDescriptor {
        GameContentDescriptor(fingerprint: Fixtures.fingerprint(8), sizeInBytes: 10,
                              fileName: name, systemID: .gameBoyAdvance, parts: [], uploadedAt: instant)
    }

    private func deferred(_ value: String) -> DeferredRemoteRecord {
        DeferredRemoteRecord(key: "revision:same", kind: "batteryRevision", payload: Data(value.utf8),
                             reason: "waiting", receivedAt: instant)
    }

    func testDescriptorsAndDeferredKeysAreIndependentAcrossProviderAndAccount() async throws {
        let library = try SQLiteLibraryStore.inMemory()
        let sync = library.syncStore
        for scope in ["cloudkit", relay, another] {
            var batch = RemoteApplyBatch()
            batch.remoteScope = scope
            batch.contentDescriptors = [descriptor(scope)]
            batch.deferred = [deferred(scope)]
            _ = try await sync.applyRemote(batch)
        }
        let legacy = try await sync.contentDescriptors()
        XCTAssertEqual(legacy.map(\.fileName), ["cloudkit"])
        for scope in [relay, another] {
            let content = try await sync.contentDescriptor(for: Fixtures.fingerprint(8), remoteScope: scope)
            let records = try await sync.deferredRecords(remoteScope: scope)
            XCTAssertEqual(content?.fileName, scope)
            XCTAssertEqual(records.map(\.payload), [Data(scope.utf8)])
        }
        var removed = RemoteApplyBatch()
        removed.remoteScope = relay
        removed.deletedContentFingerprints = [Fixtures.fingerprint(8)]
        removed.resolvedDeferredKeys = ["revision:same"]
        _ = try await sync.applyRemote(removed)
        let deleted = try await sync.contentDescriptors(remoteScope: relay)
        let resolved = try await sync.deferredRecords(remoteScope: relay)
        let retained = try await sync.contentDescriptors(remoteScope: another)
        let retainedDeferred = try await sync.deferredRecords(remoteScope: another)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertEqual(retained.map(\.fileName), [another])
        XCTAssertEqual(retainedDeferred.count, 1)
        try await sync.removeDeferredRecords(keys: ["revision:same"], remoteScope: another)
        let legacyDeferred = try await sync.deferredRecords()
        XCTAssertEqual(legacyDeferred.count, 1)
    }

    func testScopedWritesAndReconciliationNeverClaimOtherRemoteDescriptors() async throws {
        let library = try SQLiteLibraryStore.inMemory()
        let sync = library.syncStore
        try await sync.recordContentDescriptor(descriptor("legacy"))
        try await sync.journal.clear()
        try await sync.enqueueEverything(remoteScope: relay)
        let pending = try await sync.journal.pendingCount()
        XCTAssertEqual(pending, 0)
        try await sync.recordContentDescriptor(descriptor("relay"), remoteScope: relay)
        try await sync.removeContentDescriptor(for: Fixtures.fingerprint(8), recordIntent: false, remoteScope: relay)
        let legacy = try await sync.contentDescriptors()
        let selected = try await sync.contentDescriptors(remoteScope: relay)
        XCTAssertEqual(legacy.map(\.fileName), ["legacy"])
        XCTAssertTrue(selected.isEmpty)
    }

    func testScopedInboxAndDescriptorRollBackWithRegressedCheckpoint() async throws {
        let library = try SQLiteLibraryStore.inMemory()
        let sync = library.syncStore
        try await sync.setMetaValue("10", forKey: "relay.cursor")
        var batch = RemoteApplyBatch()
        batch.remoteScope = relay
        batch.contentDescriptors = [descriptor("relay")]
        batch.deferred = [deferred("relay")]
        batch.checkpoint = SyncCheckpoint(key: "relay.cursor", sequence: 9)
        do {
            _ = try await sync.applyRemote(batch)
            XCTFail("Regressed checkpoint must reject the entire transaction")
        } catch {}
        let content = try await sync.contentDescriptors(remoteScope: relay)
        let records = try await sync.deferredRecords(remoteScope: relay)
        let cursor = try await sync.metaValue(forKey: "relay.cursor")
        XCTAssertTrue(content.isEmpty)
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(cursor, "10")
    }

    func testBridgeReconciliationIncludesCanonicalRemoteHistoryWithoutChangingProvenance() async throws {
        let library = try SQLiteLibraryStore.inMemory()
        let sync = library.syncStore
        let game = Fixtures.game(seed: 11)
        try await library.games.insert(game, files: [])
        let owner = InstallationID()
        let revision = BatteryRevision(gameID: game.id, parentIDs: [], createdAt: instant,
                                       dataFingerprint: Fixtures.fingerprint(12), sizeInBytes: 4,
                                       installationID: owner, deviceKind: .iPad,
                                       location: Fixtures.location("Saves/bridge/revision.sav"), origin: .remote)
        let state = SaveState(gameID: game.id, coreID: "mgba", coreVersion: "1", kind: .manual,
                              createdAt: instant, location: Fixtures.location("Saves/bridge/state.relaystate"),
                              batteryRevisionID: revision.id, installationID: owner, deviceKind: .iPad, origin: .remote)
        let session = PlaySession(gameID: game.id, coreID: "mgba", startedAt: instant,
                                  endedAt: instant.addingTimeInterval(60), installationID: owner,
                                  deviceKind: .iPad, origin: .remote)
        var batch = RemoteApplyBatch()
        batch.revisions = [revision]
        batch.states = [state]
        batch.sessions = [session]
        _ = try await sync.applyRemote(batch)
        try await sync.journal.clear()
        try await sync.enqueueEverything(remoteScope: relay)
        let ordinary = try await sync.journal.pending(limit: 20).map(\.intent)
        XCTAssertEqual(Set(ordinary), [.gameEntry(game.contentFingerprint)])
        try await sync.journal.clear()
        try await sync.enqueueEverything(remoteScope: relay, includeRemoteHistory: true)
        let bridged = try await sync.journal.pending(limit: 20).map(\.intent)
        XCTAssertEqual(Set(bridged), [.gameEntry(game.contentFingerprint), .batteryRevision(revision.id),
                                      .saveState(state.id), .playSession(session.id)])
        let revisions = try await library.saves.batteryRevisions(for: game.id)
        let states = try await library.saves.saveStates(for: game.id)
        let sessions = try await library.playHistory.sessions(for: game.id, limit: 20)
        XCTAssertEqual(revisions.first?.origin, .remote)
        XCTAssertEqual(states.first?.origin, .remote)
        XCTAssertEqual(sessions.first?.origin, .remote)
        XCTAssertEqual(revisions.first?.installationID, owner)
        XCTAssertEqual(states.first?.installationID, owner)
        XCTAssertEqual(sessions.first?.installationID, owner)
    }

    func testV4MigrationPreservesLegacyCloudKitRowsOnlyInLegacyScope() async throws {
        let url = try Fixtures.temporaryDatabaseURL()
        let pool = try DatabasePool(path: url.path)
        try Schema.makeMigrator(upTo: 4).migrate(pool)
        let fingerprint = Fixtures.fingerprint(8).canonicalString
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO game_content VALUES (?, 10, 'legacy.gba', 'gba', '[]', 1700000000000)", arguments: [fingerprint])
            try db.execute(sql: "INSERT INTO sync_deferred VALUES ('revision:same', 'batteryRevision', ?, 'waiting', 1700000000000)", arguments: [Data("old".utf8)])
        }
        try pool.close()
        let library = try SQLiteLibraryStore.open(at: url)
        let legacyContent = try await library.syncStore.contentDescriptors()
        let legacyDeferred = try await library.syncStore.deferredRecords()
        let relayContent = try await library.syncStore.contentDescriptors(remoteScope: relay)
        let relayDeferred = try await library.syncStore.deferredRecords(remoteScope: relay)
        XCTAssertEqual(legacyContent.map(\.fileName), ["legacy.gba"])
        XCTAssertEqual(legacyDeferred.map(\.payload), [Data("old".utf8)])
        XCTAssertTrue(relayContent.isEmpty)
        XCTAssertTrue(relayDeferred.isEmpty)
        try library.close()
    }
}

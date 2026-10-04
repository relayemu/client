// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncStoreApplyTests.swift — the remote-apply transaction: entry merge rules,
//  tombstones, sessions, immutable revisions/states, deferred records,
//  atomicity, concurrent-import race.

import XCTest
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class SyncStoreApplyTests: XCTestCase {
    var store: SQLiteLibraryStore!
    var sync: any SyncStore { store.syncStore }
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let other = InstallationID()

    override func setUp() async throws {
        store = try SQLiteLibraryStore.inMemory(deviceKind: .mac)
    }

    private func entry(_ seed: UInt8, title: String, favorite: Bool = false, addedAt: Date? = nil, updatedAt: Date? = nil, generation: Int64 = 0) -> RemoteGameEntry {
        RemoteGameEntry(fingerprint: Fixtures.fingerprint(seed), systemID: .gameBoyAdvance, title: title, isFavorite: favorite,
                        addedAt: addedAt ?? t0, updatedAt: updatedAt ?? t0, contentSize: 100, generation: generation)
    }

    func testGameEntryMergesByLastWriteAndEarliestAddedAt() async throws {
        let local = Game(systemID: .gameBoyAdvance, title: "Local", contentFingerprint: Fixtures.fingerprint(1), addedAt: t0.addingTimeInterval(100), updatedAt: t0.addingTimeInterval(100))
        try await store.games.insert(local, files: [Fixtures.primaryFile(for: local)])
        // Older remote update loses; earlier addedAt wins.
        var batch = RemoteApplyBatch()
        batch.gameEntries = [entry(1, title: "Older", favorite: true, addedAt: t0, updatedAt: t0.addingTimeInterval(50))]
        _ = try await sync.applyRemote(batch)
        var game = try await store.games.game(id: local.id)
        XCTAssertEqual(game?.title, "Local")
        XCTAssertEqual(game?.isFavorite, false)
        XCTAssertEqual(game?.addedAt, t0)
        // Newer remote update wins.
        batch.gameEntries = [entry(1, title: "Newer", favorite: true, addedAt: t0, updatedAt: t0.addingTimeInterval(200))]
        _ = try await sync.applyRemote(batch)
        game = try await store.games.game(id: local.id)
        XCTAssertEqual(game?.title, "Newer")
        XCTAssertEqual(game?.isFavorite, true)
        XCTAssertEqual(game?.id, local.id, "the local GameID never changes")
        let files = try await store.games.files(for: local.id)
        XCTAssertEqual(files.count, 1, "local content untouched")
    }

    func testTombstoneRetiresGenerationRegardlessOfDatesAndAllowsExplicitSuccessor() async throws {
        let game = Fixtures.game(seed: 2, addedAt: t0)
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
        var batch = RemoteApplyBatch()
        batch.tombstones = [DeletionTombstone(target: .game(game.contentFingerprint), deletedAt: t0.addingTimeInterval(10), installationID: other)]
        let outcome = try await sync.applyRemote(batch)
        XCTAssertEqual(outcome.deletedGameIDs, [game.id])
        var found = try await store.games.game(fingerprint: game.contentFingerprint)
        XCTAssertNil(found)
        // A stale entry (added before the deletion) does not resurrect it.
        batch = RemoteApplyBatch()
        batch.gameEntries = [entry(2, title: "Stale", addedAt: t0, updatedAt: t0)]
        await XCTAssertThrowsErrorAsync(try await sync.applyRemote(batch)) { error in
            XCTAssertEqual(error as? LibraryError, .membershipChanged)
        }
        found = try await store.games.game(fingerprint: game.contentFingerprint)
        XCTAssertNil(found)
        // Only an explicit successor comes back, regardless of its timestamps.
        batch.gameEntries = [entry(2, title: "Again", addedAt: t0, updatedAt: t0, generation: 1)]
        let again = try await sync.applyRemote(batch)
        XCTAssertEqual(again.createdGameIDs.count, 1)
        found = try await store.games.game(fingerprint: game.contentFingerprint)
        XCTAssertEqual(found?.title, "Again")
    }

    func testSessionsUpsertWithoutInflatingDurationAndNeverOverwriteOwn() async throws {
        let game = Fixtures.game(seed: 3)
        try await store.games.insert(game, files: [])
        let remote = PlaySession(id: PlaySessionID(), gameID: game.id, coreID: "mgba", startedAt: t0, endedAt: t0.addingTimeInterval(60),
                                 installationID: other, deviceKind: .iPhone, origin: .remote)
        var batch = RemoteApplyBatch()
        batch.sessions = [remote, remote]           // duplicate delivery in one batch
        _ = try await sync.applyRemote(batch)
        _ = try await sync.applyRemote(batch)       // and again later
        let history = try await store.playHistory.lastPlayed()
        XCTAssertEqual(history?.sessionCount, 1)
        XCTAssertEqual(history?.totalPlayDuration, 60)
        XCTAssertEqual(history?.latestSession.deviceKind, .iPhone)
        XCTAssertEqual(history?.latestSession.origin, .remote)
        // An in-progress echo never regresses a finalised session.
        var inProgress = remote; inProgress.endedAt = nil
        batch.sessions = [inProgress]
        _ = try await sync.applyRemote(batch)
        let still = try await store.playHistory.sessions(for: game.id, limit: 1).first
        XCTAssertEqual(still?.endedAt, t0.addingTimeInterval(60))
        // Our own session is never overwritten by a remote copy.
        let owner = try await sync.identity()
        let mine = PlaySession(gameID: game.id, coreID: "mgba", startedAt: t0.addingTimeInterval(1000), endedAt: t0.addingTimeInterval(1100), installationID: owner.installationID)
        try await store.playHistory.record(mine)
        var echo = mine; echo.endedAt = t0.addingTimeInterval(9999); echo.origin = .remote
        batch.sessions = [echo]
        _ = try await sync.applyRemote(batch)
        let own = try await store.playHistory.sessions(for: game.id, limit: 1).first
        XCTAssertEqual(own?.id, mine.id)
        XCTAssertEqual(own?.endedAt, t0.addingTimeInterval(1100))
        XCTAssertEqual(own?.origin, .local)
    }

    func testRevisionsAndStatesAreIdempotentAndIntegrityChecked() async throws {
        let game = Fixtures.game(seed: 4)
        try await store.games.insert(game, files: [])
        let revision = BatteryRevision(gameID: game.id, parentIDs: [], createdAt: t0, dataFingerprint: Fixtures.fingerprint(9), sizeInBytes: 4,
                                       installationID: other, deviceKind: .iPad, location: Fixtures.location("Saves/\(game.id)/battery/revisions/a.sav"), origin: .remote)
        let state = SaveState(gameID: game.id, coreID: "mgba", coreVersion: "1", kind: .auto, createdAt: t0,
                              location: Fixtures.location("Saves/\(game.id)/states/s.relaystate"), batteryRevisionID: revision.id,
                              installationID: other, deviceKind: .iPad, origin: .remote)
        var batch = RemoteApplyBatch()
        batch.revisions = [revision]; batch.states = [state]
        var outcome = try await sync.applyRemote(batch)
        XCTAssertEqual(outcome.gamesNeedingReconciliation, [game.id])
        outcome = try await sync.applyRemote(batch)
        XCTAssertEqual(outcome.skippedExisting, 2)
        XCTAssertTrue(outcome.gamesNeedingReconciliation.isEmpty)
        let revisions = try await store.saves.batteryRevisions(for: game.id)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions[0].origin, .remote)
        let head = try await store.saves.activeBatteryRevisionID(for: game.id)
        XCTAssertNil(head, "apply never moves the head; reconciliation does")
        // Same id, different bytes: refused, batch rolled back.
        var forged = revision
        forged = BatteryRevision(id: revision.id, gameID: game.id, parentIDs: [], createdAt: t0, dataFingerprint: Fixtures.fingerprint(8), sizeInBytes: 4,
                                 installationID: other, deviceKind: .iPad, location: revision.location, origin: .remote)
        batch = RemoteApplyBatch(); batch.revisions = [forged]
        batch.gameEntries = [entry(40, title: "Would be created")]
        await XCTAssertThrowsErrorAsync(try await sync.applyRemote(batch)) { _ in }
        let created = try await store.games.game(fingerprint: Fixtures.fingerprint(40))
        XCTAssertNil(created, "nothing from a failed batch is visible")
        // Legacy remote record deletions permanently suppress every state UUID, including own states.
        let identity = try await sync.identity()
        let mine = SaveState(gameID: game.id, coreID: "mgba", coreVersion: "1", kind: .quick, createdAt: t0, location: Fixtures.location("Saves/\(game.id)/states/m.relaystate"), installationID: identity.installationID)
        try await store.saves.insert(mine)
        batch = RemoteApplyBatch(); batch.deletedStateIDs = [state.id, mine.id]
        outcome = try await sync.applyRemote(batch)
        XCTAssertEqual(Set(outcome.deletedStates.map(\.id)), Set([state.id, mine.id]))
        let remaining = try await store.saves.saveStates(for: game.id)
        XCTAssertTrue(remaining.isEmpty)
        // A tombstoned state never comes back.
        batch = RemoteApplyBatch()
        batch.tombstones = [DeletionTombstone(target: .saveState(state.id), deletedAt: t0.addingTimeInterval(5), installationID: other)]
        batch.states = [state]
        _ = try await sync.applyRemote(batch)
        let after = try await store.saves.saveStates(for: game.id)
        XCTAssertTrue(after.isEmpty)
    }

    func testDeferredRecordsRoundTrip() async throws {
        var batch = RemoteApplyBatch()
        batch.deferred = [DeferredRemoteRecord(key: "battery:abc", kind: "battery", payload: Data([1, 2]), reason: "unknown game", receivedAt: t0)]
        _ = try await sync.applyRemote(batch)
        var deferred = try await sync.deferredRecords()
        XCTAssertEqual(deferred.count, 1)
        XCTAssertEqual(deferred[0].payload, Data([1, 2]))
        batch = RemoteApplyBatch(); batch.resolvedDeferredKeys = ["battery:abc"]
        _ = try await sync.applyRemote(batch)
        deferred = try await sync.deferredRecords()
        XCTAssertTrue(deferred.isEmpty)
    }

    func testConcurrentLocalImportRaceIsReportedAsDuplicate() async throws {
        let game = Fixtures.game(seed: 6)
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
        // The applier minted a new id for a fingerprint that a local import created meanwhile.
        var batch = RemoteApplyBatch()
        batch.gameEntries = [entry(6, title: "Remote twin")]
        let outcome = try await sync.applyRemote(batch)
        XCTAssertTrue(outcome.createdGameIDs.isEmpty, "merged into the existing game, no duplicate")
        let all = try await store.games.allGames()
        XCTAssertEqual(all.count, 1)
    }

    func testContentDescriptorsAndMeta() async throws {
        let descriptor = GameContentDescriptor.singleFile(fingerprint: Fixtures.fingerprint(1), sizeInBytes: 61104, fileName: "game.gba", systemID: .gameBoyAdvance, uploadedAt: t0)
        try await sync.recordContentDescriptor(descriptor)
        let back = try await sync.contentDescriptor(for: Fixtures.fingerprint(1))
        XCTAssertEqual(back, descriptor)
        let intents = try await sync.journal.pending(limit: 10).map(\.intent)
        XCTAssertEqual(intents, [.contentIndex(Fixtures.fingerprint(1))])
        try await sync.removeContentDescriptor(for: Fixtures.fingerprint(1), recordIntent: true)
        let gone = try await sync.contentDescriptor(for: Fixtures.fingerprint(1))
        XCTAssertNil(gone)
        try await sync.setMetaValue("abc", forKey: "account")
        let meta = try await sync.metaValue(forKey: "account")
        XCTAssertEqual(meta, "abc")
        try await sync.setMetaValue(nil, forKey: "account")
        let cleared = try await sync.metaValue(forKey: "account")
        XCTAssertNil(cleared)
    }
}

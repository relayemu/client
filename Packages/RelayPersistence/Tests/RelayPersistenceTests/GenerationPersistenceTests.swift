// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class GenerationPersistenceTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    private func game(_ seed: UInt8, generation: Int64 = 0) -> Game {
        Game(systemID: .gameBoyAdvance, title: "Membership", contentFingerprint: Fixtures.fingerprint(seed),
             addedAt: time, generation: generation)
    }

    private func revision(_ game: Game, parent: BatteryRevisionID? = nil, generation: Int64? = nil) -> BatteryRevision {
        let id = BatteryRevisionID()
        return BatteryRevision(id: id, gameID: game.id, parentIDs: parent.map { [$0] } ?? [], createdAt: time,
            dataFingerprint: Fixtures.fingerprint(240), sizeInBytes: 4, installationID: InstallationID(), deviceKind: .iPad,
            location: Fixtures.location("Saves/\(game.id)/battery/\(id).sav"), origin: .remote,
            generation: generation ?? game.generation)
    }

    func testDeleteReimportAllocatesSuccessorAndRejectsStaleHistoryWithFutureDates() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let old = game(100)
        try await store.games.insert(old, files: [])
        let oldRevision = revision(old)
        try await store.saves.insertBatteryRevision(oldRevision)
        try await store.games.deleteGame(id: old.id)
        let next = try await store.games.nextGeneration(for: old.contentFingerprint)
        XCTAssertEqual(next, 1)
        let fresh = game(100, generation: next)
        try await store.games.insert(fresh, files: [])
        XCTAssertNotEqual(old.id, fresh.id)
        let stale = revision(fresh, generation: 0)
        var batch = RemoteApplyBatch()
        batch.revisions = [stale]
        batch.checkpoint = SyncCheckpoint(key: "generation.cursor", sequence: 7)
        await XCTAssertThrowsErrorAsync(try await store.syncStore.applyRemote(batch)) { error in
            XCTAssertEqual(error as? LibraryError, .membershipChanged)
        }
        let cursor = try await store.syncStore.metaValue(forKey: "generation.cursor")
        XCTAssertNil(cursor)
        let staleSession = PlaySession(gameID: fresh.id, coreID: "mgba", startedAt: time.addingTimeInterval(10_000_000),
                                       installationID: InstallationID(), origin: .remote, generation: 0)
        await XCTAssertThrowsErrorAsync(try await store.playHistory.record(staleSession)) { _ in }
        let newRevision = revision(fresh)
        batch.revisions = [newRevision]
        _ = try await store.syncStore.applyRemote(batch)
        let stored = try await store.saves.batteryRevisions(for: fresh.id)
        XCTAssertEqual(stored.map(\.id), [newRevision.id])
        XCTAssertEqual(stored.first?.generation, 1)
        let oldRows = try await store.saves.batteryRevisions(for: old.id)
        XCTAssertTrue(oldRows.isEmpty)
        let newIntents = try await store.syncStore.journal.pending(limit: 100).map(\.intent)
        XCTAssertTrue(newIntents.contains(.gameEntry(fresh.contentFingerprint, generation: 1)))
        XCTAssertTrue(newIntents.contains(.tombstone(.game(old.contentFingerprint), generation: 0)))
    }

    func testAllocationRaceAndOverflowFailWithoutRewritingMembership() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let candidate = game(101)
        let allocated = try await store.games.nextGeneration(for: candidate.contentFingerprint)
        XCTAssertEqual(allocated, 0)
        var barrier = RemoteApplyBatch()
        barrier.tombstones = [DeletionTombstone(target: .game(candidate.contentFingerprint), deletedAt: time,
                                                installationID: InstallationID(), generation: 0)]
        _ = try await store.syncStore.applyRemote(barrier)
        await XCTAssertThrowsErrorAsync(try await store.games.insert(candidate, files: [])) { error in
            XCTAssertEqual(error as? LibraryError, .membershipChanged)
        }
        barrier.tombstones = [DeletionTombstone(target: .game(candidate.contentFingerprint), deletedAt: time,
                                                installationID: InstallationID(), generation: GameMembership.maximumGeneration)]
        _ = try await store.syncStore.applyRemote(barrier)
        await XCTAssertThrowsErrorAsync(try await store.games.nextGeneration(for: candidate.contentFingerprint)) { _ in }
        let all = try await store.games.allGames()
        XCTAssertTrue(all.isEmpty)
    }

    func testImportedBarrierAllowsExactSuccessorAndOlderTombstoneCannotDeleteIt() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let fresh = game(102, generation: 6)
        var batch = RemoteApplyBatch()
        batch.tombstones = [DeletionTombstone(target: .game(fresh.contentFingerprint), deletedAt: time,
                                              installationID: InstallationID(), generation: 5)]
        batch.gameEntries = [RemoteGameEntry(fingerprint: fresh.contentFingerprint, systemID: fresh.systemID, title: fresh.title,
            isFavorite: false, addedAt: time, updatedAt: time, contentSize: nil, proposedID: fresh.id, generation: 6)]
        _ = try await store.syncStore.applyRemote(batch)
        batch = RemoteApplyBatch()
        batch.tombstones = [DeletionTombstone(target: .game(fresh.contentFingerprint), deletedAt: time.addingTimeInterval(99_999),
                                              installationID: InstallationID(), generation: 0)]
        _ = try await store.syncStore.applyRemote(batch)
        let kept = try await store.games.game(id: fresh.id)
        let retired = try await store.syncStore.retiredGeneration(for: fresh.contentFingerprint)
        XCTAssertEqual(kept?.generation, 6)
        XCTAssertEqual(retired, 5)
    }

    func testAllStateKindsAndOriginsDeleteWithPermanentUUIDTombstone() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let membership = game(103)
        try await store.games.insert(membership, files: [])
        for kind in SaveState.Kind.allCases {
            for origin in [SyncOrigin.local, .remote] {
                let id = SaveStateID()
                let state = SaveState(id: id, gameID: membership.id, coreID: "mgba", coreVersion: "1", kind: kind,
                    createdAt: time.addingTimeInterval(99_999), location: Fixtures.location("Saves/\(id).relaystate"),
                    installationID: InstallationID(), origin: origin)
                try await store.saves.insert(state)
                try await store.saves.deleteSaveState(id: id)
                let tombstone = try await store.syncStore.tombstone(for: .saveState(id))
                XCTAssertNotNil(tombstone)
                XCTAssertEqual(tombstone?.gameFingerprint, membership.contentFingerprint)
                await XCTAssertThrowsErrorAsync(try await store.saves.insert(state)) { _ in }
                let intents = try await store.syncStore.journal.pending(limit: 100).map(\.intent)
                XCTAssertTrue(intents.contains(.tombstone(.saveState(id))))
                XCTAssertFalse(intents.contains(.saveState(id, operation: .delete)))
            }
        }
        let absent = SaveStateID()
        var legacy = RemoteApplyBatch(); legacy.deletedStateIDs = [absent]
        _ = try await store.syncStore.applyRemote(legacy)
        let suppression = try await store.syncStore.tombstone(for: .saveState(absent))
        XCTAssertNotNil(suppression)
        XCTAssertNil(suppression?.gameFingerprint)
    }

    func testCrossMembershipReferencesAndClassificationMutationRejectAtomically() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let a = game(104), b = game(105)
        try await store.games.insert(a, files: [])
        try await store.games.insert(b, files: [])
        let parent = revision(a)
        try await store.saves.insertBatteryRevision(parent)
        let child = revision(b, parent: parent.id)
        await XCTAssertThrowsErrorAsync(try await store.saves.insertBatteryRevision(child)) { _ in }
        let state = SaveState(gameID: b.id, coreID: "mgba", coreVersion: "1", kind: .auto, createdAt: time,
            location: Fixtures.location("Saves/paired.relaystate"), batteryRevisionID: parent.id)
        await XCTAssertThrowsErrorAsync(try await store.saves.insert(state)) { _ in }
        var changed = a; changed.systemID = .gameBoyColor; changed.title = "Wrong"
        await XCTAssertThrowsErrorAsync(try await store.games.update(changed)) { _ in }
        let kept = try await store.games.game(id: a.id)
        XCTAssertEqual(kept?.systemID, .gameBoyAdvance)
        XCTAssertEqual(kept?.title, a.title)
    }

    func testAvailabilityCannotCrossRetirementOrDeleteSuccessorContent() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let old = game(106)
        try await store.games.insert(old, files: [])
        let oldDescriptor = GameContentDescriptor.singleFile(fingerprint: old.contentFingerprint, sizeInBytes: 4,
            fileName: "game.gba", systemID: old.systemID, uploadedAt: time)
        try await store.syncStore.recordContentDescriptor(oldDescriptor)
        try await store.games.deleteGame(id: old.id)
        let fresh = game(106, generation: 1)
        try await store.games.insert(fresh, files: [])
        await XCTAssertThrowsErrorAsync(try await store.syncStore.recordContentDescriptor(oldDescriptor)) { _ in }
        let freshDescriptor = GameContentDescriptor.singleFile(fingerprint: old.contentFingerprint, sizeInBytes: 4,
            fileName: "game.gba", systemID: old.systemID, uploadedAt: time, generation: 1)
        try await store.syncStore.recordContentDescriptor(freshDescriptor)
        var deletion = RemoteApplyBatch(); deletion.deletedContentFingerprints = [old.contentFingerprint]
        _ = try await store.syncStore.applyRemote(deletion)
        let remaining = try await store.syncStore.contentDescriptor(for: old.contentFingerprint)
        XCTAssertEqual(remaining?.generation, 1)
    }
}

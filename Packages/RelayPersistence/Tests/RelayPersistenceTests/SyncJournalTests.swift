// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncJournalTests.swift — the outbox is written in the same transaction as
//  the canonical change, coalesces mutable objects, survives failures
//  correctly, and is never written by remote applies.

import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class SyncJournalTests: XCTestCase {
    var store: SQLiteLibraryStore!
    var journal: any SyncJournal { store.syncStore.journal }

    override func setUp() async throws {
        store = try SQLiteLibraryStore.inMemory(deviceKind: .iPhone)
    }

    private func pendingIntents() async throws -> [SyncIntent] {
        try await journal.pending(limit: 100).map(\.intent)
    }

    func testEveryLocalMutationJournalsItsIntentInTheSameTransaction() async throws {
        let game = Fixtures.game(seed: 1)
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
        var intents = try await pendingIntents()
        XCTAssertEqual(intents, [.gameEntry(game.contentFingerprint)])

        // Favourite toggle coalesces into the same pending entry (one row, moved to the end).
        var favourite = game; favourite.isFavorite = true; favourite.updatedAt = Date()
        try await store.games.update(favourite)
        intents = try await pendingIntents()
        XCTAssertEqual(intents, [.gameEntry(game.contentFingerprint)])

        let session = PlaySession(gameID: game.id, coreID: "mgba", startedAt: Date())
        try await store.playHistory.record(session)
        try await store.playHistory.record(session.ended(at: Date()))
        intents = try await pendingIntents()
        XCTAssertEqual(intents, [.gameEntry(game.contentFingerprint), .playSession(session.id)])
        let recorded = try await store.playHistory.sessions(for: game.id, limit: 1).first
        let identity = try await store.syncStore.identity()
        XCTAssertEqual(recorded?.installationID, identity.installationID, "local sessions get this installation's identity")
        XCTAssertEqual(recorded?.deviceKind, .iPhone)

        let save = Save(gameID: game.id, location: Fixtures.location("Saves/\(game.id)/battery/current.sav"), sizeInBytes: 1, fingerprint: Fixtures.fingerprint(2), updatedAt: Date())
        let revision = BatteryRevision(gameID: game.id, parentIDs: [], createdAt: Date(), dataFingerprint: Fixtures.fingerprint(2), sizeInBytes: 1,
                                       installationID: identity.installationID, deviceKind: .iPhone,
                                       location: Fixtures.location("Saves/\(game.id)/battery/revisions/r.sav"), origin: .local)
        try await store.saves.commitBatterySnapshot(save, revision: revision)
        let head = try await store.saves.activeBatteryRevisionID(for: game.id)
        XCTAssertEqual(head, revision.id)
        let state = SaveState(gameID: game.id, coreID: "mgba", coreVersion: "1", kind: .manual, createdAt: Date(),
                              location: Fixtures.location("Saves/\(game.id)/states/s.relaystate"), installationID: identity.installationID, deviceKind: .iPhone)
        try await store.saves.insert(state)
        intents = try await pendingIntents()
        XCTAssertEqual(intents, [.gameEntry(game.contentFingerprint), .playSession(session.id), .batteryRevision(revision.id), .saveState(state.id)])

        // Deleting a state records only its permanent semantic tombstone.
        try await store.saves.deleteSaveState(id: state.id)
        intents = try await pendingIntents()
        XCTAssertEqual(intents.last, .tombstone(.saveState(state.id)))
        XCTAssertFalse(intents.contains(.saveState(state.id, operation: .delete)))
        XCTAssertFalse(intents.contains(.saveState(state.id)))
        let tombstone = try await store.syncStore.tombstone(for: .saveState(state.id))
        XCTAssertNotNil(tombstone)

        // Deleting the game replaces its pending entry with a tombstone intent.
        try await store.games.deleteGame(id: game.id)
        intents = try await pendingIntents()
        XCTAssertFalse(intents.contains(.gameEntry(game.contentFingerprint)))
        XCTAssertTrue(intents.contains(.tombstone(.game(game.contentFingerprint))))
        let gameTombstone = try await store.syncStore.tombstone(for: .game(game.contentFingerprint))
        XCTAssertNotNil(gameTombstone)
    }

    func testFailedMutationJournalsNothing() async throws {
        let game = Fixtures.game(seed: 1)
        let second = Fixtures.primaryFile(for: game, name: "b.gba")
        await XCTAssertThrowsErrorAsync(try await store.games.insert(game, files: [Fixtures.primaryFile(for: game), second])) { _ in }
        let count = try await journal.pendingCount()
        XCTAssertEqual(count, 0)
        // A duplicate fingerprint inserts nothing and journals nothing.
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
        var twin = Fixtures.game(seed: 1)
        twin = Game(systemID: twin.systemID, title: "Twin", contentFingerprint: twin.contentFingerprint, addedAt: Date())
        await XCTAssertThrowsErrorAsync(try await store.games.insert(twin, files: [Fixtures.primaryFile(for: twin)])) { _ in }
        let after = try await journal.pendingCount()
        XCTAssertEqual(after, 1)
    }

    func testJournalLifecycleCompleteFailClear() async throws {
        let game = Fixtures.game(seed: 5)
        try await store.games.insert(game, files: [])
        var entries = try await journal.pending(limit: 10)
        XCTAssertEqual(entries.count, 1)
        try await journal.fail([entries[0].id], reason: "network")
        entries = try await journal.pending(limit: 10)
        XCTAssertEqual(entries[0].attempts, 1)
        XCTAssertEqual(entries[0].lastError, "network")
        try await journal.complete([entries[0].id])
        let count = try await journal.pendingCount()
        XCTAssertEqual(count, 0)
        try await journal.enqueue([.gameEntry(game.contentFingerprint), .gameEntry(game.contentFingerprint)])
        let coalesced = try await journal.pendingCount()
        XCTAssertEqual(coalesced, 1)
        try await journal.clear()
        let cleared = try await journal.pendingCount()
        XCTAssertEqual(cleared, 0)
    }

    func testPaginationTraversesMoreThanOneThousandRowsWithoutChangingOldestOrdering() async throws {
        try await journal.enqueue((0..<1_201).map { SyncIntent(kind: .playSession, key: "page-\($0)") })
        let original = try await journal.pending(limit: 2_000)
        try await journal.fail([original[0].id], reason: "permanent rejection")
        let first = try await journal.pending(afterSequence: 0, throughSequence: nil, limit: 1_000)
        XCTAssertEqual(first.entries.map(\.id), original.prefix(1_000).map(\.id))
        XCTAssertEqual(first.throughSequence, original.last?.id)
        XCTAssertTrue(first.hasMore)
        let second = try await journal.pending(afterSequence: first.entries.last!.id,
                                               throughSequence: first.throughSequence, limit: 1_000)
        XCTAssertEqual(second.entries.map(\.id), original.suffix(201).map(\.id))
        XCTAssertEqual(second.throughSequence, first.throughSequence)
        XCTAssertFalse(second.hasMore)
        let oldest = try await journal.pending(limit: 1)
        XCTAssertEqual(oldest.first?.id, original.first?.id)
        XCTAssertEqual(oldest.first?.createdAt, original.first?.createdAt)
        XCTAssertEqual(oldest.first?.attempts, 1)
    }

    func testPaginationCeilingExcludesNewAndCoalescedRowsUntilNextSweep() async throws {
        let intents = (0..<5).map { SyncIntent(kind: .playSession, key: "sweep-\($0)") }
        try await journal.enqueue(intents)
        let original = try await journal.pending(limit: 10)
        let first = try await journal.pending(afterSequence: 0, throughSequence: nil, limit: 2)
        try await journal.complete([original[2].id])
        let appended = SyncIntent(kind: .playSession, key: "appended")
        try await journal.enqueue([intents[3], appended])
        let remainder = try await journal.pending(afterSequence: first.entries.last!.id,
                                                  throughSequence: first.throughSequence, limit: 2)
        XCTAssertEqual(remainder.entries.map(\.id), [original[4].id])
        XCTAssertEqual(remainder.throughSequence, first.throughSequence)
        XCTAssertFalse(remainder.hasMore)
        let nextSweep = try await journal.pending(afterSequence: 0, throughSequence: nil, limit: 10)
        XCTAssertGreaterThan(nextSweep.throughSequence, first.throughSequence)
        XCTAssertTrue(nextSweep.entries.contains { $0.intent == intents[3] && $0.id > first.throughSequence })
        XCTAssertTrue(nextSweep.entries.contains { $0.intent == appended })
        XCTAssertFalse(nextSweep.entries.contains { $0.id == original[2].id || $0.id == original[3].id })
    }

    func testPaginationReturnsEmptyAtCeilingAndOnEmptyJournal() async throws {
        let empty = try await journal.pending(afterSequence: 0, throughSequence: nil, limit: 1)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.throughSequence, 0)
        XCTAssertFalse(empty.hasMore)
        let beyondEmpty = try await journal.pending(afterSequence: 42, throughSequence: nil, limit: 1)
        XCTAssertTrue(beyondEmpty.entries.isEmpty)
        XCTAssertEqual(beyondEmpty.throughSequence, 42)
        XCTAssertFalse(beyondEmpty.hasMore)
        try await journal.enqueue([SyncIntent(kind: .playSession, key: "only")])
        let page = try await journal.pending(afterSequence: 0, throughSequence: nil, limit: 1)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertFalse(page.hasMore)
        let end = try await journal.pending(afterSequence: page.throughSequence,
                                            throughSequence: page.throughSequence, limit: 1)
        XCTAssertTrue(end.entries.isEmpty)
        XCTAssertEqual(end.throughSequence, page.throughSequence)
        XCTAssertFalse(end.hasMore)
    }

    func testPaginationRejectsInvalidBoundsAndUnreadableDatabase() async throws {
        let invalid: [(Int64, Int64?, Int)] = [(-1, nil, 1), (0, -1, 1), (4, 3, 1), (0, nil, 0), (0, nil, 1_001)]
        for (after, through, limit) in invalid {
            do {
                _ = try await journal.pending(afterSequence: after, throughSequence: through, limit: limit)
                XCTFail("Invalid pagination must throw")
            } catch let error as LibraryError {
                guard case .invalidRelationship = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        let savedJournal = journal
        try store.close()
        do {
            _ = try await savedJournal.pending(afterSequence: 0, throughSequence: nil, limit: 1)
            XCTFail("Unavailable persistence must not look like an exhausted sweep")
        } catch {}
    }

    func testReceiptMembershipIncludesAllChunksAndExcludesCompletedAndUnknownIDs() async throws {
        try await journal.enqueue((0..<1_201).map { SyncIntent(kind: .playSession, key: "receipt-\($0)") })
        let entries = try await journal.pending(limit: 2_000)
        let completed = [entries[0].id, entries[500].id, entries[1_000].id]
        try await journal.complete(completed)
        let requested = entries.map(\.id) + [Int64.max, entries[1].id]
        let found = try await journal.pendingIDs(in: requested)
        XCTAssertEqual(found, Set(entries.map(\.id)).subtracting(completed))
        let empty = try await journal.pendingIDs(in: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testReceiptMembershipFailsClosedWhenDatabaseUnavailable() async throws {
        let savedJournal = journal
        try store.close()
        do {
            _ = try await savedJournal.pendingIDs(in: [1])
            XCTFail("Unreadable persistence must not acknowledge removal of receipts")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }

    func testReceiptMembershipRejectsOversizedRequests() async throws {
        do {
            _ = try await journal.pendingIDs(in: Array(repeating: 1, count: 100_001))
            XCTFail("Oversized membership requests must fail without reporting missing receipts")
        } catch let error as LibraryError {
            guard case .invalidRelationship = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRemoteApplyNeverJournals() async throws {
        let sync = store.syncStore
        var batch = RemoteApplyBatch()
        batch.gameEntries = [RemoteGameEntry(fingerprint: Fixtures.fingerprint(7), systemID: .gameBoyAdvance, title: "Remote", isFavorite: false,
                                             addedAt: Date(), updatedAt: Date(), contentSize: 10)]
        let outcome = try await sync.applyRemote(batch)
        XCTAssertEqual(outcome.createdGameIDs.count, 1)
        let count = try await journal.pendingCount()
        XCTAssertEqual(count, 0)
        let game = try await store.games.game(fingerprint: Fixtures.fingerprint(7))
        XCTAssertEqual(game?.title, "Remote")
        let files = try await store.games.files(for: game!.id)
        XCTAssertTrue(files.isEmpty, "a remote entry creates a game without content")
    }

    func testEnqueueEverythingJournalsLocalObjectsOnly() async throws {
        let game = Fixtures.game(seed: 8)
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
        let identity = try await store.syncStore.identity()
        let localState = SaveState(gameID: game.id, coreID: "mgba", coreVersion: "1", kind: .quick, createdAt: Date(),
                                   location: Fixtures.location("Saves/\(game.id)/states/l.relaystate"), installationID: identity.installationID)
        try await store.saves.insert(localState)
        var batch = RemoteApplyBatch()
        batch.states = [SaveState(gameID: game.id, coreID: "mgba", coreVersion: "1", kind: .manual, createdAt: Date(),
                                  location: Fixtures.location("Saves/\(game.id)/states/r.relaystate"), installationID: InstallationID(), deviceKind: .mac, origin: .remote)]
        _ = try await store.syncStore.applyRemote(batch)
        try await journal.clear()
        try await store.syncStore.enqueueEverything()
        let intents = try await pendingIntents()
        XCTAssertEqual(Set(intents), [.gameEntry(game.contentFingerprint), .saveState(localState.id)])
    }
}

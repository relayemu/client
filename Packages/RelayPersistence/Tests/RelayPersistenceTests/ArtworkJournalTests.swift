// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ArtworkJournalTests.swift — a custom cover journals its sync intent in the
//  same transaction, coalesces to one pending intent per game, never counts as
//  pending progress, can be left out of an outbound read without holding back
//  later intents, and covers chosen before sync existed are journalled once.

import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class ArtworkJournalTests: XCTestCase {
    func testChoosingAndResettingJournalOneArtworkIntent() async throws {
        let store = try SQLiteLibraryStore.inMemory(deviceKind: .iPhone)
        let game = Fixtures.game(seed: 100)
        try await store.games.insert(game, files: [])
        try await store.syncStore.journal.complete(try await store.syncStore.journal.pending(limit: 100).map(\.id))

        try await store.games.setCustomCover(CustomCover(gameID: game.id, fingerprint: Fixtures.fingerprint(101), sizeInBytes: 10,
                                                         updatedAt: Date(timeIntervalSince1970: 1_000)))
        try await store.games.setCustomCover(CustomCover(gameID: game.id, fingerprint: nil, sizeInBytes: 0,
                                                         updatedAt: Date(timeIntervalSince1970: 2_000)))
        let intents = try await store.syncStore.journal.pending(limit: 100).map(\.intent)
        XCTAssertEqual(intents, [.artwork(game.contentFingerprint)])
        let counted = try await store.syncStore.journal.pendingCount()
        XCTAssertEqual(counted, 0, "a cover is not pending progress")
    }

    func testAnOutboundReadCanLeaveArtworkBehindWithoutBlockingLaterIntents() async throws {
        let store = try SQLiteLibraryStore.inMemory(deviceKind: .iPhone)
        let game = Fixtures.game(seed: 102)
        try await store.games.insert(game, files: [])
        try await store.games.setCustomCover(CustomCover(gameID: game.id, fingerprint: Fixtures.fingerprint(103), sizeInBytes: 10, updatedAt: Date()))
        let session = PlaySession(gameID: game.id, coreID: "mgba", startedAt: Date())
        try await store.playHistory.record(session)
        let journal = store.syncStore.journal

        let head = try await journal.pending(limit: 1, excluding: [.artwork]).map(\.intent)
        XCTAssertEqual(head, [.gameEntry(game.contentFingerprint)])
        let all = try await journal.pending(limit: 100, excluding: [.artwork]).map(\.intent)
        XCTAssertEqual(all, [.gameEntry(game.contentFingerprint), .playSession(session.id)])
        let page = try await journal.pending(afterSequence: 0, throughSequence: nil, limit: 10, excluding: [.artwork])
        XCTAssertEqual(page.entries.map(\.intent), [.gameEntry(game.contentFingerprint), .playSession(session.id)])
        let everything = try await journal.pending(limit: 100).map(\.intent)
        XCTAssertTrue(everything.contains(.artwork(game.contentFingerprint)))
        let counted = try await journal.pendingCount()
        XCTAssertEqual(counted, 2)
    }

    func testUpgradeJournalsCoversChosenBeforeSyncOnce() async throws {
        let url = try Fixtures.temporaryDatabaseURL()
        let chosen = Fixtures.game(seed: 104), reset = Fixtures.game(seed: 105)
        do {
            let pool = try DatabasePool(path: url.path)
            try Schema.makeMigrator(upTo: 9).migrate(pool)
            try await pool.write { db in
                for (game, generation) in [(chosen, 0), (reset, 2)] {
                    try db.execute(sql: "INSERT INTO game (id,system_id,title,content_fingerprint,added_at,updated_at,generation) VALUES (?,'gba','G',?,1000,2000,?)",
                                   arguments: [game.id.description, game.contentFingerprint.canonicalString, generation])
                }
                try db.execute(sql: "INSERT INTO custom_cover (game_id, fingerprint, size_in_bytes, updated_at) VALUES (?, ?, 10, 3000)",
                               arguments: [chosen.id.description, Fixtures.fingerprint(106).canonicalString])
                try db.execute(sql: "INSERT INTO custom_cover (game_id, fingerprint, size_in_bytes, updated_at) VALUES (?, NULL, 0, 3000)",
                               arguments: [reset.id.description])
            }
            try pool.close()
        }
        let store = try SQLiteLibraryStore.open(at: url)
        let intents = try await store.syncStore.journal.pending(limit: 100).map(\.intent)
        XCTAssertEqual(intents.filter { $0.kind == .artwork }, [.artwork(chosen.contentFingerprint)],
                       "only chosen covers exist remotely-to-be; a reset before sync has nothing to clear")
    }

    func testSchemaVersionTen() {
        XCTAssertEqual(Schema.version, 10)
        XCTAssertEqual(Schema.migrationIdentifiers.last, "v10-cover-art-artwork-journal")
    }
}

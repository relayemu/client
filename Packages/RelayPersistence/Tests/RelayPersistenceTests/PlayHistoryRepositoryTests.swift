// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class PlayHistoryRepositoryTests: XCTestCase {
    var store: SQLiteLibraryStore!
    var gameA: Game!
    var gameB: Game!
    var identity: SyncIdentity!
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        store = try SQLiteLibraryStore.inMemory()
        identity = try await store.syncStore.identity()
        gameA = Fixtures.game(seed: 1, title: "A")
        gameB = Fixtures.game(seed: 2, title: "B")
        try await store.games.insert(gameA, files: [Fixtures.primaryFile(for: gameA)])
        try await store.games.insert(gameB, files: [Fixtures.primaryFile(for: gameB)])
    }

    func testRecordIsUpsertAndSessionsAreOrderedNewestFirst() async throws {
        var s1 = PlaySession(gameID: gameA.id, coreID: "mgba", startedAt: t0, installationID: identity.installationID)
        let s2 = PlaySession(gameID: gameA.id, coreID: "mgba", startedAt: t0.addingTimeInterval(100), installationID: identity.installationID)
        try await store.playHistory.record(s1)   // in progress
        try await store.playHistory.record(s2)
        s1 = s1.ended(at: t0.addingTimeInterval(30))
        try await store.playHistory.record(s1)   // ended later: replaces the row
        let sessions = try await store.playHistory.sessions(for: gameA.id, limit: 10)
        XCTAssertEqual(sessions, [s2, s1])
        XCTAssertEqual(sessions[1].duration, 30)
        let limited = try await store.playHistory.sessions(for: gameA.id, limit: 1)
        XCTAssertEqual(limited, [s2])
    }

    func testRecentlyPlayedOrderingAndAggregates() async throws {
        // A: two ended sessions (40 s + 20 s), latest at t0+500.
        try await store.playHistory.record(PlaySession(gameID: gameA.id, coreID: "mgba", startedAt: t0, installationID: identity.installationID).ended(at: t0.addingTimeInterval(40)))
        try await store.playHistory.record(PlaySession(gameID: gameA.id, coreID: "mgba", startedAt: t0.addingTimeInterval(500), installationID: identity.installationID).ended(at: t0.addingTimeInterval(520)))
        // B: one ended session (10 s) and one still running, latest at t0+600.
        try await store.playHistory.record(PlaySession(gameID: gameB.id, coreID: "mgba", startedAt: t0.addingTimeInterval(200), installationID: identity.installationID).ended(at: t0.addingTimeInterval(210)))
        let running = PlaySession(gameID: gameB.id, coreID: "mgba", startedAt: t0.addingTimeInterval(600), installationID: identity.installationID)
        try await store.playHistory.record(running)

        let recent = try await store.playHistory.recentlyPlayed(limit: 10)
        XCTAssertEqual(recent.map(\.gameID), [gameB.id, gameA.id])
        XCTAssertEqual(recent[0].lastPlayedAt, t0.addingTimeInterval(600))
        XCTAssertEqual(recent[0].sessionCount, 2)
        XCTAssertEqual(recent[0].totalPlayDuration, 10, "running sessions contribute no duration")
        XCTAssertEqual(recent[0].latestSession, running)
        XCTAssertEqual(recent[1].totalPlayDuration, 60)
        XCTAssertEqual(recent[1].sessionCount, 2)

        let last = try await store.playHistory.lastPlayed()
        XCTAssertEqual(last, recent[0])
        let one = try await store.playHistory.recentlyPlayed(limit: 1)
        XCTAssertEqual(one, [recent[0]])
    }

    func testEmptyHistory() async throws {
        let last = try await store.playHistory.lastPlayed()
        XCTAssertNil(last)
        let recent = try await store.playHistory.recentlyPlayed(limit: 5)
        XCTAssertEqual(recent, [])
    }

    func testUnknownGameAndInvalidIntervalAreRejected() async throws {
        let ghost = GameID()
        await XCTAssertThrowsErrorAsync(try await store.playHistory.record(PlaySession(gameID: ghost, coreID: "mgba", startedAt: t0))) {
            XCTAssertEqual($0 as? LibraryError, .gameNotFound(ghost))
        }
        // The domain clamps endedAt; the CHECK constraint guards the raw table.
        await XCTAssertThrowsErrorAsync(try await store.writer.write { db in
            var record = PlaySessionRecord(PlaySession(gameID: self.gameA.id, coreID: "mgba", startedAt: self.t0))
            record.endedAt = record.startedAt - 1
            try record.insert(db)
        }) { error in
            XCTAssertNotNil(error)
        }
        let sessions = try await store.playHistory.sessions(for: gameA.id, limit: 10)
        XCTAssertEqual(sessions, [])
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class GameRepositoryTests: XCTestCase {
    var store: SQLiteLibraryStore!

    override func setUp() async throws {
        store = try SQLiteLibraryStore.inMemory()
    }

    func testInsertAndReadBack() async throws {
        let game = Fixtures.game(seed: 1, title: "Alpha")
        let file = Fixtures.primaryFile(for: game, name: "Alpha.gba")
        try await store.games.insert(game, files: [file])

        let byID = try await store.games.game(id: game.id)
        XCTAssertEqual(byID, game)
        let byFingerprint = try await store.games.game(fingerprint: game.contentFingerprint)
        XCTAssertEqual(byFingerprint, game)
        let files = try await store.games.files(for: game.id)
        XCTAssertEqual(files, [file])
        let none = try await store.games.game(id: GameID())
        XCTAssertNil(none)
    }

    func testDuplicateFingerprintIsRejectedDeterministically() async throws {
        let first = Fixtures.game(seed: 7, title: "First")
        try await store.games.insert(first, files: [Fixtures.primaryFile(for: first)])
        let second = Fixtures.game(seed: 7, title: "Second (same content)")
        for _ in 0..<2 {
            await XCTAssertThrowsErrorAsync(try await store.games.insert(second, files: [Fixtures.primaryFile(for: second)])) { error in
                XCTAssertEqual(error as? LibraryError, .duplicateContent(existing: first.id, fingerprint: first.contentFingerprint))
            }
        }
        let all = try await store.games.allGames()
        XCTAssertEqual(all, [first])
        let secondFiles = try await store.games.files(for: second.id)
        XCTAssertEqual(secondFiles, [], "nothing of the rejected insert may persist")
    }

    func testInsertIsAtomic_secondPrimaryFileRollsBackEverything() async throws {
        let game = Fixtures.game(seed: 2)
        let a = Fixtures.primaryFile(for: game, name: "a.gba")
        let b = Fixtures.primaryFile(for: game, name: "b.gba")
        // Relationship validated up front …
        await XCTAssertThrowsErrorAsync(try await store.games.insert(game, files: [a, b])) { error in
            guard case .invalidRelationship = error as? LibraryError else { return XCTFail("\(error)") }
        }
        // … and enforced by the database as well: bypass validation with a raw transaction.
        await XCTAssertThrowsErrorAsync(try await store.writer.write { db in
            try GameRecord(game).insert(db)
            try GameFileRecord(a).insert(db)
            try GameFileRecord(b).insert(db) // violates game_file_one_primary
        }) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
        }
        let gone = try await store.games.game(id: game.id)
        XCTAssertNil(gone, "the transaction must have rolled back the game row")
        let files = try await store.games.files(for: game.id)
        XCTAssertEqual(files, [])
    }

    func testFileForUnknownGameIsRejected() async throws {
        let game = Fixtures.game(seed: 3)
        let stray = GameFile(gameID: GameID(), role: .primary, fingerprint: game.contentFingerprint, sizeInBytes: 1,
                             originalFileName: "x.gba", location: Fixtures.location("Games/x/x.gba"))
        await XCTAssertThrowsErrorAsync(try await store.games.insert(game, files: [stray])) { error in
            guard case .invalidRelationship = error as? LibraryError else { return XCTFail("\(error)") }
        }
        // Foreign key enforced at the database level too.
        await XCTAssertThrowsErrorAsync(try await store.writer.write { db in try GameFileRecord(stray).insert(db) }) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
        }
    }

    func testUpdateChangesMutableFieldsOnly() async throws {
        let game = Fixtures.game(seed: 4, title: "Old")
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
        var changed = game
        changed.title = "New"
        try await store.games.update(changed)
        let stored = try await store.games.game(id: game.id)
        XCTAssertEqual(stored?.title, "New")
        XCTAssertEqual(stored?.contentFingerprint, game.contentFingerprint)
        XCTAssertEqual(stored?.addedAt, game.addedAt)

        await XCTAssertThrowsErrorAsync(try await store.games.update(Fixtures.game(seed: 5))) { error in
            guard case .gameNotFound = error as? LibraryError else { return XCTFail("\(error)") }
        }
    }

    func testDeleteCascadesToEverythingReferencingTheGame() async throws {
        let game = Fixtures.game(seed: 6)
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
        try await store.saves.upsert(Save(gameID: game.id, location: Fixtures.location("Saves/a.sav"), sizeInBytes: 1, updatedAt: Date()))
        try await store.saves.insert(SaveState(gameID: game.id, coreID: "mgba", coreVersion: "1", kind: .manual, createdAt: Date(), location: Fixtures.location("SaveStates/a.state")))
        try await store.playHistory.record(PlaySession(gameID: game.id, coreID: "mgba", startedAt: Date()))

        try await store.games.deleteGame(id: game.id)

        let g = try await store.games.game(id: game.id)
        XCTAssertNil(g)
        let files = try await store.games.files(for: game.id)
        XCTAssertEqual(files, [])
        let saves = try await store.saves.saves(for: game.id)
        XCTAssertEqual(saves, [])
        let states = try await store.saves.saveStates(for: game.id)
        XCTAssertEqual(states, [])
        let sessions = try await store.playHistory.sessions(for: game.id, limit: 10)
        XCTAssertEqual(sessions, [])
        let history = try await store.playHistory.recentlyPlayed(limit: 10)
        XCTAssertEqual(history, [])
        // Deleting again is a no-op.
        try await store.games.deleteGame(id: game.id)
    }

    func testTimestampsAreStoredAtMillisecondPrecision() async throws {
        let precise = Date(timeIntervalSince1970: 1_700_000_000.123_456_7)
        let game = Fixtures.game(seed: 30, addedAt: precise)
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
        let stored = try await store.games.game(id: game.id)
        XCTAssertEqual(stored?.addedAt.timeIntervalSince1970 ?? 0, 1_700_000_000.123, accuracy: 0.000_000_1)
        // Writing the read-back value again is lossless.
        try await store.games.update(stored!)
        let again = try await store.games.game(id: game.id)
        XCTAssertEqual(again, stored)
    }

    func testAllGamesOrderedByTitleCaseInsensitiveThenID() async throws {
        let b = Fixtures.game(seed: 10, title: "banana")
        let a = Fixtures.game(seed: 11, title: "Apple")
        let c = Fixtures.game(seed: 12, title: "cherry")
        for g in [c, b, a] { try await store.games.insert(g, files: [Fixtures.primaryFile(for: g)]) }
        let all = try await store.games.allGames()
        XCTAssertEqual(all.map(\.title), ["Apple", "banana", "cherry"])
    }

    func testDataSurvivesCloseAndReopen() async throws {
        let url = try Fixtures.temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let game = Fixtures.game(seed: 20, title: "Persisted")
        let file = Fixtures.primaryFile(for: game)
        let session = PlaySession(gameID: game.id, coreID: "mgba", startedAt: Date(timeIntervalSince1970: 100)).ended(at: Date(timeIntervalSince1970: 160))
        do {
            let store = try SQLiteLibraryStore.open(at: url)
            try await store.games.insert(game, files: [file])
            try await store.playHistory.record(session)
            try store.close()
        }
        let reopened = try SQLiteLibraryStore.open(at: url)
        defer { try? reopened.close() }
        let g = try await reopened.games.game(id: game.id)
        XCTAssertEqual(g, game)
        let f = try await reopened.games.files(for: game.id)
        XCTAssertEqual(f, [file])
        let last = try await reopened.playHistory.lastPlayed()
        XCTAssertEqual(last?.latestSession.id, session.id)
        XCTAssertEqual(last?.latestSession.endedAt, session.endedAt)
        let identity = try await reopened.syncStore.identity()
        XCTAssertEqual(last?.latestSession.installationID, identity.installationID, "local sessions carry this installation")
        XCTAssertEqual(last?.totalPlayDuration, 60)
    }
}

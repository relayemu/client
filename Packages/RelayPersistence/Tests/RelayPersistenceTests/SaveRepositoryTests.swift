// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class SaveRepositoryTests: XCTestCase {
    var store: SQLiteLibraryStore!
    var game: Game!

    override func setUp() async throws {
        store = try SQLiteLibraryStore.inMemory()
        game = Fixtures.game(seed: 1)
        try await store.games.insert(game, files: [Fixtures.primaryFile(for: game)])
    }

    func testBatterySaveUpsertOrderAndDelete() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var older = Save(gameID: game.id, location: Fixtures.location("Saves/\(game.id)/a.sav"), sizeInBytes: 8, updatedAt: t0)
        let newer = Save(gameID: game.id, location: Fixtures.location("Saves/\(game.id)/b.sav"), sizeInBytes: 16,
                         fingerprint: Fixtures.fingerprint(9), updatedAt: t0.addingTimeInterval(10))
        try await store.saves.upsert(older)
        try await store.saves.upsert(newer)
        var list = try await store.saves.saves(for: game.id)
        XCTAssertEqual(list, [newer, older])

        older.sizeInBytes = 32
        older.updatedAt = t0.addingTimeInterval(20)
        try await store.saves.upsert(older)
        list = try await store.saves.saves(for: game.id)
        XCTAssertEqual(list, [older, newer], "upsert replaced in place and reordered")

        try await store.saves.deleteSave(id: newer.id)
        list = try await store.saves.saves(for: game.id)
        XCTAssertEqual(list, [older])
    }

    func testSaveStateInsertOrderAndDelete() async throws {
        let t0 = Date(timeIntervalSince1970: 5_000)
        let s1 = SaveState(gameID: game.id, coreID: "mgba", coreVersion: "0.10.3", kind: .auto, createdAt: t0,
                           location: Fixtures.location("SaveStates/\(game.id)/1.state"))
        let s2 = SaveState(gameID: game.id, coreID: "mgba", coreVersion: "0.10.3", kind: .manual, createdAt: t0.addingTimeInterval(1),
                           location: Fixtures.location("SaveStates/\(game.id)/2.state"),
                           screenshotLocation: Fixtures.location("SaveStates/\(game.id)/2.png"), label: "Boss")
        try await store.saves.insert(s1)
        try await store.saves.insert(s2)
        var list = try await store.saves.saveStates(for: game.id)
        XCTAssertEqual(list, [s2, s1])
        XCTAssertEqual(list[0].screenshotLocation?.relativePath, "SaveStates/\(game.id)/2.png")
        XCTAssertEqual(list[0].formatVersion, SaveState.currentFormatVersion)
        try await store.saves.deleteSaveState(id: s2.id)
        list = try await store.saves.saveStates(for: game.id)
        XCTAssertEqual(list, [s1])
    }

    func testSavesForUnknownGameAreRejected() async throws {
        let ghost = GameID()
        await XCTAssertThrowsErrorAsync(try await store.saves.upsert(Save(gameID: ghost, location: Fixtures.location("Saves/x.sav"), sizeInBytes: 1, updatedAt: Date()))) {
            XCTAssertEqual($0 as? LibraryError, .gameNotFound(ghost))
        }
        await XCTAssertThrowsErrorAsync(try await store.saves.insert(SaveState(gameID: ghost, coreID: "mgba", coreVersion: "1", kind: .quick, createdAt: Date(), location: Fixtures.location("SaveStates/x.state")))) {
            XCTAssertEqual($0 as? LibraryError, .gameNotFound(ghost))
        }
    }

    func testSaveAndSaveStateTablesAreSeparate() async throws {
        try await store.saves.upsert(Save(gameID: game.id, location: Fixtures.location("Saves/a.sav"), sizeInBytes: 1, updatedAt: Date()))
        let states = try await store.saves.saveStates(for: game.id)
        XCTAssertEqual(states, [], "a battery save never shows up as a save state")
    }
}

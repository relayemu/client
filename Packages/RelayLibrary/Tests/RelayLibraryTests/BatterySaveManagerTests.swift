// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  BatterySaveManagerTests.swift — battery saves are snapshotted atomically,
//  keep a rollback copy, survive failed writes and are restored on launch.

import XCTest
import RelayDomain
@testable import RelayLibrary

final class BatterySaveManagerTests: XCTestCase {
    var root: URL!
    var location: LibraryLocation!
    var store: InMemoryLibraryStore!
    var game: Game!

    override func setUp() async throws {
        root = try TestSupport.temporaryDirectory()
        location = LibraryLocation(rootURL: root)
        try location.createDirectories()
        store = InMemoryLibraryStore()
        game = Game(systemID: .gameBoyAdvance, title: "Counter", contentFingerprint: try ContentFingerprint(sha256: [UInt8](repeating: 7, count: 32)), addedAt: Date())
        try await store.games.insert(game, files: [GameFile(gameID: game.id, role: .primary, fingerprint: game.contentFingerprint, sizeInBytes: 10, originalFileName: "counter.gba", location: try LibraryLocation.gameFileLocation(gameID: game.id, fileName: "counter.gba"))])
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func writeLive(_ bytes: [UInt8], manager: BatterySaveManager) throws {
        let live = manager.workingDirectory(for: game.id).appending(path: "counter.sav")
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: live)
    }

    func testNoBatteryDataMeansNoSaveRow() async throws {
        let manager = BatterySaveManager(store: store, location: location)
        try await manager.prepareForLaunch(gameID: game.id, romBaseName: "counter")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.workingDirectory(for: game.id).path))
        let save = try await manager.snapshot(gameID: game.id, data: nil)
        XCTAssertNil(save)
        let rows = try await store.saves.saves(for: game.id)
        XCTAssertTrue(rows.isEmpty)
    }

    func testCreateThenUpdateKeepsRollbackCopyAndOneRow() async throws {
        let manager = BatterySaveManager(store: store, location: location)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let firstOptional = try await manager.snapshot(gameID: game.id, data: Data([1, 0, 0, 0]), now: t0)
        let first = try XCTUnwrap(firstOptional)
        XCTAssertEqual(first.location.relativePath, "Saves/\(game.id)/battery/current.sav")
        XCTAssertEqual(first.sizeInBytes, 4)
        XCTAssertEqual(try Data(contentsOf: location.url(for: first.location)), Data([1, 0, 0, 0]))
        XCTAssertNil(manager.previousSnapshotURL(for: game.id))

        // Unchanged bytes: no rewrite, same row.
        let same = try await manager.snapshot(gameID: game.id, data: Data([1, 0, 0, 0]), now: t0.addingTimeInterval(10))
        XCTAssertEqual(same, first)

        let secondOptional = try await manager.snapshot(gameID: game.id, data: Data([2, 0, 0, 0]), now: t0.addingTimeInterval(20))
        let second = try XCTUnwrap(secondOptional)
        XCTAssertEqual(second.id, first.id, "one Save per game, updated in place")
        XCTAssertNotEqual(second.fingerprint, first.fingerprint)
        XCTAssertEqual(second.updatedAt, t0.addingTimeInterval(20))
        XCTAssertEqual(try Data(contentsOf: location.url(for: second.location)), Data([2, 0, 0, 0]))
        let previous = try XCTUnwrap(manager.previousSnapshotURL(for: game.id))
        XCTAssertEqual(try Data(contentsOf: previous), Data([1, 0, 0, 0]), "rollback copy is the prior snapshot")
        let rows = try await store.saves.saves(for: game.id)
        XCTAssertEqual(rows.count, 1)
    }

    func testFailedWritePreservesPreviousSnapshotAndRow() async throws {
        let good = BatterySaveManager(store: store, location: location)
        let firstOptional = try await good.snapshot(gameID: game.id, data: Data([1, 1]))
        let first = try XCTUnwrap(firstOptional)
        for stage in AtomicFile.Stage.allCases {
            let failing = BatterySaveManager(store: store, location: location,
                                             atomicFile: AtomicFile { s in if s == stage { throw AtomicFile.Failure.injected(stage) } })
            await XCTAssertThrowsErrorAsync(try await failing.snapshot(gameID: game.id, data: Data([2, 2]))) { _ in }
            XCTAssertEqual(try Data(contentsOf: location.url(for: first.location)), Data([1, 1]), "canonical intact after \(stage)")
            let rows = try await store.saves.saves(for: game.id)
            XCTAssertEqual(rows, [first], "row unchanged after \(stage)")
        }
        // And the next successful snapshot goes through.
        let secondOptional = try await good.snapshot(gameID: game.id, data: Data([2, 2]))
        let second = try XCTUnwrap(secondOptional)
        XCTAssertEqual(try Data(contentsOf: location.url(for: second.location)), Data([2, 2]))
    }

    func testLaunchRestoresLiveCopyFromCanonicalWhenMissingStaleOrEmpty() async throws {
        let manager = BatterySaveManager(store: store, location: location)
        let snapshotTime = Date()
        _ = try await manager.snapshot(gameID: game.id, data: Data([5, 5, 5]), now: snapshotTime)
        let live = manager.workingDirectory(for: game.id).appending(path: "counter.sav")
        // Missing live copy → restored.
        var restored = try await manager.prepareForLaunch(gameID: game.id, romBaseName: "counter")
        XCTAssertTrue(restored)
        XCTAssertEqual(try Data(contentsOf: live), Data([5, 5, 5]))
        // Identical live copy → untouched.
        restored = try await manager.prepareForLaunch(gameID: game.id, romBaseName: "counter")
        XCTAssertFalse(restored)
        // Stale live copy (older than the snapshot: the core never flushed before a crash) → restored.
        try Data([4]).write(to: live)
        try FileManager.default.setAttributes([.modificationDate: snapshotTime.addingTimeInterval(-10)], ofItemAtPath: live.path)
        restored = try await manager.prepareForLaunch(gameID: game.id, romBaseName: "counter")
        XCTAssertTrue(restored)
        XCTAssertEqual(try Data(contentsOf: live), Data([5, 5, 5]))
        // Empty live copy → restored.
        try Data().write(to: live)
        restored = try await manager.prepareForLaunch(gameID: game.id, romBaseName: "counter")
        XCTAssertTrue(restored)
        // A live copy clearly newer than the snapshot is the fresher truth and is kept.
        try Data([6]).write(to: live)
        try FileManager.default.setAttributes([.modificationDate: snapshotTime.addingTimeInterval(30)], ofItemAtPath: live.path)
        restored = try await manager.prepareForLaunch(gameID: game.id, romBaseName: "counter")
        XCTAssertFalse(restored)
        XCTAssertEqual(try Data(contentsOf: live), Data([6]))
    }

    func testGamesAreIsolated() async throws {
        let other = Game(systemID: .gameBoyAdvance, title: "Other", contentFingerprint: try ContentFingerprint(sha256: [UInt8](repeating: 8, count: 32)), addedAt: Date())
        try await store.games.insert(other, files: [GameFile(gameID: other.id, role: .primary, fingerprint: other.contentFingerprint, sizeInBytes: 10, originalFileName: "other.gba", location: try LibraryLocation.gameFileLocation(gameID: other.id, fileName: "other.gba"))])
        let manager = BatterySaveManager(store: store, location: location)
        try writeLive([1], manager: manager)
        _ = try await manager.snapshot(gameID: game.id, data: Data([1]))
        let otherSave = try await manager.currentSave(for: other.id)
        XCTAssertNil(otherSave)
        XCTAssertNil(manager.liveSaveURL(for: other.id))
        XCTAssertNotEqual(manager.workingDirectory(for: game.id), manager.workingDirectory(for: other.id))
    }

    func testOversizedLiveSaveIsRejected() async throws {
        let manager = BatterySaveManager(store: store, location: location)
        await XCTAssertThrowsErrorAsync(try await manager.snapshot(gameID: game.id, data: Data(repeating: 1, count: BatterySaveManager.maxSaveSize + 1))) { error in
            XCTAssertEqual(error as? BatterySaveError, .invalidSaveSize(BatterySaveManager.maxSaveSize + 1))
        }
    }
}

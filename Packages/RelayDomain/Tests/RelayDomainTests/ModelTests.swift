// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayDomain

final class ModelTests: XCTestCase {
    static let fp = try! ContentFingerprint(sha256: [UInt8](repeating: 1, count: 32))

    func testSystemCatalog() {
        XCTAssertEqual(SystemCatalog.descriptor(for: .gameBoyAdvance)?.shortName, "GBA")
        XCTAssertEqual(SystemCatalog.systems(forFileExtension: "GBA").map(\.id), [.gameBoyAdvance])
        // can say what it is instead of "unsupported file".
        XCTAssertEqual(SystemCatalog.systems(forFileExtension: "z64").map(\.id), [.nintendo64])
        XCTAssertEqual(SystemCatalog.descriptor(for: .nintendo64)?.availability,
                       .deferred(reason: .requiresJIT))
        XCTAssertFalse(SystemCatalog.descriptor(for: .nintendo64)!.isPlayable)
        XCTAssertTrue(SystemCatalog.descriptor(for: .nes)!.isPlayable)
        XCTAssertNil(SystemCatalog.descriptor(for: "dreamcast"))
    }

    func testGameIdentityIsNotTitleOrFile() {
        let a = Game(systemID: .gameBoyAdvance, title: "Same", contentFingerprint: Self.fp, addedAt: Date())
        let b = Game(systemID: .gameBoyAdvance, title: "Same", contentFingerprint: Self.fp, addedAt: a.addedAt)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.contentFingerprint, b.contentFingerprint, "same content → same fingerprint, different object identity")
    }

    func testSaveAndSaveStateAreDistinctTypes() throws {
        let gameID = GameID()
        let loc = try ContentLocation(root: .managedLibrary, relativePath: "Saves/x.sav")
        let save = Save(gameID: gameID, location: loc, sizeInBytes: 8, updatedAt: Date())
        let state = SaveState(gameID: gameID, coreID: "mgba", coreVersion: "0.10.3", kind: .manual, createdAt: Date(), location: loc)
        XCTAssertEqual(state.formatVersion, SaveState.currentFormatVersion)
        XCTAssertEqual(save.gameID, state.gameID)
        // Codable shapes differ: a save carries no core information at all.
        let saveJSON = String(data: try JSONEncoder().encode(save), encoding: .utf8)!
        XCTAssertFalse(saveJSON.contains("coreID"))
        let stateJSON = String(data: try JSONEncoder().encode(state), encoding: .utf8)!
        XCTAssertTrue(stateJSON.contains("\"coreVersion\":\"0.10.3\""))
    }

    func testSaveStateRestorability() throws {
        let loc = try ContentLocation(root: .managedLibrary, relativePath: "States/s.state")
        let state = SaveState(gameID: GameID(), coreID: "mgba", coreVersion: "0.10.3", kind: .auto, createdAt: Date(), location: loc)
        let same = EmulatorCoreDescriptor(id: "mgba", name: "mGBA", version: "0.10.3", license: "MPL-2.0", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        let newer = EmulatorCoreDescriptor(id: "mgba", name: "mGBA", version: "0.11.0", license: "MPL-2.0", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        let other = EmulatorCoreDescriptor(id: "vbam", name: "VBA-M", version: "0.10.3", license: "GPL-2.0", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        XCTAssertTrue(state.isRestorable(by: same))
        XCTAssertFalse(state.isRestorable(by: newer))
        XCTAssertFalse(state.isRestorable(by: other))
        let future = SaveState(gameID: state.gameID, coreID: "mgba", coreVersion: "0.10.3", formatVersion: SaveState.currentFormatVersion + 1, kind: .auto, createdAt: Date(), location: loc)
        XCTAssertFalse(future.isRestorable(by: same))
    }

    func testPlaySessionDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        var s = PlaySession(gameID: GameID(), coreID: "mgba", startedAt: start)
        XCTAssertNil(s.duration)
        s = s.ended(at: start.addingTimeInterval(90))
        XCTAssertEqual(s.duration, 90)
        let clamped = PlaySession(gameID: GameID(), coreID: "mgba", startedAt: start).ended(at: start.addingTimeInterval(-5))
        XCTAssertEqual(clamped.duration, 0)
    }
}

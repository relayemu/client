// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  battery revisions, state compatibility versions, tombstones, content descriptors.

import XCTest
@testable import RelayDomain

final class ContinuityModelTests: XCTestCase {
    static let fp = try! ContentFingerprint(sha256: [UInt8](repeating: 3, count: 32))

    func testDeviceKindIsPortableAndLenient() throws {
        XCTAssertEqual(DeviceKind.appleTV.rawValue, "appletv")
        XCTAssertEqual(DeviceKind(lenient: "IPAD"), .iPad)
        XCTAssertEqual(DeviceKind(lenient: "visionpro"), .unknown, "future kinds never fail decoding")
        let json = try JSONEncoder().encode([DeviceKind.iPhone, .mac])
        XCTAssertEqual(String(data: json, encoding: .utf8), "[\"iphone\",\"mac\"]")
    }

    func testInstallationIDIsOpaqueAndUnique() {
        let a = InstallationID(), b = InstallationID()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(InstallationID(a.description), a)
    }

    func testBatteryRevisionRoundTripKeepsGraphLinks() throws {
        let root = BatteryRevision(gameID: GameID(), parentIDs: [], createdAt: Date(timeIntervalSince1970: 1), dataFingerprint: Self.fp,
                                   sizeInBytes: 32, installationID: InstallationID(), deviceKind: .iPhone,
                                   location: try ContentLocation(root: .managedLibrary, relativePath: "Saves/g/battery/revisions/a.sav"), origin: .local)
        let child = BatteryRevision(gameID: root.gameID, parentIDs: [root.id], createdAt: Date(timeIntervalSince1970: 2), dataFingerprint: Self.fp,
                                    sizeInBytes: 32, installationID: root.installationID, deviceKind: .iPhone,
                                    location: try ContentLocation(root: .managedLibrary, relativePath: "Saves/g/battery/revisions/b.sav"), origin: .remote)
        let decoded = try JSONDecoder().decode(BatteryRevision.self, from: try JSONEncoder().encode(child))
        XCTAssertEqual(decoded, child)
        XCTAssertEqual(decoded.parentIDs, [root.id])
        XCTAssertEqual(decoded.origin, .remote)
    }

    func testStateCompatibilityVersionGovernsRestorability() throws {
        let loc = try ContentLocation(root: .managedLibrary, relativePath: "Saves/g/states/s.relaystate")
        let core = EmulatorCoreDescriptor(id: "mgba", name: "mGBA", version: "0.10.3", license: "MPL-2.0", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        XCTAssertEqual(core.stateCompatibilityVersion, "0.10.3", "defaults to the version: every version is its own class")
        let state = SaveState(gameID: GameID(), coreID: "mgba", coreVersion: "0.10.3", kind: .auto, createdAt: Date(), location: loc)
        XCTAssertEqual(state.stateCompatibilityVersion, "0.10.3")
        // A later core that explicitly declares the same state format restores it; one that does not, refuses.
        let declared = EmulatorCoreDescriptor(id: "mgba", name: "mGBA", version: "0.10.4", stateCompatibilityVersion: "0.10.3", license: "MPL-2.0", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        let silent = EmulatorCoreDescriptor(id: "mgba", name: "mGBA", version: "0.10.4", license: "MPL-2.0", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        XCTAssertTrue(state.isRestorable(by: declared))
        XCTAssertFalse(state.isRestorable(by: silent))
        let v1 = SaveState(gameID: state.gameID, coreID: "mgba", coreVersion: "0.10.3", formatVersion: 1, kind: .manual, createdAt: Date(), location: loc)
        XCTAssertTrue(v1.isRestorable(by: core))
    }

    func testSaveStateDefaultsAreLocalAndUnknownDevice() throws {
        let loc = try ContentLocation(root: .managedLibrary, relativePath: "Saves/g/states/s.relaystate")
        let state = SaveState(gameID: GameID(), coreID: "mgba", coreVersion: "1", kind: .quick, createdAt: Date(), location: loc)
        XCTAssertEqual(state.origin, .local)
        XCTAssertEqual(state.deviceKind, .unknown)
        XCTAssertNil(state.installationID)
        XCTAssertNil(state.batteryRevisionID)
        let session = PlaySession(gameID: GameID(), coreID: "mgba", startedAt: Date())
        XCTAssertEqual(session.origin, .local)
        XCTAssertNil(session.installationID)
    }

    func testTombstoneKeysAreLogicalNotLocal() throws {
        let install = InstallationID()
        let game = DeletionTombstone(target: .game(Self.fp), deletedAt: Date(timeIntervalSince1970: 5), installationID: install)
        XCTAssertEqual(game.target.kindName, "game")
        XCTAssertEqual(game.target.keyString, Self.fp.canonicalString)
        let stateID = SaveStateID()
        let state = DeletionTombstone(target: .saveState(stateID), deletedAt: Date(), installationID: install)
        XCTAssertEqual(state.target.kindName, "state")
        XCTAssertEqual(state.target.keyString, stateID.description)
        let decoded = try JSONDecoder().decode(DeletionTombstone.self, from: try JSONEncoder().encode(game))
        XCTAssertEqual(decoded, game)
    }

    func testContentDescriptorSingleFile() {
        let d = GameContentDescriptor.singleFile(fingerprint: Self.fp, sizeInBytes: 61104, fileName: "game.gba", systemID: .gameBoyAdvance, uploadedAt: Date())
        XCTAssertEqual(d.parts.count, 1)
        XCTAssertEqual(d.parts[0].fingerprint, Self.fp)
        XCTAssertEqual(d.parts[0].sizeInBytes, 61104)
    }
}

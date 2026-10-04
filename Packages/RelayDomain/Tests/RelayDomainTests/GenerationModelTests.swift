// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayDomain

final class GenerationModelTests: XCTestCase {
    private func legacy<T: Codable>(_ value: T) throws -> T {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json.removeValue(forKey: "generation")
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)), value)
    }
    func testMissingGenerationAlwaysDecodesAsInitialMembershipAndPreservesSource() throws {
        let fp = try ContentFingerprint(sha256: [UInt8](repeating: 9, count: 32))
        let game = Game(systemID: .gameBoyAdvance, title: "Generation", contentFingerprint: fp, addedAt: Date(), generation: 7)
        let source = InstallationID()
        let location = try ContentLocation(root: .managedLibrary, relativePath: "Saves/test")
        let revision = BatteryRevision(gameID: game.id, parentIDs: [BatteryRevisionID()], createdAt: Date(), dataFingerprint: fp,
            sizeInBytes: 4, installationID: source, deviceKind: .iPad, location: location, origin: .remote, generation: 7)
        let state = SaveState(gameID: game.id, coreID: "mgba", coreVersion: "1", kind: .auto, createdAt: Date(), location: location,
            batteryRevisionID: revision.id, installationID: source, deviceKind: .iPad, origin: .remote, generation: 7)
        let session = PlaySession(gameID: game.id, coreID: "mgba", startedAt: Date(), installationID: source,
            deviceKind: .iPad, origin: .remote, generation: 7)
        let descriptor = GameContentDescriptor.singleFile(fingerprint: fp, sizeInBytes: 4, fileName: "game.gba",
            systemID: .gameBoyAdvance, uploadedAt: Date(), generation: 7)
        let tombstone = DeletionTombstone(target: .game(fp), deletedAt: Date(), installationID: source, generation: 7)
        try roundTrip(game); try roundTrip(revision); try roundTrip(state); try roundTrip(session)
        try roundTrip(descriptor); try roundTrip(tombstone)
        XCTAssertEqual(try legacy(game).generation, 0)
        XCTAssertEqual(try legacy(revision).generation, 0)
        XCTAssertEqual(try legacy(state).generation, 0)
        XCTAssertEqual(try legacy(session).generation, 0)
        XCTAssertEqual(try legacy(descriptor).generation, 0)
        XCTAssertEqual(try legacy(tombstone).generation, 0)
        XCTAssertEqual(try legacy(revision).installationID, source)
        XCTAssertEqual(try legacy(revision).parentIDs, revision.parentIDs)
        XCTAssertEqual(try legacy(state).installationID, source)
        XCTAssertEqual(try legacy(state).batteryRevisionID, revision.id)
        XCTAssertEqual(try legacy(session).installationID, source)
        XCTAssertEqual(try legacy(session).origin, .remote)
        XCTAssertEqual(try legacy(tombstone).installationID, source)
    }
}

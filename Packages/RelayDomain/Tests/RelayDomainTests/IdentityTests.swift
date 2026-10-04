// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayDomain

final class IdentityTests: XCTestCase {
    func testEntityIdentifiersAreDistinctTypesWithValueEquality() {
        let uuid = UUID()
        let a = GameID(rawValue: uuid)
        let b = GameID(rawValue: uuid)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(GameID(), GameID(), "fresh identifiers must be unique")
        // Different identifier types with the same UUID are different values by type; compile-time distinct.
        let file = GameFileID(rawValue: uuid)
        XCTAssertEqual(file.rawValue, a.rawValue)
    }

    func testEntityIdentifierStringRoundTrip() {
        let id = SaveStateID()
        XCTAssertEqual(id.description, id.rawValue.uuidString.lowercased())
        XCTAssertEqual(SaveStateID(id.description), id)
        XCTAssertEqual(SaveStateID(id.description.uppercased()), id)
        XCTAssertNil(SaveStateID("not-a-uuid"))
    }

    func testEntityIdentifierCodableIsSingleLowercaseString() throws {
        let id = PlaySessionID()
        let data = try JSONEncoder().encode([id])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"\(id.description)\"]")
        XCTAssertEqual(try JSONDecoder().decode([PlaySessionID].self, from: data), [id])
        XCTAssertThrowsError(try JSONDecoder().decode([PlaySessionID].self, from: Data("[\"nope\"]".utf8)))
    }

    func testReferenceIdentifiers() throws {
        let gba: SystemID = "gba"
        XCTAssertEqual(gba, SystemID.gameBoyAdvance)
        XCTAssertEqual(gba.description, "gba")
        let data = try JSONEncoder().encode(["core": CoreID(rawValue: "mgba")])
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"core\":\"mgba\"}")
        XCTAssertEqual(try JSONDecoder().decode([String: CoreID].self, from: data)["core"], "mgba")
    }
}

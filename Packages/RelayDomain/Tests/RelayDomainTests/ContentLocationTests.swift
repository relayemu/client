// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayDomain

final class ContentLocationTests: XCTestCase {
    func testValidRelativePaths() throws {
        let loc = try ContentLocation(root: .managedLibrary, relativePath: "Games/abc/game.gba")
        XCTAssertEqual(loc.pathComponents, ["Games", "abc", "game.gba"])
        XCTAssertEqual(loc.description, "managedLibrary:Games/abc/game.gba")
        XCTAssertNoThrow(try ContentLocation(root: .managedLibrary, relativePath: "file"))
        XCTAssertNoThrow(try ContentLocation(root: .managedLibrary, relativePath: "a/.hidden/b"))
        XCTAssertNoThrow(try ContentLocation(root: .managedLibrary, relativePath: "a/b..c/..d"))
    }

    func testRejectsUnsafePaths() {
        for path in ["", "/abs", "a//b", "a/", "./a", "a/./b", "../a", "a/../b", "a/..", "a\0b"] {
            XCTAssertThrowsError(try ContentLocation(root: .managedLibrary, relativePath: path), "should reject '\(path)'")
        }
    }

    func testCodableRoundTripAndValidationOnDecode() throws {
        let loc = try ContentLocation(root: .managedLibrary, relativePath: "Saves/x.sav")
        let data = try JSONEncoder().encode(loc)
        XCTAssertEqual(try JSONDecoder().decode(ContentLocation.self, from: data), loc)
        let tampered = Data("{\"root\":\"managedLibrary\",\"relativePath\":\"../escape\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ContentLocation.self, from: tampered))
    }
}

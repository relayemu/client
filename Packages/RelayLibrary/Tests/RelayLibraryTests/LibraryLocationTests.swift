// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayLibrary

final class LibraryLocationTests: XCTestCase {
    func testResolvesRelativeToRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/RelayRoot", isDirectory: true)
        let loc = LibraryLocation(rootURL: root)
        let content = try ContentLocation(root: .managedLibrary, relativePath: "Games/x/y.gba")
        XCTAssertEqual(loc.url(for: content).path, "/tmp/RelayRoot/Games/x/y.gba")
        XCTAssertEqual(loc.databaseURL.lastPathComponent, "relay.sqlite")
        let id = GameID()
        XCTAssertEqual(loc.directory(forGame: id).path, "/tmp/RelayRoot/Games/\(id)")
    }

    func testGameFileLocationUsesGameIDAndSanitizedName() throws {
        let id = GameID()
        let loc = try LibraryLocation.gameFileLocation(gameID: id, fileName: "../evil/../My Game.gba")
        XCTAssertEqual(loc.relativePath, "Games/\(id)/My Game.gba")
    }

    func testSanitizedFileName() {
        XCTAssertEqual(LibraryLocation.sanitizedFileName("game.gba"), "game.gba")
        XCTAssertEqual(LibraryLocation.sanitizedFileName("dir/sub/game.gba"), "game.gba")
        XCTAssertEqual(LibraryLocation.sanitizedFileName(".hidden.gba"), "hidden.gba")
        XCTAssertEqual(LibraryLocation.sanitizedFileName(".."), "game")
        XCTAssertEqual(LibraryLocation.sanitizedFileName(""), "game")
        XCTAssertEqual(LibraryLocation.sanitizedFileName("a:b\\c\u{01}d"), "a_b_c_d")
    }
}

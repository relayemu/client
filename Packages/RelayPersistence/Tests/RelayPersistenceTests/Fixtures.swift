// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

enum Fixtures {
    static func fingerprint(_ seed: UInt8) -> ContentFingerprint {
        try! ContentFingerprint(sha256: [UInt8](repeating: seed, count: 32))
    }

    static func game(seed: UInt8, title: String = "Game", addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Game {
        Game(systemID: .gameBoyAdvance, title: title, contentFingerprint: fingerprint(seed), addedAt: addedAt)
    }

    static func primaryFile(for game: Game, name: String = "game.gba") -> GameFile {
        GameFile(gameID: game.id, role: .primary, fingerprint: game.contentFingerprint, sizeInBytes: 1234,
                 originalFileName: name,
                 location: try! LibraryLocation.gameFileLocation(gameID: game.id, fileName: name))
    }

    static func location(_ path: String) -> ContentLocation {
        try! ContentLocation(root: .managedLibrary, relativePath: path)
    }

    static func temporaryDatabaseURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "RelayPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "relay.sqlite")
    }
}

func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Any,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ handler: (Error) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

import XCTest

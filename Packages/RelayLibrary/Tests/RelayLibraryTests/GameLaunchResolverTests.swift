// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayLibrary

final class GameLaunchResolverTests: XCTestCase {
    static let mgba = EmulatorCoreDescriptor(id: "mgba", name: "mGBA", version: "0.10.3", license: "MPL-2.0",
                                             supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
    var dir: URL!
    var store: InMemoryLibraryStore!
    var location: LibraryLocation!

    override func setUp() async throws {
        dir = try TestSupport.temporaryDirectory()
        store = InMemoryLibraryStore()
        location = LibraryLocation(rootURL: dir)
        try location.createDirectories()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testResolvesGameToContentURLAndCore() async throws {
        let source = try TestSupport.writeFile([9, 9, 9], named: "g.gba", in: dir)
        let game = try await GameIngestion(store: store, location: location).ingestLocalFile(at: source).game
        let resolver = GameLaunchResolver(store: store, location: location, availableCores: [Self.mgba])
        let launch = try await resolver.resolve(gameID: game.id)
        XCTAssertEqual(launch.game, game)
        XCTAssertEqual(launch.core, Self.mgba)
        XCTAssertEqual(launch.contentURL.path, location.directory(forGame: game.id).appending(path: "g.gba").path)
        XCTAssertEqual(launch.primaryFile.role, .primary)
    }

    func testErrors() async throws {
        let resolver = GameLaunchResolver(store: store, location: location, availableCores: [Self.mgba])
        let unknown = GameID()
        await XCTAssertThrowsErrorAsync(try await resolver.resolve(gameID: unknown)) {
            XCTAssertEqual($0 as? LaunchResolutionError, .gameNotFound(unknown))
        }

        let source = try TestSupport.writeFile([1], named: "g.gba", in: dir)
        let game = try await GameIngestion(store: store, location: location).ingestLocalFile(at: source).game
        let noCores = GameLaunchResolver(store: store, location: location, availableCores: [])
        await XCTAssertThrowsErrorAsync(try await noCores.resolve(gameID: game.id)) {
            XCTAssertEqual($0 as? LaunchResolutionError, .noCoreForSystem(.gameBoyAdvance))
        }

        // Content removed behind the library's back.
        try FileManager.default.removeItem(at: location.directory(forGame: game.id))
        await XCTAssertThrowsErrorAsync(try await resolver.resolve(gameID: game.id)) {
            guard case .contentMissing = $0 as? LaunchResolutionError else { return XCTFail("\($0)") }
        }
    }

    func testPreferredCoreIsFirstRegisteredForSystem() {
        let other = EmulatorCoreDescriptor(id: "vbam", name: "VBA-M", version: "1", license: "GPL-2.0",
                                           supportedSystems: [.gameBoyAdvance], capabilities: [])
        let resolver = GameLaunchResolver(store: store, location: location, availableCores: [other, Self.mgba])
        XCTAssertEqual(resolver.preferredCore(for: .gameBoyAdvance)?.id, "vbam")
        XCTAssertNil(resolver.preferredCore(for: "nes"))
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

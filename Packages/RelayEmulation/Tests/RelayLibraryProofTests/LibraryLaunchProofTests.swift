// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LibraryLaunchProofTests.swift
//
//  Legal fixture (240p Test Suite, GPL-2.0, see Tests/Fixtures/ROMs/…/README.md)
//    → SHA-256 → canonical Game + GameFile in the SQLite library
//    → retrieved through RelayLibrary repositories
//    → duplicate recognised by fingerprint
//    → play session recorded
//    → resolved to local content and launched through EmulationSession/mGBA
//    → stopped cleanly, play history persisted
//    → store closed and reopened: everything survives.
//

import XCTest
import RelayDomain
import RelayLibrary
import RelayPersistence
import RelayEmulation
import RelayProvenanceAdapter

final class LibraryLaunchProofTests: XCTestCase {
    /// `shasum -a 256 Tests/Fixtures/ROMs/240p-test-suite-gba/240pee_mb.gba`
    static let fixtureSHA256 = "47844f7140738a06f8f3bc09780da3ab095539a250b870f614feed561d9d6f34"
    static let fixtureSize: Int64 = 61104

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/Fixtures/ROMs/240p-test-suite-gba/240pee_mb.gba")
    }

    var root: URL!
    var location: LibraryLocation!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixtureURL.path), "fixture missing at \(Self.fixtureURL.path)")
        root = FileManager.default.temporaryDirectory.appending(path: "RelayProof-\(UUID().uuidString)", directoryHint: .isDirectory)
        location = LibraryLocation(rootURL: root)
        try location.createDirectories()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testFixtureThroughLibraryIntoMGBAAndBack() async throws {
        let store = try SQLiteLibraryStore.open(at: location.databaseURL)
        let ingestion = GameIngestion(store: store, location: location)

        // 1–2. SHA-256 + canonical Game/GameFile.
        let outcome = try await ingestion.ingestLocalFile(at: Self.fixtureURL)
        guard case .inserted(let game) = outcome else { return XCTFail("expected insertion, got \(outcome)") }
        XCTAssertEqual(game.contentFingerprint.canonicalString, "sha256:" + Self.fixtureSHA256)
        XCTAssertEqual(game.systemID, .gameBoyAdvance)
        XCTAssertEqual(game.title, "240pee_mb")

        // 3. Retrieval through the repository interfaces.
        let byID = try await store.games.game(id: game.id)
        XCTAssertEqual(byID, game)
        let byFingerprint = try await store.games.game(fingerprint: try ContentFingerprint(parsing: "sha256:" + Self.fixtureSHA256))
        XCTAssertEqual(byFingerprint?.id, game.id)
        let files = try await store.games.files(for: game.id)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].role, .primary)
        XCTAssertEqual(files[0].sizeInBytes, Self.fixtureSize)
        XCTAssertEqual(files[0].location.relativePath, "Games/\(game.id)/240pee_mb.gba")

        // 4. Duplicate detection by fingerprint (same bytes, different file name).
        let copy = root.appending(path: "Renamed Copy.gba")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: copy)
        let duplicate = try await ingestion.ingestLocalFile(at: copy)
        XCTAssertEqual(duplicate, .duplicate(existing: game))
        let count = try await store.games.allGames().count
        XCTAssertEqual(count, 1)

        // 5. Play session start recorded before launch (survives a crash mid-play as "in progress").
        let factory = ProvenanceDriverFactory()
        let resolver = GameLaunchResolver(store: store, location: location, availableCores: factory.availableCores)

        // 6. Resolve local content + core.
        let launch = try await resolver.resolve(gameID: game.id)
        XCTAssertEqual(launch.core.id, ProvenanceDriverFactory.mgbaCoreID)
        XCTAssertTrue(launch.core.capabilities.contains(.saveStates))
        XCTAssertEqual(launch.contentURL, location.url(for: files[0].location))
        XCTAssertTrue(launch.contentURL.path.hasPrefix(root.path), "content resolved inside the managed library")

        var playSession = PlaySession(gameID: game.id, coreID: launch.core.id, startedAt: Date())
        try await store.playHistory.record(playSession)

        let storage = EmulationStorage(batterySavesDirectory: location.batteryWorkingDirectory(forGame: game.id),
                                       saveStatesDirectory: location.saveStatesDirectory(forGame: game.id),
                                       firmwareDirectory: root.appending(path: "Firmware"))
        let session = EmulationSession(factory: factory, storage: storage)
        try session.play(romURL: launch.contentURL, coreID: launch.core.id,
                             systemID: launch.game.systemID, audio: false)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.core, launch.core)

        // The core runs on its own thread; frames must change while we wait.
        try await Task.sleep(for: .milliseconds(600))
        let first = session.frameSource?.sampledChecksum() ?? 0
        session.press(.right)
        try await Task.sleep(for: .milliseconds(120))
        session.release(.right)
        try await Task.sleep(for: .milliseconds(600))
        let second = session.frameSource?.sampledChecksum() ?? 0
        XCTAssertNotNil(session.frameSource)
        XCTAssertNotEqual(first, 0)
        XCTAssertNotEqual(first, second, "framebuffer should change after input while running")

        // 8. Stop cleanly.
        session.stop()
        XCTAssertEqual(session.state, .stopped)

        // 9. Persist the ended session.
        playSession = playSession.ended(at: Date())
        try await store.playHistory.record(playSession)
        let last = try await store.playHistory.lastPlayed()
        XCTAssertEqual(last?.gameID, game.id)
        XCTAssertEqual(last?.sessionCount, 1)
        XCTAssertGreaterThan(last?.totalPlayDuration ?? 0, 1.0)

        // 10. Close, reopen, everything survives.
        try store.close()
        let reopened = try SQLiteLibraryStore.open(at: location.databaseURL)
        defer { try? reopened.close() }
        let gameAgain = try await reopened.games.game(id: game.id)
        XCTAssertEqual(gameAgain, game)
        let filesAgain = try await reopened.games.files(for: game.id)
        XCTAssertEqual(filesAgain, files)
        let lastAgain = try await reopened.playHistory.lastPlayed()
        XCTAssertEqual(lastAgain, last)
        let sessions = try await reopened.playHistory.sessions(for: game.id, limit: 5)
        XCTAssertEqual(sessions.map(\.id), [playSession.id])
        XCTAssertEqual(sessions.first, last?.latestSession, "the persisted session (millisecond precision) is the truth")
        XCTAssertEqual(sessions.first?.startedAt.timeIntervalSince1970 ?? 0, playSession.startedAt.timeIntervalSince1970, accuracy: 0.001)
        // And the resolver still finds the content after reopen.
        let launchAgain = try await GameLaunchResolver(store: reopened, location: location, availableCores: factory.availableCores).resolve(gameID: game.id)
        XCTAssertEqual(launchAgain.contentURL, launch.contentURL)
    }
}

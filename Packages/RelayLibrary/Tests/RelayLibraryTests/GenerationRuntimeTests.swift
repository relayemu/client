// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayLibrary

final class GenerationRuntimeTests: XCTestCase {
    func testRuntimeCapturesActiveMembershipAndFiltersStaleResumeAndBatteryRows() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = LibraryLocation(rootURL: root)
        try location.createDirectories()
        let store = InMemoryLibraryStore()
        let fp = try ContentFingerprint(sha256: [UInt8](repeating: 31, count: 32))
        let game = Game(systemID: .gameBoyAdvance, title: "Successor", contentFingerprint: fp, addedAt: Date(), generation: 1)
        try await store.games.insert(game, files: [])
        let core = EmulatorCoreDescriptor(id: "test", name: "Test", version: "1", license: "MIT",
            supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        let states = SaveStateManager(store: store, location: location, artworkStore: ArtworkStore(location: location))
        let batteries = BatterySaveManager(store: store, location: location)
        _ = try await batteries.snapshot(gameID: game.id, data: Data([1, 2, 3]))
        let activeRevisions = try await batteries.revisions(for: game.id)
        XCTAssertEqual(activeRevisions.map(\.generation), [1])
        let state = try await states.create(kind: .auto, game: game, core: core, payload: Data([4, 5]), batteryRevisionID: activeRevisions.first?.id)
        XCTAssertEqual(state.generation, 1)
        XCTAssertEqual(try states.load(state, game: game, for: core), Data([4, 5]))
        // Deliberately weak storage injects rows production persistence rejects:
        // runtime consumers must still refuse an older membership's history.
        let staleState = SaveState(gameID: game.id, coreID: core.id, coreVersion: core.version, kind: .auto,
            createdAt: state.createdAt.addingTimeInterval(10_000), location: state.location, generation: 0)
        try await store.saves.insert(staleState)
        let staleRevision = BatteryRevision(gameID: game.id, parentIDs: [], createdAt: Date().addingTimeInterval(10_000), dataFingerprint: fp,
            sizeInBytes: 3, installationID: InstallationID(), deviceKind: .iPad,
            location: try ContentLocation(root: .managedLibrary, relativePath: "Saves/old"), origin: .remote, generation: 0)
        try await store.saves.insertBatteryRevision(staleRevision)
        let resume = try await states.latestAutoResume(for: game.id, activeRevision: activeRevisions.first?.id)
        let visibleRevisions = try await batteries.revisions(for: game.id)
        XCTAssertEqual(resume?.id, state.id)
        XCTAssertEqual(visibleRevisions, activeRevisions)
        await XCTAssertThrowsErrorAsync(try await batteries.restore(staleRevision)) { error in
            XCTAssertEqual(error as? LibraryError, .membershipChanged)
        }
        XCTAssertThrowsError(try states.load(staleState, game: game, for: core)) { error in
            guard case SaveStateLoadError.corrupt = error else { return XCTFail("Expected membership rejection: \(error)") }
        }
        let anotherID = Game(systemID: game.systemID, title: "Same content", contentFingerprint: fp, addedAt: Date(), generation: 1)
        XCTAssertThrowsError(try states.load(state, game: anotherID, for: core))
    }

    func testStaleContentDescriptorRejectsBeforeMovingDownloadedBytes() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = LibraryLocation(rootURL: root.appending(path: "Library"))
        try location.createDirectories()
        let store = InMemoryLibraryStore()
        let bytes = Data([1, 2, 3])
        let fp = try SHA256ContentHasher().hash(data: bytes).fingerprint
        let game = Game(systemID: .gameBoyAdvance, title: "Successor", contentFingerprint: fp, addedAt: Date(), generation: 1)
        try await store.games.insert(game, files: [])
        let staged = root.appending(path: "staged.gba")
        try bytes.write(to: staged)
        let descriptor = GameContentDescriptor.singleFile(fingerprint: fp, sizeInBytes: 3, fileName: "game.gba",
            systemID: game.systemID, uploadedAt: Date(), generation: 0)
        let ingestion = GameIngestion(store: store, location: location)
        await XCTAssertThrowsErrorAsync(try await ingestion.installDownloadedContent(gameID: game.id, stagedURL: staged, descriptor: descriptor)) { _ in }
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
        let files = try await store.games.files(for: game.id)
        XCTAssertTrue(files.isEmpty)
    }
}

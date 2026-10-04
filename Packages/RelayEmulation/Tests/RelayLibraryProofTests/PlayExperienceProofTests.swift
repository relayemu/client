// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  PlayExperienceProofTests.swift
//
//  1. Battery save: the Relay-authored SRAM counter fixture increments SRAM
//     byte 0 at boot; Relay snapshots it atomically, keeps the rollback copy,
//     and the next launch continues from the live copy (byte 0 == 2).
//  2. Save state: capture → play on → restore → the next frame equals the
//     frame at capture time (deterministic emulation); the state file is a
//     validated Relay container.
//  3. Rewind: history accumulates while running; stepping back moves the frame
//     back; memory is bounded. Timings and sizes are printed for the docs.
//  4. Fast-forward: the core's frame rate roughly doubles at 2×; the audio ring
//     buffer stays bounded; normal speed restores the frame rate.

import XCTest
import RelayDomain
import RelayLibrary
import RelayPersistence
import RelayEmulation
import RelayProvenanceAdapter

final class PlayExperienceProofTests: XCTestCase {
    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/Fixtures/ROMs")
    }
    static var counterROM: URL { fixturesRoot.appending(path: "relay-sram-counter/relay-sram-counter.gba") }
    static var testSuiteROM: URL { fixturesRoot.appending(path: "240p-test-suite-gba/240pee_mb.gba") }

    var root: URL!
    var location: LibraryLocation!
    var store: SQLiteLibraryStore!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.counterROM.path), "fixture missing")
        root = FileManager.default.temporaryDirectory.appending(path: "RelayPlayProof-\(UUID().uuidString)", directoryHint: .isDirectory)
        location = LibraryLocation(rootURL: root)
        try location.createDirectories()
        store = try SQLiteLibraryStore.open(at: location.databaseURL)
    }

    override func tearDown() {
        try? store.close()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func launch(_ rom: URL) async throws -> (EmulationSession, Game, BatterySaveManager, EmulatorCoreDescriptor) {
        let ingestion = GameIngestion(store: store, location: location)
        guard case .inserted(let game) = try await ingestion.ingestLocalFile(at: rom) else { throw XCTSkip("ingest failed") }
        let factory = ProvenanceDriverFactory()
        let launch = try await GameLaunchResolver(store: store, location: location, availableCores: factory.availableCores).resolve(gameID: game.id)
        let battery = BatterySaveManager(store: store, location: location)
        try await battery.prepareForLaunch(gameID: game.id, romBaseName: launch.contentURL.deletingPathExtension().lastPathComponent)
        let storage = EmulationStorage(batterySavesDirectory: battery.workingDirectory(for: game.id),
                                       saveStatesDirectory: location.saveStatesDirectory(forGame: game.id),
                                       firmwareDirectory: root.appending(path: "Firmware"))
        let session = EmulationSession(factory: factory, storage: storage,
                                       rewindConfiguration: RewindConfiguration(duration: 10, captureInterval: 0.1, memoryBudgetBytes: 48 * 1024 * 1024))
        try session.play(romURL: launch.contentURL, coreID: launch.core.id,
                             systemID: launch.game.systemID, audio: false)
        XCTAssertEqual(session.state, .running)
        return (session, game, battery, launch.core)
    }

    @MainActor
    private func relaunch(_ game: Game) async throws -> (EmulationSession, BatterySaveManager) {
        let factory = ProvenanceDriverFactory()
        let launch = try await GameLaunchResolver(store: store, location: location, availableCores: factory.availableCores).resolve(gameID: game.id)
        let battery = BatterySaveManager(store: store, location: location)
        try await battery.prepareForLaunch(gameID: game.id, romBaseName: launch.contentURL.deletingPathExtension().lastPathComponent)
        let storage = EmulationStorage(batterySavesDirectory: battery.workingDirectory(for: game.id),
                                       saveStatesDirectory: location.saveStatesDirectory(forGame: game.id),
                                       firmwareDirectory: root.appending(path: "Firmware"))
        let session = EmulationSession(factory: factory, storage: storage, rewindConfiguration: .disabled)
        try session.play(romURL: launch.contentURL, coreID: launch.core.id,
                             systemID: launch.game.systemID, audio: false)
        return (session, battery)
    }

    // MARK: 1. Battery save

    /// Waits until the core's battery bytes exist and byte 0 reaches `value`.
    @MainActor
    private func waitForCounter(_ session: EmulationSession, toReach value: UInt8) async -> Data? {
        var bytes: Data?
        for _ in 0..<50 {
            bytes = session.batterySaveBytes()
            if let b = bytes, !b.isEmpty, b[0] == value { return b }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return bytes
    }

    @MainActor
    func testBatterySaveIsCreatedSnapshottedAndContinuedAcrossLaunches() async throws {
        let (session, game, battery, _) = try await launch(Self.counterROM)
        // Fresh SRAM is 0xFF-filled: the counter ROM's boot increment wraps byte 0 to 0.
        let bootOptional = await waitForCounter(session, toReach: 0)
        let boot = try XCTUnwrap(bootOptional)
        XCTAssertEqual(boot.count, 32 * 1024, "SRAM_V marker → 32 KiB SRAM")
        XCTAssertEqual(boot[0], 0, "boot increment on a fresh 0xFF save")

        // Press A twice: the counter increments (input → game → battery memory).
        for expected: UInt8 in [1, 2] {
            session.press(.a); try await Task.sleep(for: .milliseconds(200)); session.release(.a)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(session.batterySaveBytes()?[0], expected)
        }

        // Snapshot at a safe point: canonical file + Save row, distinct from any save state.
        let saveOptional = try await battery.snapshot(gameID: game.id, data: session.batterySaveBytes())
        let save = try XCTUnwrap(saveOptional)
        XCTAssertEqual(save.sizeInBytes, 32 * 1024)
        XCTAssertEqual(save.location.relativePath, "Saves/\(game.id)/battery/current.sav")
        XCTAssertEqual(try Data(contentsOf: location.url(for: save.location))[0], 2)
        let states = try await store.saves.saveStates(for: game.id)
        XCTAssertTrue(states.isEmpty, "a battery snapshot never creates a SaveState row")
        session.stop()

        // Relaunch: the live copy the core loads carries the snapshot; the boot increment makes it 3.
        let (second, battery2) = try await relaunch(game)
        let afterRelaunch = await waitForCounter(second, toReach: 3)
        XCTAssertEqual(afterRelaunch?[0], 3)
        let save2Optional = try await battery2.snapshot(gameID: game.id, data: afterRelaunch)
        let save2 = try XCTUnwrap(save2Optional)
        XCTAssertEqual(save2.id, save.id, "one Save row per game")
        XCTAssertEqual(try Data(contentsOf: location.url(for: save2.location))[0], 3)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(battery2.previousSnapshotURL(for: game.id)))[0], 2, "rollback copy")
        second.stop()

        // Lose the live copy entirely: launch restores it from the canonical snapshot and continues (4).
        try FileManager.default.removeItem(at: battery2.workingDirectory(for: game.id))
        let (third, battery3) = try await relaunch(game)
        XCTAssertNotNil(battery3.liveSaveURL(for: game.id), "live copy restored before the core loaded")
        let afterRestore = await waitForCounter(third, toReach: 4)
        XCTAssertEqual(afterRestore?[0], 4)
        third.stop()
    }

    // MARK: 2. Save state

    @MainActor
    func testSaveStateRoundTripThroughTheContainer() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.testSuiteROM.path), "fixture missing")
        let (session, game, _, core) = try await launch(Self.testSuiteROM)
        let manager = SaveStateManager(store: store, location: location, artworkStore: ArtworkStore(location: location))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(session.supportsSaveStates)

        session.pause()
        let source = try XCTUnwrap(session.frameSource)
        let frameAtCapture = source.sampledChecksum()
        let payload = try session.captureState()
        let captureMillis = session.diagnostics.lastStateCaptureMillis
        print("RELAY-MEASURE state.bytes=\(payload.count) state.capture.ms=\(String(format: "%.2f", captureMillis))")
        XCTAssertGreaterThan(payload.count, 100_000, "a GBA machine state is a few hundred KB")
        let state = try await manager.create(kind: .manual, game: game, core: core, payload: payload, screenshot: nil)
        XCTAssertEqual(state.coreID, core.id)
        XCTAssertEqual(state.coreVersion, core.version)
        session.resume()

        // Move on: input changes the picture.
        session.press(.right); try await Task.sleep(for: .milliseconds(120)); session.release(.right)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNotEqual(source.sampledChecksum(), frameAtCapture)

        // Restore through the validated container while paused; one frame renders the restored picture.
        session.pause()
        let bytes = try manager.load(state, game: game, for: core)
        XCTAssertEqual(bytes, payload)
        try session.restoreState(bytes)
        print("RELAY-MEASURE state.restore.ms=\(String(format: "%.2f", session.diagnostics.lastStateRestoreMillis))")
        XCTAssertEqual(source.sampledChecksum(), frameAtCapture, "restored machine renders the captured frame")
        session.resume()

        // Wrong core version is refused before touching the core.
        let older = EmulatorCoreDescriptor(id: core.id, name: core.name, version: "0.0.1", license: core.license,
                                           supportedSystems: core.supportedSystems, capabilities: core.capabilities)
        XCTAssertThrowsError(try manager.load(state, game: game, for: older)) { XCTAssertEqual($0 as? SaveStateLoadError, .incompatible(state)) }
        session.stop()

        // The file on disk is a Relay container whose header matches the row.
        let header = try SaveStateContainer.readHeader(at: location.url(for: state.location))
        XCTAssertEqual(header.gameID, game.id)
        XCTAssertEqual(header.gameFingerprint, game.contentFingerprint, "format 2 carries the cross-device game identity")
        XCTAssertEqual(header.coreVersion, core.version)
        XCTAssertEqual(header.payloadLength, payload.count)
    }

    // MARK: 3. Rewind

    @MainActor
    func testRewindMovesBackInTimeWithinBudget() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.testSuiteROM.path), "fixture missing")
        let (session, _, _, _) = try await launch(Self.testSuiteROM)
        XCTAssertTrue(session.supportsRewind)
        try await Task.sleep(for: .milliseconds(1500))
        // Change the picture, then let history accumulate.
        session.press(.right); try await Task.sleep(for: .milliseconds(120)); session.release(.right)
        try await Task.sleep(for: .milliseconds(1500))
        let source = try XCTUnwrap(session.frameSource)
        let statsOptional = session.rewindStatistics
        let stats = try XCTUnwrap(statsOptional)
        print("RELAY-MEASURE rewind.entries=\(stats.entries) rewind.bytes=\(stats.bytes) rewind.bytesPerEntry=\(stats.entries > 0 ? stats.bytes / stats.entries : 0)")
        XCTAssertGreaterThanOrEqual(stats.entries, 20, "~3 s at 10 captures/s")
        XCTAssertLessThanOrEqual(stats.bytes, 48 * 1024 * 1024)
        let now = source.sampledChecksum()
        XCTAssertTrue(session.beginRewind())
        var steps = 0
        while session.rewindStep() { steps += 1; if steps >= 25 { break } }
        XCTAssertGreaterThanOrEqual(steps, 20)
        let back = source.sampledChecksum()
        XCTAssertNotEqual(back, now, "the picture moved back in time")
        session.endRewind()
        XCTAssertEqual(session.state, .running)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(session.rewindStatistics?.entries ?? 0, 0, "captures resumed after rewind")
        session.stop()
    }

    // MARK: 4. Fast-forward

    @MainActor
    func testFastForwardChangesFrameRateAndKeepsAudioBounded() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.testSuiteROM.path), "fixture missing")
        let (session, _, _, _) = try await launch(Self.testSuiteROM)
        XCTAssertTrue(session.supportsFastForward)
        try await Task.sleep(for: .milliseconds(2200))
        let normal = session.diagnostics.emulationFramesPerSecond
        session.setSpeed(.double)
        try await Task.sleep(for: .milliseconds(2200))
        let fast = session.diagnostics.emulationFramesPerSecond
        let buffered = session.diagnostics.audioBufferedBytes
        session.setSpeed(.normal)
        try await Task.sleep(for: .milliseconds(2200))
        let restored = session.diagnostics.emulationFramesPerSecond
        print("RELAY-MEASURE fps.normal=\(normal) fps.double=\(fast) fps.restored=\(restored) audioBuffered.double=\(buffered)")
        XCTAssertGreaterThan(normal, 50)
        XCTAssertGreaterThan(fast, normal * 1.5, "2× should roughly double the emulated frame rate")
        XCTAssertLessThan(restored, normal * 1.3)
        XCTAssertLessThan(buffered, 1 << 20, "ring buffer stays bounded during fast-forward")
        session.stop()
    }
}

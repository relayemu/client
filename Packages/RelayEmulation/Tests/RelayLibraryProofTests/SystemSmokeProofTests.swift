// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SystemSmokeProofTests.swift
//
//  Every system Relay declares playable must pass the same ten steps against
//  fixture, import it, launch it, receive video, produce audio where the
//  system has it, inject input, see the picture change, round-trip the battery
//  save, round-trip a save state, and relaunch cleanly.
//
//  No mock driver appears here. The fixtures are Relay-authored, CC0, and
//  behave the same on every system: byte 0 of the battery save counts
//  launches plus presses of A.

import XCTest
import RelayDomain
import RelayLibrary
import RelayPersistence
import RelayEmulation
import RelayCores

final class SystemSmokeProofTests: XCTestCase {

    /// One legal fixture per playable system.
    static let fixtures: [SystemID: String] = [
        .gameBoy: "relay-gb-counter/relay-gb-counter.gb",
        .gameBoyColor: "relay-gb-counter/relay-gbc-counter.gbc",
        .gameBoyAdvance: "relay-sram-counter/relay-sram-counter.gba",
        .nes: "relay-nes-counter/relay-nes-counter.nes",
        .snes: "relay-snes-counter/relay-snes-counter.sfc",
        .nintendoDS: "relay-ds-counter/relay-ds-counter.nds",
        .masterSystem: "relay-sms-counter/relay-sms-counter.sms",
        .gameGear: "relay-sms-counter/relay-gg-counter.gg",
        .pcEngine: "relay-pce-counter/relay-pce-counter.pce",
        .wonderSwan: "relay-ws-counter/relay-ws-counter.ws",
        .wonderSwanColor: "relay-ws-counter/relay-wsc-counter.wsc",
    ]

    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/Fixtures/ROMs")
    }

    private var root: URL!
    private var location: LibraryLocation!
    private var store: SQLiteLibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RelaySmoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        location = LibraryLocation(rootURL: root)
        try location.createDirectories()
        store = try SQLiteLibraryStore.open(at: location.databaseURL)
    }

    override func tearDown() {
        try? store.close()
        try? FileManager.default.removeItem(at: root)
        root = nil; location = nil; store = nil
    }

    /// Every system the catalog calls playable has a fixture. Without this a
    /// system could be enabled with nothing proving it runs.
    func testEveryPlayableSystemHasALegalFixture() throws {
        for system in SystemCatalog.playable {
            let name = try XCTUnwrap(Self.fixtures[system.id], "\(system.id) has no smoke fixture")
            let url = Self.fixturesRoot.appending(path: name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(system.id): fixture missing at \(name)")
        }
    }

    // MARK: The contract

    @MainActor
    func testGameBoySmokeContract() async throws { try await runSmokeContract(for: .gameBoy) }

    @MainActor
    func testGameBoyColorSmokeContract() async throws { try await runSmokeContract(for: .gameBoyColor) }

    @MainActor
    func testGameBoyAdvanceSmokeContract() async throws { try await runSmokeContract(for: .gameBoyAdvance) }

    @MainActor
    func testNESSmokeContract() async throws { try await runSmokeContract(for: .nes) }

    @MainActor
    func testSuperNESSmokeContract() async throws { try await runSmokeContract(for: .snes) }

    @MainActor
    func testNintendoDSSmokeContract() async throws { try await runSmokeContract(for: .nintendoDS) }

    @MainActor
    func testMasterSystemSmokeContract() async throws { try await runSmokeContract(for: .masterSystem) }

    @MainActor
    func testGameGearSmokeContract() async throws { try await runSmokeContract(for: .gameGear) }

    @MainActor
    func testPCEngineSmokeContract() async throws { try await runSmokeContract(for: .pcEngine) }

    @MainActor
    func testWonderSwanSmokeContract() async throws { try await runSmokeContract(for: .wonderSwan) }

    @MainActor
    func testWonderSwanColorSmokeContract() async throws { try await runSmokeContract(for: .wonderSwanColor) }

    // MARK: -

    @MainActor
    private func runSmokeContract(for systemID: SystemID) async throws {
        let descriptor = try XCTUnwrap(SystemCatalog.descriptor(for: systemID))
        let fixture = Self.fixturesRoot.appending(path: try XCTUnwrap(Self.fixtures[systemID]))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "fixture missing")

        // 1. Identify — from the bytes, and as the system we expect.
        let identified = try ContentIdentifier.standard.identify(fileAt: fixture)
        XCTAssertEqual(identified.systemID, systemID, "identification disagrees with the fixture")
        XCTAssertEqual(identified.confidence, .header)

        // 2. Import into the managed library.
        let ingestion = GameIngestion(store: store, location: location)
        guard case .inserted(let game) = try await ingestion.ingestLocalFile(at: fixture) else {
            return XCTFail("\(systemID): fixture did not import")
        }
        XCTAssertEqual(game.systemID, systemID)

        // 3. Launch through the real core.
        let factory = RelayCores.standardFactory()
        let core = try XCTUnwrap(factory.availableCores.first { $0.supports(systemID) },
                                 "\(systemID) is playable but no registered core claims it")
        XCTAssertEqual(core.id, descriptor.preferredCoreID)

        var (session, battery) = try await launch(game: game)
        XCTAssertEqual(session.state, .running)

        // 4. Video: a picture of the size the catalog promises, and a live one.
        let frame = try XCTUnwrap(session.frameSource?.frameDescriptor)
        let screen = try XCTUnwrap(descriptor.screens.first)
        XCTAssertEqual(frame.width, screen.width, "\(systemID): picture width")
        XCTAssertEqual(frame.height, screen.height, "\(systemID): picture height")
        XCTAssertEqual(frame.aspectRatio, screen.aspectRatio, accuracy: 0.001,
                       "\(systemID): the presenter would draw the wrong shape")

        // Let the picture settle, and let the once-a-second diagnostics timer
        // report the rate the core is actually running audio at.
        try await Task.sleep(for: .milliseconds(1200))
        let beforeInput = checksum(of: session)
        XCTAssertNotEqual(beforeInput, 0, "\(systemID): the core produced no picture")
        // Fresh battery memory is 0xFF-filled, so the boot increment wraps byte 0
        // to 0; read what the fixture actually holds rather than assuming. A
        // system whose cartridges carry no save memory (PC Engine HuCards) has
        // nothing to read, and the driver must say so rather than invent bytes.
        let hasBattery = descriptor.saveMemory == .cartridge
        let atBoot: UInt8
        if hasBattery {
            atBoot = try XCTUnwrap(session.batterySaveBytes(), "\(systemID): no battery save after boot")[0]
        } else {
            XCTAssertNil(session.batterySaveBytes(), "\(systemID): a battery save for a system without save memory")
            atBoot = 0
        }

        // 5. Audio: the core reports the rate it runs at.
        XCTAssertGreaterThan(session.diagnostics.audioSampleRate, 0, "\(systemID): no audio rate")

        // 6 & 7. Input changes the picture. The fixtures scroll the background
        // by their counter, so a press of A is visible in the framebuffer.
        session.press(.a)
        try await Task.sleep(for: .milliseconds(200))
        session.release(.a)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(checksum(of: session), beforeInput,
                          "\(systemID): pressing A changed nothing on screen")

        // 7b. Touch, where the hardware has it: a touch on the touch screen is
        // visible in that screen's picture, and only there.
        if let touchIndex = descriptor.screens.firstIndex(where: \.acceptsTouch) {
            XCTAssertTrue(core.capabilities.contains(.touchInput), "\(systemID): touch screen without touch input")
            XCTAssertEqual(session.screenFrameSources.count, descriptor.screens.count,
                           "\(systemID): one frame source per screen")
            let touchScreen = session.screenFrameSources[touchIndex]
            let beforeTouch = touchScreen.sampledChecksum()
            let otherBefore = checksum(of: session)
            session.touch(screenIndex: touchIndex, x: 100, y: 60)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNotEqual(touchScreen.sampledChecksum(), beforeTouch, "\(systemID): the touch changed nothing on the touch screen")
            XCTAssertEqual(checksum(of: session), otherBefore, "\(systemID): a touch changed the other screen")
            session.releaseTouch()
            try await Task.sleep(for: .milliseconds(100))
        }

        // 8. Battery save: the fixture counted the launch and the press.
        if hasBattery {
            let live = try XCTUnwrap(session.batterySaveBytes(), "\(systemID): no battery save")
            XCTAssertGreaterThanOrEqual(live.count, 8 * 1024, "\(systemID): battery save too small")
            XCTAssertEqual(live[0], atBoot &+ 1, "\(systemID): the press did not reach the battery save")
        }

        // 9. Save state: capture, change the picture with another press, restore,
        // and land back on the captured frame. The fixture's picture depends only
        // on its counter, so consecutive frames are identical and the comparison
        // is exact.
        XCTAssertTrue(core.capabilities.contains(.saveStates))
        XCTAssertTrue(session.supportsSaveStates, "\(systemID): claims save states but vends none")
        session.pause()
        let captured = try session.captureState()
        XCTAssertFalse(captured.isEmpty)
        let atCapture = checksum(of: session)
        session.resume()
        session.press(.a)
        try await Task.sleep(for: .milliseconds(200))
        session.release(.a)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(checksum(of: session), atCapture, "\(systemID): the second press changed nothing")
        session.pause()
        try session.restoreState(captured)
        XCTAssertEqual(checksum(of: session), atCapture,
                       "\(systemID): restoring a state did not restore the picture")
        session.resume()
        try await Task.sleep(for: .milliseconds(200))

        // Persist whatever the core holds now, the way the product does, then stop.
        let final = hasBattery ? try XCTUnwrap(session.batterySaveBytes()) : Data()
        if hasBattery { _ = try await battery.snapshot(gameID: game.id, data: final) }
        session.stop()
        XCTAssertEqual(session.state, .stopped)

        // 10. Relaunch: the save came back, so the fixture counts on from it; a
        // system without save memory simply boots again and draws.
        (session, battery) = try await launch(game: game)
        try await Task.sleep(for: .milliseconds(600))
        if hasBattery {
            let afterRelaunch = try XCTUnwrap(session.batterySaveBytes())
            XCTAssertEqual(afterRelaunch[0], final[0] &+ 1,
                           "\(systemID): the battery save did not survive the relaunch")
        } else {
            XCTAssertNotEqual(checksum(of: session), 0, "\(systemID): no picture after the relaunch")
        }
        session.stop()
    }

    // MARK: Harness

    @MainActor
    private func launch(game: Game) async throws -> (EmulationSession, BatterySaveManager) {
        let factory = RelayCores.standardFactory()
        let resolver = GameLaunchResolver(store: store, location: location,
                                          availableCores: factory.availableCores)
        let resolved = try await resolver.resolve(gameID: game.id)
        let battery = BatterySaveManager(store: store, location: location)
        try await battery.prepareForLaunch(gameID: game.id,
                                           romBaseName: resolved.contentURL.deletingPathExtension().lastPathComponent)
        let storage = EmulationStorage(batterySavesDirectory: battery.workingDirectory(for: game.id),
                                       saveStatesDirectory: location.saveStatesDirectory(forGame: game.id),
                                       firmwareDirectory: root.appending(path: "Firmware"))
        let session = EmulationSession(factory: factory, storage: storage, rewindConfiguration: .disabled)
        try session.play(romURL: resolved.contentURL, coreID: resolved.core.id,
                         systemID: resolved.game.systemID, audio: false)
        return (session, battery)
    }

    /// The framebuffer as a number, sampled straight from the core rather than
    /// waiting for the once-a-second diagnostics timer.
    @MainActor
    private func checksum(of session: EmulationSession) -> UInt32 {
        session.frameSource?.sampledChecksum() ?? 0
    }
}

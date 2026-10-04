// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayEmulation

/// A driver that records calls; no emulator involved.
@MainActor
final class FakeDriver: EmulationDriver {
    let descriptor = EmulatorCoreDescriptor(id: "fake", name: "Fake", version: "0", license: "MIT",
                                            supportedSystems: [.gameBoyAdvance], capabilities: [])
    var frameSource: VideoFrameSource? = nil
    var log: [String] = []
    var failLoad = false

    func load(romURL: URL, storage: EmulationStorage) throws {
        log.append("load")
        if failLoad { throw EmulationError.loadFailed("nope") }
    }
    func start() throws { log.append("start") }
    func setPaused(_ paused: Bool) { log.append(paused ? "pause" : "resume") }
    func stop() { log.append("stop") }
    func press(_ input: EmulationInput) { log.append("press:\(input.rawValue)") }
    func release(_ input: EmulationInput) { log.append("release:\(input.rawValue)") }
    func startAudio() throws { log.append("audio-start") }
    func stopAudio() { log.append("audio-stop") }
    func sampleDiagnostics() -> EmulationDiagnostics { EmulationDiagnostics() }
}

@MainActor
final class FakeFactory: EmulationDriverFactory {
    let driver = FakeDriver()
    var availableCores: [EmulatorCoreDescriptor] { [driver.descriptor] }
    func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver {
        guard coreID == "fake" else { throw EmulationError.coreUnavailable(coreID) }
        return driver
    }
}

@MainActor
final class EmulationSessionTests: XCTestCase {
    private func makeSession() -> (EmulationSession, FakeFactory, URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let rom = tmp.appendingPathComponent("game.gba")
        FileManager.default.createFile(atPath: rom.path, contents: Data([0x00]))
        let storage = EmulationStorage(batterySavesDirectory: tmp, saveStatesDirectory: tmp, firmwareDirectory: tmp)
        let factory = FakeFactory()
        return (EmulationSession(factory: factory, storage: storage), factory, rom)
    }

    func testPlayPauseResumeStopSequence() throws {
        let (session, factory, rom) = makeSession()
        XCTAssertEqual(session.state, .idle)
        try session.play(romURL: rom, coreID: "fake", systemID: .gameBoyAdvance)
        XCTAssertEqual(session.state, .running)
        session.pause()
        XCTAssertEqual(session.state, .paused)
        session.resume()
        XCTAssertEqual(session.state, .running)
        session.press(.a); session.release(.a)
        session.stop()
        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(factory.driver.log, ["load", "start", "audio-start", "pause", "audio-stop", "resume", "audio-start", "press:a", "release:a", "audio-stop", "stop"])
    }

    func testMissingRomFails() {
        let (session, _, rom) = makeSession()
        let missing = rom.deletingLastPathComponent().appendingPathComponent("missing.gba")
        XCTAssertThrowsError(try session.play(romURL: missing, coreID: "fake", systemID: .gameBoyAdvance))
        XCTAssertEqual(session.state, .failed(.romNotFound("missing.gba")))
    }

    func testUnknownCoreFails() {
        let (session, _, rom) = makeSession()
        XCTAssertThrowsError(try session.play(romURL: rom, coreID: "nope", systemID: .gameBoyAdvance))
        if case .failed = session.state {} else { XCTFail("expected failed state") }
    }

    func testLoadFailureIsReported() {
        let (session, factory, rom) = makeSession()
        factory.driver.failLoad = true
        XCTAssertThrowsError(try session.play(romURL: rom, coreID: "fake", systemID: .gameBoyAdvance))
        XCTAssertEqual(session.state, .failed(.loadFailed("nope")))
    }
}

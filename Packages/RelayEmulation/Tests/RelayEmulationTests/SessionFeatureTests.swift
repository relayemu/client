// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SessionFeatureTests.swift — capability gating of save states, speed and
//  rewind through EmulationSession, with a fake driver and serializer.

import XCTest
import RelayDomain
@testable import RelayEmulation

final class FakeSerializer: EmulationStateSerializer, @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt32 = 0
    var frames = 0
    func serializeState() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        var d = Data(repeating: 0, count: 4096)
        withUnsafeBytes(of: counter.littleEndian) { d.replaceSubrange(0..<4, with: $0) }
        return d
    }
    func restoreState(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        counter = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
    func runSingleFrame() { lock.lock(); frames += 1; lock.unlock() }
    var value: UInt32 { lock.lock(); defer { lock.unlock() }; return counter }
}

@MainActor
final class FeatureDriver: EmulationDriver {
    let descriptor: EmulatorCoreDescriptor
    var frameSource: VideoFrameSource? = nil
    var stateSerializer: (any EmulationStateSerializer)?
    var log: [String] = []
    let serializer = FakeSerializer()
    let speedPresets: Set<EmulationSpeed>

    init(capabilities: CoreCapabilities, speedPresets: Set<EmulationSpeed>? = nil) {
        descriptor = EmulatorCoreDescriptor(id: "feature", name: "Feature", version: "1", license: "MIT",
                                            supportedSystems: [.gameBoyAdvance], capabilities: capabilities)
        self.speedPresets = speedPresets ?? (capabilities.contains(.fastForward) ? [.normal, .double, .maximum] : [.normal])
    }
    func load(romURL: URL, storage: EmulationStorage) throws {
        log.append("load")
        if descriptor.capabilities.contains(.saveStates) { stateSerializer = serializer }
    }
    func start() throws { log.append("start") }
    func setPaused(_ paused: Bool) { log.append(paused ? "pause" : "resume") }
    func stop() { log.append("stop") }
    func press(_ input: EmulationInput) {}
    func release(_ input: EmulationInput) {}
    func startAudio() throws { log.append("audio-start") }
    func stopAudio() { log.append("audio-stop") }
    func flushAudio() { log.append("audio-flush") }
    func setSpeed(_ speed: EmulationSpeed) { log.append("speed:\(speed.rawValue)") }
    var supportedSpeeds: Set<EmulationSpeed> { speedPresets }
    func sampleDiagnostics() -> EmulationDiagnostics { EmulationDiagnostics() }
}

@MainActor
final class FeatureFactory: EmulationDriverFactory {
    let driver: FeatureDriver
    init(capabilities: CoreCapabilities, speedPresets: Set<EmulationSpeed>? = nil) {
        driver = FeatureDriver(capabilities: capabilities, speedPresets: speedPresets)
    }
    var availableCores: [EmulatorCoreDescriptor] { [driver.descriptor] }
    func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver { driver }
}

@MainActor
final class SessionFeatureTests: XCTestCase {
    private func makeSession(_ capabilities: CoreCapabilities,
                             rewind: RewindConfiguration = RewindConfiguration(duration: 2, captureInterval: 0.02, memoryBudgetBytes: 4 * 1024 * 1024),
                             speedPresets: Set<EmulationSpeed>? = nil) throws -> (EmulationSession, FeatureFactory) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let rom = tmp.appendingPathComponent("game.gba")
        FileManager.default.createFile(atPath: rom.path, contents: Data([0x00]))
        let storage = EmulationStorage(batterySavesDirectory: tmp, saveStatesDirectory: tmp, firmwareDirectory: tmp)
        let factory = FeatureFactory(capabilities: capabilities, speedPresets: speedPresets)
        let session = EmulationSession(factory: factory, storage: storage, rewindConfiguration: rewind)
        try session.play(romURL: rom, coreID: "feature", systemID: .gameBoyAdvance, audio: false)
        return (session, factory)
    }

    func testCapabilitiesGateEverything() throws {
        let (session, factory) = try makeSession([])
        XCTAssertFalse(session.supportsSaveStates)
        XCTAssertFalse(session.supportsFastForward)
        XCTAssertFalse(session.supportsRewind)
        XCTAssertThrowsError(try session.captureState()) { XCTAssertEqual($0 as? EmulationError, .unsupported("save states")) }
        XCTAssertThrowsError(try session.restoreState(Data())) { XCTAssertEqual($0 as? EmulationError, .unsupported("save states")) }
        session.setSpeed(.double)
        XCTAssertEqual(session.speed, .normal)
        XCTAssertFalse(session.beginRewind())
        XCTAssertFalse(factory.driver.log.contains { $0.hasPrefix("speed:") })
        session.stop()
    }

    func testCaptureAndRestore() throws {
        let (session, factory) = try makeSession([.saveStates])
        XCTAssertTrue(session.supportsSaveStates)
        XCTAssertFalse(session.supportsRewind, "rewind needs the rewind capability, not only save states")
        let first = try session.captureState()
        _ = try session.captureState()
        XCTAssertNotEqual(factory.driver.serializer.value, 1)
        session.pause()
        try session.restoreState(first)
        XCTAssertEqual(factory.driver.serializer.value, 1)
        XCTAssertEqual(factory.driver.serializer.frames, 1, "one frame rendered while paused so the picture updates")
        XCTAssertTrue(factory.driver.log.contains("audio-flush"))
        XCTAssertGreaterThanOrEqual(session.diagnostics.lastStateRestoreMillis, 0)
        session.resume()
        try session.restoreState(first)
        XCTAssertEqual(factory.driver.serializer.frames, 1, "no extra frame while running")
        session.stop()
    }

    func testSpeedPresets() throws {
        let (session, factory) = try makeSession([.fastForward])
        session.setSpeed(.double)
        XCTAssertEqual(session.speed, .double)
        session.setSpeed(.maximum)
        session.setSpeed(.normal)
        XCTAssertEqual(factory.driver.log.filter { $0.hasPrefix("speed:") }, ["speed:double", "speed:maximum", "speed:normal"])
        session.stop()
        XCTAssertEqual(session.speed, .normal)
    }

    func testUnsupportedSpeedPresetIsAbsentAndIgnored() throws {
        let (session, factory) = try makeSession([.fastForward], speedPresets: [.normal, .double])
        XCTAssertEqual(session.supportedSpeeds, [.normal, .double])
        session.setSpeed(.quarter)
        XCTAssertEqual(session.speed, .normal)
        XCTAssertFalse(factory.driver.log.contains("speed:quarter"))
        session.setSpeed(.double)
        XCTAssertEqual(session.speed, .double)
        session.stop()
    }

    func testCheatsStayHiddenWhenTheAdapterAdvertisesNoSupportedFormat() throws {
        let (session, _) = try makeSession([.cheats])
        XCTAssertFalse(session.supportsCheats)
        XCTAssertEqual(
            session.validateCheat(CheatDefinition(label: "Test", code: "01234567", format: .gameShark)),
            .unsupportedFormat
        )
        XCTAssertThrowsError(
            try session.applyCheats([CheatDefinition(label: "Test", code: "01234567", format: .gameShark, isEnabled: true)])
        )
        XCTAssertNoThrow(try session.applyCheats([]), "clearing runtime cheats is always a safe no-op")
        session.stop()
    }

    func testRewindCapturesAndStepsBack() async throws {
        let (session, factory) = try makeSession([.saveStates, .rewind])
        XCTAssertTrue(session.supportsRewind)
        try await Task.sleep(for: .milliseconds(400))
        let stats = try XCTUnwrap(session.rewindStatistics)
        XCTAssertGreaterThan(stats.entries, 3, "captures at 50 Hz for 0.4 s")
        XCTAssertLessThanOrEqual(stats.entries, 100)
        let before = factory.driver.serializer.value
        XCTAssertTrue(session.beginRewind())
        XCTAssertTrue(session.isRewinding)
        XCTAssertEqual(session.state, .paused)
        XCTAssertTrue(session.rewindStep())
        XCTAssertTrue(session.rewindStep())
        XCTAssertLessThan(factory.driver.serializer.value, before, "state moved back in time")
        XCTAssertEqual(factory.driver.serializer.frames, 2)
        session.endRewind()
        XCTAssertFalse(session.isRewinding)
        XCTAssertEqual(session.state, .running)
        XCTAssertTrue(factory.driver.log.contains("audio-flush"))
        // A state load starts a new timeline.
        let snapshot = try session.captureState()
        try session.restoreState(snapshot)
        XCTAssertEqual(session.rewindStatistics?.entries, 0)
        session.stop()
        XCTAssertNil(session.rewindStatistics)
    }

    func testRewindDisabledByConfiguration() throws {
        let (session, _) = try makeSession([.saveStates, .rewind], rewind: .disabled)
        XCTAssertFalse(session.supportsRewind)
        XCTAssertFalse(session.beginRewind())
        session.stop()
    }
}

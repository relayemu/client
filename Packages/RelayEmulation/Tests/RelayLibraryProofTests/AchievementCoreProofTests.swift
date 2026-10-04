// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
import RelayEmulation
import RelayCores

/// Real shipped cores and Relay-authored CC0 ROMs. No RA service or account.
@MainActor
final class AchievementCoreProofTests: XCTestCase {
    func testGameBoy() async throws { try await exercise(.gameBoy, region: .workRAM) }
    func testGameBoyColor() async throws { try await exercise(.gameBoyColor, region: .workRAM) }
    func testGameBoyAdvance() async throws { try await exercise(.gameBoyAdvance, region: .internalRAM) }
    func testGameBoyAdvanceSaveRAM() async throws { try await exercise(.gameBoyAdvance, region: .saveRAM) }
    func testNES() async throws { try await exercise(.nes, region: .addressSpace) }
    func testSNES() async throws { try await exercise(.snes, region: .workRAM) }
    func testDS() async throws { try await exercise(.nintendoDS, region: .workRAM) }
    func testMasterSystem() async throws { try await exercise(.masterSystem, region: .workRAM) }
    func testGameGear() async throws { try await exercise(.gameGear, region: .workRAM) }
    func testPCEngine() async throws { try await exercise(.pcEngine, region: .workRAM) }
    func testWonderSwan() async throws { try await exercise(.wonderSwan, region: .workRAM) }
    func testWonderSwanColor() async throws { try await exercise(.wonderSwanColor, region: .workRAM) }

    func testHardcoreEnforcementInAllThreeNativeAdapters() async throws {
        for (system, region) in [(SystemID.gameBoyAdvance, AchievementMemoryRegion.internalRAM), (.nes, .addressSpace), (.nintendoDS, .workRAM)] {
            try await exercise(system, region: region, hardcore: true)
        }
    }

    private func exercise(_ system: SystemID, region: AchievementMemoryRegion, hardcore: Bool = false) async throws {
        let fixture = SystemSmokeProofTests.fixturesRoot.appending(path: try XCTUnwrap(SystemSmokeProofTests.fixtures[system]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        let root = FileManager.default.temporaryDirectory.appending(path: "RelayAchievementCore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = EmulationStorage(batterySavesDirectory: root.appending(path: "battery"),
                                       saveStatesDirectory: root.appending(path: "states"),
                                       firmwareDirectory: root.appending(path: "firmware"))
        let factory = RelayCores.standardFactory()
        let core = try XCTUnwrap(factory.availableCores.first { $0.supports(system) })
        let runtime = NativeMemoryProbe(region: region)
        let slot = AchievementRuntimeSlot(mode: hardcore ? .hardcore : .casual); slot.attach(runtime)
        let session = EmulationSession(factory: factory, storage: storage)
        defer { session.stop() }
        try session.play(romURL: fixture, coreID: core.id, systemID: system, audio: false, achievements: slot)
        try await Task.sleep(for: .milliseconds(700))
        session.pause()
        if system == .gameBoyAdvance && region == .saveRAM {
            let before = try XCTUnwrap(session.batterySaveBytes()?.first)
            XCTAssertEqual(runtime.firstByte, before)
            session.resume()
            session.press(.a)
            try await Task.sleep(for: .milliseconds(200))
            session.release(.a)
            try await Task.sleep(for: .milliseconds(100))
            session.pause()
            XCTAssertEqual(runtime.firstByte, before &+ 1)
        }
        let serializer = try XCTUnwrap(session.stateSerializer)
        let state = try serializer.serializeState()
        let split = try AchievementStateEnvelope.split(state)
        XCTAssertNotNil(split.progress, "\(system): achievement state missing")
        XCTAssertGreaterThan(runtime.frames, 5, "\(system): no real frame evaluation")
        XCTAssertTrue(runtime.readWasValid, "\(system): native RAM unavailable")
        XCTAssertTrue(runtime.invalidReadWasRejected, "\(system): unbounded native RAM read")
        let beforePreview = runtime.frames
        serializer.runSingleFrame()
        XCTAssertEqual(runtime.frames, beforePreview, "\(system): preview frame evaluated achievements")
        if hardcore {
            XCTAssertTrue(session.hardcoreEnabled)
            XCTAssertTrue(session.supportsSaveStates)
            XCTAssertFalse(session.supportsStateLoading)
            XCTAssertFalse(session.supportsRewind)
            XCTAssertFalse(session.supportsCheats)
            XCTAssertThrowsError(try session.applyCheats([.init(label: "Fixture", code: "00000000 00000000", format: .gameShark, isEnabled: true)]))
            XCTAssertFalse(session.beginRewind())
            XCTAssertFalse(session.supportedSpeeds.contains(.half))
            XCTAssertFalse(session.supportedSpeeds.contains(.quarter))
            session.setSpeed(.half); XCTAssertEqual(session.speed, .normal)
            session.setSpeed(.quarter); XCTAssertEqual(session.speed, .normal)
            XCTAssertThrowsError(try session.restoreState(state))
            XCTAssertThrowsError(try serializer.restoreState(state), "Direct serializer access must also be guarded")
            session.continueInCasual()
            XCTAssertFalse(session.hardcoreEnabled)
            XCTAssertTrue(session.supportsStateLoading)
        }
        try serializer.restoreState(state)
        XCTAssertEqual(runtime.lastRestore, split.progress)
        try serializer.restoreState(split.core)
        XCTAssertNil(runtime.lastRestore, "\(system): legacy state must reset achievement progress")
        session.stop()
        let stopped = runtime.frames
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runtime.frames, stopped)
        XCTAssertThrowsError(try serializer.serializeState())
    }
}

private final class NativeMemoryProbe: EmulationAchievementRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private let region: AchievementMemoryRegion
    private var count = 0
    private var valid = false
    private var rejected = false
    private var restored: Data?
    private var byte: UInt8 = 0
    init(region: AchievementMemoryRegion) { self.region = region }
    var frames: Int { locked { count } }
    var readWasValid: Bool { locked { valid } }
    var invalidReadWasRejected: Bool { locked { rejected } }
    var lastRestore: Data? { locked { restored } }
    var firstByte: UInt8 { locked { byte } }
    func evaluateFrame(readMemory: AchievementMemoryReader) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let readable = bytes.withUnsafeMutableBytes { readMemory(region, 0, $0) == 4 }
        let sampled = bytes[0]
        let bounded = bytes.withUnsafeMutableBytes { readMemory(region, UInt32.max, $0) == 0 }
        locked { count += 1; valid = readable; rejected = bounded; byte = sampled }
    }
    func captureProgress() -> Data? { locked { Data(String(count).utf8) } }
    func restoreProgress(_ data: Data?) { locked { restored = data } }
    func resetProgress() { locked { restored = nil } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

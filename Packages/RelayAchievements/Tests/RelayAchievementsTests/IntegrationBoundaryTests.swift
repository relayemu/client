// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayAchievements

final class IntegrationBoundaryTests: XCTestCase {
    func testSecureSessionAndOutboxAreRemovedAndLateCallbacksAreFenced() async throws {
        let store = MemorySecureStore()
        let vault = AchievementVault(store: store)
        let generation = await vault.currentGeneration()
        let credentials = AchievementCredentials(username: "fixture", token: "fixture-session")
        let award = PendingAchievementAward(username: "fixture", achievementID: 1, gameHash: String(repeating: "a", count: 32), earnedAt: Date())
        try await vault.save(credentials, generation: generation)
        try await vault.record(award, generation: generation)
        try await vault.record(award, generation: generation)
        let saved = try await vault.credentials()
        let pending = try await vault.pending(username: "FIXTURE")
        XCTAssertEqual(saved, credentials)
        XCTAssertEqual(pending.count, 1)
        XCTAssertFalse(String(decoding: try XCTUnwrap(store.read("session")), as: UTF8.self).contains("password"))
        try await vault.disconnect()
        XCTAssertNil(try store.read("session")); XCTAssertNil(try store.read("pending"))
        do { try await vault.save(credentials, generation: generation); XCTFail("Stale login") }
        catch { XCTAssertEqual(error as? AchievementServiceError, .cancelled) }
        do { try await vault.record(award, generation: generation); XCTFail("Stale award") }
        catch { XCTAssertEqual(error as? AchievementServiceError, .cancelled) }
        XCTAssertNil(try store.read("session")); XCTAssertNil(try store.read("pending"))
    }

    func testFailedKeychainRemovalIsReportedAndStillInvalidatesGeneration() async throws {
        let store = MemorySecureStore(); let vault = AchievementVault(store: store)
        let generation = await vault.currentGeneration()
        store.failsRemoval = true
        do { try await vault.disconnect(); XCTFail("Must report removal failure") }
        catch { XCTAssertEqual(error as? AchievementServiceError, .storage) }
        let current = await vault.currentGeneration()
        XCTAssertNotEqual(current, generation)
        store.failsRemoval = false
        try await vault.disconnect()
    }

    func testStateEnvelopeLegacyRoundTripAndCorruption() throws {
        let core = Data([1, 2, 3, 4]); let progress = Data([9, 8, 7])
        let legacy = try AchievementStateEnvelope.split(core)
        XCTAssertEqual(legacy.core, core); XCTAssertNil(legacy.progress)
        var wrapped = AchievementStateEnvelope.append(to: core, progress: progress)
        let parts = try AchievementStateEnvelope.split(wrapped)
        XCTAssertEqual(parts.core, core); XCTAssertEqual(parts.progress, progress)
        wrapped[core.count] ^= 1
        XCTAssertThrowsError(try AchievementStateEnvelope.split(wrapped))
        XCTAssertThrowsError(try AchievementStateEnvelope.split(Data("RelayAchState0001".utf8)))
    }

    func testMemoryRegionsCrossBoundaryShortReadAndUnsupported() {
        var bytes = [UInt8](repeating: 0, count: 4)
        var calls: [(AchievementMemoryRegion, UInt32, Int)] = []
        let count = bytes.withUnsafeMutableBytes { raw in
            AchievementSystem.read(system: .gameBoyAdvance, address: 0x7ffe, buffer: raw) { region, offset, output in
                calls.append((region, offset, output.count))
                output.initializeMemory(as: UInt8.self, repeating: region == .internalRAM ? 1 : 2)
                return output.count
            }
        }
        XCTAssertEqual(count, 4); XCTAssertEqual(bytes, [1, 1, 2, 2])
        XCTAssertEqual(calls.map(\.0), [.internalRAM, .workRAM]); XCTAssertEqual(calls.map(\.1), [0x7ffe, 0])
        let short = bytes.withUnsafeMutableBytes { raw in
            AchievementSystem.read(system: .gameBoyAdvance, address: 0x7fff, buffer: raw) { _, _, _ in 0 }
        }
        XCTAssertEqual(short, 0)
        for (system, address) in [(SystemID.gameBoyAdvance, UInt32.max), (.nintendoDS, 0x400000), (.pcEngine, 0x2000)] {
            let invalid = bytes.withUnsafeMutableBytes { raw in
                AchievementSystem.read(system: system, address: address, buffer: raw) { _, _, _ in XCTFail("Unmapped read"); return 4 }
            }
            XCTAssertEqual(invalid, 0)
        }
    }

    func testCasualPolicyAndRewindCannotEvaluatePreviewFrames() {
        let runtime = CountingRuntime(); let slot = AchievementRuntimeSlot()
        slot.restoreProgress(Data([42])); slot.attach(runtime)
        XCTAssertEqual(runtime.restored, Data([42]))
        slot.evaluateFrame { _, _, _ in 0 }; XCTAssertEqual(runtime.frames, 1)
        slot.setPreviewing(true); slot.evaluateFrame { _, _, _ in 0 }; XCTAssertEqual(runtime.frames, 1)
        slot.setPreviewing(false); slot.evaluateFrame { _, _, _ in 0 }; XCTAssertEqual(runtime.frames, 2)
        slot.resetProgress()
        slot.evaluateFrame { _, _, _ in 0 }; XCTAssertEqual(runtime.frames, 3)
        XCTAssertFalse(AchievementClientValidation.isCurrentVersionApproved)
    }

    func testTransportOnlyAcceptsOfficialTLSAPI() {
        XCTAssertTrue(AchievementURLSessionTransport.accepts(URL(string: "https://retroachievements.org/dorequest.php")!))
        for url in ["http://retroachievements.org/dorequest.php", "https://evil.test/dorequest.php", "https://retroachievements.org/dorequest.php?t=secret", "https://user:password@retroachievements.org/dorequest.php", "https://retroachievements.org:444/dorequest.php"] {
            XCTAssertFalse(AchievementURLSessionTransport.accepts(URL(string: url)!))
        }
    }
}

private final class CountingRuntime: EmulationAchievementRuntime, @unchecked Sendable {
    var frames = 0
    var restored: Data?
    func evaluateFrame(readMemory: AchievementMemoryReader) { frames += 1 }
    func captureProgress() -> Data? { restored }
    func restoreProgress(_ data: Data?) { restored = data }
    func resetProgress() { restored = nil }
}

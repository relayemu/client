// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayAchievements

final class RuntimeTests: XCTestCase {
    func testHardcoreRapidPauseProtectionIsOfficialAndCasualIsUnrestricted() async throws {
        let vault = AchievementVault(store: MemorySecureStore())
        let runtime = RcheevosRuntime(transport: FixtureTransport(), vault: vault,
                                     generation: await vault.currentGeneration(), userAgent: "Relay/1.0.0", mode: .hardcore)
        defer { runtime.close() }
        _ = try await runtime.login(username: "RelayFixture", token: "fixture-session")
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try await loadFixtureGame(runtime, romURL: url)
        func frame() { runtime.evaluateFrame { _, _, target in target.initializeMemory(as: UInt8.self, repeating: 0); return target.count } }
        for _ in 0..<600 { frame() }
        XCTAssertTrue(runtime.canPause())
        frame()
        XCTAssertFalse(runtime.canPause(), "Rapid pause/resume must not approximate frame advance")
        for _ in 0..<600 { frame() }
        XCTAssertTrue(runtime.canPause())
        runtime.disableHardcore(); frame()
        XCTAssertTrue(runtime.canPause())
    }

    func testHardcoreEvaluationIndicatorsLeaderboardsAndModeBoundOfflineReplay() async throws {
        let transport = FixtureTransport(); await transport.setCompetitive()
        let vault = AchievementVault(store: MemorySecureStore())
        let generation = await vault.currentGeneration()
        let runtime = RcheevosRuntime(transport: transport, vault: vault, generation: generation,
                                     userAgent: "Relay/1.0.0", mode: .hardcore)
        defer { runtime.close() }
        let credentials = try await runtime.login(username: "RelayFixture", token: "fixture-session")
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try await loadFixtureGame(runtime, romURL: url)
        var memory = [UInt8](repeating: 0, count: 64)
        func frame() {
            runtime.evaluateFrame { _, offset, target in
                for i in 0..<target.count { target[i] = memory[Int(offset) + i] }
                return target.count
            }
        }
        frame()
        XCTAssertEqual(runtime.snapshot()?.mode, .hardcore)
        XCTAssertEqual(runtime.snapshot()?.richPresence, "Playing Relay Fixture")
        XCTAssertEqual(runtime.snapshot()?.leaderboards.count, 1)
        memory[4] = 1; frame()
        XCTAssertEqual(runtime.takeEvents().challenges.keys.sorted(), [4])
        memory[2] = 4; memory[6] = 1; frame()
        XCTAssertEqual(runtime.takeEvents().progress?.percent, 80)
        XCTAssertEqual(runtime.snapshot()?.richPresence, "Count: 4")
        runtime.idle()
        XCTAssertEqual(runtime.snapshot()?.richPresence, "Count: 4", "Paused/UI reads must use the latest evaluated RAM")
        memory[11] = 1; memory[14] = 17; frame()
        XCTAssertEqual(runtime.snapshot()?.leaderboards.first?.isTracking, true)
        memory[13] = 1; frame()
        var result: AchievementLeaderboardResult?
        for _ in 0..<100 {
            result = runtime.takeEvents().leaderboardResult
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(result?.rank, 1)
        XCTAssertEqual(result?.score, "000017")
        let submission = await transport.requests.first { FixtureTransport.fields($0)["r"] == "submitlbentry" }
        XCTAssertEqual(submission.map { FixtureTransport.fields($0)["s"] }, "17")
        await transport.setOffline(true)
        memory[1] = 1; frame(); frame()
        let events = runtime.takeEvents()
        XCTAssertEqual(events.unlocks.map(\.id), [1])
        XCTAssertEqual(events.unlocks.first?.isHardcore, true)
        for _ in 0..<100 {
            if try await !vault.pending(username: credentials.username).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pending = try await vault.pending(username: credentials.username)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.isHardcore, true)
        runtime.close()
        await transport.setOffline(false)
        // A later Casual client must preserve the mode of the original award.
        let next = RcheevosRuntime(transport: transport, vault: vault, generation: generation, userAgent: "Relay/1.0.0")
        defer { next.close() }
        _ = try await next.login(username: credentials.username, token: credentials.token)
        await next.restorePendingUnlocks(username: credentials.username)
        _ = try await loadFixtureGame(next, romURL: url)
        XCTAssertEqual(next.snapshot()?.unlockedCount, 1, "A pending Hardcore unlock also counts in Casual")
        await next.retryPersistedAwards(credentials: credentials)
        let remaining = try await vault.pending(username: credentials.username)
        XCTAssertTrue(remaining.isEmpty)
        let awards = await transport.requests.filter { FixtureTransport.fields($0)["r"] == "awardachievement" }
        XCTAssertTrue(awards.allSatisfy { FixtureTransport.fields($0)["h"] == "1" })
    }

    func testOfficialHitCountsRoundTripWithSaveState() async throws {
        let transport = FixtureTransport(); await transport.setIncludeHitAchievement()
        let vault = AchievementVault(store: MemorySecureStore())
        let runtime = RcheevosRuntime(transport: transport, vault: vault,
                                     generation: await vault.currentGeneration(), userAgent: "Relay/1.0.0")
        defer { runtime.close() }
        _ = try await runtime.login(username: "RelayFixture", token: "fixture-session")
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try await loadFixtureGame(runtime, romURL: url)
        var active = false
        func frame() {
            runtime.evaluateFrame { _, offset, target in
                for i in 0..<target.count { target[i] = active && offset + UInt32(i) == 3 ? 1 : 0 }
                return target.count
            }
        }
        frame(); active = true; frame() // one hit
        let progress = try XCTUnwrap(runtime.captureProgress())
        frame() // two hits
        XCTAssertTrue(runtime.takeEvents().unlocks.isEmpty)
        runtime.restoreProgress(progress) // back to one hit
        frame()
        XCTAssertTrue(runtime.takeEvents().unlocks.isEmpty, "Restoring must also restore accumulated hits")
        frame()
        XCTAssertEqual(runtime.takeEvents().unlocks.map(\.id), [3])
        runtime.restoreProgress(progress); frame(); frame()
        XCTAssertTrue(runtime.takeEvents().unlocks.isEmpty, "A state must not notify an unlock twice")
    }

    func testOfflineUnlockSurvivesRestartAndReconnectWithoutSecondNotification() async throws {
        let transport = FixtureTransport(); let store = MemorySecureStore()
        let vault = AchievementVault(store: store)
        let generation = await vault.currentGeneration()
        let runtime = RcheevosRuntime(transport: transport, vault: vault, generation: generation, userAgent: "Relay/1.0.0")
        let credentials = try await runtime.login(username: "RelayFixture", token: "fixture-session")
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try await loadFixtureGame(runtime, romURL: url)
        runtime.evaluateFrame { _, _, target in
            target.initializeMemory(as: UInt8.self, repeating: 0); return target.count
        }
        await transport.setOffline(true)
        runtime.evaluateFrame { _, offset, target in
            for i in 0..<target.count { target[i] = offset + UInt32(i) == 1 ? 1 : 0 }
            return target.count
        }
        XCTAssertEqual(runtime.takeEvents().unlocks.map(\.id), [1])
        for _ in 0..<100 {
            if try await !vault.pending(username: credentials.username).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pending = try await vault.pending(username: credentials.username)
        XCTAssertEqual(pending.count, 1)
        runtime.close()
        await transport.setOffline(false)
        let next = RcheevosRuntime(transport: transport, vault: vault, generation: generation, userAgent: "Relay/1.0.0")
        defer { next.close() }
        _ = try await next.login(username: credentials.username, token: credentials.token)
        await next.restorePendingUnlocks(username: credentials.username)
        _ = try await loadFixtureGame(next, romURL: url)
        XCTAssertEqual(next.snapshot()?.unlockedCount, 1)
        next.evaluateFrame { _, offset, target in
            for i in 0..<target.count { target[i] = offset + UInt32(i) == 1 ? 1 : 0 }
            return target.count
        }
        XCTAssertTrue(next.takeEvents().unlocks.isEmpty)
        await next.retryPersistedAwards(credentials: credentials)
        for _ in 0..<100 {
            if try await vault.pending(username: credentials.username).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let remaining = try await vault.pending(username: credentials.username)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUnidentifiedTitleAndRejectedLogin() async throws {
        let transport = FixtureTransport(); let vault = AchievementVault(store: MemorySecureStore())
        let runtime = RcheevosRuntime(transport: transport, vault: vault,
                                     generation: await vault.currentGeneration(), userAgent: "Relay/1.0.0")
        defer { runtime.close() }
        await transport.setRejectLogin(true)
        do { _ = try await runtime.login(username: "fixture", password: "wrong"); XCTFail("Rejected password") }
        catch { XCTAssertEqual(error as? AchievementServiceError, .invalidCredentials) }
        await transport.setRejectLogin(false)
        _ = try await runtime.login(username: "fixture", token: "fixture-session")
        await transport.setUnknown(true)
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try await loadFixtureGame(runtime, romURL: url); XCTFail("Unknown title") }
        catch { XCTAssertEqual(error as? AchievementServiceError, .unidentified) }
    }

    func testOfficialLoginIdentifyEvaluateProgressAndUnlockOnce() async throws {
        let transport = FixtureTransport()
        let vault = AchievementVault(store: MemorySecureStore())
        let runtime = RcheevosRuntime(transport: transport, vault: vault,
                                     generation: await vault.currentGeneration(), userAgent: "Relay/1.0.0 rcheevos/12.4.0")
        defer { runtime.close() }
        let credentials = try await runtime.login(username: "RelayFixture", password: "fixture-password")
        XCTAssertEqual(credentials.username, "RelayFixture")
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try await loadFixtureGame(runtime, romURL: url)
        XCTAssertEqual(loaded.achievements.count, 2)
        XCTAssertEqual(loaded.hash.count, 32)
        var memory = [UInt8](repeating: 0, count: 0x8000)
        func frame() {
            runtime.evaluateFrame { region, offset, target in
                guard region == .internalRAM, Int(offset) + target.count <= memory.count else { return 0 }
                for i in 0..<target.count { target[i] = memory[Int(offset) + i] }
                return target.count
            }
        }
        frame() // WAITING must see a false frame before activation.
        memory[2] = 3; frame()
        XCTAssertEqual(runtime.snapshot()?.achievements.first { $0.id == 2 }?.percent, 60)
        memory[1] = 1; frame(); frame(); frame()
        XCTAssertEqual(runtime.takeEvents().unlocks.map(\.id), [1])
        XCTAssertTrue(runtime.takeEvents().unlocks.isEmpty)
        XCTAssertEqual(runtime.snapshot()?.unlockedCount, 1)
        for _ in 0..<100 {
            if await transport.unlocks.contains(1) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" && $0.httpMethod == "POST" && $0.url?.query == nil })
        let awards = requests.filter { FixtureTransport.fields($0)["r"] == "awardachievement" }
        XCTAssertEqual(awards.count, 1)
        XCTAssertEqual(awards.first.map { FixtureTransport.fields($0)["h"] }, "0")
        XCTAssertFalse(AchievementClientValidation.isCurrentVersionApproved)
    }

    func testOfflineLoginFailsWithoutBlockingCallerAndTokenLoginUsesNoPassword() async throws {
        let transport = FixtureTransport(); await transport.setOffline(true)
        let vault = AchievementVault(store: MemorySecureStore())
        let runtime = RcheevosRuntime(transport: transport, vault: vault,
                                     generation: await vault.currentGeneration(), userAgent: "Relay/1.0.0")
        defer { runtime.close() }
        do {
            _ = try await runtime.login(username: "RelayFixture", token: "fixture-session")
            XCTFail("Offline login must fail")
        } catch { XCTAssertEqual(error as? AchievementServiceError, .unavailable) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(FixtureTransport.fields(requests[0])["p"])
    }
}

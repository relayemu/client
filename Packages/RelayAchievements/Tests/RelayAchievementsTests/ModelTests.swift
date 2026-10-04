// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayAchievements

@MainActor
final class ModelTests: XCTestCase {
    func testProductionDefaultsRejectHardcorePreferenceAndPS1Integration() async throws {
        XCTAssertFalse(AchievementClientValidation.isCurrentVersionApproved,
                       "This unapproved test bundle must use the normal fail-closed gate")
        let suite = "RA-production-gate-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "relay.achievements.hardcore")
        // Omit the validation override: exercise the production initializer.
        let model = AchievementsModel(store: MemorySecureStore(), transport: FixtureTransport(), preferences: preferences)
        XCTAssertFalse(model.hardcoreAvailable)
        XCTAssertEqual(model.preferredMode, .casual)
        model.setPreferredMode(.hardcore)
        XCTAssertEqual(model.preferredMode, .casual)
        await model.connect(username: "RelayFixture", password: "fixture-password")
        XCTAssertTrue(model.isConnected, "The explicit mode guard must also hold for a connected account")
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        let slot = try XCTUnwrap(model.prepareForPlay(gameID: GameID(), system: .gameBoyAdvance,
                                                    romURL: url, mode: .hardcore))
        XCTAssertFalse(slot.hardcoreEnabled, "An explicit requested mode cannot bypass approval")
        XCTAssertEqual(model.activeMode, .casual)
        model.endPlay()
        XCTAssertFalse(AchievementSystem.isEligible(.playStation),
                       "Adding PS1 emulation must not silently opt it into V1 achievements")
        XCTAssertEqual(SystemCatalog.playable.filter { AchievementSystem.isEligible($0.id) }.count, 11,
                       "V1 has twelve playable systems but only eleven RetroAchievements integrations")
        XCTAssertNil(model.prepareForPlay(gameID: GameID(), system: .playStation, romURL: url))
        await model.disconnect()
    }

    func testHardcoreNeedsValidationAndCannotUpgradeAnExistingSlot() async throws {
        let preferences = UserDefaults(suiteName: "RA-mode-test-" + UUID().uuidString)!
        let store = MemorySecureStore(); let transport = FixtureTransport()
        let unvalidated = AchievementsModel(store: store, transport: transport, hardcoreValidated: false, preferences: preferences)
        unvalidated.setPreferredMode(.hardcore)
        XCTAssertEqual(unvalidated.preferredMode, .casual)
        let model = AchievementsModel(store: store, transport: transport, hardcoreValidated: true, preferences: preferences)
        await model.connect(username: "RelayFixture", password: "fixture-password")
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        let casual = try XCTUnwrap(model.prepareForPlay(gameID: GameID(), system: .gameBoyAdvance, romURL: url))
        model.setPreferredMode(.hardcore)
        XCTAssertFalse(casual.hardcoreEnabled, "Changing the preference must never upgrade a running timeline")
        model.endPlay()
        let hardcore = try XCTUnwrap(model.prepareForPlay(gameID: GameID(), system: .gameBoyAdvance, romURL: url))
        XCTAssertTrue(hardcore.hardcoreEnabled)
        await model.disconnect()
        XCTAssertFalse(hardcore.hardcoreEnabled)
        XCTAssertFalse(model.hasAccount)
    }

    func testDisconnectDuringLoginCannotResurrectCredentials() async throws {
        let store = MemorySecureStore(); let transport = DelayedLoginTransport()
        let model = AchievementsModel(store: store, transport: transport)
        let connecting = Task { await model.connect(username: "RelayFixture", password: "fixture-password") }
        for _ in 0..<100 {
            if await transport.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await transport.isWaiting
        XCTAssertTrue(waiting)
        await model.disconnect()
        await transport.complete()
        await connecting.value
        XCTAssertEqual(model.account, .disconnected)
        XCTAssertNil(try store.read("session"))
        XCTAssertFalse(model.hasAccount)
    }

    func testConnectTokenRestoreDisconnectAndInvalidPassword() async throws {
        let store = MemorySecureStore(); let transport = FixtureTransport()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AchievementsModel(store: store, transport: transport, cacheDirectory: directory)
        await model.connect(username: " RelayFixture ", password: "fixture-password")
        XCTAssertEqual(model.account, .connected("RelayFixture"))
        XCTAssertTrue(model.hasAccount)
        let saved = try XCTUnwrap(store.read("session"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("fixture-password"))
        let restored = AchievementsModel(store: store, transport: transport, cacheDirectory: directory)
        await restored.restoreAccount()
        XCTAssertEqual(restored.account, .connected("RelayFixture"))
        await restored.disconnect()
        XCTAssertNil(try store.read("session")); XCTAssertNil(try store.read("pending"))
        XCTAssertEqual(restored.account, .disconnected)
        await transport.setRejectLogin(true)
        await restored.connect(username: "RelayFixture", password: "wrong")
        XCTAssertFalse(restored.hasAccount)
        XCTAssertEqual(restored.lastError, .invalidCredentials)
    }

    func testOfflineLaunchReturnsImmediatelyAndReconnectAttachesToRunningSlot() async throws {
        let store = MemorySecureStore(); let transport = FixtureTransport()
        let credentials = AchievementCredentials(username: "RelayFixture", token: "fixture-session")
        try store.write(JSONEncoder().encode(credentials), key: "session")
        await transport.setOffline(true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AchievementsModel(store: store, transport: transport, cacheDirectory: directory)
        await model.restoreAccount()
        XCTAssertEqual(model.account, .unavailable)
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        let gameID = GameID()
        let slot = try XCTUnwrap(model.prepareForPlay(gameID: gameID, system: .gameBoyAdvance, romURL: url))
        XCTAssertEqual(model.gameStates[gameID], .unavailable)
        XCTAssertNotNil(slot) // The API is synchronous, independent of HTTP.
        await transport.setOffline(false)
        await model.retry()
        for _ in 0..<100 {
            slot.evaluateFrame { _, _, target in
                target.initializeMemory(as: UInt8.self, repeating: 0); return target.count
            }
            await model.poll()
            if model.gameStates[gameID] == .active { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.account, .connected("RelayFixture"))
        XCTAssertEqual(model.gameStates[gameID], .active)
        XCTAssertEqual(model.games[gameID]?.achievements.count, 2)
        model.endPlay()
        XCTAssertNil(model.activeGameID)
        XCTAssertEqual(model.gameStates[gameID], .inactive)
        await model.disconnect()
    }

    func testUnsupportedSystemDoesNotInstallRuntimeOrMakeRequests() async throws {
        let transport = FixtureTransport()
        let model = AchievementsModel(store: MemorySecureStore(), transport: transport)
        let url = try fixtureROM(); defer { try? FileManager.default.removeItem(at: url) }
        let slot = model.prepareForPlay(gameID: GameID(), system: "not-supported", romURL: url)
        XCTAssertNil(slot)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testStorageFailureDoesNotPretendConnectedOrDisconnected() async throws {
        let store = MemorySecureStore(); store.failsWrites = true
        let model = AchievementsModel(store: store, transport: FixtureTransport())
        await model.connect(username: "RelayFixture", password: "fixture-password")
        XCTAssertFalse(model.isConnected); XCTAssertEqual(model.lastError, .storage)
        store.failsRemoval = true
        await model.disconnect()
        XCTAssertEqual(model.account, .credentialRemovalFailed)
        store.failsRemoval = false
        await model.disconnect()
        XCTAssertEqual(model.account, .disconnected)
    }
}

private actor DelayedLoginTransport: AchievementHTTPTransport {
    private var continuation: CheckedContinuation<AchievementHTTPResponse, Never>?
    var isWaiting: Bool { continuation != nil }
    func send(_ request: URLRequest) async -> AchievementHTTPResponse {
        await withCheckedContinuation { continuation = $0 }
    }
    func complete() {
        continuation?.resume(returning: .init(status: 200, body: Data("{\"Success\":true,\"User\":\"RelayFixture\",\"Token\":\"fixture-session\",\"Score\":0,\"SoftcoreScore\":0,\"Messages\":0}".utf8)))
        continuation = nil
    }
}

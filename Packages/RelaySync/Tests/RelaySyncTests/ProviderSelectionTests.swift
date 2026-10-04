// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
import RelayDomain
import RelayLibrary
@testable import RelaySync

/// Deliberately keeps retired hosts to simulate callbacks queued before stop.
private actor RetainingTransport: SyncTransport {
    var host: (any SyncTransportHost)?
    var stopped = false
    let identity: String
    let suspendUpload: Bool
    private var uploadCompletion: CheckedContinuation<Void, Never>?
    private var uploadObserver: CheckedContinuation<Void, Never>?
    private var uploadStarted = false
    var uploadCount = 0
    init(identity: String, suspendUpload: Bool = false) { self.identity = identity; self.suspendUpload = suspendUpload }
    func waitForUpload() async {
        if !uploadStarted { await withCheckedContinuation { uploadObserver = $0 } }
    }
    func start(host: any SyncTransportHost) async throws {
        self.host = host
        stopped = false
        await host.accountDidChange(.init(availability: .available, identity: identity))
    }
    func stop() async {
        stopped = true
        // Simulates a request that reports success just after transport cancellation.
        uploadCompletion?.resume()
        uploadCompletion = nil
    }
    func resetState() async {}
    func requestSync(reason: SyncReason) async {}
    func fetchNow() async throws {}
    func uploadContent(_ record: SyncRecord, fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        uploadCount += 1
        guard suspendUpload else { return }
        uploadStarted = true
        uploadObserver?.resume(); uploadObserver = nil
        await withCheckedContinuation { uploadCompletion = $0 }
    }
    func fetchContent(_ key: RecordKey, progress: @escaping @Sendable (Double) -> Void) async throws -> InboundChange? { nil }
    func contentExists(_ key: RecordKey) async throws -> Bool { false }
    func deleteContent(_ key: RecordKey) async throws { XCTFail("Selecting a provider must never delete old remote content") }
}

final class ProviderSelectionTests: XCTestCase {
    func testLegacyDisabledSettingAndUnknownProviderFailClosed() async throws {
        let device = try await SimulatedDevice(name: "selection-migration", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        try await device.store.syncStore.setMetaValue("0", forKey: SyncMetaKey.savesEnabled)
        let legacy = await device.coordinator.savedProviderSelection()
        XCTAssertEqual(legacy, .off)
        try await device.store.syncStore.setMetaValue("future-provider", forKey: SyncMetaKey.selectedProvider)
        try await device.store.syncStore.setMetaValue("1", forKey: SyncMetaKey.savesEnabled)
        let unknown = await device.coordinator.savedProviderSelection()
        XCTAssertEqual(unknown, .off, "An unknown durable value cannot silently select a different remote")
        await device.start()
        let status = await device.status
        XCTAssertFalse(status.isOperational)
        XCTAssertEqual(status.provider, .off)
    }

    func testLegacyReconciledMarkerCannotSkipSchema2CanonicalRebuild() async throws {
        let device = try await SimulatedDevice(name: "legacy-reconciliation", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        let bytes = gbaBytes(seed: 74)
        let original = try await device.importGame(bytes)
        try await device.store.games.deleteGame(id: original.id)
        let successor = try await device.importGame(bytes)
        try await device.play(successor, battery: Data([19, 20]))
        XCTAssertEqual(successor.generation, 1)
        // Model an already-acknowledged old library: migration has no pending
        // game/history journal rows to rewrite, but canonical rows remain.
        let oldJournal = try await device.store.syncStore.journal.pending(limit: 100)
        try await device.store.syncStore.journal.complete(oldJournal.map(\.id))
        try await device.store.syncStore.setMetaValue("account-a", forKey: SyncMetaKey.accountIdentity)
        try await device.store.syncStore.setMetaValue("1", forKey: SyncMetaKey.reconciled)
        await device.coordinator.selectProvider(.iCloud, transport: RetainingTransport(identity: "account-a"))
        let outbound = await device.coordinator.nextOutboundBatch(limit: 100)
        let records = outbound.compactMap { change -> SyncRecord? in
            if case .save(let record, _) = change.payload { return record }
            return nil
        }
        XCTAssertTrue(records.contains { if case .game(let entry) = $0 { return entry.generation == 1 }; return false })
        XCTAssertTrue(records.contains { if case .batteryRevision(let revision) = $0 { return revision.generation == 1 }; return false })
        XCTAssertTrue(records.contains { if case .state(let state) = $0 { return state.generation == 1 }; return false })
        XCTAssertTrue(records.contains { if case .session(let session) = $0 { return session.generation == 1 }; return false })
        XCTAssertTrue(records.contains { if case .tombstone(let tombstone) = $0 { return tombstone.targetKind == "game" && tombstone.generation == 0 }; return false })
        let legacyMarker = try await device.store.syncStore.metaValue(forKey: SyncMetaKey.reconciled)
        let schema2Marker = try await device.store.syncStore.metaValue(forKey:
            SyncMetaKey.scoped(SyncMetaKey.reconciled + ".schema2", provider: .iCloud, account: "account-a"))
        XCTAssertEqual(legacyMarker, "1", "Historical acknowledgement metadata is preserved")
        XCTAssertEqual(schema2Marker, "1", "Schema 2 is marked only after rebuilding canonical intents")
    }

    func testSwitchRejectsRetiredFetchSendAccountStatusAndCursorCallbacks() async throws {
        let device = try await SimulatedDevice(name: "switch", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        let old = RetainingTransport(identity: "cloud-user")
        let selected = RetainingTransport(identity: "relay-user")
        await device.coordinator.selectProvider(.iCloud, transport: old)
        let game = try await device.importGame(gbaBytes(seed: 11), title: "Local")
        let oldHost = await old.host!
        let oldBatch = await oldHost.nextOutboundBatch(limit: 50)
        XCTAssertFalse(oldBatch.isEmpty)
        await device.coordinator.setGameFilesEnabled(true)
        await device.coordinator.selectProvider(.relaySync, transport: selected, capabilities: .hostedGameFilesSupported)
        let pendingBefore = try await device.pendingCount()
        let stale = SyncGameEntry(fingerprint: game.contentFingerprint, systemID: game.systemID.rawValue, title: "Stale overwrite",
                                 isFavorite: false, addedAt: 1, updatedAt: Int64.max / 2, contentSize: nil)
        await oldHost.didFetch(changes: [.init(key: .game(game.contentFingerprint), record: .game(stale))], deletions: [])
        await oldHost.didSend(oldBatch.map { .init(key: $0.key, outcome: .saved) })
        await oldHost.accountDidChange(.init(availability: .available, identity: "wrong-account"))
        await oldHost.transportDidUpdate(.init(isSyncing: true, lastProblem: .quotaFull, detail: "retired"))
        await oldHost.zoneWasReset()
        let retiredBatch = await oldHost.nextOutboundBatch(limit: 50)
        XCTAssertTrue(retiredBatch.isEmpty)
        do {
            try await oldHost.applyHostedPage(changes: [], deletions: [], cursor: 1, scope: "retired")
            XCTFail("A retired host cannot commit a cursor")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let currentGame = try await device.game(game.contentFingerprint)
        let pendingAfter = try await device.pendingCount()
        let status = await device.status
        let oldStopped = await old.stopped
        XCTAssertTrue(oldStopped)
        XCTAssertEqual(currentGame?.title, "Local")
        XCTAssertEqual(pendingAfter, pendingBefore)
        XCTAssertEqual(status.provider, .relaySync)
        XCTAssertFalse(status.accountChangePending)
        XCTAssertFalse(status.gameFilesEnabled, "iCloud opt-in cannot authorize hosted uploads")
        XCTAssertFalse(status.isSyncing)
        XCTAssertNil(status.problem)
        XCTAssertNil(status.lastPushAt)
    }

    func testSwitchConvergesLocalHistoryAndScopesRemoteContentWithoutDeletingEitherCloud() async throws {
        let cloud = InMemoryCloud()
        let relay = InMemoryCloud()
        let device = try await SimulatedDevice(name: "bridge", kind: .mac, cloud: cloud, clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let game = try await device.importGame(gbaBytes(seed: 21))
        try await device.play(game, battery: Data([8, 9]))
        await device.coordinator.setGameFilesEnabled(true)
        try await device.coordinator.uploadContent(gameID: game.id)
        try await device.sync()
        let originalCloudCount = await cloud.recordCount(ofType: .gameContent)
        XCTAssertEqual(originalCloudCount, 1)
        let transport = relay.connect(device: "relay-bridge")
        await device.coordinator.selectProvider(.relaySync, transport: transport, capabilities: .hostedGameFilesSupported)
        let cloudFingerprints = await device.coordinator.cloudContentFingerprints()
        XCTAssertTrue(cloudFingerprints.isEmpty, "Old iCloud descriptors cannot claim hosted content availability")
        try await transport.pump()
        let remoteGames = await relay.recordCount(ofType: .game)
        let remoteRevisions = await relay.recordCount(ofType: .batteryRevision)
        let remoteContent = await relay.recordCount(ofType: .gameContent)
        XCTAssertEqual(remoteGames, 1)
        XCTAssertEqual(remoteRevisions, 1)
        XCTAssertEqual(remoteContent, 0)
        await device.coordinator.setGameFilesEnabled(true)
        try await device.coordinator.uploadContent(gameID: game.id)
        try await transport.pump()
        let hostedContent = await relay.recordCount(ofType: .gameContent)
        let oldContent = await cloud.recordCount(ofType: .gameContent)
        XCTAssertEqual(hostedContent, 1, "Upload must check the selected provider, regardless of the old descriptor")
        XCTAssertEqual(oldContent, 1)
        await device.coordinator.selectProvider(.off, transport: nil)
        try await device.play(game, battery: Data([10, 11]))
        XCTAssertEqual(try device.currentBattery(game), Data([10, 11]))
        await device.coordinator.selectProvider(.iCloud, transport: device.transport)
        let restored = await device.status
        let restoredContent = await device.coordinator.cloudContentFingerprints()
        XCTAssertTrue(restored.gameFilesEnabled)
        XCTAssertTrue(restoredContent.contains(game.contentFingerprint))
        try await device.sync()
        let preserved = await relay.recordCount(ofType: .gameContent)
        XCTAssertEqual(preserved, 1)
    }

    func testSwitchBridgesPreviouslyReceivedRemoteHistory() async throws {
        let cloud = InMemoryCloud()
        let relay = InMemoryCloud()
        let clock = TestClock()
        let author = try await SimulatedDevice(name: "author", kind: .iPhone, cloud: cloud, clock: clock)
        let bridge = try await SimulatedDevice(name: "received-bridge", kind: .iPad, cloud: cloud, clock: clock)
        defer { author.destroy(); bridge.destroy() }
        await author.start(); await bridge.start()
        let authoredGame = try await author.importGame(gbaBytes(seed: 51))
        try await author.play(authoredGame, battery: Data([13, 14]))
        try await author.sync(); try await bridge.sync()
        let receivedGame = try await bridge.game(authoredGame.contentFingerprint)
        let game = try XCTUnwrap(receivedGame)
        let receivedHeads = try await bridge.heads(game)
        XCTAssertEqual(receivedHeads.count, 1)
        XCTAssertEqual(receivedHeads.first?.origin, .remote)
        let hosted = relay.connect(device: "received-bridge-hosted")
        await bridge.coordinator.selectProvider(.relaySync, transport: hosted)
        try await hosted.pump()
        let games = await relay.recordCount(ofType: .game)
        let batteries = await relay.recordCount(ofType: .batteryRevision)
        let states = await relay.recordCount(ofType: .state)
        let sessions = await relay.recordCount(ofType: .session)
        XCTAssertEqual(games, 1)
        XCTAssertEqual(batteries, 1, "History received from the old provider is canonical history too")
        XCTAssertEqual(states, 1)
        XCTAssertEqual(sessions, 1)
        XCTAssertEqual(try bridge.currentBattery(game), Data([13, 14]))
    }

    func testColdStartOfSavedHostedProviderDoesNotRejournalReceivedHistory() async throws {
        let (author, receiver, game) = try await makeReconciledHostedReceiver()
        defer { author.destroy(); receiver.destroy() }
        await receiver.coordinator.stop()
        try receiver.store.close()
        let reopened = try await SimulatedDevice(name: receiver.name, kind: receiver.kind, cloud: receiver.cloud,
                                                 clock: receiver.clock, root: receiver.root)
        defer { try? reopened.store.close() }
        let selected = await reopened.coordinator.savedProviderSelection()
        XCTAssertEqual(selected, .relaySync)
        await reopened.coordinator.selectProvider(selected, transport: RetainingTransport(identity: "account-a"))
        let pending = try await reopened.pendingCount()
        let batch = await reopened.coordinator.nextOutboundBatch(limit: 50)
        let heads = try await reopened.heads(game)
        XCTAssertEqual(pending, 0, "Reopening the same provider/account is not a provider bridge")
        XCTAssertTrue(batch.isEmpty, "Received foreign-installation history must not become a new outbound intent on restart")
        XCTAssertEqual(heads.first?.origin, .remote)
        XCTAssertEqual(heads.first?.installationID, author.identity.installationID)
        let marker = try await reopened.store.syncStore.metaValue(forKey:
            SyncMetaKey.scoped(SyncMetaKey.reconciled + ".schema2", provider: .relaySync, account: "account-a"))
        XCTAssertEqual(marker, "1")
    }

    func testColdStartExplicitProviderChangeStillBridgesReceivedHistory() async throws {
        let (author, receiver, game) = try await makeReconciledHostedReceiver()
        defer { author.destroy(); receiver.destroy() }
        // iCloud was reconciled before this receiver selected Relay Sync and received the game.
        let cloudMarker = try await receiver.store.syncStore.metaValue(forKey:
            SyncMetaKey.scoped(SyncMetaKey.reconciled + ".schema2", provider: .iCloud, account: "account-a"))
        XCTAssertEqual(cloudMarker, "1")
        await receiver.coordinator.stop()
        try receiver.store.close()
        let reopened = try await SimulatedDevice(name: receiver.name, kind: receiver.kind, cloud: receiver.cloud,
                                                 clock: receiver.clock, root: receiver.root)
        defer { try? reopened.store.close() }
        await reopened.coordinator.selectProvider(.iCloud, transport: reopened.transport)
        let pending = try await reopened.pendingCount()
        XCTAssertGreaterThan(pending, 0, "An explicit cold-start switch must compare against the persisted provider")
        try await reopened.sync()
        let batteries = await receiver.cloud.recordCount(ofType: .batteryRevision)
        let states = await receiver.cloud.recordCount(ofType: .state)
        let sessions = await receiver.cloud.recordCount(ofType: .session)
        let heads = try await reopened.heads(game)
        XCTAssertEqual(batteries, 1)
        XCTAssertEqual(states, 1)
        XCTAssertEqual(sessions, 1)
        XCTAssertEqual(heads.first?.origin, .remote)
        XCTAssertEqual(heads.first?.installationID, author.identity.installationID)
    }

    /// Creates a receiver with both provider markers initialized, then receives hosted
    /// history only after its initial reconciliation, so no outbound journal row exists.
    private func makeReconciledHostedReceiver() async throws -> (SimulatedDevice, SimulatedDevice, Game) {
        let relay = InMemoryCloud()
        let clock = TestClock()
        let author = try await SimulatedDevice(name: "cold-author", kind: .iPhone, cloud: relay, clock: clock)
        let receiver = try await SimulatedDevice(name: "cold-receiver", kind: .mac, cloud: InMemoryCloud(), clock: clock)
        await author.coordinator.selectProvider(.relaySync, transport: author.transport)
        await receiver.start()
        let hosted = relay.connect(device: "cold-receiver-hosted")
        await receiver.coordinator.selectProvider(.relaySync, transport: hosted)
        let authored = try await author.importGame(gbaBytes(seed: 73))
        try await author.play(authored, battery: Data([17, 18]))
        try await author.sync()
        try await hosted.pump()
        let received = try await receiver.game(authored.contentFingerprint)
        let game = try XCTUnwrap(received)
        let pending = try await receiver.pendingCount()
        let heads = try await receiver.heads(game)
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(heads.first?.origin, .remote)
        return (author, receiver, game)
    }

    func testSwitchCancelsAndDrainsAnUploadBeforePublishingNewScope() async throws {
        let device = try await SimulatedDevice(name: "transfer-switch", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        let old = RetainingTransport(identity: "old", suspendUpload: true)
        await device.coordinator.selectProvider(.iCloud, transport: old)
        let game = try await device.importGame(gbaBytes(seed: 41))
        await device.coordinator.setGameFilesEnabled(true)
        let upload = Task { try await device.coordinator.uploadContent(gameID: game.id) }
        await old.waitForUpload()
        let replacement = RetainingTransport(identity: "new")
        await device.coordinator.selectProvider(.relaySync, transport: replacement)
        do { try await upload.value; XCTFail("The retired transfer must fail cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let available = await device.coordinator.cloudContentFingerprints()
        let oldDescriptor = try await device.store.syncStore.contentDescriptor(for: game.contentFingerprint)
        let state = await device.status
        let hasContent = try await device.hasContent(game)
        XCTAssertTrue(available.isEmpty)
        XCTAssertNil(oldDescriptor, "A completion after cancellation cannot advertise content")
        XCTAssertEqual(state.provider, .relaySync)
        XCTAssertNil(state.problem)
        XCTAssertTrue(hasContent)
    }

    func testConcurrentGameUploadsHaveOneAdmission() async throws {
        let device = try await SimulatedDevice(name: "single-upload", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        let transport = RetainingTransport(identity: "one", suspendUpload: true)
        await device.coordinator.selectProvider(.relaySync, transport: transport)
        let game = try await device.importGame(gbaBytes(seed: 61))
        await device.coordinator.setGameFilesEnabled(true)
        let first = Task { try await device.coordinator.uploadContent(gameID: game.id) }
        await transport.waitForUpload()
        // Refresh may request the same game repeatedly while its first request is suspended.
        try await device.coordinator.uploadContent(gameID: game.id)
        try await device.coordinator.uploadContent(gameID: game.id)
        let count = await transport.uploadCount
        XCTAssertEqual(count, 1)
        await device.coordinator.selectProvider(.off, transport: nil)
        do { try await first.value; XCTFail("The suspended request was retired") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSignedOutSelectionRemainsHostedAndOfflineLocalWritesSurvive() async throws {
        let device = try await SimulatedDevice(name: "offline-provider", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        await device.coordinator.selectProvider(.relaySync, transport: nil)
        let game = try await device.importGame(gbaBytes(seed: 31))
        try await device.play(game, battery: Data([12]))
        let selection = await device.coordinator.savedProviderSelection()
        let status = await device.status
        let count = try await device.pendingCount()
        XCTAssertEqual(selection, .relaySync)
        XCTAssertEqual(status.provider, .relaySync)
        XCTAssertEqual(status.account, .noAccount)
        XCTAssertFalse(status.isOperational)
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(try device.currentBattery(game), Data([12]))
    }

    func testAcceptedAccountGetsSeparateOptInAndRestoresOriginalAccountPolicy() async throws {
        let device = try await SimulatedDevice(name: "account-scope", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        let first = RetainingTransport(identity: "first-account")
        await device.coordinator.selectProvider(.relaySync, transport: first)
        await device.coordinator.setGameFilesEnabled(true)
        let second = RetainingTransport(identity: "second-account")
        await device.coordinator.selectProvider(.relaySync, transport: second)
        let frozen = await device.status
        XCTAssertTrue(frozen.accountChangePending)
        await device.coordinator.acceptAccountChange()
        let accepted = await device.status
        XCTAssertFalse(accepted.gameFilesEnabled)
        XCTAssertTrue(accepted.isOperational)
        await device.coordinator.selectProvider(.relaySync, transport: first)
        await device.coordinator.acceptAccountChange()
        let original = await device.status
        XCTAssertTrue(original.gameFilesEnabled)
        XCTAssertTrue(original.isOperational)
    }
}

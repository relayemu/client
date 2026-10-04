// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
import RelayLibrary
@testable import RelaySync

final class HostedPageTests: XCTestCase {
    func testCursorAndRecordsCommitTogetherAndReplayIsIdempotent() async throws {
        let device = try await SimulatedDevice(name: "checkpoint", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let fingerprint = try SHA256ContentHasher().hash(data: gbaBytes(seed: 91)).fingerprint
        let game = SyncRecord.game(SyncGameEntry(fingerprint: fingerprint, systemID: "gba", title: "Checkpoint", isFavorite: false,
                                                addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: 4096))
        let scope = "preproduction.account-a"
        try await device.coordinator.applyHostedPage(changes: [InboundChange(key: game.key, record: game)], deletions: [], cursor: 7, scope: scope)
        let inserted = try await device.game(fingerprint)
        let cursor = try await device.coordinator.hostedCursor(scope: scope)
        XCTAssertNotNil(inserted)
        XCTAssertEqual(cursor, 7)
        try await device.coordinator.applyHostedPage(changes: [InboundChange(key: game.key, record: game)], deletions: [], cursor: 7, scope: scope)
        let replayed = try await device.game(fingerprint)
        XCTAssertEqual(replayed?.id, inserted?.id)
        let otherCursor = try await device.coordinator.hostedCursor(scope: "preproduction.account-b")
        XCTAssertEqual(otherCursor, 0)
        var changed = game
        if case .game(var entry) = changed { entry.title = "Should roll back"; entry.updatedAt += 100; changed = .game(entry) }
        do {
            try await device.coordinator.applyHostedPage(changes: [InboundChange(key: changed.key, record: changed)], deletions: [], cursor: 6, scope: scope)
            XCTFail("A stale checkpoint must roll back its semantic writes")
        } catch {}
        let afterFailure = try await device.game(fingerprint)
        XCTAssertEqual(afterFailure?.title, "Checkpoint")
        let durable = try await device.coordinator.hostedCursor(scope: scope)
        XCTAssertEqual(durable, 7)
    }

    func testRejectedAssetDoesNotAcknowledgePageOrPublishOtherRecords() async throws {
        let device = try await SimulatedDevice(name: "reject-page", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let fp = try SHA256ContentHasher().hash(data: gbaBytes(seed: 92)).fingerprint
        let game = SyncRecord.game(SyncGameEntry(fingerprint: fp, systemID: "gba", title: "Not committed", isFavorite: false,
                                                addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: 4096))
        let revision = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [],
            createdAt: 1_700_000_000_001, dataFingerprint: fp, dataSize: 4096, installationID: InstallationID(), deviceKind: "iphone", hasScreenshot: false))
        do {
            try await device.coordinator.applyHostedPage(changes: [InboundChange(key: game.key, record: game), InboundChange(key: revision.key, record: revision)],
                                                        deletions: [], cursor: 2, scope: "account")
            XCTFail("Missing revision data must reject the complete page")
        } catch { XCTAssertEqual(error as? SyncPageError, .rejectedRecords) }
        let absent = try await device.game(fp)
        let cursor = try await device.coordinator.hostedCursor(scope: "account")
        XCTAssertNil(absent)
        XCTAssertEqual(cursor, 0)
    }

    func testDeferredPayloadAndCursorSurviveRestart() async throws {
        let device = try await SimulatedDevice(name: "deferred-page", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let bytes = Data([1, 2, 3, 4])
        let hash = try SHA256ContentHasher().hash(data: bytes).fingerprint
        let fp = try SHA256ContentHasher().hash(data: gbaBytes(seed: 93)).fingerprint
        let asset = device.root.appending(path: "remote-save")
        try bytes.write(to: asset)
        let revision = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [],
            createdAt: 1_700_000_000_001, dataFingerprint: hash, dataSize: 4, installationID: InstallationID(), deviceKind: "iphone", hasScreenshot: false))
        try await device.coordinator.applyHostedPage(changes: [InboundChange(key: revision.key, record: revision, assets: [.data: asset])],
                                                    deletions: [], cursor: 1, scope: "account")
        let deferred = try await device.store.syncStore.deferredRecords()
        XCTAssertEqual(deferred.count, 1)
        let oldEnvelope = try JSONDecoder().decode(DeferredEnvelope.self, from: XCTUnwrap(deferred.first).payload)
        try FileManager.default.removeItem(at: asset)
        for path in oldEnvelope.assets.values { XCTAssertTrue(FileManager.default.fileExists(atPath: device.location.syncInboxDirectory.appending(path: path).path)) }
        let restarted = try await device.restart()
        defer { try? restarted.store.close() }
        let cursor = try await restarted.coordinator.hostedCursor(scope: "account")
        XCTAssertEqual(cursor, 1)
        let game = SyncRecord.game(SyncGameEntry(fingerprint: fp, systemID: "gba", title: "Deferred", isFavorite: false,
                                                addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: 4096))
        try await restarted.coordinator.applyHostedPage(changes: [InboundChange(key: game.key, record: game)], deletions: [], cursor: 2, scope: "account")
        let remaining = try await restarted.store.syncStore.deferredRecords()
        let applied = try await restarted.game(fp)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try applied.flatMap { try restarted.currentBattery($0) }, bytes)
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
import RelayDomain
@testable import RelaySync

final class TransportStatusTests: XCTestCase {
    func testLegacyCompatibilityProblemsPreserveProgressUntilAcknowledgedRetry() async throws {
        for reason in ["hosted history requires original installation", "hosted state retention deletion unsupported"] {
            let device = try await SimulatedDevice(name: "legacy-status-retry", kind: .mac,
                                                   cloud: InMemoryCloud(), clock: TestClock())
            defer { device.destroy() }
            await device.coordinator.selectProvider(.relaySync, transport: device.transport)
            let game = try await device.importGame(gbaBytes(seed: 96))
            let battery = Data([1, 2, 3, 4])
            _ = try await device.play(game, battery: battery)
            await device.coordinator.transportDidUpdate(.init(lastProblem: .invalidRecord(reason)))
            let pendingBefore = try await device.pendingCount()
            XCTAssertGreaterThan(pendingBefore, 0)
            await device.coordinator.requestSync(reason: .manual)
            await device.coordinator.transportDidUpdate(.init(isSyncing: true))
            let retrying = await device.status
            XCTAssertEqual(retrying.problem, .failed(reason), "Requesting a retry is not a successful sync")
            XCTAssertEqual(try device.currentBattery(game), battery)
            let pendingAfter = try await device.pendingCount()
            XCTAssertEqual(pendingAfter, pendingBefore, "The failure must not discard pending progress")
            let batch = await device.coordinator.nextOutboundBatch(limit: 50)
            XCTAssertFalse(batch.isEmpty)
            await device.coordinator.didSend(batch.map { .init(key: $0.key, outcome: .saved) })
            let recovered = await device.status
            XCTAssertNil(recovered.problem)
            XCTAssertEqual(recovered.pendingCount, 0)
            XCTAssertEqual(try device.currentBattery(game), battery)
            let retained = try await device.game(game.contentFingerprint)
            XCTAssertEqual(retained?.id, game.id)
        }
    }

    func testUnrecognizedTransportFailuresSurfaceOneFixedClassification() async throws {
        let device = try await SimulatedDevice(name: "transport-failure", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.coordinator.selectProvider(.relaySync, transport: device.transport)
        let failures: [TransportProblem] = [
            .invalidRecord("hosted response"),
            .invalidRecord("untrusted synthetic response details"),
            .other("opaque synthetic server details"),
            .serverRecordChanged, .unknownItem, .zoneMissing, .limitExceeded,
        ]
        for failure in failures {
            await device.coordinator.transportDidUpdate(.init(lastProblem: failure))
            let status = await device.status
            XCTAssertEqual(status.problem, .failed("sync transport"), "Unhandled failures must not disappear")
            XCTAssertNotNil(status.problemSince)
            XCTAssertNil(status.lastPullAt, "A failed response is not a completed pull")
        }
    }

    func testKnownTransportClassificationsRemainSpecific() async throws {
        let device = try await SimulatedDevice(name: "known-transport-failure", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.coordinator.selectProvider(.relaySync, transport: device.transport)
        let cases: [(TransportProblem, SyncProblem)] = [
            (.quotaFull, .quotaFull),
            (.network, .network),
            (.rateLimited(retryAfterSeconds: 60), .network),
            (.accountUnavailable, .accountUnavailable),
            (.invalidRecord("hosted history requires original installation"), .failed("hosted history requires original installation")),
            (.invalidRecord("hosted state retention deletion unsupported"), .failed("hosted state retention deletion unsupported")),
        ]
        for (failure, expected) in cases {
            await device.coordinator.transportDidUpdate(.init(lastProblem: failure))
            let status = await device.status
            XCTAssertEqual(status.problem, expected)
            try await device.coordinator.applyHostedPage(changes: [], deletions: [], cursor: 0, scope: "status-specific")
            let afterPage = await device.status
            XCTAssertEqual(afterPage.problem, expected, "Generic response recovery cannot erase a specific problem")
        }
    }

    func testRetryHeartbeatCannotClearFailureButCommittedEmptyPageCan() async throws {
        let clock = TestClock()
        let device = try await SimulatedDevice(name: "transport-recovery", kind: .mac, cloud: InMemoryCloud(), clock: clock)
        defer { device.destroy() }
        await device.coordinator.selectProvider(.relaySync, transport: device.transport)
        await device.coordinator.transportDidUpdate(.init(lastProblem: .invalidRecord("hosted response")))
        let failed = await device.status
        clock.advance(10)
        await device.coordinator.transportDidUpdate(.init(isSyncing: true, lastProblem: nil))
        await device.coordinator.transportDidUpdate(.init(lastProblem: nil, lastPullAt: clock.now))
        await device.coordinator.didSend([])
        let retrying = await device.status
        XCTAssertEqual(retrying.problem, .failed("sync transport"))
        XCTAssertEqual(retrying.problemSince, failed.problemSince)
        XCTAssertNil(retrying.lastPullAt, "Transport hints do not advance the semantic success timestamp")
        try await device.coordinator.applyHostedPage(changes: [], deletions: [], cursor: 0, scope: "status-recovery")
        let recovered = await device.status
        XCTAssertNil(recovered.problem)
        XCTAssertNil(recovered.problemSince)
        XCTAssertEqual(recovered.lastPullAt, clock.now)
        let key = SyncMetaKey.scoped(SyncMetaKey.lastPullAt, provider: .relaySync, account: "account-a")
        let persisted = try await device.store.syncStore.metaValue(forKey: key)
        XCTAssertEqual(persisted, String(SyncTime.millis(clock.now)))
    }

    func testCloudKitSendRecoveryDoesNotRequireHostedPage() async throws {
        let device = try await SimulatedDevice(name: "cloudkit-status-recovery", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        _ = try await device.importGame(gbaBytes(seed: 98))
        await device.coordinator.transportDidUpdate(.init(lastProblem: .other("synthetic cloud transport failure")))
        let failed = await device.status
        XCTAssertEqual(failed.provider, .iCloud)
        XCTAssertEqual(failed.problem, .failed("sync transport"))
        let batch = await device.coordinator.nextOutboundBatch(limit: 50)
        XCTAssertFalse(batch.isEmpty)
        await device.coordinator.didSend(batch.map { .init(key: $0.key, outcome: .saved) })
        let recovered = await device.status
        XCTAssertEqual(recovered.pendingCount, 0)
        XCTAssertNotNil(recovered.lastPushAt)
        XCTAssertNil(recovered.problem, "CloudKit keeps its acknowledged-send recovery path")
    }

    func testSuccessfulPullDoesNotHidePendingOutboundRepair() async throws {
        let device = try await SimulatedDevice(name: "pending-transport-repair", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.coordinator.selectProvider(.relaySync, transport: device.transport)
        _ = try await device.importGame(gbaBytes(seed: 97))
        await device.coordinator.transportDidUpdate(.init(lastProblem: .invalidRecord("hosted payload rejected; repair required")))
        try await device.coordinator.applyHostedPage(changes: [], deletions: [], cursor: 0, scope: "pending-status")
        let pending = await device.status
        XCTAssertGreaterThan(pending.pendingCount, 0)
        XCTAssertEqual(pending.problem, .failed("sync transport"))
        let batch = await device.coordinator.nextOutboundBatch(limit: 50)
        XCTAssertFalse(batch.isEmpty)
        await device.coordinator.didSend(batch.map { .init(key: $0.key, outcome: .saved) })
        let acknowledged = await device.status
        XCTAssertEqual(acknowledged.problem, .failed("sync transport"), "A push alone cannot prove a malformed pull recovered")
        try await device.coordinator.applyHostedPage(changes: [], deletions: [], cursor: 0, scope: "pending-status")
        let recovered = await device.status
        XCTAssertNil(recovered.problem)
    }
}

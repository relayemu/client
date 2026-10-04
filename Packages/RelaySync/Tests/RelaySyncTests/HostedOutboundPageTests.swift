// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
import RelayDomain
import RelayLibrary
@testable import RelaySync

final class HostedOutboundPageTests: XCTestCase {
    func testUnbuildablePrefixAdvancesToLaterValidIntentWithoutRotatingDiagnostics() async throws {
        let device = try await SimulatedDevice(name: "hosted-page-prefix", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.coordinator.selectProvider(.relaySync, transport: device.transport)
        try await device.store.syncStore.journal.enqueue([SyncIntent(kind: .gameEntry, key: "invalid-fingerprint")])
        let game = try await device.importGame(gbaBytes(seed: 81))
        let before = await device.coordinator.pendingEntries()
        XCTAssertEqual(before.count, 2)
        let first = try await device.coordinator.nextHostedOutboundPage(afterSequence: 0, throughSequence: nil, limit: 1)
        XCTAssertTrue(first.changes.isEmpty, "A malformed local intent has no outbound payload")
        XCTAssertEqual(first.nextAfterSequence, before[0].id)
        XCTAssertEqual(first.throughSequence, before[1].id)
        XCTAssertTrue(first.hasMore)
        let second = try await device.coordinator.nextHostedOutboundPage(afterSequence: first.nextAfterSequence,
                                                                        throughSequence: first.throughSequence, limit: 1)
        XCTAssertEqual(second.changes.map(\.key), [.game(game.contentFingerprint)])
        XCTAssertEqual(second.nextAfterSequence, before[1].id)
        XCTAssertFalse(second.hasMore)
        await device.coordinator.didSend(second.changes.map { .init(key: $0.key, outcome: .saved) })
        let after = await device.coordinator.pendingEntries()
        XCTAssertEqual(after.map(\.id), [before[0].id], "The unbuildable intent stays pending at its original diagnostic position")
    }

    func testFrozenRoundExcludesNewRowsAndAdvancesAcrossInFlightRows() async throws {
        let device = try await SimulatedDevice(name: "hosted-page-ceiling", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.coordinator.selectProvider(.relaySync, transport: device.transport)
        let firstGame = try await device.importGame(gbaBytes(seed: 82))
        let secondGame = try await device.importGame(gbaBytes(seed: 83))
        let initial = await device.coordinator.pendingEntries()
        let first = try await device.coordinator.nextHostedOutboundPage(afterSequence: 0, throughSequence: nil, limit: 1)
        XCTAssertEqual(first.changes.map(\.key), [.game(firstGame.contentFingerprint)])
        XCTAssertEqual(first.throughSequence, initial[1].id)
        let thirdGame = try await device.importGame(gbaBytes(seed: 84))
        let second = try await device.coordinator.nextHostedOutboundPage(afterSequence: first.nextAfterSequence,
                                                                        throughSequence: first.throughSequence, limit: 1)
        XCTAssertEqual(second.changes.map(\.key), [.game(secondGame.contentFingerprint)])
        XCTAssertFalse(second.hasMore, "A row created after the round's ceiling waits for the next round")
        let exhausted = try await device.coordinator.nextHostedOutboundPage(afterSequence: second.nextAfterSequence,
                                                                           throughSequence: second.throughSequence, limit: 1)
        XCTAssertTrue(exhausted.changes.isEmpty)
        XCTAssertEqual(exhausted.nextAfterSequence, second.nextAfterSequence)
        XCTAssertFalse(exhausted.hasMore)
        let nextRound = try await device.coordinator.nextHostedOutboundPage(afterSequence: 0, throughSequence: nil, limit: 10)
        let diagnostics = await device.coordinator.pendingEntries()
        XCTAssertEqual(nextRound.changes.map(\.key), [.game(thirdGame.contentFingerprint)], "Already admitted rows are not sent twice")
        XCTAssertEqual(nextRound.nextAfterSequence, diagnostics.last?.id)
        XCTAssertEqual(diagnostics.prefix(2).map(\.id), initial.map(\.id), "Cursor scans do not reorder oldest-first diagnostics")
        await device.coordinator.didSend((first.changes + second.changes + nextRound.changes).map {
            .init(key: $0.key, outcome: .failed(.network, serverRecord: nil))
        })
        let legacy = await device.coordinator.nextOutboundBatch(limit: 1)
        XCTAssertEqual(legacy.map(\.key), [.game(firstGame.contentFingerprint)], "The legacy transport keeps oldest-first retry semantics")
    }

    func testHostedPaginationRequiresSelectedAvailableAccountAndValidBounds() async throws {
        let device = try await SimulatedDevice(name: "hosted-page-admission", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        do {
            _ = try await device.coordinator.nextHostedOutboundPage(afterSequence: 0, throughSequence: nil, limit: 1)
            XCTFail("iCloud does not use the hosted scheduler")
        } catch { XCTAssertEqual(error as? SyncPageError, .inactiveProvider) }
        await device.coordinator.selectProvider(.relaySync, transport: device.transport)
        for (after, through, limit) in [(Int64(-1), Optional<Int64>.none, 1), (0, nil, 0), (0, nil, 1_001), (2, 1, 1)] {
            do {
                _ = try await device.coordinator.nextHostedOutboundPage(afterSequence: after, throughSequence: through, limit: limit)
                XCTFail("Invalid journal page bounds must be rejected")
            } catch { XCTAssertEqual(error as? SyncPageError, .invalidScope) }
        }
        await device.coordinator.accountDidChange(.init(availability: .available, identity: "different-account"))
        do {
            _ = try await device.coordinator.nextHostedOutboundPage(afterSequence: 0, throughSequence: nil, limit: 1)
            XCTFail("A pending account decision cannot admit outgoing work")
        } catch { XCTAssertEqual(error as? SyncPageError, .inactiveProvider) }
        await device.coordinator.selectProvider(.off, transport: nil)
        do {
            _ = try await device.coordinator.nextHostedOutboundPage(afterSequence: 0, throughSequence: nil, limit: 1)
            XCTFail("Off cannot admit outgoing work")
        } catch { XCTAssertEqual(error as? SyncPageError, .inactiveProvider) }
    }

    func testRetiredGenerationCannotReadHostedPage() async throws {
        let device = try await SimulatedDevice(name: "hosted-page-generation", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.coordinator.selectProvider(.relaySync, transport: device.transport)
        let epoch = await device.coordinator.transportEpoch
        let oldHost = GenerationTransportHost(coordinator: device.coordinator, epoch: epoch)
        await device.coordinator.selectProvider(.off, transport: nil)
        do {
            _ = try await oldHost.nextHostedOutboundPage(afterSequence: 0, throughSequence: nil, limit: 1)
            XCTFail("A retired page reader must fail rather than look like an exhausted round")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

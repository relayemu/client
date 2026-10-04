// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A retired transport may retain this host, but cannot mutate another provider's library state.
final class GenerationTransportHost: SyncTransportHost, Sendable {
    private let coordinator: SyncCoordinator
    private let epoch: UInt64

    init(coordinator: SyncCoordinator, epoch: UInt64) {
        self.coordinator = coordinator
        self.epoch = epoch
    }

    private func forward(_ operation: @Sendable (SyncCoordinator) async -> Void) async {
        guard await coordinator.beginTransportCallback(epoch: epoch) else { return }
        await operation(coordinator)
        await coordinator.endTransportCallback()
    }

    func nextOutboundBatch(limit: Int) async -> [OutboundChange] {
        guard await coordinator.beginTransportCallback(epoch: epoch) else { return [] }
        let batch = await coordinator.nextOutboundBatch(limit: limit)
        let current = await coordinator.transportCallbackIsCurrent(epoch: epoch)
        await coordinator.endTransportCallback()
        return current ? batch : []
    }

    func nextHostedOutboundPage(afterSequence: Int64, throughSequence: Int64?, limit: Int) async throws -> HostedOutboundPage {
        guard await coordinator.beginTransportCallback(epoch: epoch) else { throw CancellationError() }
        do {
            let page = try await coordinator.nextHostedOutboundPage(afterSequence: afterSequence, throughSequence: throughSequence, limit: limit)
            guard await coordinator.transportCallbackIsCurrent(epoch: epoch) else { throw CancellationError() }
            await coordinator.endTransportCallback()
            return page
        } catch {
            await coordinator.endTransportCallback()
            throw error
        }
    }

    func didSend(_ results: [SendResult]) async { await forward { await $0.didSend(results) } }
    func didFetch(changes: [InboundChange], deletions: [RecordKey]) async {
        await forward { await $0.didFetch(changes: changes, deletions: deletions) }
    }
    func accountDidChange(_ change: AccountChange) async { await forward { await $0.accountDidChange(change) } }
    func transportDidUpdate(_ status: TransportStatus) async { await forward { await $0.transportDidUpdate(status) } }
    func zoneWasReset() async { await forward { await $0.zoneWasReset() } }

    func applyHostedPage(changes: [InboundChange], deletions: [RecordKey], cursor: Int64, scope: String) async throws {
        guard await coordinator.beginTransportCallback(epoch: epoch) else { throw CancellationError() }
        do {
            try await coordinator.applyHostedPage(changes: changes, deletions: deletions, cursor: cursor, scope: scope)
            await coordinator.endTransportCallback()
        } catch {
            await coordinator.endTransportCallback()
            throw error
        }
    }

    func hostedPendingJournalIDs(in ids: [Int64]) async throws -> Set<Int64> {
        guard await coordinator.beginTransportCallback(epoch: epoch) else { throw CancellationError() }
        do {
            let pending = try await coordinator.hostedPendingJournalIDs(in: ids)
            await coordinator.endTransportCallback()
            return pending
        } catch {
            await coordinator.endTransportCallback()
            throw error
        }
    }

    func hostedCursor(scope: String) async throws -> Int64 {
        guard await coordinator.beginTransportCallback(epoch: epoch) else { throw CancellationError() }
        do {
            let cursor = try await coordinator.hostedCursor(scope: scope)
            await coordinator.endTransportCallback()
            return cursor
        } catch {
            await coordinator.endTransportCallback()
            throw error
        }
    }
}

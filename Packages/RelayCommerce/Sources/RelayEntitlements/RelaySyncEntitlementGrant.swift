// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Transport-independent, bounded observation of an authenticated Sync grant.
/// Persisting a grant never extends its validity. Recovery and unknown plans fail closed.
public struct RelaySyncEntitlementGrant: Equatable, Sendable {
    public let accountID: UUID
    public let validUntil: Date

    public init?(accountID: UUID, planID: String?, vaultState: String,
                 entitledUntil: Date?, observedAt: Date, sessionExpiresAt: Date) {
        guard vaultState == "ACTIVE", ["sync", "sync_plus"].contains(planID ?? ""),
              let entitledUntil, entitledUntil > observedAt, sessionExpiresAt > observedAt else { return nil }
        self.accountID = accountID
        // Remote revocation cannot remain cached indefinitely while offline.
        self.validUntil = min(entitledUntil, sessionExpiresAt, observedAt.addingTimeInterval(24 * 60 * 60))
    }

    public func isActive(at date: Date) -> Bool { date < validUntil }
}

extension RelayEntitlementState {
    public func includingSyncGrant(_ grant: RelaySyncEntitlementGrant?, at date: Date) -> RelayEntitlementState {
        RelayEntitlementState(
            activeProductIDs: activeProductIDs,
            familySharedProductIDs: familySharedProductIDs,
            additionalSources: grant?.isActive(at: date) == true ? [.relaySyncBundle] : []
        )
    }
}

/// Delegates all commerce to StoreKit and unions a separate Sync grant. Reading
/// state is synchronous; launch and gameplay never wait for a network refresh.
@MainActor
public final class CombinedRelayEntitlementProvider: RelayEntitlementProviding {
    private let store: any RelayEntitlementProviding
    private var syncGrant: RelaySyncEntitlementGrant?
    private let now: () -> Date
    private var storeTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<RelayEntitlementState>.Continuation] = [:]

    public var state: RelayEntitlementState { store.state.includingSyncGrant(syncGrant, at: now()) }

    public init(store: any RelayEntitlementProviding, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        storeTask = Task { [weak self, store] in
            for await _ in store.stateUpdates() {
                guard !Task.isCancelled, let self else { return }
                self.publish()
            }
        }
    }

    deinit { storeTask?.cancel(); expiryTask?.cancel() }

    public func updateSyncGrant(_ grant: RelaySyncEntitlementGrant?) {
        syncGrant = grant
        expiryTask?.cancel()
        if let grant, grant.isActive(at: now()) {
            let seconds = max(0, grant.validUntil.timeIntervalSince(now()))
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000)) }
                catch { return }
                self?.publish()
            }
        }
        publish()
    }

    public func stateUpdates() -> AsyncStream<RelayEntitlementState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers.removeValue(forKey: id) }
            }
        }
    }

    public func loadProducts() async throws -> [RelayStoreProduct] { try await store.loadProducts() }
    public func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome {
        switch try await store.purchase(productID) {
        case .purchased: publish(); return .purchased(state)
        case .pending: return .pending
        case .setupPending: return .setupPending
        case .userCancelled: return .userCancelled
        }
    }
    public func reconcileBilling() async throws { try await store.reconcileBilling(); publish() }
    public func restorePurchases() async throws -> RelayEntitlementState {
        _ = try await store.restorePurchases(); publish(); return state
    }
    public func refresh() async -> RelayEntitlementState {
        _ = await store.refresh(); publish(); return state
    }
    private func publish() { for observer in observers.values { observer.yield(state) } }
}

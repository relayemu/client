// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct RelaySubscriptionPeriod: Equatable, Sendable {
    public enum Unit: Sendable { case day, week, month, year }
    public let value: Int
    public let unit: Unit
    public init(value: Int, unit: Unit) { self.value = value; self.unit = unit }
}

/// The transport independently validates proof and refreshes the authenticated
/// backend grant. No transaction identity or local boolean authorizes service.
public protocol RelayBillingClaiming: Sendable {
    func claim(transactionJWS: String, accountID: UUID) async throws
}

public struct RelayStoreProduct: Equatable, Sendable {
    public let id: RelayProductID
    public let displayName: String
    public let description: String
    public let displayPrice: String
    public let subscriptionPeriod: RelaySubscriptionPeriod?

    public init(
        id: RelayProductID,
        displayName: String,
        description: String,
        displayPrice: String,
        subscriptionPeriod: RelaySubscriptionPeriod? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.subscriptionPeriod = subscriptionPeriod
    }
}

public enum RelayPurchaseOutcome: Equatable, Sendable {
    case purchased(RelayEntitlementState)
    case pending
    /// Apple accepted the purchase; server setup can be retried without buying again.
    case setupPending
    case userCancelled
}

public enum RelayEntitlementError: Error, Equatable, Sendable {
    case productUnavailable(RelayProductID)
    case failedVerification
    case accountRequired
    case accountMismatch
}

/// App-facing purchase boundary. Callers observe normalized state and never
/// handle StoreKit transactions directly.
@MainActor
public protocol RelayEntitlementProviding: AnyObject {
    var state: RelayEntitlementState { get }

    /// Each call returns an independent stream beginning with the current state.
    func stateUpdates() -> AsyncStream<RelayEntitlementState>
    func loadProducts() async throws -> [RelayStoreProduct]
    func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome
    func restorePurchases() async throws -> RelayEntitlementState
    func refresh() async -> RelayEntitlementState
    func reconcileBilling() async throws
}

extension RelayEntitlementProviding {
    public func reconcileBilling() async throws {}
}

/// Fail-closed provider for previews, tests and environments where the App
/// Store is intentionally unavailable. Local gameplay remains fully usable.
@MainActor
public final class UnavailableEntitlementProvider: RelayEntitlementProviding {
    public let state = RelayEntitlementState.free

    public init() {}

    public func stateUpdates() -> AsyncStream<RelayEntitlementState> {
        let state = self.state
        return AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    public func loadProducts() async throws -> [RelayStoreProduct] {
        []
    }

    public func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome {
        throw RelayEntitlementError.productUnavailable(productID)
    }

    public func restorePurchases() async throws -> RelayEntitlementState {
        state
    }

    public func refresh() async -> RelayEntitlementState {
        state
    }
}

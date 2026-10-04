// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import RelayEntitlements

public enum RelaySyncPurchaseNotice: Equatable, Sendable {
    case ready, accountRequired, pending, cancelled, setupPending, accountMismatch
    case restored, productUnavailable, verificationFailed, storeUnavailable
}

/// Native membership presentation. A completed Apple sheet is never interpreted
/// as hosted authorization; the account snapshot remains the entitlement source.
@MainActor @Observable
public final class RelaySyncMembershipModel {
    public private(set) var products: [RelayProductID: RelayStoreProduct] = [:]
    public private(set) var accountID: UUID?
    public private(set) var hasDirectProOnceBonus = false
    public private(set) var isLoading = false
    public private(set) var isWorking = false
    public private(set) var purchasingProductID: RelayProductID?
    public private(set) var notice: RelaySyncPurchaseNotice?
    private let provider: any RelayEntitlementProviding

    public init(provider: any RelayEntitlementProviding) { self.provider = provider }

    public func updateAccount(_ accountID: UUID?, directProOnceVerified: Bool = false) {
        if self.accountID != accountID { notice = nil }
        self.accountID = accountID
        hasDirectProOnceBonus = accountID != nil && directProOnceVerified
    }

    /// The bonus is derived exclusively from an authenticated backend response,
    /// never from local StoreKit Pro or family-shared ownership.
    public func quotaGB(isPlus: Bool) -> Int {
        isPlus ? (hasDirectProOnceBonus ? 600 : 500) : (hasDirectProOnceBonus ? 125 : 100)
    }

    public func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            products = Dictionary(uniqueKeysWithValues: try await provider.loadProducts().map { ($0.id, $0) })
            if products.isEmpty { notice = .productUnavailable }
        } catch { notice = .storeUnavailable }
    }

    public func purchase(_ productID: RelayProductID) async {
        guard accountID != nil else { notice = .accountRequired; return }
        guard !isWorking else { return }
        let purchasingAccount = accountID
        isWorking = true; purchasingProductID = productID; notice = nil
        defer { isWorking = false; purchasingProductID = nil }
        do {
            let result = try await provider.purchase(productID)
            guard purchasingAccount == accountID else { return }
            switch result {
            case .purchased: notice = .ready
            case .setupPending: notice = .setupPending
            case .pending: notice = .pending
            case .userCancelled: notice = .cancelled
            }
        } catch { if purchasingAccount == accountID { show(error) } }
    }

    /// This is the only membership action that asks Apple to restore purchases.
    public func restore() async {
        guard accountID != nil else { notice = .accountRequired; return }
        guard !isWorking else { return }
        let restoringAccount = accountID
        var restoredFromApple = false
        isWorking = true; notice = nil
        defer { isWorking = false }
        do {
            _ = try await provider.restorePurchases()
            restoredFromApple = true
            try await provider.reconcileBilling()
            guard restoringAccount == accountID else { return }
            notice = .restored
        } catch { if restoringAccount == accountID { show(error, reconciling: restoredFromApple) } }
    }

    public func retrySetup(announceSuccess: Bool = true) async {
        guard accountID != nil else { notice = .accountRequired; return }
        guard !isWorking else { return }
        let reconcilingAccount = accountID
        isWorking = true
        if announceSuccess { notice = nil }
        defer { isWorking = false }
        do {
            try await provider.reconcileBilling()
            guard reconcilingAccount == accountID else { return }
            if announceSuccess { notice = .ready }
        } catch { if reconcilingAccount == accountID { show(error, reconciling: true) } }
    }

    private func show(_ error: Error, reconciling: Bool = false) {
        switch error {
        case RelayEntitlementError.accountRequired: notice = .accountRequired
        case RelayEntitlementError.accountMismatch: notice = .accountMismatch
        case RelayEntitlementError.failedVerification: notice = .verificationFailed
        case RelayEntitlementError.productUnavailable: notice = .productUnavailable
        default: notice = reconciling ? .setupPending : .storeUnavailable
        }
    }
}

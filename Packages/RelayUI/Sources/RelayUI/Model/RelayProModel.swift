// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import RelayEntitlements

public enum RelayProNotice: Equatable, Sendable {
    case purchased
    case setupPending
    case accountMismatch
    case restored
    case nothingToRestore
    case pending
    case cancelled
    case productUnavailable
    case verificationFailed
    case storeUnavailable
}

/// Observable, StoreKit-free product model for Relay Pro. StoreKit prices and
/// transactions arrive through the portable entitlement provider boundary.
@MainActor
@Observable
public final class RelayProModel {
    public private(set) var entitlement: RelayEntitlementState {
        didSet {
            guard entitlement != oldValue else { return }
            entitlementDidChange?(entitlement)
        }
    }
    public private(set) var products: [RelayProductID: RelayStoreProduct] = [:]
    public private(set) var isLoadingProduct = false
    public private(set) var purchasingProductID: RelayProductID?
    public private(set) var isRestoring = false
    public private(set) var notice: RelayProNotice?

    private let provider: any RelayEntitlementProviding
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored var entitlementDidChange: ((RelayEntitlementState) -> Void)?

    public init(provider: any RelayEntitlementProviding) {
        self.provider = provider
        entitlement = provider.state
    }

    deinit { observationTask?.cancel() }

    public var isPro: Bool { entitlement.accessLevel == .pro }
    public var onceProduct: RelayStoreProduct? { products[.proOnce] }
    public var monthlyProduct: RelayStoreProduct? { products[.proMonthly] }
    public var isPurchasing: Bool { purchasingProductID != nil }

    /// Starts live entitlement observation without delaying app or game launch.
    public func start() {
        guard observationTask == nil else { return }
        let updates = provider.stateUpdates()
        observationTask = Task { [weak self] in
            for await state in updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                entitlement = state
            }
        }
        Task { [weak self] in await self?.loadProduct() }
    }

    public func loadProduct() async {
        guard !isLoadingProduct else { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            products = Dictionary(uniqueKeysWithValues: try await provider.loadProducts().map { ($0.id, $0) })
            if onceProduct == nil || monthlyProduct == nil { notice = .productUnavailable }
        } catch {
            products = [:]
            notice = .storeUnavailable
        }
    }

    /// Reconciles subscription expiry/refund/account changes from StoreKit.
    /// Callers run this after launch or foregrounding; gameplay never waits on it.
    public func refresh() async {
        entitlement = await provider.refresh()
    }

    public func purchase(_ productID: RelayProductID) async {
        guard !isPurchasing else { return }
        purchasingProductID = productID
        notice = nil
        defer { purchasingProductID = nil }
        do {
            switch try await provider.purchase(productID) {
            case .purchased(let state):
                entitlement = state
                notice = state.accessLevel == .pro ? .purchased : .verificationFailed
            case .setupPending: notice = .setupPending
            case .pending: notice = .pending
            case .userCancelled: notice = .cancelled
            }
        } catch RelayEntitlementError.accountMismatch {
            notice = .accountMismatch
        } catch RelayEntitlementError.failedVerification {
            notice = .verificationFailed
        } catch RelayEntitlementError.productUnavailable {
            notice = .productUnavailable
        } catch {
            notice = .storeUnavailable
        }
    }

    public func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        notice = nil
        defer { isRestoring = false }
        do {
            let restored = try await provider.restorePurchases()
            entitlement = restored
            notice = restored.accessLevel == .pro ? .restored : .nothingToRestore
        } catch {
            notice = .storeUnavailable
        }
    }

    public func clearNotice() { notice = nil }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayEntitlements
@testable import RelayUI

@MainActor final class RelaySyncMembershipModelTests: XCTestCase {
    func testAccountRequiredBeforeAnyApplePurchaseOrRestore() async {
        let provider = MembershipProvider()
        let model = RelaySyncMembershipModel(provider: provider)
        await model.purchase(.syncMonthly)
        await model.restore()
        XCTAssertEqual(model.notice, .accountRequired)
        XCTAssertEqual(provider.purchases, [])
        XCTAssertEqual(provider.restores, 0)
    }

    func testBackendFailureAfterPurchaseCanRetryWithoutAnotherPurchaseOrRestore() async {
        let provider = MembershipProvider()
        provider.outcome = .setupPending
        let model = RelaySyncMembershipModel(provider: provider)
        model.updateAccount(UUID())
        await model.purchase(.syncMonthly)
        XCTAssertEqual(model.notice, .setupPending)
        await model.retrySetup()
        XCTAssertEqual(model.notice, .ready)
        XCTAssertEqual(provider.purchases, [.syncMonthly])
        XCTAssertEqual(provider.reconciliations, 1)
        XCTAssertEqual(provider.restores, 0)
        XCTAssertEqual(provider.state, .free, "Presentation cannot invent a backend Pro grant")
    }

    func testPendingAndCancellationSurviveBackgroundReconciliation() async {
        let provider = MembershipProvider()
        let model = RelaySyncMembershipModel(provider: provider)
        model.updateAccount(UUID())
        for (outcome, notice) in [(RelayPurchaseOutcome.pending, RelaySyncPurchaseNotice.pending),
                                  (.userCancelled, .cancelled)] {
            provider.outcome = outcome
            await model.purchase(.syncPlusYearly)
            await model.retrySetup(announceSuccess: false)
            XCTAssertEqual(model.notice, notice)
            XCTAssertEqual(provider.state, .free)
        }
    }

    func testAccountMismatchIsSafeAndDoesNotExposeProviderDetails() async {
        let provider = MembershipProvider()
        provider.purchaseError = RelayEntitlementError.accountMismatch
        let model = RelaySyncMembershipModel(provider: provider)
        model.updateAccount(UUID())
        await model.purchase(.syncYearly)
        XCTAssertEqual(model.notice, .accountMismatch)
        XCTAssertEqual(model.notice?.message, L("This Relay Sync subscription is linked to another Relay account."))
        XCTAssertFalse(model.notice?.message.contains("@") ?? true)
    }

    func testLocalProAndFamilySharingNeverImplyLoyaltyQuota() {
        let provider = MembershipProvider()
        provider.state = RelayEntitlementState(activeProductIDs: [.proOnce])
        let model = RelaySyncMembershipModel(provider: provider)
        model.updateAccount(UUID())
        XCTAssertEqual(model.quotaGB(isPlus: false), 100)
        XCTAssertEqual(model.quotaGB(isPlus: true), 500)
        model.updateAccount(model.accountID, directProOnceVerified: true)
        XCTAssertEqual(model.quotaGB(isPlus: false), 125)
        XCTAssertEqual(model.quotaGB(isPlus: true), 600)
        model.updateAccount(nil, directProOnceVerified: true)
        XCTAssertEqual(model.quotaGB(isPlus: false), 100)
        XCTAssertEqual(model.quotaGB(isPlus: true), 500)
    }

    func testAccountChangeClearsPreviousSetupAndBonus() async {
        let provider = MembershipProvider()
        provider.outcome = .setupPending
        let model = RelaySyncMembershipModel(provider: provider)
        model.updateAccount(UUID(), directProOnceVerified: true)
        await model.purchase(.syncPlusMonthly)
        model.updateAccount(UUID())
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.hasDirectProOnceBonus)
    }

    func testStoreKitPricesAndPeriodsAreRetainedWithoutFallbackPrices() async {
        let provider = MembershipProvider()
        let product = RelayStoreProduct(id: .syncYearly, displayName: "Sync", description: "",
                                        displayPrice: "CHF 47.00", subscriptionPeriod: .init(value: 1, unit: .year))
        provider.products = [product]
        let model = RelaySyncMembershipModel(provider: provider)
        await model.loadProducts()
        XCTAssertEqual(model.products[.syncYearly], product)
        XCTAssertNil(model.products[.syncMonthly])
        XCTAssertEqual(provider.restores, 0)
    }

    func testLatePurchaseDoesNotAttachNoticeToDifferentRelayAccount() async {
        let provider = MembershipProvider()
        provider.suspendPurchase = true
        let model = RelaySyncMembershipModel(provider: provider)
        model.updateAccount(UUID())
        let purchase = Task { await model.purchase(.syncMonthly) }
        while provider.purchaseContinuation == nil { await Task.yield() }
        model.updateAccount(UUID())
        provider.purchaseContinuation?.resume(returning: .setupPending)
        await purchase.value
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isWorking)
    }

    func testFailedRetryStaysRecoverableWithoutRestoringOrRepurchasing() async {
        let provider = MembershipProvider()
        provider.reconciliationError = URLError(.notConnectedToInternet)
        let model = RelaySyncMembershipModel(provider: provider)
        model.updateAccount(UUID())
        await model.retrySetup()
        XCTAssertEqual(model.notice, .setupPending)
        XCTAssertEqual(provider.restores, 0)
        XCTAssertEqual(provider.purchases, [])
        provider.reconciliationError = nil
        await model.retrySetup()
        XCTAssertEqual(model.notice, .ready)
    }

    func testRestoreOnlyOccursOnExplicitAction() async {
        let provider = MembershipProvider()
        let model = RelaySyncMembershipModel(provider: provider)
        model.updateAccount(UUID())
        await model.loadProducts()
        await model.retrySetup(announceSuccess: false)
        XCTAssertEqual(provider.restores, 0)
        await model.restore()
        XCTAssertEqual(provider.restores, 1)
        XCTAssertEqual(model.notice, .restored)
    }
}

@MainActor private final class MembershipProvider: RelayEntitlementProviding {
    var state = RelayEntitlementState.free
    var products: [RelayStoreProduct] = []
    var outcome: RelayPurchaseOutcome = .userCancelled
    var purchaseError: Error?
    var reconciliationError: Error?
    var suspendPurchase = false
    var purchaseContinuation: CheckedContinuation<RelayPurchaseOutcome, Never>?
    var purchases: [RelayProductID] = []
    var restores = 0
    var reconciliations = 0
    func stateUpdates() -> AsyncStream<RelayEntitlementState> { AsyncStream { $0.finish() } }
    func loadProducts() async throws -> [RelayStoreProduct] { products }
    func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome {
        purchases.append(productID)
        if let purchaseError { throw purchaseError }
        if suspendPurchase { return await withCheckedContinuation { purchaseContinuation = $0 } }
        return outcome
    }
    func restorePurchases() async throws -> RelayEntitlementState { restores += 1; return state }
    func reconcileBilling() async throws {
        reconciliations += 1
        if let reconciliationError { throw reconciliationError }
    }
    func refresh() async -> RelayEntitlementState { state }
}

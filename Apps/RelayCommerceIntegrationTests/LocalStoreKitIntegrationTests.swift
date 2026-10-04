// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import StoreKit
import StoreKitTest
import XCTest
import RelayEntitlements
import RelayStoreKit

@MainActor
final class AppleSandboxCatalogTests: XCTestCase {
    func testInspectSandboxEntitlements() async throws {
        guard ProcessInfo.processInfo.environment["RELAY_APPLE_CATALOG_GROUP"] != nil else {
            throw XCTSkip("Requires an explicit real Sandbox qualification run")
        }
        var currentCount = 0
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                XCTFail("Unverified current StoreKit entitlement")
                continue
            }
            currentCount += 1
            XCTAssertEqual(transaction.environment, .sandbox)
            print("APPLE_CURRENT product=\(transaction.productID) environment=\(transaction.environment.rawValue) tokenPresent=\(transaction.appAccountToken != nil)")
        }
        var unfinishedCount = 0
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else {
                XCTFail("Unverified unfinished StoreKit transaction")
                continue
            }
            unfinishedCount += 1
            XCTAssertEqual(transaction.environment, .sandbox)
            print("APPLE_UNFINISHED product=\(transaction.productID) environment=\(transaction.environment.rawValue) tokenPresent=\(transaction.appAccountToken != nil)")
        }
        print("APPLE_TRANSACTION_COUNTS current=\(currentCount) unfinished=\(unfinishedCount)")
    }

    func testConfiguredAppleCatalog() async throws {
        guard let expectedGroup = ProcessInfo.processInfo.environment["RELAY_APPLE_CATALOG_GROUP"] else {
            throw XCTSkip("Requires an explicit Apple catalog group and a scheme without StoreKit configuration")
        }
        let identifiers = Set(RelayProductID.supported.map(\.rawValue))
        let products = try await Product.products(for: identifiers)
        XCTAssertEqual(Set(products.map(\.id)), identifiers)
        for product in products.sorted(by: { $0.id < $1.id }) {
            let group = product.subscription?.subscriptionGroupID ?? "none"
            print("APPLE_CATALOG id=\(product.id) price=\(product.displayPrice) group=\(group)")
            if product.subscription != nil {
                XCTAssertEqual(group, expectedGroup, "Product must come from the configured Apple group")
            }
        }
    }
}

@MainActor
final class LocalStoreKitIntegrationTests: XCTestCase {
    private let onceProductID = RelayProductID.proOnce.rawValue
    private let monthlyProductID = RelayProductID.proMonthly.rawValue

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLocalProductPurchasesRestoresAndRevokesThroughStoreKit() async throws {
        let session = try SKTestSession(configurationFileNamed: "Relay")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.clearTransactions()

        let provider = StoreKitEntitlementProvider()
        let products = try await provider.loadProducts()
        XCTAssertEqual(Set(products.map(\.id)), RelayProductID.supported)
        XCTAssertFalse(try XCTUnwrap(products.first?.displayPrice).isEmpty)
        let initial = await provider.refresh()
        XCTAssertEqual(initial, .free)

        let purchase = try await provider.purchase(.proOnce)
        guard case .purchased(let purchasedState) = purchase else {
            return XCTFail("the local non-consumable did not complete")
        }
        XCTAssertEqual(purchasedState.accessLevel, .pro)

        let restored = try await provider.restorePurchases()
        XCTAssertEqual(restored.accessLevel, .pro)

        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == onceProductID })
        try session.refundTransaction(identifier: transaction.identifier)

        try await refreshUntilFree(provider)
        XCTAssertEqual(provider.state, .free)
    }

    func testMonthlySubscriptionGrantsProAndExpiresLive() async throws {
        let session = try SKTestSession(configurationFileNamed: "Relay")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.clearTransactions()

        let provider = StoreKitEntitlementProvider()
        _ = try await provider.loadProducts()
        let purchase = try await provider.purchase(.proMonthly)
        guard case .purchased(let purchasedState) = purchase else {
            return XCTFail("the local monthly subscription did not complete")
        }
        XCTAssertEqual(purchasedState.accessLevel, .pro)
        XCTAssertEqual(purchasedState.activeProductIDs, [.proMonthly])

        try session.expireSubscription(productIdentifier: monthlyProductID)
        try await refreshUntilFree(provider)
        XCTAssertEqual(provider.state, .free)
    }

    func testAskToBuyProducesPendingWithoutGrantingPro() async throws {
        let session = try SKTestSession(configurationFileNamed: "Relay")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.askToBuyEnabled = true

        let provider = StoreKitEntitlementProvider()
        _ = try await provider.loadProducts()

        let result = try await provider.purchase(.proOnce)
        XCTAssertEqual(result, .pending)
        XCTAssertEqual(provider.state, .free)
    }

    func testMembershipUpgradesCarryAccountTokenAndVerifiedProofThroughStoreKit() async throws {
        let session = try cleanSession()
        let account = UUID()
        let billing = LocalBillingRecorder()
        let provider = StoreKitEntitlementProvider()
        provider.setBillingBridge(billing); provider.setBillingAccountID(account)
        _ = try await provider.loadProducts()
        _ = try await provider.purchase(.proMonthly)
        XCTAssertEqual(provider.state.activeProductIDs, [.proMonthly])
        _ = try await provider.purchase(.syncMonthly)
        try await waitForCurrentMembership(.syncMonthly)
        _ = try await provider.purchase(.syncPlusMonthly)
        try await waitForCurrentMembership(.syncPlusMonthly)
        let currentTransaction = await awaitCurrentTransaction(.syncPlusMonthly)
        let current = try XCTUnwrap(currentTransaction)
        XCTAssertEqual(current.appAccountToken, account)
        XCTAssertEqual(current.ownershipType, .purchased)
        XCTAssertEqual(provider.state, .free, "Only the backend can grant Sync-derived Pro")
        let claims = await billing.claims
        XCTAssertTrue(claims.contains { $0.0.split(separator: ".").count == 3 && $0.1 == account })
        XCTAssertFalse(session.allTransactions().isEmpty)
    }

    func testMembershipDowngradeRemainsPendingInAppleStatus() async throws {
        let session = try cleanSession()
        defer { withExtendedLifetime(session) {} }
        let provider = StoreKitEntitlementProvider()
        provider.setBillingBridge(LocalBillingRecorder()); provider.setBillingAccountID(UUID())
        _ = try await provider.loadProducts()
        try await purchaseSuccessfully(.syncPlusMonthly, using: provider)
        try await waitForCurrentMembership(.syncPlusMonthly)
        try await purchaseSuccessfully(.syncMonthly, using: provider)
        try await waitForRenewalPreference(.syncMonthly, current: .syncPlusMonthly)
        XCTAssertEqual(provider.state, .free)
    }

    func testMembershipPeriodChangeFollowsVerifiedAppleStatus() async throws {
        let session = try cleanSession()
        defer { withExtendedLifetime(session) {} }
        let provider = StoreKitEntitlementProvider()
        provider.setBillingBridge(LocalBillingRecorder()); provider.setBillingAccountID(UUID())
        _ = try await provider.loadProducts()
        try await purchaseSuccessfully(.syncPlusMonthly, using: provider)
        try await waitForCurrentMembership(.syncPlusMonthly)
        try await purchaseSuccessfully(.syncPlusYearly, using: provider)
        try await waitForRenewalPreference(.syncPlusYearly, current: .syncPlusMonthly,
                                           alternateCurrent: .syncPlusYearly)
        XCTAssertEqual(provider.state, .free)
    }

    func testUnfinishedHostedPurchaseRecoversAndRestoresWithoutAnotherPurchase() async throws {
        let session = try cleanSession()
        let account = UUID(); let billing = LocalBillingRecorder()
        await billing.setUnavailable(true)
        let provider = StoreKitEntitlementProvider()
        provider.setBillingBridge(billing); provider.setBillingAccountID(account)
        _ = try await provider.loadProducts()
        let result = try await provider.purchase(.syncYearly)
        XCTAssertEqual(result, .setupPending)
        let purchaseCount = session.allTransactions().count
        await billing.setUnavailable(false)
        try await provider.reconcileBilling()
        _ = try await provider.restorePurchases()
        XCTAssertEqual(session.allTransactions().count, purchaseCount)
        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.refundTransaction(identifier: transaction.identifier)
        _ = await provider.refresh()
        XCTAssertEqual(provider.state, .free)
    }

    private func cleanSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "Relay")
        session.resetToDefaultState(); session.disableDialogs = true
        session.askToBuyEnabled = false; session.clearTransactions()
        return session
    }

    private func purchaseSuccessfully(_ id: RelayProductID, using provider: StoreKitEntitlementProvider) async throws {
        let outcome = try await provider.purchase(id)
        guard case .purchased = outcome else {
            XCTFail("StoreKit purchase of \(id.rawValue) returned \(outcome)")
            throw RelayEntitlementError.failedVerification
        }
    }

    private func awaitCurrentTransaction(_ id: RelayProductID) async -> StoreKit.Transaction? {
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == id.rawValue,
               !transaction.isUpgraded, transaction.revocationDate == nil { return transaction }
        }
        return nil
    }

    private func waitForCurrentMembership(_ id: RelayProductID) async throws {
        for _ in 0..<100 {
            var current: Set<String> = []
            for await result in StoreKit.Transaction.currentEntitlements {
                if case .verified(let transaction) = result, !transaction.isUpgraded,
                   transaction.revocationDate == nil,
                   RelayProductID(rawValue: transaction.productID).subscriptionLevel != nil {
                    current.insert(transaction.productID)
                }
            }
            if current == [id.rawValue] { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("StoreKit did not make the requested membership current")
    }

    private func waitForRenewalPreference(_ preferred: RelayProductID, current: RelayProductID,
                                          alternateCurrent: RelayProductID? = nil) async throws {
        let products = try await Product.products(for: [current.rawValue])
        let subscription = try XCTUnwrap(products.first?.subscription)
        var observed: [String] = []
        for _ in 0..<100 {
            observed = []
            for status in try await subscription.status {
                let transactionState: String
                switch status.transaction {
                case .verified(let transaction): transactionState = transaction.productID
                case .unverified: transactionState = "unverified transaction"
                }
                let renewalState: String
                switch status.renewalInfo {
                case .verified(let renewal): renewalState = renewal.autoRenewPreference ?? "no renewal preference"
                case .unverified: renewalState = "unverified renewal"
                }
                observed.append("\(transactionState) -> \(renewalState)")
                if case .verified(let transaction) = status.transaction,
                   case .verified(let renewal) = status.renewalInfo,
                   (transaction.productID == current.rawValue || transaction.productID == alternateCurrent?.rawValue),
                   !transaction.isUpgraded, transaction.revocationDate == nil,
                   transaction.expirationDate.map({ $0 > Date() }) == true,
                   renewal.currentProductID == transaction.productID,
                   renewal.autoRenewPreference == preferred.rawValue { return }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("StoreKit expected \(current.rawValue) -> \(preferred.rawValue); observed \(observed)")
    }

    /// SKTestSession mutates StoreKit's test ledger. Re-read the public current-
    /// entitlement sequence exactly as the app does on foreground; adapter-level
    /// tests separately prove that Transaction.updates changes state immediately.
    private func refreshUntilFree(_ provider: StoreKitEntitlementProvider) async throws {
        for _ in 0..<100 {
            if await provider.refresh() == .free { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Deliberately records only the local adapter boundary. It is not an Apple
/// server verifier and its success never synthesizes a backend entitlement.
private actor LocalBillingRecorder: RelayBillingClaiming {
    var claims: [(String, UUID)] = []
    private var unavailable = false
    func setUnavailable(_ value: Bool) { unavailable = value }
    func claim(transactionJWS: String, accountID: UUID) async throws {
        claims.append((transactionJWS, accountID))
        if unavailable { throw URLError(.notConnectedToInternet) }
    }
}

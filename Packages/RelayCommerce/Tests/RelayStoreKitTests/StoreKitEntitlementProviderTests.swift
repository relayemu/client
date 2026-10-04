// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayEntitlements
@testable import RelayStoreKit

@MainActor
final class StoreKitEntitlementProviderTests: XCTestCase {
    func testAllHostedProductsRequireAccountBeforeApplePurchase() async throws {
        for id in RelayProductID.hosted {
            let client = TestStoreKitClient()
            client.products = [client.product(id: id.rawValue)]
            let provider = StoreKitEntitlementProvider(client: client)
            do { _ = try await provider.purchase(id); XCTFail("Signed-out purchase accepted") }
            catch { XCTAssertEqual(error as? RelayEntitlementError, .accountRequired) }
            XCTAssertEqual(client.purchaseCount, 0)
        }
    }

    func testHostedPurchaseUsesAccountUUIDAndVerifiedJWSWithoutGrantingLocalPro() async throws {
        let account = UUID()
        let client = TestStoreKitClient()
        client.products = [client.product(id: RelayProductID.syncMonthly.rawValue)]
        client.nextPurchase = .success(.verified(client.transaction(.syncMonthly, token: account)))
        let billing = TestBilling()
        let provider = StoreKitEntitlementProvider(client: client)
        provider.setBillingBridge(billing); provider.setBillingAccountID(account)
        let result = try await provider.purchase(.syncMonthly)
        XCTAssertEqual(result, .purchased(.free))
        XCTAssertEqual(client.purchaseToken, account)
        XCTAssertEqual(provider.state, .free)
        let claims = await billing.claims
        XCTAssertEqual(claims.last?.0, "signed.test.proof")
        XCTAssertEqual(claims.last?.1, account)
        XCTAssertEqual(client.finishCount, 1)
    }

    func testBackendFailureKeepsTransactionUnfinishedAndRetryReacquiresProof() async throws {
        let account = UUID(); let client = TestStoreKitClient(); let billing = TestBilling()
        client.products = [client.product(id: RelayProductID.syncPlusYearly.rawValue)]
        let transaction = client.transaction(.syncPlusYearly, token: account)
        client.nextPurchase = .success(.verified(transaction))
        await billing.setFailure(true)
        let provider = StoreKitEntitlementProvider(client: client)
        provider.setBillingBridge(billing); provider.setBillingAccountID(account)
        let result = try await provider.purchase(.syncPlusYearly)
        XCTAssertEqual(result, .setupPending)
        XCTAssertEqual(client.finishCount, 0)
        XCTAssertEqual(provider.state, .free)
        client.unfinished = [.verified(transaction)]
        await billing.setFailure(false)
        try await provider.reconcileBilling()
        XCTAssertEqual(client.finishCount, 1)
        XCTAssertEqual(client.synchronizeCount, 0)
    }

    func testMismatchedAccountFailsClosedAndNeverSubmitsProof() async throws {
        let client = TestStoreKitClient(); let billing = TestBilling()
        client.products = [client.product(id: RelayProductID.syncMonthly.rawValue)]
        client.nextPurchase = .success(.verified(client.transaction(.syncMonthly, token: UUID())))
        let provider = StoreKitEntitlementProvider(client: client)
        provider.setBillingBridge(billing); provider.setBillingAccountID(UUID())
        do { _ = try await provider.purchase(.syncMonthly); XCTFail("Account mismatch accepted") }
        catch { XCTAssertEqual(error as? RelayEntitlementError, .accountMismatch) }
        let claims = await billing.claims
        XCTAssertTrue(claims.isEmpty)
        XCTAssertEqual(client.finishCount, 0)
    }

    func testFamilySharedProOnceGrantsLocalProWithoutSubmittingLoyaltyProof() async throws {
        let client = TestStoreKitClient(); let billing = TestBilling()
        client.current = [.verified(client.transaction(.proOnce, ownership: .familyShared))]
        let provider = StoreKitEntitlementProvider(client: client)
        provider.setBillingBridge(billing); provider.setBillingAccountID(UUID())
        let state = await provider.refresh()
        XCTAssertEqual(state.accessLevel, .pro)
        try await provider.reconcileBilling()
        let claims = await billing.claims
        XCTAssertTrue(claims.isEmpty)
    }

    func testFamilySharedSyncFailsClosed() async throws {
        let client = TestStoreKitClient(); let billing = TestBilling()
        client.products = [client.product(id: RelayProductID.syncMonthly.rawValue)]
        client.nextPurchase = .success(.verified(client.transaction(.syncMonthly, ownership: .familyShared)))
        let provider = StoreKitEntitlementProvider(client: client)
        provider.setBillingBridge(billing); provider.setBillingAccountID(UUID())
        let result = try await provider.purchase(.syncMonthly)
        XCTAssertEqual(result, .setupPending)
        XCTAssertEqual(provider.state, .free)
        let claims = await billing.claims
        XCTAssertTrue(claims.isEmpty)
    }

    func testPendingDowngradeUsesReturnedCurrentProductNotClickedProduct() async throws {
        let account = UUID(); let client = TestStoreKitClient(); let billing = TestBilling()
        client.products = [client.product(id: RelayProductID.syncMonthly.rawValue)]
        // Apple keeps Sync+ effective until the future downgrade date.
        client.nextPurchase = .success(.verified(client.transaction(.syncPlusMonthly, token: account)))
        let provider = StoreKitEntitlementProvider(client: client)
        provider.setBillingBridge(billing); provider.setBillingAccountID(account)
        let result = try await provider.purchase(.syncMonthly)
        XCTAssertEqual(result, .purchased(.free))
        XCTAssertEqual(provider.state.activeProductIDs, [])
        let claims = await billing.claims
        XCTAssertEqual(claims.count, 1)
    }

    func testForegroundAndReinstallReconciliationNeverInvokeExplicitRestore() async throws {
        let client = TestStoreKitClient(); let billing = TestBilling()
        client.current = [.verified(client.transaction(.syncYearly))]
        let provider = StoreKitEntitlementProvider(client: client)
        provider.setBillingBridge(billing); provider.setBillingAccountID(UUID())
        _ = await provider.refresh()
        try await provider.reconcileBilling()
        XCTAssertEqual(client.synchronizeCount, 0)
        let claims = await billing.claims
        XCTAssertFalse(claims.isEmpty)
        XCTAssertEqual(provider.state, .free)
    }

    func testEffectiveHostedUpgradeReplacesMonthlyButPreservesLifetime() async throws {
        let client = TestStoreKitClient(); let billing = TestBilling()
        client.current = [.verified(client.transaction(.proOnce)), .verified(client.transaction(.proMonthly))]
        client.products = [client.product(id: RelayProductID.syncMonthly.rawValue)]
        client.nextPurchase = .success(.verified(client.transaction(.syncMonthly, signedDate: Date())))
        let provider = StoreKitEntitlementProvider(client: client)
        _ = await provider.refresh()
        provider.setBillingBridge(billing); provider.setBillingAccountID(UUID())
        _ = try await provider.purchase(.syncMonthly)
        XCTAssertEqual(provider.state.activeProductIDs, [.proOnce])
    }

    func testSimultaneousBillingReconciliationCoalescesIdenticalProof() async throws {
        let client = TestStoreKitClient(); let billing = PausingBilling()
        let provider = StoreKitEntitlementProvider(client: client)
        _ = await provider.refresh()
        client.unfinished = [.verified(client.transaction(.syncMonthly))]
        provider.setBillingBridge(billing); provider.setBillingAccountID(UUID())
        let first = Task { try await provider.reconcileBilling() }
        while await billing.count == 0 { await Task.yield() }
        let second = Task { try await provider.reconcileBilling() }
        for _ in 0..<20 { await Task.yield() }
        let count = await billing.count
        XCTAssertEqual(count, 1)
        await billing.release()
        try await first.value; try await second.value
    }

    func testLocalStateReadDoesNotWaitForPausedBillingRequest() async throws {
        let client = TestStoreKitClient(); let billing = PausingBilling()
        let provider = StoreKitEntitlementProvider(client: client)
        _ = await provider.refresh()
        client.unfinished = [.verified(client.transaction(.syncMonthly))]
        provider.setBillingBridge(billing); provider.setBillingAccountID(UUID())
        let refresh = Task { try await provider.reconcileBilling() }
        while await billing.count == 0 { await Task.yield() }
        XCTAssertEqual(provider.state, .free)
        await billing.release(); try await refresh.value
    }

    func testStalledHostedClaimDoesNotDelayLocalRefundOrMonthlyUpdate() async throws {
        let client = TestStoreKitClient(); let billing = PausingBilling()
        let provider = StoreKitEntitlementProvider(client: client)
        _ = await provider.refresh()
        while !client.isListening { await Task.yield() }
        client.send(.verified(client.transaction(.proOnce, signedDate: Date(timeIntervalSince1970: 100))))
        for _ in 0..<1_000 {
            if provider.state.ownsProOnce { break }
            await Task.yield()
        }
        XCTAssertTrue(provider.state.ownsProOnce)
        provider.setBillingBridge(billing); provider.setBillingAccountID(UUID())
        client.send(.verified(client.transaction(.syncMonthly, signedDate: Date(timeIntervalSince1970: 200))))
        while await billing.count == 0 { await Task.yield() }
        client.send(.verified(client.transaction(.proOnce, isActive: false, signedDate: Date(timeIntervalSince1970: 300))))
        for _ in 0..<1_000 {
            if provider.state == .free { break }
            await Task.yield()
        }
        XCTAssertEqual(provider.state, .free, "Local refund must apply before the server returns")
        client.send(.verified(client.transaction(.proMonthly, signedDate: Date(timeIntervalSince1970: 400))))
        for _ in 0..<1_000 {
            if provider.state.hasActiveProMonthly { break }
            await Task.yield()
        }
        XCTAssertEqual(provider.state.activeProductIDs, [.proMonthly])
        let requestsBeforeRelease = await billing.count
        XCTAssertEqual(requestsBeforeRelease, 1, "Background delivery is serialized while local updates continue")
        await billing.release()
    }

    func testOlderIncludedSnapshotCannotClearNewerVerifiedPurchase() async throws {
        let client = TestStoreKitClient()
        let provider = StoreKitEntitlementProvider(client: client)
        _ = await provider.refresh()
        while !client.isListening { await Task.yield() }
        client.send(.verified(client.transaction(.proOnce, signedDate: Date(timeIntervalSince1970: 200))))
        while provider.state.accessLevel != .pro { await Task.yield() }
        client.current = [.verified(client.transaction(.proOnce, isActive: false, signedDate: Date(timeIntervalSince1970: 100)))]
        let refreshed = await provider.refresh()
        XCTAssertEqual(refreshed.activeProductIDs, [.proOnce])
    }

    func testOlderSignedUpdateCannotRegrantRevokedLocalPurchase() async throws {
        let client = TestStoreKitClient(); let provider = StoreKitEntitlementProvider(client: client)
        _ = await provider.refresh()
        while !client.isListening { await Task.yield() }
        client.send(.verified(client.transaction(.proOnce, isActive: false, signedDate: Date(timeIntervalSince1970: 200))))
        await Task.yield()
        client.send(.verified(client.transaction(.proOnce, signedDate: Date(timeIntervalSince1970: 100))))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(provider.state, .free)
    }

    func testProviderStartsAndStaysFreeWithoutTransactions() async {
        let client = TestStoreKitClient()
        let provider = StoreKitEntitlementProvider(client: client)

        XCTAssertEqual(provider.state, .free)
        let refreshed = await provider.refresh()
        XCTAssertEqual(refreshed, .free)
    }

    func testLoadsBothSupportedProductsWithLocalizedPresentation() async throws {
        let client = TestStoreKitClient()
        client.products = [
            client.product(id: RelayProductID.proOnce.rawValue, price: "€14.99"),
            client.product(id: RelayProductID.proMonthly.rawValue, price: "€2.49"),
            client.product(id: "example.unknown", price: "$0.01"),
        ]
        let provider = StoreKitEntitlementProvider(client: client)

        let products = try await provider.loadProducts()

        XCTAssertEqual(products.map(\.id), [.proOnce, .proMonthly])
        XCTAssertEqual(products.map(\.displayPrice), ["€14.99", "€2.49"])
    }

    func testVerifiedPurchaseFinishesAndGrantsImmediately() async throws {
        let client = TestStoreKitClient()
        let transaction = client.transaction(.proOnce)
        client.nextPurchase = .success(.verified(transaction))
        client.products = [client.product()]
        let provider = StoreKitEntitlementProvider(client: client)

        let outcome = try await provider.purchase(.proOnce)

        XCTAssertEqual(outcome, .purchased(RelayEntitlementState(activeProductIDs: [.proOnce])))
        XCTAssertEqual(provider.state.accessLevel, .pro)
        XCTAssertEqual(client.finishCount, 1)
    }

    func testPurchasePreservesExistingFamilySharingAttribution() async throws {
        let client = TestStoreKitClient()
        client.current = [.verified(client.transaction(.proOnce, ownership: .familyShared))]
        client.products = [client.product(id: RelayProductID.proMonthly.rawValue)]
        client.nextPurchase = .success(.verified(client.transaction(.proMonthly)))
        let provider = StoreKitEntitlementProvider(client: client)
        _ = await provider.refresh()

        _ = try await provider.purchase(.proMonthly)

        XCTAssertEqual(provider.state.activeProductIDs, [.proOnce, .proMonthly])
        XCTAssertEqual(provider.state.sources, [.familyShared, .purchased])
    }

    func testInFlightStaleRefreshCannotRevokeVerifiedPurchase() async throws {
        let client = TestStoreKitClient()
        client.currentReadDelay = .milliseconds(150)
        client.products = [client.product()]
        client.nextPurchase = .success(.verified(client.transaction(.proOnce)))
        let provider = StoreKitEntitlementProvider(client: client)
        try await Task.sleep(for: .milliseconds(200)) // let the provider's initial refresh finish

        let staleRefresh = Task { await provider.refresh() }
        try await Task.sleep(for: .milliseconds(25))
        _ = try await provider.purchase(.proOnce)
        _ = await staleRefresh.value

        XCTAssertEqual(provider.state.accessLevel, .pro)
        XCTAssertEqual(provider.state.activeProductIDs, [.proOnce])
    }

    func testFamilySharedCurrentEntitlementGrantsTheSameAccess() async {
        let client = TestStoreKitClient()
        client.current = [.verified(client.transaction(.proOnce, ownership: .familyShared))]
        let provider = StoreKitEntitlementProvider(client: client)

        let state = await provider.refresh()

        XCTAssertEqual(state.accessLevel, .pro)
        XCTAssertEqual(state.source, .familyShared)
    }

    func testActiveMonthlyCurrentEntitlementGrantsTheSameAccess() async {
        let client = TestStoreKitClient()
        client.current = [.verified(client.transaction(.proMonthly))]
        let provider = StoreKitEntitlementProvider(client: client)

        let state = await provider.refresh()

        XCTAssertEqual(state.accessLevel, .pro)
        XCTAssertEqual(state.activeProductIDs, [.proMonthly])
    }

    func testUnverifiedAndUnknownTransactionsAreIgnored() async {
        let client = TestStoreKitClient()
        client.current = [
            .unverified,
            .verified(client.transaction(RelayProductID(rawValue: "example.unknown"))),
        ]
        let provider = StoreKitEntitlementProvider(client: client)

        let refreshed = await provider.refresh()
        XCTAssertEqual(refreshed, .free)
        XCTAssertEqual(client.finishCount, 0)
    }

    func testInactiveCurrentTransactionNeverGrantsAccess() async {
        let client = TestStoreKitClient()
        client.current = [.verified(client.transaction(.proMonthly, isActive: false))]
        let provider = StoreKitEntitlementProvider(client: client)

        let refreshed = await provider.refresh()

        XCTAssertEqual(refreshed, .free)
    }

    func testPurchaseCancellationAndPendingDoNotGrantAccess() async throws {
        let client = TestStoreKitClient()
        client.products = [client.product()]
        let provider = StoreKitEntitlementProvider(client: client)

        client.nextPurchase = .userCancelled
        let cancelled = try await provider.purchase(.proOnce)
        XCTAssertEqual(cancelled, .userCancelled)
        client.nextPurchase = .pending
        let pending = try await provider.purchase(.proOnce)
        XCTAssertEqual(pending, .pending)
        XCTAssertEqual(provider.state, .free)
    }

    func testUnverifiedPurchaseFailsClosed() async throws {
        let client = TestStoreKitClient()
        client.products = [client.product()]
        client.nextPurchase = .success(.unverified)
        let provider = StoreKitEntitlementProvider(client: client)

        do {
            _ = try await provider.purchase(.proOnce)
            XCTFail("Unverified purchase unexpectedly granted access")
        } catch {
            XCTAssertEqual(error as? RelayEntitlementError, .failedVerification)
        }
        XCTAssertEqual(provider.state, .free)
    }

    func testRestoreSynchronizesThenRefreshesEntitlement() async throws {
        let client = TestStoreKitClient()
        client.current = [.verified(client.transaction(.proOnce))]
        let provider = StoreKitEntitlementProvider(client: client)

        let restored = try await provider.restorePurchases()

        XCTAssertEqual(client.synchronizeCount, 1)
        XCTAssertEqual(restored.accessLevel, .pro)
    }

    func testTransactionUpdatePublishesPurchaseAndRevocationLive() async {
        let client = TestStoreKitClient()
        let provider = StoreKitEntitlementProvider(client: client)
        var iterator = provider.stateUpdates().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, .free)

        let transaction = client.transaction(.proOnce)
        client.current = [.verified(transaction)]
        client.send(.verified(transaction))
        let purchased = await iterator.next()
        XCTAssertEqual(purchased?.accessLevel, .pro)

        client.current = []
        client.send(.verified(client.transaction(.proOnce, isActive: false)))
        let revoked = await iterator.next()
        XCTAssertEqual(revoked, .free)
    }

    func testSubscribersAreIndependentAndBounded() async {
        let client = TestStoreKitClient()
        let provider = StoreKitEntitlementProvider(client: client)
        var first = provider.stateUpdates().makeAsyncIterator()
        var second = provider.stateUpdates().makeAsyncIterator()
        let firstInitial = await first.next()
        let secondInitial = await second.next()
        XCTAssertEqual(firstInitial, .free)
        XCTAssertEqual(secondInitial, .free)

        let transaction = client.transaction(.proOnce)
        client.current = [.verified(transaction)]
        client.send(.verified(transaction))

        let firstPurchased = await first.next()
        let secondPurchased = await second.next()
        XCTAssertEqual(firstPurchased?.accessLevel, .pro)
        XCTAssertEqual(secondPurchased?.accessLevel, .pro)
    }
}

@MainActor
private final class TestStoreKitClient: StoreKitClient {
    var products: [StoreProduct] = []
    var current: [StoreVerification] = []
    var unfinished: [StoreVerification] = []
    var purchaseCount = 0
    var purchaseToken: UUID?
    var nextPurchase: StorePurchaseResult = .userCancelled
    var finishCount = 0
    var synchronizeCount = 0
    var currentReadDelay: Duration?
    var isListening: Bool { continuation != nil }
    private var continuation: AsyncStream<StoreVerification>.Continuation?

    func unfinishedTransactions() async -> [StoreVerification] { unfinished }
    func products(for identifiers: Set<String>) async throws -> [StoreProduct] { products }
    func currentEntitlements() async -> [StoreVerification] {
        let snapshot = current
        if let currentReadDelay { try? await Task.sleep(for: currentReadDelay) }
        return snapshot
    }
    func transactionUpdates() -> AsyncStream<StoreVerification> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            self.continuation = continuation
        }
    }
    func synchronize() async throws { synchronizeCount += 1 }

    func product(id: String = RelayProductID.proOnce.rawValue, price: String = "$9.99") -> StoreProduct {
        StoreProduct(id: id, displayName: "Relay Pro", description: "Play on Mac", displayPrice: price,
                     purchase: { [weak self] token in
                        self?.purchaseCount += 1; self?.purchaseToken = token
                        return self?.nextPurchase ?? .userCancelled
                     })
    }

    func transaction(_ id: RelayProductID, ownership: StoreTransaction.Ownership = .purchased,
                     isActive: Bool = true, token: UUID? = nil, signedDate: Date = .distantPast) -> StoreTransaction {
        StoreTransaction(productID: id.rawValue, ownership: ownership, isActive: isActive,
                         transactionJWS: "signed.test.proof", appAccountToken: token, signedDate: signedDate,
                         finish: { [weak self] in self?.finishCount += 1 })
    }

    func send(_ verification: StoreVerification) { continuation?.yield(verification) }
}

private actor TestBilling: RelayBillingClaiming {
    var claims: [(String, UUID)] = []
    private var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func claim(transactionJWS: String, accountID: UUID) async throws {
        claims.append((transactionJWS, accountID))
        if fails { throw URLError(.notConnectedToInternet) }
    }
}

private actor PausingBilling: RelayBillingClaiming {
    var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func claim(transactionJWS: String, accountID: UUID) async throws {
        count += 1
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

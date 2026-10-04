// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayEntitlements
@testable import RelayUI

@MainActor
final class RelayProModelTests: XCTestCase {
    func testPurchaseOutcomesAreIntentionalAndNeverInventAPrice() async {
        let provider = FakeEntitlementProvider()
        provider.products = [
            RelayStoreProduct(id: .proOnce, displayName: "Relay Pro Once", description: "Play on Mac", displayPrice: "€12.34"),
            RelayStoreProduct(id: .proMonthly, displayName: "Relay Pro Monthly", description: "Play on Mac", displayPrice: "€2.34"),
        ]
        let model = RelayProModel(provider: provider)

        await model.loadProduct()
        XCTAssertEqual(model.onceProduct?.displayPrice, "€12.34")
        XCTAssertEqual(model.monthlyProduct?.displayPrice, "€2.34")

        provider.purchaseOutcome = .pending
        await model.purchase(.proMonthly)
        XCTAssertEqual(model.notice, .pending)
        XCTAssertFalse(model.isPro)

        provider.purchaseOutcome = .userCancelled
        await model.purchase(.proOnce)
        XCTAssertEqual(model.notice, .cancelled)
        XCTAssertFalse(model.isPro)

        let pro = RelayEntitlementState(activeProductIDs: [.proOnce])
        provider.purchaseOutcome = .purchased(pro)
        await model.purchase(.proOnce)
        XCTAssertEqual(model.notice, .purchased)
        XCTAssertTrue(model.isPro)
    }

    func testRestoreAndUnavailableStoreDegradeSafely() async {
        let provider = FakeEntitlementProvider()
        let model = RelayProModel(provider: provider)

        provider.shouldFail = true
        await model.loadProduct()
        XCTAssertEqual(model.notice, .storeUnavailable)
        XCTAssertFalse(model.isPro)

        provider.shouldFail = false
        provider.restoredState = .free
        await model.restore()
        XCTAssertEqual(model.notice, .nothingToRestore)

        provider.restoredState = RelayEntitlementState(activeProductIDs: [.proOnce])
        await model.restore()
        XCTAssertEqual(model.notice, .restored)
        XCTAssertTrue(model.isPro)
    }

    func testLiveEntitlementChangesUpdateTheProductWithoutRestart() async {
        let provider = FakeEntitlementProvider()
        let model = RelayProModel(provider: provider)
        var observed: [RelayAccessLevel] = []
        model.start()
        await Task.yield()
        observed.append(model.entitlement.accessLevel)

        provider.send(RelayEntitlementState(activeProductIDs: [.proOnce]))
        for _ in 0..<50 where model.entitlement.accessLevel != .pro {
            try? await Task.sleep(for: .milliseconds(10))
        }
        observed.append(model.entitlement.accessLevel)
        provider.send(.free)
        for _ in 0..<50 where model.entitlement.accessLevel != .free {
            try? await Task.sleep(for: .milliseconds(10))
        }
        observed.append(model.entitlement.accessLevel)

        XCTAssertEqual(observed, [.free, .pro, .free])
        XCTAssertFalse(model.isPro)
    }
}

@MainActor
private final class FakeEntitlementProvider: RelayEntitlementProviding {
    var state = RelayEntitlementState.free
    var products: [RelayStoreProduct] = []
    var purchaseOutcome: RelayPurchaseOutcome = .userCancelled
    var restoredState = RelayEntitlementState.free
    var shouldFail = false
    private var continuation: AsyncStream<RelayEntitlementState>.Continuation?

    func stateUpdates() -> AsyncStream<RelayEntitlementState> {
        let current = state
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.yield(current)
        }
    }

    func loadProducts() async throws -> [RelayStoreProduct] {
        if shouldFail { throw TestError.unavailable }
        return products
    }

    func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome {
        if shouldFail { throw TestError.unavailable }
        if case .purchased(let newState) = purchaseOutcome { state = newState }
        return purchaseOutcome
    }

    func restorePurchases() async throws -> RelayEntitlementState {
        if shouldFail { throw TestError.unavailable }
        state = restoredState
        return restoredState
    }

    func refresh() async -> RelayEntitlementState { state }

    func send(_ newState: RelayEntitlementState) {
        state = newState
        continuation?.yield(newState)
    }

    enum TestError: Error { case unavailable }
}

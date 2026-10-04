// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RelayEntitlements

final class RelayEntitlementTests: XCTestCase {
    func testFreeStateHasNoSourceOrActiveProducts() {
        XCTAssertEqual(RelayEntitlementState.free.accessLevel, .free)
        XCTAssertEqual(RelayEntitlementState.free.activeProductIDs, [])
        XCTAssertNil(RelayEntitlementState.free.source)
    }

    func testKnownPurchaseGrantsPro() {
        let state = RelayEntitlementState(activeProductIDs: [.proOnce])

        XCTAssertEqual(state.accessLevel, .pro)
        XCTAssertEqual(state.activeProductIDs, [.proOnce])
        XCTAssertEqual(state.source, .purchased)
    }

    func testActiveMonthlySubscriptionGrantsPro() {
        let state = RelayEntitlementState(activeProductIDs: [.proMonthly])

        XCTAssertEqual(state.accessLevel, .pro)
        XCTAssertEqual(state.activeProductIDs, [.proMonthly])
        XCTAssertEqual(state.sources, [.purchased])
    }

    func testOnceAndMonthlyAreBothReportedForRenewalWarning() {
        let state = RelayEntitlementState(activeProductIDs: [.proOnce, .proMonthly])

        XCTAssertTrue(state.ownsProOnce)
        XCTAssertTrue(state.hasActiveProMonthly)
        XCTAssertTrue(state.hasOnceAndMonthly)
    }

    func testFamilySharedPurchaseIsDistinguished() {
        let state = RelayEntitlementState(
            activeProductIDs: [.proOnce],
            familySharedProductIDs: [.proOnce]
        )

        XCTAssertEqual(state.accessLevel, .pro)
        XCTAssertEqual(state.source, .familyShared)
    }

    func testUnknownProductNeverGrantsAccess() {
        let unknown = RelayProductID(rawValue: "example.invalid.product")
        let state = RelayEntitlementState(
            activeProductIDs: [unknown],
            familySharedProductIDs: [unknown]
        )

        XCTAssertEqual(state, .free)
    }

    func testFutureRelaySyncBundleCanGrantProWithoutStoreKitProductIdentity() {
        let state = RelayEntitlementState(
            activeProductIDs: [],
            additionalSources: [.relaySyncBundle]
        )

        XCTAssertEqual(state.accessLevel, .pro)
        XCTAssertEqual(state.activeProductIDs, [])
        XCTAssertEqual(state.sources, [.relaySyncBundle])
    }

    func testOnlyTheExplicitRelaySyncBundleAdditionalSourceCanGrantPro() {
        let state = RelayEntitlementState(
            activeProductIDs: [],
            additionalSources: [.purchased, .familyShared]
        )

        XCTAssertEqual(state, .free)
    }

    func testEveryProFeatureUsesTheCentralAccessPolicy() {
        let free = RelayAccessPolicy(entitlement: .free)
        let grantedStates = [
            RelayEntitlementState(activeProductIDs: [.proOnce]),
            RelayEntitlementState(activeProductIDs: [.proMonthly]),
            RelayEntitlementState(activeProductIDs: [], additionalSources: [.relaySyncBundle]),
        ]

        for feature in RelayProFeature.allCases {
            XCTAssertFalse(free.allows(feature), "Free unexpectedly allowed \(feature)")
            for state in grantedStates {
                XCTAssertTrue(RelayAccessPolicy(entitlement: state).allows(feature),
                              "A valid Pro source unexpectedly denied \(feature)")
            }
        }
    }

    @MainActor
    func testUnavailableProviderFailsClosedWithoutBlockingRefresh() async throws {
        let provider = UnavailableEntitlementProvider()

        let refreshed = await provider.refresh()
        let restored = try await provider.restorePurchases()
        let products = try await provider.loadProducts()

        XCTAssertEqual(refreshed, .free)
        XCTAssertEqual(restored, .free)
        XCTAssertEqual(products, [])

        do {
            _ = try await provider.purchase(.proOnce)
            XCTFail("Unavailable provider unexpectedly completed a purchase")
        } catch {
            XCTAssertEqual(
                error as? RelayEntitlementError,
                .productUnavailable(.proOnce)
            )
        }
    }

    @MainActor
    func testUnavailableProviderStreamBeginsFreeAndFinishes() async {
        let provider = UnavailableEntitlementProvider()
        var iterator = provider.stateUpdates().makeAsyncIterator()

        let first = await iterator.next()
        let second = await iterator.next()

        XCTAssertEqual(first, .free)
        XCTAssertNil(second)
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RelayEntitlements

final class RelaySyncEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testActiveSyncPlansGrantProAndExpireWithoutRemovingStoreKit() {
        for plan in ["sync", "sync_plus"] {
            let grant = makeGrant(plan: plan)
            XCTAssertEqual(RelayEntitlementState.free.includingSyncGrant(grant, at: now).accessLevel, .pro)
            XCTAssertEqual(RelayEntitlementState.free.includingSyncGrant(grant, at: now.addingTimeInterval(101)).accessLevel, .free)
            for product in [RelayProductID.proOnce, .proMonthly] {
                let purchase = RelayEntitlementState(activeProductIDs: [product])
                let expired = purchase.includingSyncGrant(grant, at: now.addingTimeInterval(101))
                XCTAssertEqual(expired, purchase)
                XCTAssertEqual(expired.accessLevel, .pro)
            }
        }
    }

    func testRecoveryPurgedUnknownAndExpiredNeverGrant() {
        for state in ["RECOVERY", "PURGE_PENDING", "PURGED", "unknown"] {
            XCTAssertNil(makeGrant(state: state))
        }
        XCTAssertNil(makeGrant(plan: "future"))
        XCTAssertNil(makeGrant(expiry: -1))
    }

    func testCacheBoundedByServerExpirySessionAndMaximumAge() {
        XCTAssertEqual(makeGrant(expiry: 200_000)?.validUntil, now.addingTimeInterval(86_400))
        XCTAssertEqual(makeGrant(expiry: 30)?.validUntil, now.addingTimeInterval(30))
        let sessionLimited = RelaySyncEntitlementGrant(accountID: UUID(), planID: "sync", vaultState: "ACTIVE",
            entitledUntil: now.addingTimeInterval(5000), observedAt: now, sessionExpiresAt: now.addingTimeInterval(10))
        XCTAssertEqual(sessionLimited?.validUntil, now.addingTimeInterval(10))
    }

    func testUnionPreservesMixedFamilySharingAttribution() {
        let store = RelayEntitlementState(activeProductIDs: [.proOnce, .proMonthly], familySharedProductIDs: [.proOnce])
        let combined = store.includingSyncGrant(makeGrant(), at: now)
        XCTAssertEqual(combined.sources, [.purchased, .familyShared, .relaySyncBundle])
        XCTAssertEqual(combined.familySharedProductIDs, [.proOnce])
        XCTAssertEqual(combined.includingSyncGrant(nil, at: now), store)
    }

    @MainActor
    func testCompositeStateExpiresSynchronouslyWithoutNetwork() {
        let clock = MutableGrantClock(now)
        let combined = CombinedRelayEntitlementProvider(store: UnavailableEntitlementProvider(), now: { clock.date })
        combined.updateSyncGrant(makeGrant())
        XCTAssertEqual(combined.state.accessLevel, .pro)
        clock.date = now.addingTimeInterval(101)
        XCTAssertEqual(combined.state.accessLevel, .free)
    }

    private func makeGrant(plan: String = "sync", state: String = "ACTIVE", expiry: TimeInterval = 100) -> RelaySyncEntitlementGrant? {
        RelaySyncEntitlementGrant(accountID: UUID(), planID: plan, vaultState: state,
            entitledUntil: now.addingTimeInterval(expiry), observedAt: now, sessionExpiresAt: now.addingTimeInterval(300_000))
    }
}

@MainActor
private final class MutableGrantClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayHostedSync
@testable import RelayUI

final class HostedBillingPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    func testPlannedChangeRequiresRenewalAndUnexpiredService() throws {
        for status in ["active", "grace", "billing_grace", "expired", "revoked", "retry", "billing_retry"] {
            for renewal in [true, false] {
                for end in [999, 1000, 1001] {
                    let value = HostedBillingPresentation(snapshot: try snapshot(status, renewal, end), now: now)
                    let eligible = ["active", "grace", "billing_grace"].contains(status) && renewal && end > 1000
                    XCTAssertEqual(value.pendingProductID != nil, eligible, "\(status), renewal=\(renewal), end=\(end)")
                }
            }
        }
    }

    func testPeriodSummaryNeverPromisesExpiredOrRevokedAccess() throws {
        let active = HostedBillingPresentation(snapshot: try snapshot("active", false, 1001), now: now)
        let date = now.addingTimeInterval(1).formatted(date: .abbreviated, time: .omitted)
        XCTAssertEqual(active.renewalMessage(now: now), L("Available until \(date)"))
        XCTAssertNil(active.renewalMessage(now: now.addingTimeInterval(1)))
        for status in ["expired", "revoked", "billing_retry"] {
            let value = HostedBillingPresentation(snapshot: try snapshot(status, false, 2000), now: now)
            XCTAssertNil(value.renewalMessage(now: now))
        }
    }

    func testScheduledPlanSummaryIsBoundedByVerifiedService() throws {
        let value = HostedBillingPresentation(snapshot: try snapshot("active", true, 1001), now: now)
        let date = now.addingTimeInterval(1).formatted(date: .abbreviated, time: .omitted)
        XCTAssertEqual(value.renewalMessage(now: now), L("Plan changes on \(date)"))
        XCTAssertNil(value.attentionMessage(now: now))
        XCTAssertNil(value.renewalMessage(now: now.addingTimeInterval(1)))
        XCTAssertEqual(value.attentionMessage(now: now.addingTimeInterval(1)),
                       L("Uploads paused. Refresh your plan to check it."))
    }

    func testExpiredGraceDoesNotRemainActive() throws {
        let expired = HostedBillingPresentation(snapshot: try snapshot("billing_grace", true, 1000), now: now)
        XCTAssertEqual(expired.status, L("Membership expired"))
        XCTAssertNil(expired.pendingProductID)
        let grace = HostedBillingPresentation(snapshot: try snapshot("grace", false, 1001), now: now)
        XCTAssertEqual(grace.status, L("Apple billing grace period"))
        XCTAssertEqual(grace.serviceEnd, now.addingTimeInterval(1))
    }

    func testMissingVerifiedPeriodDoesNotAppearHealthy() throws {
        for status in ["active", "grace", "billing_grace"] {
            let value = HostedBillingPresentation(snapshot: try snapshot(status, true, nil), now: now)
            XCTAssertNil(value.renewalMessage(now: now))
            XCTAssertNil(value.pendingProductID)
            XCTAssertEqual(value.attentionMessage(now: now),
                           L("Uploads paused. Refresh your plan to check it."))
        }
    }

    func testOptionalDeletionHoldOnlyAddsVerificationCopy() throws {
        let legacy = try snapshot("expired", false, 900)
        XCTAssertNil(legacy.purgeAwaitingProvider)
        XCTAssertNil(HostedBillingPresentation(snapshot: legacy, now: now).deletionHoldMessage)
        let held = try snapshot("expired", false, 900, hold: true)
        let value = HostedBillingPresentation(snapshot: held, now: now)
        XCTAssertEqual(held.purgeAwaitingProvider, true)
        XCTAssertNotNil(value.deletionHoldMessage)
        XCTAssertNil(value.visiblePurgeDate(now.addingTimeInterval(-100)))
        XCTAssertEqual(HostedBillingPresentation(snapshot: legacy, now: now).visiblePurgeDate(now), now)
        XCTAssertEqual(value.status, L("Membership expired"))
        XCTAssertNil(value.pendingProductID)
        XCTAssertEqual(held.vaultState, "no_access")
        XCTAssertNil(held.syncProUntil)
        XCTAssertEqual(held.effectiveQuotaBytes, 0)
    }

    private func snapshot(_ status: String, _ renewal: Bool, _ end: Int?, hold: Bool? = nil) throws -> HostedBillingSnapshot {
        var object: [String: Any] = ["status": status, "autoRenew": renewal,
            "pendingProductID": "app.relayemu.relay.syncplus.yearly",
            "directProOnce": false,
            "effectiveQuotaBytes": 0, "vaultState": "no_access"]
        if let end { object["entitledUntil"] = end; object["graceUntil"] = end }
        if let hold { object["purgeAwaitingProvider"] = hold }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(HostedBillingSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

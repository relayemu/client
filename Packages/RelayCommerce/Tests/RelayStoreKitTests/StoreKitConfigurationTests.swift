// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
import RelayEntitlements

final class StoreKitConfigurationTests: XCTestCase {
    func testMembershipConfigurationMatchesAllSixProductsAndAppleLevels() throws {
        let data = try Data(contentsOf: Self.configurationURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let products = try XCTUnwrap(root["products"] as? [[String: Any]])

        XCTAssertEqual(products.count, 1)
        let product = try XCTUnwrap(products.first)
        XCTAssertEqual(product["productID"] as? String, RelayProductID.proOnce.rawValue)
        XCTAssertEqual(product["type"] as? String, "NonConsumable")
        XCTAssertEqual(product["familyShareable"] as? Bool, false)
        let groups = try XCTUnwrap(root["subscriptionGroups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?["name"] as? String, "Relay Membership")
        let subscriptions = try XCTUnwrap(groups.first?["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(subscriptions.count, 5)
        let monthly = try XCTUnwrap(subscriptions.first)
        XCTAssertEqual(monthly["productID"] as? String, RelayProductID.proMonthly.rawValue)
        XCTAssertEqual(monthly["type"] as? String, "RecurringSubscription")
        XCTAssertEqual(monthly["recurringSubscriptionPeriod"] as? String, "P1M")
        XCTAssertEqual(monthly["groupNumber"] as? Int, 3,
                       "Pro Monthly must leave higher group levels for future Relay Sync upgrades")
        XCTAssertEqual(monthly["familyShareable"] as? Bool, false)
        for subscription in subscriptions {
            let id = RelayProductID(rawValue: try XCTUnwrap(subscription["productID"] as? String))
            XCTAssertEqual(subscription["groupNumber"] as? Int, id.subscriptionLevel)
            XCTAssertEqual(subscription["subscriptionGroupID"] as? String, groups.first?["id"] as? String)
            XCTAssertEqual(subscription["familyShareable"] as? Bool, false,
                           "Family Sharing is OFF for every V1 product")
            let period = id == .syncYearly || id == .syncPlusYearly ? "P1Y" : "P1M"
            XCTAssertEqual(subscription["recurringSubscriptionPeriod"] as? String, period)
        }
        XCTAssertEqual((root["nonRenewingSubscriptions"] as? [Any])?.count, 0)
        XCTAssertEqual(Set(([product] + subscriptions).compactMap { $0["productID"] as? String }),
                       Set(RelayProductID.supported.map(\.rawValue)))
    }

    private static var configurationURL: URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appending(path: "Apps/StoreKit/Relay.storekit")
    }
}

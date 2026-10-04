// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Authenticated backend billing presentation; never a StoreKit-derived quota.
/// Pending product is Apple's future renewal intent, not current service.
public struct HostedBillingSnapshot: Decodable, Equatable, Sendable {
    public let provider: String?
    public let status: String
    public let currentProductID: String?
    public let pendingProductID: String?
    public let autoRenew: Bool?
    public let entitledUntil: Date?
    public let graceUntil: Date?
    public let directProOnce: Bool
    public let planID: String?
    public let effectiveQuotaBytes: Int64
    public let syncProUntil: Date?
    public let vaultState: String
    public let purgeAwaitingProvider: Bool?
}

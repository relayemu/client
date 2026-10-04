// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Stable App Store product identity. Product names and prices are presentation
/// data loaded from StoreKit, never encoded here.
public struct RelayProductID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let proOnce = RelayProductID(
        rawValue: "app.relayemu.relay.pro.lifetime"
    )

    public static let proMonthly = RelayProductID(
        rawValue: "app.relayemu.relay.pro.monthly"
    )

    public static let syncMonthly = RelayProductID(rawValue: "app.relayemu.relay.sync.monthly")
    public static let syncYearly = RelayProductID(rawValue: "app.relayemu.relay.sync.yearly")
    public static let syncPlusMonthly = RelayProductID(rawValue: "app.relayemu.relay.syncplus.monthly")
    public static let syncPlusYearly = RelayProductID(rawValue: "app.relayemu.relay.syncplus.yearly")
    public static let localPro: Set<RelayProductID> = [.proOnce, .proMonthly]
    public static let hosted: Set<RelayProductID> = [.syncMonthly, .syncYearly, .syncPlusMonthly, .syncPlusYearly]
    public static let supported = localPro.union(hosted)
    public var requiresRelayAccount: Bool { Self.hosted.contains(self) }
    /// Apple level 1 is the highest service. Period variants share a level.
    public var subscriptionLevel: Int? {
        switch self {
        case .syncPlusMonthly, .syncPlusYearly: 1
        case .syncMonthly, .syncYearly: 2
        case .proMonthly: 3
        default: nil
        }
    }
}

public enum RelayAccessLevel: String, Codable, Sendable {
    case free
    case pro
}

public enum RelayEntitlementSource: String, Codable, Hashable, Sendable {
    case purchased
    case familyShared
    /// An authenticated, unexpired Relay Sync or Sync+ service grant.
    case relaySyncBundle
}

/// A normalized snapshot derived only from currently verified transactions.
/// Unknown products never grant access.
public struct RelayEntitlementState: Equatable, Sendable {
    public let accessLevel: RelayAccessLevel
    public let activeProductIDs: Set<RelayProductID>
    public let familySharedProductIDs: Set<RelayProductID>
    public let sources: Set<RelayEntitlementSource>

    /// Compatibility convenience for product UI that only needs attribution.
    /// When several grants coexist, a direct App Store purchase wins, followed
    /// by Family Sharing and then a future Relay Sync bundle.
    public var source: RelayEntitlementSource? {
        if sources.contains(.purchased) { return .purchased }
        if sources.contains(.familyShared) { return .familyShared }
        if sources.contains(.relaySyncBundle) { return .relaySyncBundle }
        return nil
    }

    public var ownsProOnce: Bool {
        activeProductIDs.contains(.proOnce)
    }

    public var hasActiveProMonthly: Bool {
        activeProductIDs.contains(.proMonthly)
    }

    /// The lifetime purchase does not cancel an existing subscription. Product
    /// UI must make the continuing renewal visible and hand cancellation to Apple.
    public var hasOnceAndMonthly: Bool {
        ownsProOnce && hasActiveProMonthly
    }

    public static let free = RelayEntitlementState(
        activeProductIDs: [],
        familySharedProductIDs: []
    )

    public init(
        activeProductIDs: Set<RelayProductID>,
        familySharedProductIDs: Set<RelayProductID> = [],
        additionalSources: Set<RelayEntitlementSource> = []
    ) {
        let recognized = activeProductIDs.intersection(RelayProductID.localPro)
        let recognizedFamily = familySharedProductIDs.intersection(recognized)

        self.activeProductIDs = recognized
        self.familySharedProductIDs = recognizedFamily
        var normalizedSources = additionalSources.intersection([.relaySyncBundle])
        if !recognizedFamily.isEmpty { normalizedSources.insert(.familyShared) }
        if !recognized.subtracting(recognizedFamily).isEmpty { normalizedSources.insert(.purchased) }
        let normalizedAccess: RelayAccessLevel = recognized.isEmpty && !normalizedSources.contains(.relaySyncBundle) ? .free : .pro
        accessLevel = normalizedAccess
        sources = normalizedAccess == .free ? [] : normalizedSources
    }
}

/// Features Relay Pro may unlock. iCloud, systems, saves, local import/export and
/// gameplay on iPhone, iPad and Apple TV deliberately do not appear here.
public enum RelayProFeature: String, CaseIterable, Sendable {
    case transfer
    case macGameplay
    case extendedRewind
    case advancedSpeeds
    case advancedControllerMapping
    case advancedDisplay
    case touchLayoutEditing
    case cheats
    case extendedRecording
}

public struct RelayAccessPolicy: Sendable {
    public let entitlement: RelayEntitlementState

    public init(entitlement: RelayEntitlementState) {
        self.entitlement = entitlement
    }

    public func allows(_ feature: RelayProFeature) -> Bool {
        entitlement.accessLevel == .pro
    }
}

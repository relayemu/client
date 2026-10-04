// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import RelayEntitlements

public struct RelayHostedEnvironment: Equatable, Sendable {
    public let apiOrigin: URL
    public let portalOrigin: URL
    public let keychainService: String
    private init(apiOrigin: URL, portalOrigin: URL, keychainService: String) {
        self.apiOrigin = apiOrigin; self.portalOrigin = portalOrigin; self.keychainService = keychainService
    }
    /// Production credentials cannot be restored from the closed-beta namespace.
    public static let production = RelayHostedEnvironment(
        apiOrigin: URL(string: "https://sync.relayemu.app")!,
        portalOrigin: URL(string: "https://account.relayemu.app")!,
        keychainService: "app.relayemu.relay.hosted-sync.production"
    )
    /// The app must explicitly opt into the closed-beta environment.
    public static let preproduction = RelayHostedEnvironment(
        apiOrigin: URL(string: "https://sync-preprod.relayemu.app")!,
        portalOrigin: URL(string: "https://account-preprod.relayemu.app")!,
        keychainService: "app.relayemu.relay.hosted-sync.preproduction"
    )
    public static func configured(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        #if DEBUG
        arguments.contains("--relay-sync-preproduction") ? .preproduction : nil
        #else
        nil
        #endif
    }
    #if DEBUG
    /// Disposable local integration fixtures only; unavailable in Release.
    public static func transferTestEnvironment(origin: URL, showPublicPortal: Bool = false) throws -> Self {
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else { throw HostedAuthError.invalidResponse }
        // A visual preview can use the shipping address while every API request
        // and disposable credential remains confined to the loopback fixture.
        let portal = showPublicPortal ? URL(string: "https://account.relayemu.app")! : origin
        return Self(apiOrigin: origin, portalOrigin: portal, keychainService: "app.relayemu.relay.transfer.test")
    }
    #endif
}

public enum HostedDeviceKind: String, Codable, Sendable { case iphone, ipad, appletv, mac, unknown }
public enum HostedVaultState: String, Codable, Sendable { case active = "ACTIVE", recovery = "RECOVERY", purgePending = "PURGE_PENDING", purged = "PURGED", unknown }

public enum HostedAuthError: Error, Equatable, Sendable {
    case invalidResponse, expiredSession, signedOut, invalidChallenge, operationInProgress, staleOperation
    case keychain(Int32)
}

public struct HostedAppleChallenge: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let challengeID: UUID
    public let nonce: String
    public let expiresAt: Date
    public var description: String { "HostedAppleChallenge(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Opaque API bearer; only the Keychain store may persist this value.
public struct HostedSessionCredential: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let expiresAt: Date
    public let relayAccountID: UUID
    public init(accessToken: String, expiresAt: Date, relayAccountID: UUID) {
        self.accessToken = accessToken; self.expiresAt = expiresAt; self.relayAccountID = relayAccountID
    }
    public var description: String { "HostedSessionCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct HostedAccountOverview: Codable, Equatable, Sendable {
    public let accountID: UUID
    public let vaultState: HostedVaultState
    public let planID: String?
    public let usedBytes: Int64
    public let quotaBytes: Int64
    public let entitledUntil: Date?
    public let purgeAt: Date?
    public let lastSyncAt: Date?
    public let deviceCount: Int
    public let conflictCount: Int
    // The qualified v1 /account response wraps the exported Overview DTO and
    // uses its PascalCase keys. Unknown state remains visible but grants nothing.
    private enum CodingKeys: String, CodingKey {
        case accountID = "AccountID", vaultState = "VaultState", planID = "PlanID"
        case usedBytes = "UsedBytes", quotaBytes = "QuotaBytes", entitledUntil = "EntitledUntil"
        case purgeAt = "PurgeAt", lastSyncAt = "LastSyncAt", deviceCount = "DeviceCount", conflictCount = "ConflictCount"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(UUID.self, forKey: .accountID)
        vaultState = HostedVaultState(rawValue: try c.decode(String.self, forKey: .vaultState)) ?? .unknown
        planID = try c.decodeIfPresent(String.self, forKey: .planID)
        usedBytes = try c.decode(Int64.self, forKey: .usedBytes)
        quotaBytes = try c.decode(Int64.self, forKey: .quotaBytes)
        entitledUntil = try c.decodeIfPresent(Date.self, forKey: .entitledUntil)
        purgeAt = try c.decodeIfPresent(Date.self, forKey: .purgeAt)
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        deviceCount = try c.decode(Int.self, forKey: .deviceCount)
        conflictCount = try c.decode(Int.self, forKey: .conflictCount)
        guard usedBytes >= 0, quotaBytes >= 0, deviceCount >= 0, conflictCount >= 0 else { throw HostedAuthError.invalidResponse }
    }
}

public struct HostedAccountSnapshot: Equatable, Sendable {
    public let accountID: UUID
    public let expiresAt: Date
    public let overview: HostedAccountOverview?
    public let syncGrant: RelaySyncEntitlementGrant?
}

public enum HostedAccountState: Equatable, Sendable {
    case signedOut
    case connected(HostedAccountSnapshot)
}

enum HostedAuthJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw HostedAuthError.invalidResponse }
            return date
        }
        do { return try decoder.decode(type, from: data) }
        catch { throw HostedAuthError.invalidResponse }
    }
}

/// Cached authenticated observation. Its original observation time is retained
/// across restarts; loading it cannot renew the offline entitlement lease.
public struct HostedAccountObservation: Codable, Sendable {
    public let overview: HostedAccountOverview
    public let observedAt: Date
    public init(overview: HostedAccountOverview, observedAt: Date) {
        self.overview = overview; self.observedAt = observedAt
    }
}

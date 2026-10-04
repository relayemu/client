// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncPolicy.swift
//  RelaySync
//
//  default when an iCloud account exists; game-file sync is Free and opt-in.

import Foundation

/// Transport/build capability injected by the app. It is deliberately separate
/// from commerce: Relay never gates the player's iCloud storage behind Pro.
public struct SyncCapabilities: Hashable, Sendable {
    /// Whether the game-file sync switch may be turned on at all.
    public var gameFileSyncAllowed: Bool
    public var maxGameContentSize: Int64

    public init(gameFileSyncAllowed: Bool, maxGameContentSize: Int64 = SyncLimits.maxContentPartSize) {
        self.gameFileSyncAllowed = gameFileSyncAllowed
        self.maxGameContentSize = min(maxGameContentSize, SyncLimits.maxContentSize)
    }

    /// A transport that does not support heavy game-file assets.
    public static let savesOnly = SyncCapabilities(gameFileSyncAllowed: false)
    /// Relay's normal iCloud capability. Game files still require explicit opt-in.
    public static let gameFilesSupported = SyncCapabilities(gameFileSyncAllowed: true, maxGameContentSize: SyncLimits.maxContentSize)
    /// Hosted transport splits the logical file into multipart requests itself.
    public static let hostedGameFilesSupported = SyncCapabilities(gameFileSyncAllowed: true, maxGameContentSize: SyncLimits.maxContentSize)
    /// Compatibility spelling for deterministic existing sync harnesses.
    public static let internalTesting = gameFilesSupported
}

/// Keys of the small durable policy values kept in the store's sync meta table.
public enum SyncProviderSelection: String, Codable, CaseIterable, Sendable {
    case off
    case iCloud
    case relaySync
}

public enum SyncMetaKey {
    public static let selectedProvider = "policy.selected_provider"
    /// Stable, unambiguous provider/account namespace. Account values are opaque identities.
    public static func scoped(_ key: String, provider: SyncProviderSelection, account: String?) -> String {
        let component = Data((account ?? "unbound").utf8).base64EncodedString()
        return "provider.\(provider.rawValue).account.\(component).\(key)"
    }
    public static func acceptedAccount(provider: SyncProviderSelection) -> String {
        "provider.\(provider.rawValue).\(accountIdentity)"
    }

    public static let savesEnabled = "policy.saves_enabled"           // "1" / "0"; absent = on
    public static let gameFilesEnabled = "policy.game_files_enabled"  // "1" / "0"; absent = off
    public static let accountIdentity = "account.identity"            // opaque hash
    public static let reconciled = "sync.reconciled"                  // "1" once the library was journaled
    public static let lastPushAt = "sync.last_push_at"                // ms
    public static let lastPullAt = "sync.last_pull_at"                // ms
    public static let localUploadedBytes = "sync.local_uploaded_bytes"
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Device.swift
//  RelayDomain
//
//  Provenance of synchronized objects: which Relay installation produced a
//  session, a battery revision or a state, and what kind of device it was.
//
//  `InstallationID` is a random identifier minted once per Relay
//  installation (per managed library). It is never derived from hardware,
//  advertising or account identifiers and is used only for sync provenance
//  ("this device" vs "another device") — never for analytics.
//
//  `DeviceKind` is the generic noun the product shows ("Played on iPad").
//  Personal device names are never stored or synchronized.

import Foundation

/// Identity of one Relay installation (one managed library on one device).
public struct InstallationID: EntityIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// The kind of Apple device an object was produced on. Portable raw values.
public enum DeviceKind: String, Codable, Sendable, CaseIterable, Hashable {
    case iPhone = "iphone"
    case iPad = "ipad"
    case appleTV = "appletv"
    case mac = "mac"
    case unknown = "unknown"

    /// Parses a raw value; unknown strings map to `.unknown` (never a failure).
    public init(lenient raw: String) {
        self = DeviceKind(rawValue: raw.lowercased()) ?? .unknown
    }
}

/// Where a synchronized object was created relative to this installation.
public enum SyncOrigin: String, Codable, Sendable, Hashable {
    /// Created here; the journal uploads it.
    case local
    /// Received from another installation through sync.
    case remote
}

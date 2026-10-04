// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Identity.swift
//  RelayDomain
//
//  Object identity for Relay's canonical model.
//
//  Two families of identifiers exist on purpose:
//
//  * Entity identifiers (`GameID`, `GameFileID`, `SaveID`, `SaveStateID`,
//    `PlaySessionID`) are opaque UUIDs minted by Relay when an object is
//    created. They never derive from file names, paths, hashes, database row
//    ids or CloudKit record names, so two devices importing the same content
//    produce different `GameID`s and are reconciled through the content
//    fingerprint (see `ContentFingerprint`), never the other way round.
//
//  * Reference identifiers (`SystemID`, `CoreID`) are stable, human-readable
//    strings owned by Relay (`"gba"`, `"mgba"`). They name static reference
//    data that ships with the app, so they must stay meaningful across
//    versions and platforms.

import Foundation

/// An opaque UUID-backed identifier. Encoded as a lowercase UUID string.
public protocol EntityIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension EntityIdentifier {
    /// Mints a fresh, random identifier.
    init() { self.init(rawValue: UUID()) }

    /// Parses the canonical string form; nil when `string` is not a UUID.
    init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.init(rawValue: uuid)
    }

    /// Canonical string form (lowercase UUID), used for storage and logs.
    var description: String { rawValue.uuidString.lowercased() }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid identifier '\(string)'")
        }
        self.init(rawValue: uuid)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Identity of a game in the Relay library (one logical title the user can play).
public struct GameID: EntityIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identity of one concrete imported file that belongs to a game.
public struct GameFileID: EntityIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identity of a battery / in-game save.
public struct SaveID: EntityIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identity of an emulator save state.
public struct SaveStateID: EntityIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identity of one play session (launch → stop).
public struct PlaySessionID: EntityIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct BatteryRevisionID: EntityIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// A stable string identifier owned by Relay. Encoded as its raw string.
public protocol ReferenceIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral where RawValue == String {
    init(rawValue: String)
}

public extension ReferenceIdentifier {
    var description: String { rawValue }
    init(stringLiteral value: String) { self.init(rawValue: value) }
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Identifies an emulated system (console/handheld), e.g. `"gba"`.
public struct SystemID: ReferenceIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Identifies an emulator core implementation available to Relay, e.g. `"mgba"`.
/// A core is always paired with a version string where behaviour can differ
/// between versions (save states); the identifier alone names the implementation.
public struct CoreID: ReferenceIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CoreManifest.swift
//  RelayDomain
//
//  Relay's canonical description of every emulator core it has audited.
//
//  `Resources/CoreManifest.json` at the repository root is the single source of
//  truth: `THIRD_PARTY_LICENSES.{md,json}` and
//  Release inspection reads it to decide what may appear in a product, and
//  `CoreManifestTests` holds the compiled catalog and the manifest to each
//  other so the two can never drift.
//
//  This type only decodes and answers questions about the manifest. It makes
//  no licensing judgement of its own: every judgement in the file was made
//  against the actual licence file fetched from the named upstream at the

import Foundation

/// Whether a core's licence lets Relay — a paid product — distribute it.
public enum CoreCommercialUse: String, Hashable, Codable, Sendable {
    /// The licence permits commercial distribution.
    case permitted
    /// The licence forbids commercial use or forbids derivative works.
    /// Such a core may never appear in a Relay Release product.
    case prohibited
    /// The licence text does not settle the question.
    case unresolved
}

/// Whether a lawyer still has to look at this core before Relay ships it.
public enum CoreLegalReviewStatus: String, Hashable, Codable, Sendable {
    case notRequired = "not-required"
    case required
    /// Settled, and settled against shipping it.
    case blocked
}

/// Whether a core's licence may be combined with Relay's GPL-3.0-or-later
/// client (ADR 0003). Recorded per core from the licence file *and* the source
/// headers; "unverified" means the file is GPL-2.0 text and the headers have
/// not yet been read for "or later".
public enum CoreClientCompatibility: String, Hashable, Codable, Sendable {
    case compatible, incompatible, unverified, prohibited
}

/// How far a core has got in Relay.
public enum CoreRelayStatus: String, Hashable, Codable, Sendable {
    /// Built into Relay and enabled for Release.
    case enabled
    /// Audited and technically viable; not integrated.
    case candidate
    /// Audited and set aside, with the reason recorded.
    case rejected
}

public struct CoreManifestEntry: Hashable, Codable, Sendable, Identifiable {
    public let id: CoreID
    public let name: String
    public let relayStatus: CoreRelayStatus
    /// Canonical upstream project.
    public let upstream: String
    /// The exact revision Relay audited and, when enabled, builds from.
    public let revision: String
    /// Set when `upstream` is itself a fork, naming what it forked from.
    public let upstreamBase: String?
    public let version: String
    /// Declared only for cores Relay integrates; a core Relay does not run
    /// has no save-state compatibility class to promise.
    public let stateCompatibilityVersion: String?
    /// SPDX identifier where one applies, otherwise the licence's own name.
    public let license: String
    public let commercialUse: CoreCommercialUse
    /// "none", "file-level" or "strong".
    public let copyleft: String
    public let sourceOfferRequired: Bool
    public let attributionRequired: Bool
    public let legalReviewStatus: CoreLegalReviewStatus
    public let clientCompatibility: CoreClientCompatibility
    public let clientCompatibilityNote: String?
    /// Where the licence bytes this entry was judged from are stored.
    public let licenceEvidence: String
    public let systems: [SystemID]
    /// Apple platforms the core is known to build and run on.
    public let applePlatforms: [String]
    public let requiresJIT: Bool
    public let firmware: [String]
    public let capabilities: [String]
    public let build: Build
    public let notes: String?

    public struct Build: Hashable, Codable, Sendable {
        /// "vendored-subtree", "not-integrated", or "prohibited".
        public let mechanism: String
        public let path: String?
        public let product: String?
        public let adapter: String?
        /// The Relay commit that imported the pristine upstream tree, so the
        /// source offer can show exactly what Relay changed.
        public let baselineCommit: String?
    }

    /// Whether this core may be linked into a Relay Release product.
    /// Only a core Relay actually enabled, whose licence permits commercial
    /// distribution, and which needs no further legal review, qualifies.
    public var isReleaseEligible: Bool {
        relayStatus == .enabled && commercialUse == .permitted && legalReviewStatus == .notRequired
            && clientCompatibility == .compatible
    }

    /// Cores that must never reach a Release product, whatever else changes.
    public var isProhibited: Bool {
        commercialUse == .prohibited || legalReviewStatus == .blocked || clientCompatibility == .prohibited
    }
}

public struct CoreManifest: Hashable, Codable, Sendable {
    public let schemaVersion: Int
    public let auditedOn: String
    public let cores: [CoreManifestEntry]

    private enum CodingKeys: String, CodingKey { case schemaVersion, auditedOn, cores }

    public init(schemaVersion: Int, auditedOn: String, cores: [CoreManifestEntry]) {
        self.schemaVersion = schemaVersion
        self.auditedOn = auditedOn
        self.cores = cores
    }

    public static func decode(from data: Data) throws -> CoreManifest {
        try JSONDecoder().decode(CoreManifest.self, from: data)
    }

    public func entry(for id: CoreID) -> CoreManifestEntry? { cores.first { $0.id == id } }

    /// The cores Relay builds and ships.
    public var enabled: [CoreManifestEntry] { cores.filter { $0.relayStatus == .enabled } }
    /// Cores that may never appear in a Release product.
    public var prohibited: [CoreManifestEntry] { cores.filter(\.isProhibited) }

    /// The core Relay prefers for a system, if the manifest enables one.
    /// A system never has two enabled cores; that is asserted by the tests.
    public func enabledCore(for system: SystemID) -> CoreManifestEntry? {
        enabled.first { $0.systems.contains(system) }
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MetadataProvider.swift
//  RelayLibrary
//
//  The Relay-owned metadata boundary. Providers are optional, asynchronous,
//  and never on the launch path: a game plays with or without metadata.
//  Release builds use the offline title catalog (RelayTitleCatalog), with
//  `NoMetadataProvider` as the fallback; Debug chains `StaticMetadataProvider`
//  fixtures before the catalog. Matching is by the request's lookup digests
//  or fingerprint, never by file name; a game with no content on this device
//  offers its synced title instead.

import Foundation
import RelayDomain

public struct MetadataRequest: Hashable, Sendable {
    public let fingerprint: ContentFingerprint
    public let systemID: SystemID
    public let fileName: String
    public let sizeInBytes: Int64
    /// Catalog lookup keys read from the stored file; nil when they could not be read.
    public let lookupDigests: LookupDigests?
    /// The game's synced title, set only when its content is not on this device
    /// (there is no file to read). A provider may match it exactly.
    public let title: String?

    public init(fingerprint: ContentFingerprint, systemID: SystemID, fileName: String, sizeInBytes: Int64,
                lookupDigests: LookupDigests? = nil, title: String? = nil) {
        self.fingerprint = fingerprint
        self.systemID = systemID
        self.fileName = fileName
        self.sizeInBytes = sizeInBytes
        self.lookupDigests = lookupDigests
        self.title = title
    }
}

/// Cover artwork as delivered by a provider.
public struct ArtworkPayload: Hashable, Sendable {
    /// Encoded image bytes (PNG or JPEG).
    public let data: Data
    /// File extension without dot, lowercase ("png", "jpg").
    public let fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension.lowercased()
    }
}

public struct MetadataCandidate: Hashable, Sendable {
    public var title: String
    public var alternateTitles: [String]
    public var developer: String?
    public var publisher: String?
    public var releaseYear: Int?
    public var genre: String?
    public var region: String?
    public var summary: String?
    public var artwork: ArtworkPayload?
    /// Key of the cover on Relay's mirror (CoverKey); nil when unknown.
    public var coverKey: String?
    /// Provider that produced this candidate when it differs from the queried one (chained providers).
    public var source: String?
    /// 0…1; providers order candidates by this.
    public var confidence: Double

    public init(title: String, alternateTitles: [String] = [], developer: String? = nil, publisher: String? = nil,
                releaseYear: Int? = nil, genre: String? = nil, region: String? = nil, summary: String? = nil,
                artwork: ArtworkPayload? = nil, coverKey: String? = nil, source: String? = nil, confidence: Double = 1) {
        self.title = title
        self.alternateTitles = alternateTitles
        self.developer = developer
        self.publisher = publisher
        self.releaseYear = releaseYear
        self.genre = genre
        self.region = region
        self.summary = summary
        self.artwork = artwork
        self.coverKey = coverKey
        self.source = source
        self.confidence = confidence
    }
}

public protocol MetadataProvider: Sendable {
    /// Stable identifier recorded on `GameMetadata.source`.
    var id: String { get }
    /// Version of the provider's data; a change triggers a library backfill. nil: never backfill.
    var revision: String? { get }
    /// Whether `match` reads `MetadataRequest.lookupDigests`. Only then does Relay
    /// read the stored file to compute them (a disc can be hundreds of megabytes).
    var usesLookupDigests: Bool { get }
    /// Candidates, best first; empty when nothing matches. Must not throw for "no match".
    func match(_ request: MetadataRequest) async throws -> [MetadataCandidate]
}

public extension MetadataProvider {
    var revision: String? { nil }
    var usesLookupDigests: Bool { false }
}

/// Asks each provider in turn and returns the first non-empty answer, recording
/// which provider produced it.
public struct ChainedMetadataProvider: MetadataProvider {
    public let providers: [any MetadataProvider]
    public init(_ providers: [any MetadataProvider]) { self.providers = providers }
    public var id: String { providers.map { $0.id }.joined(separator: "+") }
    public var revision: String? { providers.lazy.compactMap { $0.revision }.first }
    public var usesLookupDigests: Bool { providers.contains { $0.usesLookupDigests } }

    public func match(_ request: MetadataRequest) async throws -> [MetadataCandidate] {
        for provider in providers {
            let found = (try? await provider.match(request)) ?? []
            if !found.isEmpty { return found.map { var c = $0; c.source = c.source ?? provider.id; return c } }
        }
        return []
    }
}

/// Never matches anything.
public struct NoMetadataProvider: MetadataProvider {
    public let id = "none"
    public init() {}
    public func match(_ request: MetadataRequest) async throws -> [MetadataCandidate] { [] }
}

/// Exact-fingerprint lookup table. Used for fixtures and tests.
public struct StaticMetadataProvider: MetadataProvider {
    public let id: String
    private let entries: [ContentFingerprint: MetadataCandidate]

    public init(id: String = "static", entries: [ContentFingerprint: MetadataCandidate]) {
        self.id = id
        self.entries = entries
    }

    public func match(_ request: MetadataRequest) async throws -> [MetadataCandidate] {
        entries[request.fingerprint].map { [$0] } ?? []
    }
}

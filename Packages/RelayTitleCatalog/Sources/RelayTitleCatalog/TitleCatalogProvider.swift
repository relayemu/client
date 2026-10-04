// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  TitleCatalogProvider.swift
//  RelayTitleCatalog
//
//  The Release metadata provider: exact SHA-1 first, then the headerless
//  SHA-1, then a PlayStation serial. A title must belong to the game's system
//  or its colour/monochrome sibling (Relay files dual-mode Game Boy games as
//  Game Boy Color). A game with no content on this device is matched by its
//  synced title, choosing the variant best ranked for the device's region.
//  Returns title, region and cover key, never image bytes.

import Foundation
import RelayDomain
import RelayLibrary

public struct TitleCatalogProvider: MetadataProvider {
    public let id = "title-catalog"
    public let usesLookupDigests = true
    public var revision: String? { catalog.revision }
    private let catalog: TitleCatalog
    private let regionPreference: [String]

    public init(catalog: TitleCatalog, regionCode: String? = Locale.current.region?.identifier) {
        self.catalog = catalog
        regionPreference = CatalogName.regionPreference(for: regionCode)
    }

    /// The bundled catalog, or nil when the resource cannot be opened.
    public static func bundled() -> (any MetadataProvider)? {
        (try? TitleCatalog.bundled()).map { TitleCatalogProvider(catalog: $0) }
    }

    static func family(of system: SystemID) -> [SystemID] {
        switch system {
        case .gameBoy: return [.gameBoy, .gameBoyColor]
        case .gameBoyColor: return [.gameBoyColor, .gameBoy]
        case .wonderSwan: return [.wonderSwan, .wonderSwanColor]
        case .wonderSwanColor: return [.wonderSwanColor, .wonderSwan]
        default: return [system]
        }
    }

    public func match(_ request: MetadataRequest) async throws -> [MetadataCandidate] {
        let family = Self.family(of: request.systemID)
        if let digests = request.lookupDigests { return try match(digests, in: family) }
        if let title = request.title { return try match(title: title, in: family) }
        return []
    }

    private func match(_ digests: LookupDigests, in family: [SystemID]) throws -> [MetadataCandidate] {
        var lookups: [(() throws -> [CatalogTitle], Double)] = [({ try catalog.titles(sha1: digests.sha1) }, 1)]
        if let headerless = digests.headerlessSHA1 { lookups.append(({ try catalog.titles(sha1: headerless) }, 1)) }
        if let serial = digests.discSerial { lookups.append(({ try catalog.titles(serial: serial) }, 0.9)) }
        for (lookup, confidence) in lookups {
            let titles = try lookup()
            guard let best = family.lazy.compactMap({ system in titles.first { $0.system == system } }).first else { continue }
            return [Self.candidate(best, confidence: confidence)]
        }
        return []
    }

    private func match(title: String, in family: [SystemID]) throws -> [MetadataCandidate] {
        let key = CatalogName.matchKey(title)
        guard !key.isEmpty else { return [] }
        for system in family {
            let ranked = try catalog.titles(system: system, matchKey: key).min { a, b in
                let ra = CatalogName.rank(a.name, preference: regionPreference), rb = CatalogName.rank(b.name, preference: regionPreference)
                return (ra.0, ra.1, ra.2, a.id) < (rb.0, rb.1, rb.2, b.id)
            }
            if let best = ranked { return [Self.candidate(best, confidence: 0.6)] }
        }
        return []
    }

    private static func candidate(_ title: CatalogTitle, confidence: Double) -> MetadataCandidate {
        MetadataCandidate(title: CatalogName.displayTitle(title.name), region: CatalogName.region(title.name),
                          coverKey: CoverKey.make(system: title.system, catalogName: title.name), confidence: confidence)
    }
}

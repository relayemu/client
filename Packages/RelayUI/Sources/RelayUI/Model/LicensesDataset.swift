// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct LicensesDataset: Codable, Sendable, Equatable {
    public struct Component: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let category: String
        public let name: String
        public let version: String
        public let revision: String?
        public let license: String
        public let licenseName: String
        public let licenseNote: String?
        public let copyright: String
        public let upstream: String
        public let upstreamBase: String?
        public let description: String
        public let systems: [String]?
        public let modifications: String?
        public let sourceLocation: String?
        public let licenseText: String
        public let noticeText: String?
        public let shipped: Bool

        /// "7.11.1 (b83108d1)" or just the version.
        public var versionLabel: String {
            if let revision, !revision.isEmpty, !version.contains(revision.prefix(8)) {
                return "\(version) (\(revision.prefix(10)))"
            }
            return version
        }
    }

    public struct Category: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let components: [Component]
    }

    public let schemaVersion: Int
    public let generatedFrom: [String]
    public let relayVersion: String
    public let sourceRepository: String
    public let relayLicense: String
    public let categories: [Category]

    public var shippedComponents: [Component] { categories.flatMap(\.components) }

    /// The bundled dataset. Absent only in a broken build, in which case the
    /// licence screen says so instead of showing an empty list.
    public static func bundled() -> LicensesDataset? {
        guard let url = Bundle.module.url(forResource: "licenses", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LicensesDataset.self, from: data)
    }

    public static func load(from url: URL) throws -> LicensesDataset {
        try JSONDecoder().decode(LicensesDataset.self, from: Data(contentsOf: url))
    }

    /// Links shown on the About screen. One repository, four documents.
    public enum Link: CaseIterable, Sendable {
        case sourceCode, relayLicense, thirdParty, trademarks

        public func url(repository: String) -> URL {
            let base = repository.hasSuffix("/") ? String(repository.dropLast()) : repository
            switch self {
            case .sourceCode: return URL(string: base)!
            case .relayLicense: return URL(string: base + "/blob/main/LICENSE")!
            case .thirdParty: return URL(string: base + "/blob/main/THIRD_PARTY_LICENSES.md")!
            case .trademarks: return URL(string: base + "/blob/main/TRADEMARKS.md")!
            }
        }
    }
}

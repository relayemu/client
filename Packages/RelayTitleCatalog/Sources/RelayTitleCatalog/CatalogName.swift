// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CatalogName.swift
//  RelayTitleCatalog
//
//  No-Intro/Redump names read "Title (Region) (Languages) (Revision) [flags]".
//  The display title drops every trailing tag and fronts a sorting article
//  ("Legend of Zelda, The - …" → "The Legend of Zelda - …"); the region is the
//  first tag. A game known only by its synced title is matched on its match
//  key and the variant ranked best for the device's region.

import Foundation

public enum CatalogName {
    private static let trailingTags = #"(\s*(\([^()]*\)|\[[^\[\]]*\]))+\s*$"#
    private static let articles = ["The", "A", "An", "Le", "La", "Les", "Die", "Der", "Das", "El", "Los", "Las", "Il", "Lo"]

    public static func displayTitle(_ name: String) -> String {
        let base = name.replacingOccurrences(of: trailingTags, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return name }
        let parts = base.components(separatedBy: " - ")
        var head = parts[0]
        for article in articles where head.hasSuffix(", " + article) {
            head = article + " " + head.dropLast(article.count + 2)
            break
        }
        return ([head] + parts.dropFirst()).joined(separator: " - ")
    }

    public static func region(_ name: String) -> String? {
        guard let open = name.firstIndex(of: "("),
              let close = name[open...].firstIndex(of: ")") else { return nil }
        let region = name[name.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return region.isEmpty ? nil : region
    }

    /// Every "(…)" and "[…]" tag of a name, in order.
    public static func tags(_ name: String) -> [String] {
        var tags: [String] = [], current: String?, closing: Character = ")"
        for character in name {
            if current == nil, character == "(" || character == "[" {
                current = ""
                closing = character == "(" ? ")" : "]"
            } else if let tag = current, character == closing {
                tags.append(tag.trimmingCharacters(in: .whitespaces))
                current = nil
            } else if current != nil {
                current?.append(character)
            }
        }
        return tags
    }

    /// A title reduced to what survives renaming across devices and keyboards:
    /// case, diacritics and width folded, punctuation collapsed to single spaces.
    public static func matchKey(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var key = String.UnicodeScalarView()
        var separated = false
        for scalar in folded.unicodeScalars {
            guard CharacterSet.alphanumerics.contains(scalar) else { separated = true; continue }
            if separated, !key.isEmpty { key.append(" ") }
            separated = false
            key.append(scalar)
        }
        return String(key)
    }

    /// No-Intro region names, most wanted first, for a device in `regionCode`
    /// (ISO 3166-1); a worldwide release always ranks before other markets.
    public static func regionPreference(for regionCode: String?) -> [String] {
        let local: [String]
        switch regionCode?.uppercased() {
        case "US": local = ["USA"]
        case "CA": local = ["Canada", "USA"]
        case "GB", "IE": local = ["UK", "Europe"]
        case "FR", "MC": local = ["France", "Europe"]
        case "BE": local = ["Belgium", "France", "Netherlands", "Europe"]
        case "LU": local = ["France", "Germany", "Europe"]
        case "CH": local = ["Switzerland", "Germany", "France", "Italy", "Europe"]
        case "DE": local = ["Germany", "Europe"]
        case "AT": local = ["Austria", "Germany", "Europe"]
        case "IT": local = ["Italy", "Europe"]
        case "ES": local = ["Spain", "Europe"]
        case "PT": local = ["Portugal", "Europe"]
        case "NL": local = ["Netherlands", "Europe"]
        case "SE": local = ["Sweden", "Scandinavia", "Europe"]
        case "NO": local = ["Norway", "Scandinavia", "Europe"]
        case "DK": local = ["Denmark", "Scandinavia", "Europe"]
        case "FI": local = ["Finland", "Scandinavia", "Europe"]
        case "PL": local = ["Poland", "Europe"]
        case "RO", "GR", "CZ", "HU": local = ["Europe"]
        case "RU": local = ["Russia", "Europe"]
        case "AU", "NZ": local = ["Australia", "Europe"]
        case "BR": local = ["Brazil", "USA"]
        case "MX": local = ["Mexico", "Latin America", "USA"]
        case "AR", "CL", "CO", "PE": local = ["Latin America", "USA"]
        case "JP": local = ["Japan"]
        case "KR": local = ["Korea", "Japan"]
        case "CN": local = ["China", "Asia"]
        case "TW": local = ["Taiwan", "Asia", "Japan"]
        case "HK": local = ["Hong Kong", "Asia", "Japan"]
        default: local = []
        }
        var seen = Set<String>()
        return (local + ["World", "USA", "Europe", "Japan"]).filter { seen.insert($0).inserted }
    }

    private static let unreleased: Set<String> = ["Beta", "Proto", "Demo", "Sample", "Kiosk", "Debug", "Pirate", "Unl"]

    /// Orders catalog names for a device (smaller is better): a release before a
    /// beta, prototype, demo or pirate copy, then the preferred region, then the
    /// plainest name (fewest tags).
    public static func rank(_ name: String, preference: [String]) -> (Int, Int, Int) {
        let nameTags = Self.tags(name)
        let isUnreleased = nameTags.contains { tag in tag.split(separator: " ").contains { unreleased.contains(String($0)) } }
        let regions = region(name)?.components(separatedBy: ", ") ?? []
        let regionRank = regions.compactMap { preference.firstIndex(of: $0) }.min() ?? preference.count
        return (isUnreleased ? 1 : 0, regionRank, nameTags.count)
    }
}

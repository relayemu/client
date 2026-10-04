// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RelayDesignSystem

final class LocalizationResourceTests: XCTestCase {
    private static let v1Locales = [
        "en", "fr", "de", "es-ES", "es-MX", "it", "nl", "pl",
        "pt-PT", "pt-BR", "sv", "ro", "ja", "ko", "zh-Hant",
    ]

    func testAllV1LocaleBundlesAndRepresentativeStringsArePackaged() throws {
        for locale in Self.v1Locales {
            let path = try XCTUnwrap(
                Bundle.module.path(forResource: locale, ofType: "lproj"),
                "\(locale).lproj missing from the RelayDesignSystem bundle"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            let action = bundle.localizedString(forKey: "How to Add", value: "⟂", table: "Localizable")
            XCTAssertNotEqual(action, "⟂", "missing How to Add in \(locale)")
            XCTAssertFalse(action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let games = String.localizedStringWithFormat(
                bundle.localizedString(forKey: "%lld games", value: "⟂", table: "Localizable"),
                2
            )
            XCTAssertTrue(games.contains("2"), "plural did not format for \(locale): \(games)")
        }
    }

    func testUnsupportedLanguageFallsBackToEnglish() {
        let preferred = Bundle.preferredLocalizations(
            from: Bundle.module.localizations,
            forPreferences: ["ar"]
        )
        XCTAssertEqual(preferred.first, "en")
    }
}

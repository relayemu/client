// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LocalizationTests.swift — V1 launch locale resources and representative copy.

import XCTest
@testable import RelayUI

final class LocalizationTests: XCTestCase {
    static let v1Locales = [
        "en", "fr", "de", "es-ES", "es-MX", "it", "nl", "pl",
        "pt-PT", "pt-BR", "sv", "ro", "ja", "ko", "zh-Hant",
    ]

    static let keys = [
        "Home", "Library", "Search", "Settings", "Continue Playing", "Recently Played", "Recently Added", "Favorites",
        "Import Files", "Which formats work?", "No games yet.", "Drop some in. Relay finds the covers and keeps your saves with you.",
        "Play", "Continue", "Exit Game", "Resume", "Delete", "Not played yet", "Import issues",
        "Relay couldn't recognise this file.", "This game won't start.",
        "Relay account", "Relay Sync status",
        "Keep version %lld: %@, saved %@",
        "Sync provider", "Not connected", "Recovery", "Last successful sync", "Open account portal",
        "Sign out of Relay Sync?", "Upload game files to Relay Sync", "Online storage removed",
        "Your session has expired. Sign in with Apple again.",
        "Apple sign-in could not be completed. Please try again.",
        "Retry sync",
        "Import…", "Game", "Quick Load", "Load Save…", "Fast Forward", "Normal Speed",
        "Then: %@", "Plan changes on %@", "Renews %@", "Available until %@",
        "Expanded", "Collapsed", "Up", "Down", "Left", "Right",
        "Explore Sync memberships", "Finish membership setup", "Manage in App Store",
        "Your library, with room to grow.", "One membership, managed by Apple",
        "This Relay Sync subscription is linked to another Relay account.",
        "Purchase cancelled. Your current plan is unchanged.",
        "Your purchase is pending approval. Your current plan stays unchanged until Apple approves it.",
        "Record Gameplay", "Long Recordings", "Stop · %@",
        "Caption", "Write your own caption", "Relay Card preview",
        "Relay couldn't prepare this card. Try again.",
        "Save", "Save As…", "Saved", "Couldn't save the file",
        "Your export is still available. Try saving it in another location.",
        "Record gameplay without a plan-imposed time limit. Storage and device safety limits still apply.",
        "Recording stopped because storage is low. Share any ready recording before starting another.",
        "Relay couldn't check the available storage. Recording has stopped.",
        "Some older progress belongs to another device and stays local here. Open Relay on the original device to sync it.",
        "Relay Sync cannot automatically remove older save history yet. Your local saves are safe. You can keep playing while this sync action is paused.",
    ]

    func frenchBundle() throws -> Bundle {
        try localeBundle("fr")
    }

    func localeBundle(_ locale: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.module.path(forResource: locale, ofType: "lproj"),
            "\(locale).lproj missing from the RelayUI bundle"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    func testAllV1LocaleBundlesAndRepresentativeStringsArePackaged() throws {
        let representativeKeys = [
            "Home", "Library", "Search", "Settings", "Continue",
            "Quick Save", "PlayStation Firmware", "RetroAchievements account",
            "Skin", "Record Gameplay", "Relay Sync status",
        ]
        for locale in Self.v1Locales {
            let bundle = try localeBundle(locale)
            for key in representativeKeys {
                let missingValue = locale == "en" ? key : "⟂"
                let value = bundle.localizedString(forKey: key, value: missingValue, table: "Localizable")
                if locale != "en" {
                    XCTAssertNotEqual(value, "⟂", "missing \(locale) translation for '\(key)'")
                }
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if locale != "en" {
                let settings = bundle.localizedString(forKey: "Settings", value: "⟂", table: "Localizable")
                XCTAssertNotEqual(settings, "Settings", "suspicious English fallback in \(locale)")
            }
            let plural = String.localizedStringWithFormat(
                bundle.localizedString(forKey: "%lld games", value: "⟂", table: "Localizable"),
                2
            )
            XCTAssertTrue(plural.contains("2"), "plural did not format for \(locale): \(plural)")
        }
    }

    func testUnsupportedLanguageFallsBackToEnglish() {
        let preferred = Bundle.preferredLocalizations(
            from: Bundle.module.localizations,
            forPreferences: ["ar"]
        )
        XCTAssertEqual(preferred.first, "en")
    }

    func testPluralLookupsFormatRepresentativeCountsInEveryLocale() throws {
        for locale in Self.v1Locales {
            let bundle = try localeBundle(locale)
            for key in ["%lld games", "%lld items"] {
                let format = bundle.localizedString(forKey: key, value: "⟂", table: "Localizable")
                XCTAssertNotEqual(format, "⟂")
                for count: Int64 in [0, 1, 2, 21, 1_000_000] {
                    let rendered = String.localizedStringWithFormat(format, count)
                    XCTAssertEqual(rendered.filter(\.isNumber), String(count),
                                   "Incorrect localized count: \(locale) / \(key) / \(rendered)")
                    XCTAssertFalse(rendered.contains("%"), "Unresolved format: \(locale) / \(rendered)")
                    XCTAssertFalse(rendered.contains("#@"), "Unresolved plural: \(locale) / \(rendered)")
                }
            }
        }
    }

    func testApprovedAmendmentsResolveThroughFoundationInsteadOfOldKeys() throws {
        let keys = [
            "Relay Pro is yours for good.",
            "Delete Everywhere removes the game and its saves from the selected sync service and devices using it. Other services keep their copies. Saves can't be recovered.",
            "Some older progress belongs to another device and stays local here. Open Relay on the original device to sync it.",
            "Relay Sync cannot automatically remove older save history yet. Your local saves are safe. You can keep playing while this sync action is paused.",
            "Membership revoked",
            "Uploads paused. Refresh your plan to check it.",
        ]
        let approved = [
            "en": [
                "Relay Pro is active.",
                "Delete Everywhere removes the game and its saves from the selected sync service and devices using it. Other services keep their copies. This can’t be undone on the selected service.",
                "Some earlier progress couldn’t be synced.",
                "Some older online saves couldn’t be removed. You can keep playing.",
                "Subscription no longer active",
                "Uploads are paused. Refresh your account information to check access.",
            ],
            "fr": [
                "Relay Pro est actif.",
                "Supprimer partout retire le jeu et ses sauvegardes du service choisi et des appareils qui l’utilisent. Les autres services gardent leurs copies. Cette action est irréversible sur le service choisi.",
                "Une partie de ta progression n’a pas pu être synchronisée.",
                "Certaines anciennes sauvegardes en ligne n’ont pas pu être supprimées. Tu peux continuer à jouer.",
                "Ton abonnement n’est plus actif",
                "Les envois sont en pause. Actualise les informations de ton compte pour vérifier ton accès.",
            ],
        ]
        for (locale, values) in approved {
            let bundle = try localeBundle(locale)
            for (key, value) in zip(keys, values) {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: "Localizable"), value,
                               "Approved amendment did not resolve in \(locale)")
            }
        }
    }

    func testKeyStringsAreTranslatedToFrench() throws {
        let fr = try frenchBundle()
        for key in Self.keys {
            let value = fr.localizedString(forKey: key, value: "⟂", table: "Localizable")
            XCTAssertNotEqual(value, "⟂", "missing French for '\(key)'")
            XCTAssertNotEqual(value, key, "untranslated French for '\(key)'")
        }
    }

    func testFrenchUsesInformalRegisterAndTypography() throws {
        let fr = try frenchBundle()
        let body = fr.localizedString(forKey: "Drop some in. Relay finds the covers and keeps your saves with you.", value: nil, table: "Localizable")
        XCTAssertTrue(body.contains("tes "), "'tu' register expected, got: \(body)")
        XCTAssertFalse(body.contains("vos "), "no 'vous' in product copy")
        let question = fr.localizedString(forKey: "Which formats work?", value: nil, table: "Localizable")
        XCTAssertTrue(question.hasSuffix("\u{202F}?"), "narrow no-break space before '?' expected: \(question)")
        let plural = String.localizedStringWithFormat(fr.localizedString(forKey: "%lld games", value: nil, table: "Localizable"), 3)
        XCTAssertTrue(plural.contains("3 jeux") || plural.contains("jeux"), "plural rule: \(plural)")
    }

    func testDeviceKindsAreGenderedInFrench() throws {
        let fr = try frenchBundle()
        XCTAssertEqual(fr.localizedString(forKey: "this iPhone", value: nil, table: "Localizable"), "cet iPhone")
        XCTAssertEqual(fr.localizedString(forKey: "this Apple TV", value: nil, table: "Localizable"), "cette Apple TV")
        XCTAssertEqual(fr.localizedString(forKey: "this Mac", value: nil, table: "Localizable"), "ce Mac")
    }
}

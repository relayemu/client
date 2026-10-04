// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Rendered localization evidence over shipping surfaces and components. These
/// checks do not replace native-human linguistic review or physical-device RC.
@MainActor
final class LocalizationLayoutUITests: XCTestCase {
    private static let v1Locales = [
        ("en", "en_US"), ("fr", "fr_FR"), ("de", "de_DE"),
        ("es-ES", "es_ES"), ("es-MX", "es_MX"), ("it", "it_IT"),
        ("nl", "nl_NL"), ("pl", "pl_PL"), ("pt-PT", "pt_PT"),
        ("pt-BR", "pt_BR"), ("sv", "sv_SE"), ("ro", "ro_RO"),
        ("ja", "ja_JP"), ("ko", "ko_KR"), ("zh-Hant", "zh_TW"),
    ]

    private static let deepLocales = [
        ("fr", "fr_FR"), ("de", "de_DE"), ("pl", "pl_PL"),
        ("pt-PT", "pt_PT"), ("pt-BR", "pt_BR"), ("ja", "ja_JP"),
        ("ko", "ko_KR"), ("zh-Hant", "zh_TW"),
    ]

    private static let protectedNameLocales = [
        ("pl", "pl_PL"), ("zh-Hant", "zh_TW"),
    ]

    override func setUp() {
        // One failed locale must not suppress evidence for every locale that
        // follows it in the bounded V1 matrix.
        continueAfterFailure = true
    }

    func testAllV1LocalesRenderRepresentativeProSurface() {
        for (language, region) in Self.v1Locales {
            let app = launch(
                language: language,
                region: region,
                screenArguments: ["--relay-screen", "pro", "--relay-pro-test", "free"]
            )
            let once = app.buttons["relayPro.purchase.once"]
            XCTAssertTrue(once.waitForExistence(timeout: 30), "Relay Pro did not render in \(language)")
            let monthly = app.buttons["relayPro.purchase.monthly"]
            XCTAssertTrue(monthly.exists, "Monthly offer missing in \(language)")
            let restore = app.buttons["relayPro.restore"]
            XCTAssertTrue(restore.exists, "Restore action missing in \(language)")
            for control in [once, monthly, restore] {
                XCTAssertFalse(control.label.isEmpty, "Empty localized action in \(language)")
                assertHorizontalBounds(control, in: app, locale: language)
            }
            capture(app, "l10n-\(language)-pro")
            app.terminate()
        }
    }

    func testApprovedProStatusAndStandardAccountGateEnglishFrench() {
        for (language, region, status) in [("en", "en_US", "Relay Pro is active."),
                                           ("fr", "fr_FR", "Relay Pro est actif.")] {
            let app = launch(language: language, region: region,
                             screenArguments: ["--relay-screen", "pro", "--relay-pro-test", "owned"])
            let active = app.staticTexts[status].firstMatch
            reveal(active, in: app)
            XCTAssertTrue(active.isHittable)
            capture(app, "rc-pro-approved-status-\(language)")
            // The standard RC does not define RELAY_HOSTED_PREPRODUCTION.
            // Do not activate a service merely to satisfy a navigation test.
            XCTAssertFalse(app.buttons["relayPro.memberships"].exists)
            let restore = app.buttons["relayPro.restore"]
            reveal(restore, in: app)
            XCTAssertTrue(restore.isHittable)
            capture(app, "rc-pro-restore-and-standard-account-gate-\(language)")
            let done = app.buttons["relayPro.dismiss"]
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            done.tap()
            XCTAssertFalse(done.exists)
            app.terminate()
        }
    }

    func testDeepLocalesKeepHostileLayoutActionsReachable() {
        for (language, region) in Self.deepLocales {
            let app = launch(
                language: language,
                region: region,
                screenArguments: ["--relay-layout-fixture"]
            )
            let marker = app.descendants(matching: .any)
                .matching(identifier: "layout.fixture.marker").firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 30), "Layout fixture missing in \(language)")
            for identifier in ["layout.fixture.continue", "layout.fixture.primary", "layout.fixture.secondary"] {
                let control = app.buttons[identifier]
                reveal(control, in: app)
                XCTAssertFalse(control.label.isEmpty, "Empty layout label in \(language)")
                XCTAssertGreaterThanOrEqual(control.frame.height, 44)
                assertHorizontalBounds(control, in: app, locale: language)
            }
            capture(app, "l10n-deep-\(language)-layout")
            app.terminate()
        }
    }

    func testDeepLocalesKeepProActionsReachableAtAccessibilityTextSize() {
        for (language, region) in Self.deepLocales {
            let app = launch(
                language: language,
                region: region,
                screenArguments: [
                    "--relay-screen", "pro", "--relay-pro-test", "free",
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                ]
            )
            for identifier in ["relayPro.purchase.once", "relayPro.purchase.monthly", "relayPro.restore"] {
                let control = app.buttons[identifier]
                reveal(control, in: app)
                XCTAssertTrue(control.isHittable, "Pro action is not reachable in \(language) at Accessibility XXXL")
                XCTAssertFalse(control.label.isEmpty, "Empty Pro action in \(language) at Accessibility XXXL")
                assertHorizontalBounds(control, in: app, locale: language)
            }
            let terms = app.links["relayPro.terms"]
            let privacy = app.links["relayPro.privacy"]
            for link in [terms, privacy] {
                reveal(link, in: app)
                XCTAssertTrue(link.isHittable, "Pro legal link is not reachable in \(language) at Accessibility XXXL")
                assertHorizontalBounds(link, in: app, locale: language)
            }
            XCTAssertLessThanOrEqual(
                terms.frame.maxY,
                privacy.frame.minY,
                "Pro legal links should stack at accessibility text sizes in \(language)"
            )
            capture(app, "l10n-deep-\(language)-pro-accessibility-xxxl")
            app.terminate()
        }
    }

    func testDeepLocalesKeepAchievementSignInReachableAtAccessibilityTextSize() {
        for (language, region) in Self.deepLocales {
            let app = launch(
                language: language,
                region: region,
                screenArguments: [
                    "--relay-achievements-fixture", "disconnected",
                    "--relay-pro-test", "free",
                    "--relay-screen", "achievements",
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                ]
            )
            let username = app.textFields["ra.username"]
            reveal(username, in: app)
            XCTAssertTrue(username.isHittable, "Achievement sign-in field is not reachable in \(language) at Accessibility XXXL")
            assertHorizontalBounds(username, in: app, locale: language)
            let connect = app.buttons["ra.connect"]
            reveal(connect, in: app)
            XCTAssertTrue(connect.isHittable, "Achievement sign-in action is not reachable in \(language) at Accessibility XXXL")
            XCTAssertFalse(connect.label.isEmpty, "Empty Achievement sign-in action in \(language)")
            assertHorizontalBounds(connect, in: app, locale: language)
            capture(app, "l10n-deep-\(language)-achievements-accessibility-xxxl")
            app.terminate()
        }
    }

    func testProtectedRetroAchievementsNameAtAccessibilityTextSize() {
        for (language, region) in Self.protectedNameLocales {
            let app = launch(
                language: language,
                region: region,
                screenArguments: [
                    "--relay-achievements-fixture", "disconnected",
                    "--relay-pro-test", "free",
                    "--relay-screen", "achievements",
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                ]
            )
            let error = app.descendants(matching: .any)["ra.error"]
            reveal(error, in: app)
            XCTAssertTrue(error.exists, "Achievement error is missing in \(language) at Accessibility XXXL")
            XCTAssertTrue(
                error.label.contains("RetroAchievements"),
                "The spoken protected product name changed in \(language)"
            )
            assertHorizontalBounds(error, in: app, locale: language)
            capture(app, "l10n-protected-\(language)-achievements-accessibility-xxxl")
            app.terminate()
        }
    }

    func testDeepLocalesKeepRelaySyncRecoveryReachableAtAccessibilityTextSize() {
        for (language, region) in Self.deepLocales {
            let app = launch(
                language: language,
                region: region,
                screenArguments: [
                    "--relay-accessibility-fixture", "recovery",
                    "--relay-screen", "settings",
                    "--relay-pro-test", "free",
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                ]
            )
            let vault = app.descendants(matching: .any)["settings.relayAccount.vault"]
            reveal(vault, in: app)
            XCTAssertFalse(vault.label.isEmpty, "Empty Relay Sync recovery status in \(language)")
            assertHorizontalBounds(vault, in: app, locale: language)
            let recovery = app.descendants(matching: .any)["settings.relayAccount.recovery"]
            reveal(recovery, in: app)
            XCTAssertFalse(recovery.label.isEmpty, "Empty Relay Sync recovery explanation in \(language)")
            assertHorizontalBounds(recovery, in: app, locale: language)
            let uploads = app.descendants(matching: .any)["settings.relayGameFileSync"]
            reveal(uploads, in: app)
            XCTAssertFalse(uploads.isEnabled, "Relay Sync uploads should remain disabled during recovery in \(language)")
            assertHorizontalBounds(uploads, in: app, locale: language)
            capture(app, "l10n-deep-\(language)-sync-recovery-accessibility-xxxl")
            app.terminate()
        }
    }

    private func launch(language: String, region: String, screenArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-sync-off",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", region,
        ] + screenArguments
        app.launch()
        return app
    }

    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        let collection = app.collectionViews.firstMatch
        let container: XCUIElement
        if scroll.waitForExistence(timeout: 2) {
            container = scroll
        } else {
            XCTAssertTrue(collection.waitForExistence(timeout: 5))
            container = collection
        }
        for upward in [true, false] {
            for _ in 0..<16 {
                if target.exists && target.isHittable { return }
                if upward { container.swipeUp() } else { container.swipeDown() }
            }
        }
        XCTFail("Localized control is not reachable: \(target.identifier)")
    }

    private func assertHorizontalBounds(_ target: XCUIElement, in app: XCUIApplication, locale: String) {
        XCTAssertGreaterThan(target.frame.width, 0)
        XCTAssertGreaterThanOrEqual(target.frame.minX, app.frame.minX, "Left overflow in \(locale)")
        XCTAssertLessThanOrEqual(target.frame.maxX, app.frame.maxX, "Right overflow in \(locale)")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let geometry = XCTAttachment(string: "Observed viewport: \(app.frame)\n" + app.debugDescription)
        geometry.name = name + "-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

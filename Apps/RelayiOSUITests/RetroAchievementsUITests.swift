// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@MainActor
final class RetroAchievementsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testGameDetailAchievementsRouteEnglishAndFrench() {
        for language in ["en", "fr"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "--relay-isolated-qualification", UUID().uuidString,
                "--relay-sync-off", "--relay-achievements-fixture", "disconnected",
                "--relay-import-fixture", "--relay-fixture", "relay-sram-counter",
                "--relay-screen", "library", "-AppleLanguages", "(\(language))",
            ]
            app.launch()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'counter'"))
                .firstMatch.waitForExistence(timeout: 30))
            app.terminate()
            let screenIndex = app.launchArguments.firstIndex(of: "library")!
            app.launchArguments[screenIndex] = "detail"
            app.launch()
            let achievements = app.buttons["game.achievements"]
            XCTAssertTrue(achievements.waitForExistence(timeout: 30))
            for _ in 0..<4 where !achievements.isHittable { app.swipeUp() }
            XCTAssertTrue(achievements.isHittable)
            capture("ra-\(language)-game-detail-action")
            achievements.tap()
            XCTAssertTrue(app.descendants(matching: .any)["ra.dashboard"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["ra.openConnect"].exists)
            capture("ra-\(language)-game-empty-dashboard")
            app.buttons["ra.openConnect"].tap()
            XCTAssertTrue(app.textFields["ra.username"].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    func testUnapprovedHardcoreControlsAreHiddenInEnglishAndFrench() {
        for language in ["en", "fr"] {
            let settings = launch(scenario: "disconnected", language: language)
            XCTAssertTrue(settings.textFields["ra.username"].waitForExistence(timeout: 30))
            XCTAssertFalse(settings.switches["ra.hardcore"].exists)
            XCTAssertFalse(settings.descendants(matching: .any)["ra.approvalPending"].exists)
            XCTAssertFalse(settings.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Hardcore'")).firstMatch.exists)
            capture("ra-\(language)-unapproved-settings")
            settings.terminate()

            let game = launch(scenario: "connected", language: language, autoplay: true)
            XCTAssertTrue(game.descendants(matching: .any).matching(identifier: "relay.player").firstMatch
                .waitForExistence(timeout: 60))
            XCTAssertFalse(game.descendants(matching: .any)["ra.hardcoreActive"].exists)
            revealAndPause(game)
            tapVisibleButton(game, label: language == "fr" ? "Succès" : "Achievements")
            XCTAssertTrue(game.descendants(matching: .any)["ra.dashboard"].waitForExistence(timeout: 10))
            XCTAssertFalse(game.buttons["ra.restartHardcore"].exists)
            XCTAssertFalse(game.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Hardcore'")).firstMatch.exists)
            capture("ra-\(language)-unapproved-dashboard")
            game.terminate()
        }
    }

    func testConnectPersistsInKeychainAndDisconnectRemovesSessionEnglish() {
        exerciseConnection(language: "en")
    }

    func testConnectPersistsInKeychainAndDisconnectRemovesSessionFrench() {
        exerciseConnection(language: "fr")
    }

    private func exerciseConnection(language: String) {
        let isolation = UUID().uuidString
        let app = launch(scenario: "disconnected", language: language, isolation: isolation)
        let username = app.textFields["ra.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        username.tap(); username.typeText("RelayFixture")
        let password = app.secureTextFields["ra.password"]
        password.tap(); password.typeText("fixture-password")
        app.buttons["ra.connect"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ra.connected"].waitForExistence(timeout: 15))
        capture("ra-\(language)-connected")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["ra.connected"].waitForExistence(timeout: 30), "Session must survive process restart through Keychain")
        app.buttons["ra.disconnect"].tap()
        XCTAssertTrue(username.waitForExistence(timeout: 15))
        capture("ra-\(language)-disconnected")
        app.terminate(); app.launch()
        XCTAssertTrue(username.waitForExistence(timeout: 30), "Disconnect must remove the stored session")
        XCTAssertFalse(app.descendants(matching: .any)["ra.connected"].exists)
        if language == "fr" { XCTAssertTrue(app.buttons["Se connecter"].exists) }
        else { XCTAssertTrue(app.buttons["Sign In"].exists) }
    }

    func testOfflineAccountNeverBlocksGameplay() {
        let app = launch(scenario: "offline", autoplay: true)
        let player = app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 60))
        let a = app.buttons["A"]
        XCTAssertTrue(a.waitForExistence(timeout: 10)); a.press(forDuration: 0.2)
        XCTAssertTrue((player.value as? String ?? "").contains("last:a"))
        capture("ra-offline-gameplay")
    }

    func testRealGameUnlockNotificationAndDashboard() {
        exerciseGame(language: "en")
    }

    func testRealGameUnlockNotificationAndDashboardFrench() {
        exerciseGame(language: "fr")
    }

    func testHardcoreModeCanDowngradeAndRequiresRestartToReenableEnglish() {
        exerciseHardcore(language: "en")
    }

    func testHardcoreModeCanDowngradeAndRequiresRestartToReenableFrench() {
        exerciseHardcore(language: "fr")
    }

    func testFrenchLargeTextAccessibilityAndFinalSummary() throws {
        exerciseGame(language: "fr")
        let standard = launch(scenario: "disconnected", language: "fr")
        XCTAssertTrue(standard.textFields["ra.username"].waitForExistence(timeout: 30))
        try audit(standard, types: [.textClipped, .sufficientElementDescription])
        let standardButtonHeight = standard.buttons["ra.connect"].frame.height
        capture("ra-fr-standard-text-account")
        standard.terminate()
        let app = launch(scenario: "disconnected", language: "fr",
                         extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let username = app.textFields["ra.username"]
        for _ in 0..<6 {
            if username.exists && username.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(username.exists && username.isHittable)
        capture("ra-fr-accessibility-account")
        let largeButtonHeight = app.buttons["ra.connect"].frame.height
        XCTAssertGreaterThan(largeButtonHeight, standardButtonHeight * 1.2,
                             "The Connect control must grow with accessibility text size")
        let measurement = XCTAttachment(string: "Connect row: standard=\(standardButtonHeight), accessibilityXXXL=\(largeButtonHeight)")
        measurement.name = "ra-native-text-scaling"; measurement.lifetime = .keepAlways; add(measurement)
        // Apple's Dynamic Type heuristic reports this disabled SwiftUI button
        // despite measured scaling. Preserve that raw diagnostic in the feature
        // verification record; this test proves layout without suppressing issues.
        try audit(app, types: [.textClipped, .sufficientElementDescription])
    }

    private func audit(_ app: XCUIApplication, types: XCUIAccessibilityAuditType) throws {
        try app.performAccessibilityAudit(for: types) { issue in
            var details = "\(issue.compactDescription)\n\(issue.detailedDescription)"
            if let element = issue.element { details += "\n\(element.debugDescription)" }
            let attachment = XCTAttachment(string: details)
            attachment.name = "ra-accessibility-issue"; attachment.lifetime = .keepAlways; self.add(attachment)
            return false
        }
    }

    private func exerciseHardcore(language: String) {
        let app = launch(scenario: "hardcore", language: language, autoplay: true)
        let ready = language == "fr" ? "RetroAchievements prêt · Hardcore" : "RetroAchievements ready · Hardcore"
        XCTAssertTrue(app.staticTexts[ready].waitForExistence(timeout: 60))
        capture("ra-\(language)-hardcore-gameplay")
        revealAndPause(app)
        XCTAssertTrue(app.buttons[language == "fr" ? "Sauvegarde rapide" : "Quick Save"].exists)
        XCTAssertFalse(app.buttons[language == "fr" ? "Retour arrière" : "Rewind"].exists)
        tapVisibleButton(app, label: language == "fr" ? "Succès" : "Achievements")
        let casual = language == "fr" ? "Continuer en mode Casual" : "Continue in Casual"
        XCTAssertTrue(app.buttons[casual].waitForExistence(timeout: 10))
        capture("ra-\(language)-hardcore-dashboard")
        app.buttons[casual].tap()
        let restart = language == "fr" ? "Redémarrer en mode Hardcore" : "Restart in Hardcore"
        XCTAssertTrue(app.buttons[restart].waitForExistence(timeout: 5))
        app.buttons[restart].tap()
        let confirmation = app.sheets.buttons[restart]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        capture("ra-\(language)-hardcore-restart")
        confirmation.tap()
        XCTAssertTrue(app.staticTexts[ready].waitForExistence(timeout: 20))
    }

    private func revealAndPause(_ app: XCUIApplication) {
        // SwiftUI propagates the player's identifier to this control. Hit its
        // observed bounds after revealing it, as an actual user would.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)).tap()
        tapVisibleButton(app, label: "Pause")
    }

    private func tapVisibleButton(_ app: XCUIApplication, label: String) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let frame = button.frame
        XCTAssertGreaterThan(frame.width, 0)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    private func exerciseGame(language: String) {
        let app = launch(scenario: "connected", language: language, autoplay: true)
        let player = app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts[language == "fr" ? "RetroAchievements prêt · Casual" : "RetroAchievements ready · Casual"].waitForExistence(timeout: 20))
        app.buttons["A"].press(forDuration: 0.2)
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", language == "fr" ? "Succès débloqué" : "Achievement unlocked")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        capture("ra-\(language)-unlock-notification")
        revealAndPause(app)
        XCTAssertTrue(app.buttons[language == "fr" ? "Reprendre" : "Resume"].waitForExistence(timeout: 5))
        capture("ra-\(language)-pause-actions")
        tapVisibleButton(app, label: language == "fr" ? "Succès" : "Achievements")
        let summary = app.staticTexts["ra.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.label, language == "fr" ? "Succès débloqués\u{202F}: 1 sur 2" : "1 of 2 unlocked")
        capture("ra-\(language)-game-dashboard")
        app.switches["ra.remaining"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["ra.achievement.1"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ra.achievement.2"].exists)
    }

    private func launch(scenario: String, language: String = "en", isolation: String = UUID().uuidString,
                        autoplay: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-isolated-qualification", isolation, "--relay-sync-off",
                               "--relay-achievements-fixture", scenario, "--relay-pro-test", "free",
                               "-relay.touch.showWithController", "YES",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language == "fr" ? "fr_FR" : "en_US"]
        if autoplay { app.launchArguments += ["--relay-autoplay-fixture", "--relay-fixture", "relay-sram-counter"] }
        else { app.launchArguments += ["--relay-screen", "achievements"] }
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

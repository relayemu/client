// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@MainActor
final class RelayProUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRelayProSurfaceSupportsFocusAndPurchase() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-reset-library", "--relay-screen", "pro",
            "--relay-pro-test", "free", "--relay-sync-off",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        let purchase = app.buttons["relayPro.purchase.once"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["relayPro.restore"].exists)
        XCTAssertTrue(app.staticTexts["Play on Mac"].exists)
        XCTAssertTrue(app.buttons["relayPro.purchase.monthly"].exists)
        XCTAssertTrue(purchase.hasFocus || app.buttons["relayPro.restore"].hasFocus,
                      "the purchase surface has no controller focus target")
        capture("appletv-relay-pro-free")

        if !purchase.hasFocus {
            for _ in 0..<4 where !purchase.hasFocus { XCUIRemote.shared.press(.up) }
        }
        XCTAssertTrue(purchase.hasFocus, "controller navigation could not focus Purchase")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Relay Pro is active."].waitForExistence(timeout: 10))
        capture("appletv-relay-pro-owned")
    }

    func testOwnedGameplayExposesControllerAndDisplayTools() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-reset-library", "--relay-autoplay-fixture",
            "--relay-fixture", "relay-sram-counter", "--relay-pro-test", "owned",
            "--relay-sync-off", "--relay-input-script", "3:menu",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch.waitForExistence(timeout: 60))
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15))
        XCTAssertTrue(resume.hasFocus, "Pause should start with Resume focused")
        XCTAssertTrue(app.buttons["Quick Save"].exists)
        XCTAssertTrue(app.buttons["Saves"].exists)
        XCTAssertFalse(app.buttons["relay.proFeature.advancedControllerMapping"].exists)
        XCTAssertFalse(app.buttons["relay.proFeature.advancedDisplay"].exists)
        capture("appletv-pro-value-pack-pause")

        openDisclosure("speed", direction: .down, in: app)
        XCTAssertTrue(app.buttons["0.5×"].exists)
        openDisclosure("rewind", direction: .down, in: app)
        XCTAssertTrue(app.buttons["1 minute"].exists)
        openDisclosure("controller", direction: .down, in: app)
        let mapping = app.buttons["relay.proFeature.advancedControllerMapping"]
        XCTAssertTrue(mapping.waitForExistence(timeout: 10))
        for _ in 0..<12 where !mapping.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(mapping.hasFocus, "controller navigation could not focus Controller Mapping")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["relay.controllerMappingEditor"].waitForExistence(timeout: 15))
        XCTAssertFalse(resume.exists, "Pause must leave accessibility while its tool is open")
        capture("appletv-pro-controller-mapping")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(mapping.waitForExistence(timeout: 15))

        openDisclosure("display", direction: .up, in: app)
        let display = app.buttons["relay.proFeature.advancedDisplay"]
        XCTAssertTrue(display.waitForExistence(timeout: 10))
        for _ in 0..<12 where !display.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(display.hasFocus, "controller navigation could not focus Advanced Display")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["relay.advancedDisplayEditor"].waitForExistence(timeout: 15))
        capture("appletv-pro-advanced-display")
    }

    /// The in-game Saves browser used to inherit the compact sheet geometry on
    /// Apple TV, which clipped its French heading and empty-state helper. Exercise
    /// the shipping presentation path and require the complete localized copy.
    func testFrenchInGameSavesUsesFullScreenReadableLayout() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-reset-library", "--relay-autoplay-fixture",
            "--relay-fixture", "relay-sram-counter", "--relay-pro-test", "free",
            "--relay-sync-off", "--relay-input-script", "3:saves",
            "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR",
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch
            .waitForExistence(timeout: 60))
        let title = app.staticTexts["Sauvegardes"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Aucune sauvegarde pour l’instant."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Pendant une partie, utilise « Sauvegarder » dans le menu pause."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Sauvegarder maintenant"].isHittable)
        XCTAssertGreaterThanOrEqual(title.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX)
        capture("appletv-fr-in-game-saves-full-screen")
    }

    private func openDisclosure(_ name: String, direction: XCUIRemote.Button, in app: XCUIApplication) {
        let row = app.buttons["relay.pause.\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        for _ in 0..<12 where !row.hasFocus { XCUIRemote.shared.press(direction) }
        XCTAssertTrue(row.hasFocus, "controller navigation could not focus \(name)")
        XCUIRemote.shared.press(.select)
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["RELAY_COMMERCE_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}

@MainActor
final class RetroAchievementsTVUITests: XCTestCase {
    func testAccountFieldsScrollIntoRemoteFocus() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-sync-off", "--relay-achievements-fixture", "disconnected",
            "--relay-screen", "achievements", "-AppleLanguages", "(fr)",
        ]
        app.launch()
        let username = app.textFields["ra.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        for _ in 0..<12 where !username.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(username.hasFocus)
        XCTAssertTrue(username.isHittable)
        let password = app.secureTextFields["ra.password"]
        for _ in 0..<6 where !password.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(password.hasFocus)
        XCTAssertTrue(password.isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "ra-tv-fr-account-focus"; screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIRemote.shared.press(.menu)
        XCTAssertFalse(username.exists)
    }
}

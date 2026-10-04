// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  HomeScreenAssetsUITests.swift
//
//  Inspecting the source SVGs is not verification: the platform composes the
//  layered icon with parallax and masks the Top Shelf behind the focused tile.
//  This test drives the Siri Remote through XCUIRemote — which reaches the Home
//  Screen, not just the app — puts Relay's icon into the top row so tvOS shows
//  its Top Shelf, and saves full-screen captures the phase's audit reads.
//
//  Captures land in the test attachments and, when RELAY_TV_CAPTURE_DIR is set
//  in the environment, as PNG files in that directory.

import XCTest

@MainActor
final class HomeScreenAssetsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// The icon, focused on the Home Screen (parallax layers composed), then the
    /// icon moved to the top row so the Top Shelf image is what the shelf shows.
    func testAppIconAndTopShelfOnTheHomeScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-reset-library", "--relay-screen", "library"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        let remote = XCUIRemote.shared
        // Home returns to the Home Screen. On a fresh simulator the top row holds
        // Settings, Relay and the test runner, and focus lands on Settings; one
        // press to the right focuses Relay, whose Top Shelf the row then shows.
        remote.press(.home)
        sleep(2)
        capture("tv-home-screen")
        remote.press(.right)
        sleep(2)
        capture("tv-home-icon-focused-top-shelf")
        // A second capture a moment later, for the parallax at rest.
        sleep(2)
        capture("tv-home-top-shelf")
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["RELAY_TV_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}

/// Regression for Home after the first real play session. Use normal product
/// import/play/stop paths and real Siri Remote focus; never seed play history.
@MainActor
final class HomeHistoryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testFirstSessionReturnsToHomeAndContinueSurvivesRelaunch() {
        for locale in ["en", "fr"] {
            let app = XCUIApplication()
            let isolation = UUID().uuidString
            let base = ["--relay-isolated-qualification", isolation, "--relay-sync-off",
                        "--relay-diag-log", "--relay-fixture", "relay-gb-counter",
                        "-AppleLanguages", "(\(locale))", "-AppleLocale", locale == "fr" ? "fr_FR" : "en_US"]
            let continueHeading = locale == "fr" ? "Continuer à jouer" : "Continue Playing"
            let exitLabel = locale == "fr" ? "Quitter le jeu" : "Exit Game"
            app.launchArguments = base + ["--relay-import-fixture"]
            app.launch()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "relay-gb-counter"))
                .firstMatch.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(app.staticTexts[continueHeading].exists, "A fresh import has no play history")
            app.terminate()

            app.launchArguments = base + ["--relay-autoplay-fixture", "--relay-input-script", "3:menu"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["relay.player"].waitForExistence(timeout: 30))
            exitGame(app, label: exitLabel)
            assertHome(app, heading: continueHeading, name: "home-history-\(locale)-first-return")
            app.terminate()

            app.launchArguments = base
            app.launch()
            assertHome(app, heading: continueHeading, name: "home-history-\(locale)-relaunch")
            // The added-game link has the same title. Only the Continue hero
            // includes the local play-history status in its accessibility label.
            let hero = app.buttons.matching(NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "relay-gb-counter", locale == "fr" ? "Joué" : "Played"
            )).firstMatch
            XCTAssertTrue(hero.waitForExistence(timeout: 10))
            // Home's tab bar is horizontal: Right selects Library, whereas Down
            // enters the Continue shelf. Keep this a real remote interaction.
            focus(hero, direction: .down, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.descendants(matching: .any)["relay.player"].waitForExistence(timeout: 15),
                          "The Continue card must resume through real remote activation: \(app.debugDescription)")
            XCUIRemote.shared.press(.menu)
            exitGame(app, label: exitLabel)
            assertHome(app, heading: continueHeading, name: "home-history-\(locale)-continue-return")
            app.terminate()
        }
    }

    private func exitGame(_ app: XCUIApplication, label: String) {
        let exit = app.buttons[label]
        XCTAssertTrue(exit.waitForExistence(timeout: 15), app.debugDescription)
        focus(exit, direction: .down, in: app)
        XCUIRemote.shared.press(.select)
    }

    private func focus(_ target: XCUIElement, direction: XCUIRemote.Button, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let reverse: XCUIRemote.Button = direction == .down ? .up : .down
        for movement in [direction, reverse] {
            for _ in 0..<24 where !target.hasFocus { XCUIRemote.shared.press(movement) }
            if target.hasFocus { break }
        }
        XCTAssertTrue(target.hasFocus, "Native remote focus did not reach \(target.label): \(app.debugDescription)")
    }

    private func assertHome(_ app: XCUIApplication, heading: String, name: String) {
        XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 15), app.debugDescription)
        // The original crash is asynchronous, after Home first mounts its hero.
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.staticTexts[heading].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}

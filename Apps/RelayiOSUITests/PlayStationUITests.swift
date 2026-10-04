// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@MainActor
final class PlayStationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testPlayStationTouchControlsInPortraitAndLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
            "--relay-sync-off", "--relay-autoplay-fixture", "--relay-fixture", "relay-ps1-counter",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-relay.touch.showWithController", "YES"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let player = app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 60))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for label in ["○", "×", "△", "□", "L1", "R1", "L2", "R2", "L3", "R3", "Left analog stick", "Right analog stick"] {
                let button = app.buttons[label]
                XCTAssertTrue(button.waitForExistence(timeout: 10), label)
                XCTAssertTrue(button.isHittable, "\(label) is not reachable")
            }
            app.buttons["○"].press(forDuration: 0.2)
            let circle = expectation(for: NSPredicate(format: "value CONTAINS %@", "last:a"), evaluatedWith: player)
            wait(for: [circle], timeout: 10)
            app.buttons["×"].press(forDuration: 0.2)
            let delivered = expectation(for: NSPredicate(format: "value CONTAINS %@", "last:b"), evaluatedWith: player)
            wait(for: [delivered], timeout: 10)
            let stick = app.buttons["Left analog stick"]
            stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: stick.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            // Full-screen capture avoids XCTest's cropped application image
            // when the phone has rotated into landscape.
            let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            capture.name = "ps1-phone-\(orientation.rawValue)"; capture.lifetime = .keepAlways; add(capture)
        }
    }

    func testFirmwarePageInEnglishAndFrench() {
        for locale in ["en", "fr"] {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                "--relay-sync-off", "--relay-screen", "settings", "-AppleLanguages", "(\(locale))"]
            app.launch()
            let settingsTitle = locale == "en" ? "Settings" : "Réglages"
            if !app.navigationBars[settingsTitle].firstMatch.waitForExistence(timeout: 2) {
                let settings = app.buttons[settingsTitle].firstMatch
                XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
            }
            let link = app.buttons["PlayStation Firmware"]
            let french = app.buttons["Firmware PlayStation"]
            let selected = locale == "en" ? link : french
            XCTAssertTrue(selected.waitForExistence(timeout: 30))
            if !selected.isHittable { app.swipeUp() }
            selected.tap()
            XCTAssertTrue(app.buttons["ps1.importBIOS"].waitForExistence(timeout: 10))
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "ps1-bios-\(locale)"; capture.lifetime = .keepAlways; add(capture)
            app.terminate()
        }
    }

    func testNativeDiscSwitchAndMissingArtworkFallbackWithoutAchievements() {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
            "--relay-sync-off", "--relay-import-fixture", "--relay-fixture", "relay-ps1-multidisc",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-relay.touch.showWithController", "YES"]
        app.launch()
        defer { app.terminate() }
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'relay-ps1-multidisc'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 40))
        capture("rc-ps1-home-fallback", app: app)
        card.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["game.achievements"].exists)
        capture("rc-ps1-detail-fallback-no-ra", app: app)
        play.tap()
        let player = app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 60))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)).tap()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.isHittable)
        pause.tap()
        XCTAssertFalse(app.buttons["relay.pause.achievements"].exists)
        let disc = app.buttons["relay.pause.disc"].firstMatch
        XCTAssertTrue(disc.waitForExistence(timeout: 10))
        disc.tap()
        let picker = app.buttons["relay.pause.discPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        for index in [2, 1] {
            picker.tap()
            app.buttons["Disc \(index)"].firstMatch.tap()
            let selected = expectation(for: NSPredicate(format: "value == %@", "Disc \(index) of 2"), evaluatedWith: disc)
            wait(for: [selected], timeout: 10)
            capture("rc-ps1-selected-disc-\(index)", app: app)
        }
        app.buttons["Resume"].tap()
        let cross = app.buttons["×"]
        XCTAssertTrue(cross.isHittable)
        cross.press(forDuration: 0.2)
        let delivered = expectation(for: NSPredicate(format: "value CONTAINS %@", "last:b"), evaluatedWith: player)
        wait(for: [delivered], timeout: 10)
        capture("rc-ps1-disc-return-game", app: app)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let geometry = XCTAttachment(string: app.debugDescription)
        geometry.name = name + "-geometry"; geometry.lifetime = .keepAlways; add(geometry)
    }
}

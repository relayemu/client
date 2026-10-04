// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import AppKit

@MainActor
final class PlayStationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testNativePlayStationPlayerAndBIOSPage() {
        for surface in ["player", "settings"] {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                "--relay-sync-off", "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)"]
            if surface == "player" { app.launchArguments += ["--relay-autoplay-fixture", "--relay-fixture", "relay-ps1-counter"] }
            else { app.launchArguments += ["--relay-screen", "settings"] }
            app.launch(); app.activate()
            if !app.windows.firstMatch.waitForExistence(timeout: 2) {
                let bundle = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("RelayMac.app")
                XCTAssertTrue(NSWorkspace.shared.open(bundle))
            }
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
            if surface == "player" {
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch.waitForExistence(timeout: 30))
                app.typeKey("x", modifierFlags: [])
            } else {
                let bios = app.buttons["PlayStation Firmware"]
                XCTAssertTrue(bios.waitForExistence(timeout: 30)); bios.click()
                XCTAssertTrue(app.buttons["ps1.importBIOS"].waitForExistence(timeout: 10))
            }
            let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            capture.name = "ps1-mac-\(surface)"; capture.lifetime = .keepAlways; add(capture)
            app.terminate()
        }
    }
}

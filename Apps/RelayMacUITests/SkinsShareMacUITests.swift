// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AppKit

@MainActor
final class SkinsShareMacUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testScreenshotAndCardUseOneNativeShareSurface() {
        for locale in ["en", "fr"] {
            let app = launch(locale: locale)
            defer { app.terminate() }
            for action in ["relay.share.screenshot", "relay.share.card"] {
                pause(app)
                element("relay.share.menu", in: app).click()
                element(action, in: app).click()
                let native = element("relay.share.native", in: app)
                XCTAssertTrue(native.waitForExistence(timeout: 15))
                XCTAssertTrue(element("relay.share.save", in: app).exists)
                XCTAssertEqual(app.sheets.count, 1)
                XCTAssertFalse(app.buttons[locale == "fr" ? "Reprendre" : "Resume"].isHittable)
                capture(app, "mac-\(locale)-\(action)")
                native.click()
                capture(app, "mac-\(locale)-native-picker")
                app.typeKey(.escape, modifierFlags: [])
                let done = app.buttons[locale == "fr" ? "OK" : "Done"]
                if !done.isHittable { app.typeKey(.escape, modifierFlags: []) }
                XCTAssertTrue(done.isHittable)
                done.click()
                app.buttons[locale == "fr" ? "Reprendre" : "Resume"].click()
            }
        }
    }

    func testClipRecordingAndNativePreview() throws {
        let app = launch(locale: "en")
        defer { app.terminate() }
        Thread.sleep(forTimeInterval: 12) // Quiet gameplay baseline before capture.
        pause(app)
        element("relay.share.menu", in: app).click()
        let record = element("relay.share.record", in: app)
        XCTAssertTrue(record.exists)
        guard record.isEnabled else {
            capture(app, "mac-recording-unavailable")
            throw XCTSkip("ReplayKit unavailable on this Mac run")
        }
        let monitor = addUIInterruptionMonitor(withDescription: "Apple recording consent") { alert in
            for label in ["Start Recording", "Record Screen", "Enregistrer l’écran", "Démarrer l’enregistrement"] where alert.buttons[label].exists {
                alert.buttons[label].click()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        record.click()
        app.windows.firstMatch.click()
        let stop = element("relay.share.stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "mac-recording")
        // Mac gameplay uses the owned Pro fixture. It must continue past the
        // Free cap and end only after an explicit stop in this flow.
        let prematureEnd = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stop)
        prematureEnd.isInverted = true
        wait(for: [prematureEnd], timeout: 16)
        XCTAssertTrue(stop.exists)
        stop.click()
        let ended = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stop)
        wait(for: [ended], timeout: 20)
        pause(app)
        element("relay.share.menu", in: app).click()
        let clip = element("relay.share.clip", in: app)
        XCTAssertTrue(clip.waitForExistence(timeout: 10), app.debugDescription)
        clip.click()
        XCTAssertTrue(element("relay.share.native", in: app).waitForExistence(timeout: 15))
        capture(app, "mac-clip-preview")
    }

    private func launch(locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        let qualification = UUID().uuidString
        print("SKINS-SHARE qualification=\(qualification) locale=\(locale)")
        app.launchArguments = ["--relay-isolated-qualification", qualification,
            "--relay-skins-share-qualification", "--relay-autoplay-fixture", "--relay-fixture", "relay-sram-tone",
            "--relay-pro-test", "owned", "--relay-sync-off", "--relay-diag-log", "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(\(locale))", "-AppleLocale", locale == "fr" ? "fr_FR" : "en_US"]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("RelayMac.app")
            XCTAssertTrue(NSWorkspace.shared.open(url))
        }
        XCTAssertTrue(element("relay.player", in: app).waitForExistence(timeout: 45))
        return app
    }

    private func pause(_ app: XCUIApplication) {
        let pause = app.buttons["Pause"].firstMatch
        if !pause.isHittable {
            element("relay.player", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.25)).click()
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.click()
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}

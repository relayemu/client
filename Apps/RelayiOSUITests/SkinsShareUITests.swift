// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import UIKit

@MainActor
final class SkinsShareUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    func testSkinsKeepRealTouchInputInPortraitAndLandscape() {
        for fixture in ["relay-gb-counter", "relay-sram-counter", "relay-nes-counter", "relay-ds-counter", "relay-ws-counter"] {
            let app = launch(fixture: fixture)
            let player = element("relay.player", in: app)
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                // Reset the observed last input so each orientation must
                // deliver a new event, even after A passed in the prior one.
                let b = app.buttons["B"].firstMatch
                XCTAssertTrue(b.waitForExistence(timeout: 10))
                b.press(forDuration: 0.1)
                let reset = expectation(for: NSPredicate(format: "value CONTAINS %@", "last:b"), evaluatedWith: player)
                wait(for: [reset], timeout: 10)
                let a = app.buttons["A"].firstMatch
                XCTAssertTrue(a.waitForExistence(timeout: 10))
                XCTAssertTrue(a.isHittable)
                a.press(forDuration: 0.2)
                let delivered = expectation(for: NSPredicate(format: "value CONTAINS %@", "last:a"), evaluatedWith: player)
                wait(for: [delivered], timeout: 10)
                capture("\(fixture)-\(orientation.rawValue)")
            }
            app.terminate()
        }
    }

    func testSkinCustomizationAndDisableEnglishFrench() {
        for language in ["en", "fr"] {
            let app = launch(fixture: "relay-sram-counter", language: language)
            pause(app)
            element("relay.pause.controller", in: app).tap()
            tap("relay.skin.open", in: app)
            XCTAssertTrue(element("relay.skin.editor", in: app).waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons[language == "fr" ? "Reprendre" : "Resume"].isHittable)
            let finish = app.buttons["relay.skin.finish"]
            XCTAssertTrue(finish.isEnabled)
            finish.tap()
            app.buttons[language == "fr" ? "Brume" : "Mist"].tap()
            app.buttons["relay.skin.accent"].tap()
            app.buttons[language == "fr" ? "Sarcelle" : "Teal"].tap()
            capture("skin-mist-\(language)")
            let toggle = app.switches["relay.skin.enabled"]
            XCTAssertTrue(toggle.isHittable)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let disabled = expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: finish)
            wait(for: [disabled], timeout: 5)
            capture("skin-disabled-\(language)")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            app.buttons[language == "fr" ? "OK" : "Done"].tap()
            app.buttons[language == "fr" ? "Reprendre" : "Resume"].tap()
            capture("skin-mist-gameplay-\(language)")
            let a = app.buttons["A"].firstMatch
            XCTAssertTrue(a.isHittable)
            a.press(forDuration: 0.2)
            app.terminate()
        }
    }

    func testFreeSkinControlsAtAccessibilityTextSize() {
        let app = launch(fixture: "relay-sram-counter", language: "fr", pro: false, accessibilityText: true)
        defer { app.terminate() }
        pause(app)
        tap("relay.pause.controller", in: app)
        tap("relay.skin.open", in: app)
        let toggle = app.switches["relay.skin.enabled"]
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let off = expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        wait(for: [off], timeout: 5)
        capture("skin-free-french-accessibility")
        let done = app.buttons["OK"]
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(app.buttons["Reprendre"].waitForExistence(timeout: 5))
    }

    func testFrenchDisplayPickersContainTheirAccessibilityXXXLValues() {
        let app = launch(fixture: "relay-sram-counter", language: "fr", pro: false, accessibilityText: true)
        defer { app.terminate() }
        pause(app)
        tap("relay.pause.display", in: app)

        assertValue("Pixel par pixel", fitsIn: "relay.pause.scalingPicker", in: app)
        assertValue("Original", fitsIn: "relay.pause.filterPicker", in: app)
        capture("display-french-accessibility-contained")
    }

    func testFreeScreenshotAndCardReachNativeShareSheet() {
        for (action, name) in [("relay.share.screenshot", "screenshot"), ("relay.share.card", "card")] {
            let app = launch(fixture: "relay-sram-counter", pro: false)
            pause(app)
            tap("relay.share.menu", in: app)
            tap(action, in: app)
            XCTAssertTrue(element("relay.share.save", in: app).waitForExistence(timeout: 10))
            if action == "relay.share.card" {
                let caption = element("relay.share.caption", in: app)
                XCTAssertTrue(caption.waitForExistence(timeout: 10))
                caption.tap()
                caption.typeText(" - Great run!")
                XCTAssertTrue((caption.value as? String)?.contains("Great run!") == true)
            }
            let save = element("relay.share.save", in: app)
            let prepared = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
            wait(for: [prepared], timeout: 10)
            save.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertTrue(cancel.isHittable)
            XCTAssertFalse(save.isHittable, "The Files picker must cover the Relay preview")
            capture("native-files-save-\(name)")
            cancel.tap()
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            tap("relay.share.native", in: app)
            let nativeCopy = app.buttons["Copy"].firstMatch
            let saveImage = app.buttons["Save Image"].firstMatch
            let visible = NSPredicate { _, _ in nativeCopy.exists || saveImage.exists || app.otherElements["ActivityListView"].exists }
            let ready = expectation(for: visible, evaluatedWith: app)
            wait(for: [ready], timeout: 20)
            XCTAssertFalse(app.buttons["Resume"].isHittable)
            capture("native-share-\(name)")
            app.terminate()
        }
    }

    func testCaptionLocalSaveNativeCopyAndReturnToGameplayEnglishFrench() {
        for language in ["en", "fr"] {
            let app = launch(fixture: "relay-sram-counter", language: language, pro: false)
            pause(app)
            tap("relay.share.menu", in: app)
            tap("relay.share.card", in: app)
            let caption = element("relay.share.caption", in: app)
            XCTAssertTrue(caption.waitForExistence(timeout: 10))
            caption.tap()
            caption.typeText(" RC caption \(language)")
            XCTAssertTrue((caption.value as? String)?.contains("RC caption \(language)") == true)
            capture("rc-caption-edited-\(language)")
            let save = element("relay.share.save", in: app)
            let prepared = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
            wait(for: [prepared], timeout: 10)
            save.tap()
            let nativeSave = app.buttons["DOCPicker.actionButton"]
            XCTAssertTrue(nativeSave.waitForExistence(timeout: 20))
            XCTAssertFalse(save.isHittable)
            let local = app.cells.matching(NSPredicate(format: "label == 'On My iPad' OR label == 'Sur mon iPad'")).firstMatch
            XCTAssertTrue(local.isHittable, "Select the simulator-local location explicitly, never iCloud")
            local.tap()
            let relayFolder = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Relay'")).firstMatch
            XCTAssertTrue(relayFolder.waitForExistence(timeout: 10))
            relayFolder.tap()
            let filename = app.textFields["DOCPicker.filenameTextField"]
            XCTAssertTrue(filename.waitForExistence(timeout: 10))
            let oldName = filename.value as? String ?? ""
            XCTAssertTrue(oldName.contains("Relay Card"), "The exported filename must remain invariant")
            filename.tap()
            filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count)
                              + "Relay RC Card \(language) \(UUID().uuidString.prefix(8))")
            nativeSave.tap()
            XCTAssertTrue(app.staticTexts[language == "fr" ? "Sauvegardé" : "Saved"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Caption editing must release keyboard ownership")
            capture("rc-card-saved-\(language)")
            tap("relay.share.native", in: app)
            let copy = app.cells.matching(NSPredicate(format: "label == 'Copy' OR label == 'Copier'")).firstMatch
            XCTAssertTrue(copy.waitForExistence(timeout: 15))
            capture("rc-card-native-copy-\(language)")
            copy.tap()
            let done = app.buttons[language == "fr" ? "OK" : "Done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            XCTAssertTrue(done.isHittable)
            done.tap()
            let resume = app.buttons[language == "fr" ? "Reprendre" : "Resume"]
            XCTAssertTrue(resume.waitForExistence(timeout: 10))
            XCTAssertTrue(resume.isHittable)
            resume.tap()
            let a = app.buttons["A"].firstMatch
            XCTAssertTrue(a.isHittable)
            a.press(forDuration: 0.2)
            let delivered = expectation(for: NSPredicate(format: "value CONTAINS %@", "last:a"),
                                        evaluatedWith: element("relay.player", in: app))
            wait(for: [delivered], timeout: 10)
            capture("rc-share-return-to-game-\(language)")
            app.terminate()
        }
    }

    func testExplicitClipRecordsAndReachesNativeShareSheet() throws {
        let app = launch(fixture: "relay-sram-tone", pro: false)
        Thread.sleep(forTimeInterval: 12) // Quiet native gameplay baseline before capture.
        pause(app)
        tap("relay.share.menu", in: app)
        let record = element("relay.share.record", in: app)
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        guard record.isEnabled else {
            capture("recording-unavailable")
            throw XCTSkip("ReplayKit unavailable on this target; a physical recording run remains required")
        }
        let monitor = addUIInterruptionMonitor(withDescription: "Apple recording consent") { alert in
            // Recording only. Never select a microphone or broadcast option.
            for label in ["Start Recording", "Record Screen", "Enregistrer l’écran", "Démarrer l’enregistrement"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        record.tap()
        app.tap()
        let stop = element("relay.share.stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 20), app.debugDescription)
        capture("clip-recording")
        app.buttons["A"].firstMatch.press(forDuration: 0.3)
        let ended = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stop)
        wait(for: [ended], timeout: 20)
        pause(app)
        tap("relay.share.menu", in: app)
        let clip = element("relay.share.clip", in: app)
        XCTAssertTrue(clip.waitForExistence(timeout: 15), app.debugDescription)
        clip.tap()
        XCTAssertTrue(element("relay.share.save", in: app).waitForExistence(timeout: 10))
        tap("relay.share.native", in: app)
        capture("native-share-clip")
        XCTAssertFalse(app.buttons["Resume"].isHittable)
    }

    private func launch(fixture: String, language: String = "en", pro: Bool = true, accessibilityText: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let qualification = UUID().uuidString
        print("SKINS-SHARE qualification=\(qualification) fixture=\(fixture)")
        app.launchArguments = ["--relay-isolated-qualification", qualification,
            "--relay-skins-share-qualification", "--relay-autoplay-fixture", "--relay-fixture", fixture,
            "--relay-pro-test", pro ? "owned" : "free", "--relay-sync-off", "--relay-diag-log",
            "-relay.touch.showWithController", "YES",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language == "fr" ? "fr_FR" : "en_US"]
        if accessibilityText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(element("relay.player", in: app).waitForExistence(timeout: 60))
        return app
    }

    private func pause(_ app: XCUIApplication) {
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        // Renew the three-second reveal window before checking and tapping.
        // Two successive isHittable reads can otherwise straddle auto-hide.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)).tap()
        let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: pause)
        wait(for: [visible], timeout: 5)
        let controlFrame = pause.frame
        XCTAssertEqual(controlFrame.width, 40)
        XCTAssertEqual(controlFrame.height, 40)
        // SwiftUI inherits relay.player on several descendants. XCTest's tap()
        // re-resolves that identifier and can hit a different node. The native
        // snapshot and screenshot agree on this visible 40-point circle; use
        // its measured centre without an ambiguous identifier re-resolution.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: controlFrame.midX - app.frame.minX,
                                 dy: controlFrame.midY - app.frame.minY)).tap()
        XCTAssertTrue(element("relay.share.menu", in: app).waitForExistence(timeout: 10), app.debugDescription)
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tap(_ id: String, in app: XCUIApplication) {
        let target = element(id, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        for _ in 0..<6 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.isHittable)
        target.tap()
    }

    private func assertValue(_ value: String, fitsIn identifier: String, in app: XCUIApplication) {
        let picker = app.buttons[identifier].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<6 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.isHittable)
        let label = picker.staticTexts[value].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThanOrEqual(label.frame.minY, picker.frame.minY,
                                    "\(value) extends above its picker")
        XCTAssertLessThanOrEqual(label.frame.maxY, picker.frame.maxY,
                                 "\(value) extends below its picker")
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: XCUIApplication().debugDescription)
        tree.name = "\(name)-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}

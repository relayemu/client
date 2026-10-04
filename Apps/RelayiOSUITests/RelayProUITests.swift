// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@MainActor
final class RelayProUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testPurchaseSurfaceUnlocksImmediately() {
        let app = launch(scenario: "free")
        let purchase = app.buttons["relayPro.purchase.once"]

        XCTAssertTrue(purchase.waitForExistence(timeout: 20))
        scrollToHittable(purchase, in: app)
        XCTAssertTrue(purchase.isHittable)
        XCTAssertTrue(app.staticTexts["Play on Mac"].exists)
        XCTAssertTrue(app.buttons["relayPro.purchase.monthly"].exists)
        XCTAssertTrue(app.staticTexts["All 12 systems are free on iPhone, iPad and Apple TV. Your library, saves and iCloud sync are free on every device."].exists)
        XCTAssertTrue(app.buttons["relayPro.restore"].exists)
        capture("iphone-relay-pro-free")

        purchase.tap()
        XCTAssertTrue(app.staticTexts["Relay Pro is active."].waitForExistence(timeout: 10))
        XCTAssertFalse(purchase.exists)
        capture("iphone-relay-pro-owned")
    }

    func testRestoreIsDiscoverableAndUnlocks() {
        let app = launch(scenario: "restorable")
        let restore = app.buttons["relayPro.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 20))
        scrollToHittable(restore, in: app)
        XCTAssertTrue(restore.isHittable)

        restore.tap()
        XCTAssertTrue(app.staticTexts["Relay Pro is active."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Relay Pro restored"].exists)
    }

    func testMonthlyAlternativeUnlocksImmediately() {
        let app = launch(scenario: "free")
        let monthly = app.buttons["relayPro.purchase.monthly"]
        XCTAssertTrue(monthly.waitForExistence(timeout: 20))
        scrollToHittable(monthly, in: app)
        XCTAssertTrue(monthly.isHittable)

        monthly.tap()
        XCTAssertTrue(app.staticTexts["Relay Pro Monthly is active"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["relayPro.purchase.once"].exists, "Monthly keeps the explicit Once upgrade path")
    }

    func testOnceAndMonthlyWarnsAboutContinuingRenewal() {
        let app = launch(scenario: "onceAndMonthly")
        XCTAssertTrue(app.staticTexts["Relay Pro is active."].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Your monthly subscription is still active."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["relayPro.manageMonthly"].exists)
    }

    func testFeatureSpecificUpsellCanBeDismissed() {
        let app = launch(scenario: "free", additionalArguments: ["--relay-pro-feature", "extendedRewind"])
        XCTAssertTrue(app.staticTexts["Longer Rewind"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Play on Mac"].exists)
        app.swipeDown()
    }

    func testOwnedGameplayExposesValuePackEditors() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-reset-library", "--relay-autoplay-fixture",
            "--relay-fixture", "relay-sram-counter", "--relay-pro-test", "owned",
            "--relay-sync-off", "-AppleLanguages", "(en)",
        ]
        app.launch()

        let player = app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 60))
        pauseGameplay(in: app, player: player)

        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Quick Save"].exists)
        XCTAssertTrue(app.buttons["Saves"].exists)
        XCTAssertFalse(app.buttons["relay.proFeature.touchLayoutEditing"].exists)
        XCTAssertFalse(app.buttons["relay.proFeature.advancedControllerMapping"].exists)
        XCTAssertTrue(app.buttons["relay.proFeature.cheats"].exists)
        XCTAssertFalse(app.buttons["relay.proFeature.advancedDisplay"].exists)
        capture("iphone-pro-value-pack-pause")

        openDisclosure("speed", in: app)
        app.buttons["relay.pause.speedPicker"].tap()
        XCTAssertTrue(app.buttons["0.5×"].waitForExistence(timeout: 10))
        app.buttons["0.5×"].tap()
        openDisclosure("rewind", in: app)
        app.buttons["relay.pause.rewindPicker"].tap()
        XCTAssertTrue(app.buttons["1 minute"].waitForExistence(timeout: 10))
        app.buttons["1 minute"].tap()
        openDisclosure("controller", in: app)
        let touchEditor = app.buttons["relay.proFeature.touchLayoutEditing"]
        XCTAssertTrue(touchEditor.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["relay.proFeature.advancedControllerMapping"].exists)
        scrollToHittable(touchEditor, in: app)
        XCTAssertGreaterThanOrEqual(touchEditor.frame.height, 44, "The tool label must own a full-size hit target")
        touchEditor.tap()
        XCTAssertTrue(app.descendants(matching: .any)["relay.touchLayoutEditor"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Resume"].exists, "Pause must leave accessibility while its tool is open")
        XCTAssertTrue(app.buttons["Reset"].exists)
        XCTAssertTrue(app.buttons["Save Layout"].exists)
        capture("iphone-pro-touch-layout")
    }

    func testOwnedGameplayOpensControllerCheatAndDisplayEditors() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-reset-library", "--relay-autoplay-fixture",
            "--relay-fixture", "relay-sram-counter", "--relay-pro-test", "owned",
            "--relay-sync-off", "-AppleLanguages", "(en)",
        ]
        app.launch()

        let player = app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 60))
        pauseGameplay(in: app, player: player)

        openEditor(feature: "advancedControllerMapping", editor: "relay.controllerMappingEditor", closeButton: "Cancel",
                   screenshot: "iphone-pro-controller-mapping", in: app)
        openEditor(feature: "cheats", editor: "relay.cheatsEditor", closeButton: "Done",
                   screenshot: "iphone-pro-cheats", in: app)
        openEditor(feature: "advancedDisplay", editor: "relay.advancedDisplayEditor", closeButton: "Cancel",
                   screenshot: "iphone-pro-advanced-display", in: app)
    }

    func testFrenchSurfaceHasBothOffersAndFreeICloudCopy() {
        let app = launch(scenario: "free", language: "fr")
        XCTAssertTrue(app.staticTexts["Jouer sur Mac"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["relayPro.purchase.once"].exists)
        XCTAssertTrue(app.buttons["relayPro.purchase.monthly"].exists)
        XCTAssertTrue(app.staticTexts["Recommandé"].exists)
        XCTAssertTrue(app.staticTexts["Les 12 systèmes sont gratuits sur iPhone, iPad et Apple TV. Ta bibliothèque, tes sauvegardes et la synchronisation iCloud restent gratuites sur tous tes appareils."].exists)
        capture("iphone-relay-pro-fr")
    }

    func testAccessibilitySettingsKeepBothOffersAndRestoreReachable() {
        let app = launch(
            scenario: "free",
            additionalArguments: ["--relay-accessibility-evidence"],
            initialScreen: "settings"
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        // Read the actual environment before a Pro presentation can hide the
        // root probe. The runner configures the real simulator/device settings.
        let probe = app.descendants(matching: .any)
            .matching(identifier: "relay.debug.accessibilityEnvironment").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "The DEBUG environment probe is required")
        let actualAX5 = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "dynamicType=accessibility5;"), object: probe
        )
        let observed = XCTWaiter.wait(for: [actualAX5], timeout: 10)
        let environment = probe.value as? String ?? ""
        let measured = XCTAttachment(string: environment)
        measured.name = "relay-pro-measured-launch-accessibility-environment"
        measured.lifetime = .keepAlways
        add(measured)
        capture("relay-pro-launch-accessibility-environment")
        XCTAssertEqual(observed, .completed, "Actual AX5 is required; configure the simulator/device text size. Observed: \(environment)")
        XCTAssertTrue(environment.contains("systemContentSize=UICTContentSizeCategoryAccessibilityXXXL"),
                      "UIKit must also report the actual largest accessibility category: \(environment)")
        probe.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "Remove the DEBUG readout before measuring the product viewport")

        let settings = app.navigationBars["Settings"].firstMatch
        if !settings.waitForExistence(timeout: 2) {
            let openSettings = app.buttons["Settings"].firstMatch
            XCTAssertTrue(openSettings.waitForExistence(timeout: 20))
            openSettings.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let openPro = app.buttons["settings.relayPro"]
        XCTAssertTrue(openPro.waitForExistence(timeout: 10))
        scrollToHittable(openPro, in: app)
        XCTAssertTrue(openPro.isHittable)
        openPro.tap()

        let once = app.buttons["relayPro.purchase.once"]
        let monthly = app.buttons["relayPro.purchase.monthly"]
        let restore = app.buttons["relayPro.restore"]

        XCTAssertTrue(once.waitForExistence(timeout: 20))
        XCTAssertTrue(monthly.exists)
        XCTAssertTrue(restore.exists)
        XCTAssertFalse(once.label.isEmpty)
        XCTAssertFalse(monthly.label.isEmpty)
        XCTAssertNotNil(once.label.rangeOfCharacter(from: .decimalDigits), "Once must expose its price")
        XCTAssertNotNil(monthly.label.rangeOfCharacter(from: .decimalDigits), "Monthly must expose its price")

        let scroll = app.scrollViews.containing(.button, identifier: "relayPro.purchase.once").firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), "The product Pro scroll view is required")
        for (name, control) in [("once", once), ("monthly", monthly), ("restore", restore)] {
            let reachable = revealProControlFully(control, in: scroll, app: app)
            let visible = proVisibleContentFrame(in: scroll, app: app)
            let geometry = XCTAttachment(string:
                "Measured launch environment: \(environment)\n" +
                "Target: \(control.identifier)\nLabel: \(control.label)\n" +
                "Control frame: \(control.frame)\nVisible content frame: \(visible)\n" +
                "Hittable: \(control.isHittable)\n" + app.debugDescription)
            geometry.name = "relay-pro-ax5-\(name)-geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
            capture("relay-pro-ax5-\(name)-visible")
            XCTAssertTrue(reachable, "The complete \(name) control must be visible and hittable")
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThan(control.frame.width, 0)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44 - 1e-9)
            XCTAssertTrue(visible.insetBy(dx: -1e-9, dy: -1e-9).contains(control.frame),
                          "The complete \(name) frame must remain below chrome and inside the viewport")
        }
    }

    private func revealProControlFully(_ control: XCUIElement, in scroll: XCUIElement,
                                       app: XCUIApplication) -> Bool {
        for _ in 0..<24 {
            let visible = proVisibleContentFrame(in: scroll, app: app)
            if control.exists && control.isHittable &&
                visible.insetBy(dx: -1e-9, dy: -1e-9).contains(control.frame) { return true }
            // A controlled native swipe avoids flinging past an entire AX5
            // offer and oscillating around it while only an edge is hittable.
            let downward = control.exists && control.frame.minY < visible.minY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.35 : 0.75))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.75 : 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let visible = proVisibleContentFrame(in: scroll, app: app)
        return control.exists && control.isHittable &&
            visible.insetBy(dx: -1e-9, dy: -1e-9).contains(control.frame)
    }

    private func proVisibleContentFrame(in scroll: XCUIElement, app: XCUIApplication) -> CGRect {
        var visible = scroll.frame.intersection(app.frame)
        if let navigation = app.navigationBars.allElementsBoundByIndex.last, navigation.exists {
            let top = max(visible.minY, navigation.frame.maxY)
            visible = CGRect(x: visible.minX, y: top, width: visible.width,
                             height: max(0, visible.maxY - top))
        }
        for tabBar in app.tabBars.allElementsBoundByIndex where tabBar.exists && tabBar.isHittable {
            if visible.intersects(tabBar.frame) && tabBar.frame.minY > visible.midY {
                visible.size.height = max(0, tabBar.frame.minY - visible.minY)
            }
        }
        return visible
    }

    private func launch(
        scenario: String,
        language: String = "en",
        additionalArguments: [String] = [],
        initialScreen: String = "pro"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-reset-library", "--relay-screen", initialScreen,
            "--relay-pro-test", scenario, "--relay-sync-off",
            "-AppleLanguages", "(\(language))",
        ] + additionalArguments
        app.launch()
        return app
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

    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 where !element.isHittable { app.swipeUp() }
    }

    private func openEditor(
        feature: String,
        editor: String,
        closeButton: String,
        screenshot: String,
        in app: XCUIApplication
    ) {
        let button = app.buttons["relay.proFeature.\(feature)"]
        if !button.exists {
            let group = feature == "advancedDisplay" ? "display" : "controller"
            openDisclosure(group, in: app)
        }
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        scrollToHittable(button, in: app)
        // Fractional simulator transforms can put an exact 44-point target a
        // few floating-point units below 44. Keep the threshold within a millionth of a point.
        XCTAssertGreaterThanOrEqual(button.frame.height + 0.000_001, 44, "The tool label must own a full-size hit target")
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)[editor].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Resume"].exists, "Only the selected tool should remain in accessibility")
        capture(screenshot)
        let close = app.buttons[closeButton]
        scrollToHittable(close, in: app)
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Resume"].exists)
    }

    private func openDisclosure(_ name: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any).matching(identifier: "relay.pause.\(name)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        scrollToHittable(row, in: app)
        XCTAssertTrue(row.isHittable)
        row.tap()
    }

    /// The production pause button fades after a few idle seconds. Physical
    /// devices can spend long enough attaching the automation runner for that
    /// to happen before the first assertion, so reveal the chrome from the
    /// picture area just as a user would before tapping Pause.
    private func pauseGameplay(in app: XCUIApplication, player: XCUIElement) {
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        if !pause.isHittable {
            player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
        XCTAssertTrue(pause.isHittable)
        pause.tap()
    }
}

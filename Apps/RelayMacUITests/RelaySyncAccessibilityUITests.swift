// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AppKit
import ApplicationServices

@MainActor
final class RelaySyncAccessibilityUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Practical dismissal, independent of whether Done starts above the fold.
    /// Native pointer/keyboard input only; no purchase or account action is used.
    func testLocalizedProPointerAndEscapeAtPracticalMinimumSize() throws {
        try qualifyLocalizedProDismissal(methods: ["click", "escape"])
    }

    func testLocalizedProKeyboardAtPracticalMinimumSize() throws {
        try qualifyLocalizedProDismissal(methods: ["tab", "shift-tab"])
    }

    private func qualifyLocalizedProDismissal(methods: [String]) throws {
        for locale in ["fr", "de"] {
          for method in methods {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                "--relay-skins-share-qualification", "--relay-screen", "pro",
                "--relay-sync-off", "--relay-pro-test", "free",
                "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(\(locale))"]
            app.launch()
            defer { app.terminate() }
            app.activate()
            if !app.windows.firstMatch.waitForExistence(timeout: 3) {
                let bundle = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("RelayMac.app")
                XCTAssertTrue(NSWorkspace.shared.open(bundle))
            }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 20))
            // Exercise the real modal Pro action, not Settings' pushed Pro page.
            // Use the observed parent window edges to constrain the presentation.
            let right = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -1, dy: 0))
            let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 719, dy: 0))
            right.press(forDuration: 0.1, thenDragTo: left)
            let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
                .withOffset(CGVector(dx: 0, dy: -1))
            let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 559))
            bottom.press(forDuration: 0.1, thenDragTo: top)
            XCTAssertLessThanOrEqual(window.frame.width, 740, "Exercise the actual minimum-size window")
            XCTAssertLessThanOrEqual(window.frame.height, 612,
                                     "The observed native minimum is 560-point content plus 52-point window chrome")

                let close = app.buttons["relayPro.dismiss"]
                XCTAssertTrue(close.waitForExistence(timeout: 10))
                XCTAssertEqual(app.sheets.count, 1)
                capture(app, "rc-mac-pro-\(locale)-\(method)-initial")
                if method == "click" {
                    let scroll = app.sheets.firstMatch.scrollViews.firstMatch
                    XCTAssertTrue(scroll.waitForExistence(timeout: 5))
                    // Inspect both ends. Initial non-visibility is not itself a failure.
                    for delta in [CGFloat(-300), CGFloat(300)] {
                        for _ in 0..<8 where !close.isHittable {
                            scroll.scroll(byDeltaX: 0, deltaY: delta)
                        }
                    }
                    XCTAssertTrue(close.isHittable, "Done must be reachable by scrolling")
                    capture(app, "rc-mac-pro-\(locale)-done-reached")
                    close.click()
                } else if method == "escape" {
                    app.typeKey(.escape, modifierFlags: [])
                } else {
                    XCTAssertTrue(NSApplication.shared.isFullKeyboardAccessEnabled,
                                  "Enable actual Keyboard navigation before this native regression")
                    focusLocalizedDismissalByTab(close, in: app, reverse: method == "shift-tab")
                    XCTAssertTrue(close.isHittable, "The focused dismissal must become visible")
                    capture(app, "rc-mac-pro-\(locale)-\(method)-focused")
                    app.typeKey(" ", modifierFlags: [])
                }
                XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
                XCTAssertTrue(app.windows.firstMatch.isHittable, "Dismissal must return to the main window")
          }
        }
    }

    /// XCTest already observes native focus for its authorized UI session.
    /// Retain the measured attributes and a visible focus-ring screenshot;
    /// no separate cross-process Accessibility permission is needed here.
    /// The older full-loop AX regressions below retain their own prerequisites.
    private func focusLocalizedDismissalByTab(_ close: XCUIElement, in app: XCUIApplication,
                                             reverse: Bool) {
        var trace = ["Input: \(reverse ? "Shift+Tab" : "Tab"); target: relayPro.dismiss"]
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "rc-mac-pro-native-keyboard-focus"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for step in 1...48 {
            app.typeKey(.tab, modifierFlags: reverse ? [.shift] : [])
            // Inspect only this button's native attributes, never a focused
            // ancestor or an unrelated descendant in the application tree.
            let attributes = close.debugDescription.components(separatedBy: "\n").first ?? ""
            trace.append("Step \(step): \(attributes)")
            XCTAssertTrue(attributes.hasPrefix("Attributes: Button"),
                          "Keep the focus reader bound to the actual native dismissal button")
            if attributes.contains("Keyboard Focused") { return }
        }
        XCTFail("Native dismissal did not receive keyboard focus after 48 Tab inputs")
    }

    func testProSheetCanCloseWithDoneAndEscape() {
        for useEscape in [false, true] {
            let app = launchPro(scenario: "free")
            let close = app.buttons["relayPro.dismiss"]
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            XCTAssertTrue(close.isHittable, "Dismissal must stay visible above scrolling content")
            capture(app, "relay-pro-free-dismissal")
            if useEscape { app.typeKey(.escape, modifierFlags: []) } else { close.click() }
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    func testOwnedProCanReturnFromMembershipAndClose() {
        let app = launchPro(scenario: "owned")
        let close = app.buttons["relayPro.dismiss"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["relayPro.purchase.once"].exists)
        let memberships = app.buttons["relayPro.memberships"]
        XCTAssertTrue(memberships.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        memberships.click()
        let membership = element("relayMembership.screen", in: app)
        XCTAssertTrue(membership.waitForExistence(timeout: 10))
        XCTAssertEqual(app.sheets.count, 1, "Membership must use the existing Pro navigation stack")
        XCTAssertFalse(app.buttons["relayMembership.dismiss"].exists)
        // Description: Back; identifier: chevron.backward.
        let back = app.buttons["chevron.backward"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
        capture(app, "relay-pro-owned-membership-navigation")
        back.click()
        XCTAssertTrue(membership.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        XCTAssertTrue(close.isHittable, "Back must return to the dismissible Pro surface")
        capture(app, "relay-pro-owned-after-membership-back")
        close.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        app.terminate()
    }

    func testKeyboardFocusRevealsOffscreenProControlsInBothDirections() throws {
        let app = launchKeyboardScrollQualification(screen: "pro")
        defer { app.terminate() }
        let accessibilityApp = try keyboardApplication(for: app)
        try constrainKeyboardWindow(in: app, accessibilityApp: accessibilityApp)
        let scroll = app.sheets.firstMatch.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertLessThan(scroll.frame.width, 760, "Qualify the compact Pro layout")
        let order = ["relayPro.purchase.once", "relayPro.purchase.monthly", "relayPro.memberships",
                     "relayPro.restore", "relayPro.terms", "relayPro.privacy"]
        for identifier in order {
            let target = element(identifier, in: app)
            XCTAssertTrue(target.waitForExistence(timeout: 10) && target.isEnabled, identifier)
        }
        focusByTab(identifier: "relayPro.dismiss", in: app, accessibilityApp: accessibilityApp)
        scroll.scroll(byDeltaX: 0, deltaY: 2_000)
        XCTAssertFalse(scroll.frame.intersects(element(order[0], in: app).frame),
                       "The regression requires a purchase control initially outside the viewport")
        capture(app, "relay-pro-keyboard-before-forward")
        // Qualify the complete exact loop, not just the first visible control.
        // No purchase, restore, external link or account action is activated.
        for identifier in order {
            tab(to: identifier, in: app, accessibilityApp: accessibilityApp)
            assertKeyboardTargetVisible(element(identifier, in: app), in: scroll)
            capture(app, "relay-pro-keyboard-forward-" + identifier)
        }
        tab(to: "relayPro.dismiss", in: app, accessibilityApp: accessibilityApp)
        XCTAssertTrue(app.buttons["relayPro.dismiss"].isHittable)
        for identifier in order.reversed() {
            tab(to: identifier, in: app, accessibilityApp: accessibilityApp, reverse: true)
            assertKeyboardTargetVisible(element(identifier, in: app), in: scroll)
            capture(app, "relay-pro-keyboard-reverse-" + identifier)
        }
        tab(to: "relayPro.dismiss", in: app, accessibilityApp: accessibilityApp, reverse: true)
        XCTAssertTrue(app.buttons["relayPro.dismiss"].isHittable)
    }

    func testKeyboardFocusScrollsLongContentAndSpaceActivatesExistingButton() throws {
        let app = launchKeyboardScrollQualification(screen: "layout")
        defer { app.terminate() }
        XCTAssertTrue(element("layout.fixture.marker", in: app).waitForExistence(timeout: 20))
        let accessibilityApp = try keyboardApplication(for: app)
        try constrainKeyboardWindow(in: app, accessibilityApp: accessibilityApp)
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let shelf = app.scrollViews["layout.fixture.shelf"]
        XCTAssertTrue(shelf.exists)
        XCTAssertFalse(shelf.frame.contains(app.buttons["layout.fixture.card.3"].frame),
                       "The fourth card must begin outside the horizontal viewport")
        let primary = app.buttons["layout.fixture.primary"]
        focusByTab(identifier: "layout.fixture.title", in: app, accessibilityApp: accessibilityApp)
        scroll.scroll(byDeltaX: 0, deltaY: 2_000)
        XCTAssertFalse(scroll.frame.intersects(primary.frame), "The fixture must begin with its lower action offscreen")
        capture(app, "relay-layout-keyboard-before-forward")
        let cards = (0..<4).map { "layout.fixture.card.\($0)" }
        let forward = ["layout.fixture.continue"] + cards + ["layout.fixture.primary", "layout.fixture.secondary"]
        for identifier in forward {
            tab(to: identifier, in: app, accessibilityApp: accessibilityApp)
            assertKeyboardTargetVisible(element(identifier, in: app), in: scroll)
            if cards.contains(identifier) {
                assertKeyboardTargetVisible(element(identifier, in: app), in: shelf)
            }
            capture(app, "relay-layout-keyboard-forward-" + identifier)
        }
        tab(to: "layout.fixture.primary", in: app, accessibilityApp: accessibilityApp, reverse: true)
        assertKeyboardTargetVisible(primary, in: scroll)
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(element("layout.fixture.feedback", in: app).label, "Actions reached: 1",
                       "Space must activate the existing button exactly once")

        let backward = Array(cards.reversed()) + ["layout.fixture.continue", "layout.fixture.title"]
        for identifier in backward {
            tab(to: identifier, in: app, accessibilityApp: accessibilityApp, reverse: true)
            assertKeyboardTargetVisible(element(identifier, in: app), in: scroll)
            if cards.contains(identifier) {
                assertKeyboardTargetVisible(element(identifier, in: app), in: shelf)
            }
            capture(app, "relay-layout-keyboard-reverse-" + identifier)
        }
    }

    private func tab(to identifier: String, in app: XCUIApplication, accessibilityApp: AXUIElement,
                     reverse: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey(.tab, modifierFlags: reverse ? [.shift] : [])
        let path = keyboardFocusPath(in: accessibilityApp)
        let trace = XCTAttachment(string: "Input: \(reverse ? "Shift+Tab" : "Tab"); expected: \(identifier)\nActual: \(path)")
        trace.name = "relay-mac-keyboard-" + (reverse ? "reverse-" : "forward-") + identifier
        trace.lifetime = .keepAlways
        add(trace)
        XCTAssertTrue(path.contains { $0.identifier == identifier },
                      "Native Tab order must reach \(identifier) in one step; actual path: \(path)", file: file, line: line)
    }

    private func launchKeyboardScrollQualification(screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-accessibility-evidence", "--relay-sync-off", "--relay-pro-test", "free",
            "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR",
        ]
        app.launchArguments += screen == "layout" ? ["--relay-layout-fixture"] : ["--relay-screen", screen]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }

    private func keyboardApplication(for app: XCUIApplication) throws -> AXUIElement {
        // This reads the actual shared macOS Keyboard navigation setting. It
        // does not stand in for the separately named Full Keyboard Access mode.
        XCTAssertTrue(NSApplication.shared.isFullKeyboardAccessEnabled,
                      "Enable actual Keyboard navigation before this native regression")
        XCTAssertTrue(AXIsProcessTrusted(), "The UI test runner needs Accessibility permission to observe focus and constrain the native window")
        app.activate()
        let running = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertEqual(running.bundleIdentifier, "app.relayemu.relay")
        return AXUIElementCreateApplication(running.processIdentifier)
    }

    private func constrainKeyboardWindow(in app: XCUIApplication, accessibilityApp: AXUIElement) throws {
        let window = try XCTUnwrap(axElement(accessibilityApp, attribute: kAXFocusedWindowAttribute as CFString))
        var size = CGSize(width: 720, height: 612)
        let value = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        XCTAssertEqual(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value), .success)
        // Record actual geometry; launch arguments do not stand in for a real
        // constrained window. The product's minimum size remains authoritative.
        XCTAssertLessThan(app.windows.firstMatch.frame.width, 760)
    }

    private func assertKeyboardTargetVisible(_ target: XCUIElement, in scroll: XCUIElement,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(target.isHittable, "Focused control must be hittable", file: file, line: line)
        XCTAssertGreaterThan(target.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(target.frame.height, 0, file: file, line: line)
        XCTAssertTrue(scroll.frame.insetBy(dx: -1, dy: -1).contains(target.frame),
                      "Focused control \(target.frame) must fit its viewport \(scroll.frame)", file: file, line: line)
    }

    private func launchPro(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-screen", "pro", "--relay-sync-off", "--relay-pro-test", scenario,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state == .runningForeground { capture(app, "relay-sync-final-state") }
        super.tearDown()
    }

    func testSignedOutSettingsAndNativeProviderKeyboardDismissal() throws {
        let app = launch()
        let provider = element("settings.syncProvider", in: app)
        reveal(provider, in: app)
        XCTAssertTrue(provider.label.contains("Sync with"))
        provider.click()
        XCTAssertTrue(app.menuItems["Relay Sync"].waitForExistence(timeout: 5))
        capture(app, "relay-sync-mac-native-picker")
        try app.performAccessibilityAudit()
        // Select the known item, then verify native keyboard dismissal.
        // This is not a claim of Full Keyboard Access traversal.
        app.menuItems["Relay Sync"].click()
        provider.click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.menuItems["Relay Sync"].exists)

        openLiveAccount(in: app)
        let connection = element("settings.relayAccount.connection", in: app)
        reveal(connection, in: app)
        XCTAssertEqual(connection.label, "Relay Account")
        XCTAssertEqual(connection.value as? String, "Not connected")
        let signIn = app.buttons["settings.relayAccount.signIn"]
        reveal(signIn, in: app)
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertTrue(signIn.label.localizedCaseInsensitiveContains("Sign in with Apple"))
        capture(app, "relay-sync-mac-signed-out")
        try app.performAccessibilityAudit()
    }

    func testEffectiveIncreasedContrastAndReduceMotionSettings() throws {
        let app = launch()
        let probe = element("relay.debug.accessibilityEnvironment", in: app)
        XCTAssertTrue(probe.waitForExistence(timeout: 20))
        let value = probe.value as? String ?? ""
        // These are actual SwiftUI/AppKit observations. Configure the host's
        // accessibility preferences before this test; arguments cannot prove it.
        XCTAssertTrue(value.contains("contrast=increased"), value)
        XCTAssertTrue(value.contains("reduceMotion=true"), value)
        XCTAssertTrue(value.contains("systemReduceMotion=true"), value)
        XCTAssertTrue(value.contains("systemIncreaseContrast=true"), value)
        capture(app, "relay-sync-mac-effective-accessibility-environment")
        openLiveAccount(in: app)
        reveal(app.buttons["settings.relayAccount.signIn"], in: app)
        capture(app, "relay-sync-mac-contrast-motion-account")
        try app.performAccessibilityAudit()
    }

    /// Requires actual Keyboard > Keyboard navigation and Accessibility trust
    /// for this UI test runner. AppKit's isFullKeyboardAccessEnabled measures
    /// Keyboard navigation, not the separately named accessibility feature.
    /// Neither setting is changed or inferred from launch arguments here.
    func testKeyboardTabAndShiftTabReachSignOutAndSpaceCancelsDialog() throws {
        let app = launch(fixture: "active")
        let probe = element("relay.debug.accessibilityEnvironment", in: app)
        XCTAssertTrue(probe.waitForExistence(timeout: 20))
        XCTAssertTrue((probe.value as? String ?? "").contains("systemKeyboardNavigation=true"),
                      "Enable actual Keyboard navigation before the Mac keyboard qualification")
        guard AXIsProcessTrusted() else {
            XCTFail("The Mac UI test runner requires Accessibility permission to read actual keyboard focus")
            return
        }
        app.activate()
        let running = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertEqual(running.bundleIdentifier, "app.relayemu.relay")
        let accessibilityApp = AXUIElementCreateApplication(running.processIdentifier)

        focusByTab(identifier: "settings.relayAccount.signOut", in: app, accessibilityApp: accessibilityApp)
        capture(app, "relay-sync-mac-keyboard-sign-out-focused")
        focusByTab(identifier: "settings.relayAccount.refresh", in: app,
                   accessibilityApp: accessibilityApp, reverse: true)
        capture(app, "relay-sync-mac-keyboard-shift-tab-refresh-focused")
        focusByTab(identifier: "settings.relayAccount.signOut", in: app, accessibilityApp: accessibilityApp)
        app.typeKey(" ", modifierFlags: [])
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Space must open the native sign-out confirmation")
        focusByTab(title: "Cancel", in: app, accessibilityApp: accessibilityApp)
        capture(app, "relay-sync-mac-keyboard-cancel-focused")
        app.typeKey(" ", modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancel)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        capture(app, "relay-sync-mac-keyboard-dialog-cancelled")
    }

    func testActivePresentationAndKeyboardDismissalOfSignOut() throws {
        try qualifyFixture("active")
    }

    func testRecoveryPresentationAndDisabledUploads() throws {
        try qualifyFixture("recovery")
    }

    func testPurgedPresentationAndLocalProgressCopy() throws {
        try qualifyFixture("purged")
    }

    func testErrorPresentationAndRetry() throws {
        try qualifyFixture("error")
    }

    func testConflictChoicesAndTransferProgressExposeCompleteLabels() throws {
        let app = launch(fixture: "conflict")
        XCTAssertTrue(element("relay.debug.fixture", in: app).waitForExistence(timeout: 20))
        let first = app.buttons["sync.conflict.keep.11111111-1111-4111-8111-111111111111"]
        reveal(first, in: app)
        let firstLabel = first.label
        XCTAssertTrue(firstLabel.contains("Keep version 1"), firstLabel)
        XCTAssertTrue(firstLabel.contains("iPhone"), firstLabel)
        XCTAssertTrue(firstLabel.contains("saved"), firstLabel)
        capture(app, "relay-sync-conflict-first-choice")
        try app.performAccessibilityAudit()

        let second = app.buttons["sync.conflict.keep.22222222-2222-4222-8222-222222222222"]
        reveal(second, in: app)
        let secondLabel = second.label
        XCTAssertTrue(secondLabel.contains("Keep version 2"), secondLabel)
        XCTAssertTrue(secondLabel.contains("Mac"), secondLabel)
        XCTAssertTrue(secondLabel.contains("saved"), secondLabel)
        XCTAssertNotEqual(firstLabel, secondLabel)
        capture(app, "relay-sync-conflict-second-choice")
        try app.performAccessibilityAudit()
        app.terminate()

        let transferApp = launch(fixture: "transfer")
        let transfer = transferApp.buttons["relay.debug.transfer"]
        reveal(transfer, in: transferApp)
        XCTAssertTrue(transfer.label.contains("Downloading"), transfer.label)
        XCTAssertTrue(transfer.label.contains("42"), transfer.label)
        capture(transferApp, "relay-sync-transfer-progress")
        try transferApp.performAccessibilityAudit()
        transferApp.terminate()
    }

    private func qualifyFixture(_ scenario: String) throws {
        let app = launch(fixture: scenario)
        XCTAssertTrue(element("relay.debug.fixture", in: app).waitForExistence(timeout: 20))
        capture(app, "relay-sync-mac-fixture-\(scenario)-marker")
        let vault = element("settings.relayAccount.vault", in: app)
        if scenario == "active" || scenario == "error" {
            let connection = element("settings.relayAccount.connection", in: app)
            reveal(connection, in: app)
            XCTAssertEqual(connection.value as? String, "Connected")
            let plan = element("settings.relayAccount.plan", in: app)
            reveal(plan, in: app)
            XCTAssertTrue((plan.label + " " + String(describing: plan.value ?? "")).contains("Relay Sync"))
            XCTAssertFalse(vault.exists, "Healthy storage should not repeat the account state")
        } else {
            reveal(vault, in: app)
            let expected = scenario == "recovery" ? "Download your files" : "Online storage removed"
            XCTAssertTrue((vault.label + " " + String(describing: vault.value ?? "")).contains(expected))
        }
        capture(app, "relay-sync-mac-fixture-\(scenario)-account")
        try app.performAccessibilityAudit()
        if scenario == "recovery" || scenario == "purged" {
            reveal(element("settings.relayAccount.recovery", in: app), in: app)
            if scenario == "recovery" {
                reveal(element("settings.relayAccount.recoveryEnds", in: app), in: app)
            }
            capture(app, "relay-sync-mac-fixture-\(scenario)-lifecycle")
            try app.performAccessibilityAudit()
        }
        let uploads = element("settings.relayGameFileSync", in: app)
        reveal(uploads, in: app)
        XCTAssertEqual(uploads.isEnabled, scenario == "active" || scenario == "error")
        if scenario == "error" {
            let retry = app.buttons["settings.relayAccount.retrySync"]
            reveal(retry, in: app)
            XCTAssertTrue(retry.isEnabled)
            let error = element("settings.relayAccount.error", in: app)
            reveal(error, in: app)
            XCTAssertTrue(error.label.contains("local progress is safe"))
        }
        capture(app, "relay-sync-mac-fixture-\(scenario)-controls")
        try app.performAccessibilityAudit()
        if scenario == "active" {
            let signOut = app.buttons["settings.relayAccount.signOut"]
            reveal(signOut, in: app)
            signOut.click()
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
            capture(app, "relay-sync-mac-fixture-sign-out-dialog")
            try app.performAccessibilityAudit()
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertFalse(app.buttons["Cancel"].exists)
            XCTAssertTrue(signOut.exists)
        }
        app.terminate()
    }

    /// Live Settings navigates into the account; immutable account fixtures
    /// continue to render the product section directly.
    private func openLiveAccount(in app: XCUIApplication) {
        let account = element("settings.relayAccount.open", in: app)
        reveal(account, in: app)
        XCTAssertTrue(account.isEnabled)
        XCTAssertFalse(account.label.isEmpty)
        account.click()
        XCTAssertTrue(element("settings.relayAccount.connection", in: app).waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(app.sheets.count, 1, "Account navigation must not add a sheet")
    }

    private func launch(fixture: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-accessibility-evidence", "--relay-screen", "settings", "--relay-sync-off",
            "--relay-pro-test", "free",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        if let fixture { app.launchArguments += ["--relay-accessibility-fixture", fixture] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func focusByTab(identifier: String? = nil, title: String? = nil,
                            in app: XCUIApplication, accessibilityApp: AXUIElement, reverse: Bool = false,
                            file: StaticString = #filePath, line: UInt = #line) {
        var trace = ["Input: \(reverse ? "Shift+Tab" : "Tab"); target: \(identifier ?? title ?? "unspecified")"]
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "relay-sync-mac-keyboard-focus-trace"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for step in 0..<48 {
            let path = keyboardFocusPath(in: accessibilityApp)
            trace.append("Step \(step): \(path)")
            if path.contains(where: { node in
                if let identifier { return node.identifier == identifier }
                return node.role == "AXButton" && node.title == title
            }) { return }
            app.typeKey(.tab, modifierFlags: reverse ? [.shift] : [])
        }
        capture(app, "relay-sync-mac-keyboard-focus-failure")
        XCTFail("Native keyboard focus did not reach the requested control after 48 Tab inputs", file: file, line: line)
    }

    /// A native control may place keyboard focus on a child. Follow its actual
    /// AX parents, bounded to six nodes, retaining the measured path as evidence.
    private func keyboardFocusPath(in application: AXUIElement) -> [(identifier: String, title: String, role: String)] {
        var current = axElement(application, attribute: kAXFocusedUIElementAttribute as CFString)
        var result: [(identifier: String, title: String, role: String)] = []
        for _ in 0..<6 {
            guard let node = current else { break }
            let title = axString(node, attribute: kAXTitleAttribute as CFString)
            result.append((
                axString(node, attribute: kAXIdentifierAttribute as CFString),
                title.isEmpty ? axString(node, attribute: kAXDescriptionAttribute as CFString) : title,
                axString(node, attribute: kAXRoleAttribute as CFString)
            ))
            current = axElement(node, attribute: kAXParentAttribute as CFString)
        }
        return result
    }

    private func axElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func axString(_ element: AXUIElement, attribute: CFString) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private func reveal(_ target: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<16 where !target.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250) }
        XCTAssertTrue(target.waitForExistence(timeout: 5), target.identifier, file: file, line: line)
        XCTAssertTrue(target.isHittable, target.identifier, file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

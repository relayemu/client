// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Uses Siri Remote input and actual focus readback. The isolated library also
/// creates an isolated installation-scoped Keychain account; no sign-out/reset
/// is necessary. Native Sign in with Apple is inspected without authenticating.
@MainActor
final class RelaySyncAccessibilityUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state == .runningForeground { capture(app, "relay-sync-final-state") }
        super.tearDown()
    }

    func testRemoteFocusReachesProviderAndNativeAppleSignIn() throws {
        let app = launch()
        let provider = app.segmentedControls["settings.syncProvider"]
        let off = provider.buttons["Off"].firstMatch
        focus(off, in: app, direction: .down)
        XCTAssertTrue(off.hasFocus)
        XCTAssertEqual(off.label, "Off")
        capture(app, "relay-sync-tv-provider-focused")
        try audit(app)

        // An audit may move focus to an unrelated Settings row. Re-establish
        // the vertical anchor before navigating within the native segment.
        focus(off, in: app, direction: .down)
        let relay = provider.buttons["Relay Sync"].firstMatch
        XCTAssertTrue(relay.waitForExistence(timeout: 5))
        focus(relay, in: app, direction: .right)
        capture(app, "relay-sync-tv-native-picker-focused")
        XCUIRemote.shared.press(.select)
        let selectedRelay = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: relay)
        XCTAssertEqual(XCTWaiter.wait(for: [selectedRelay], timeout: 5), .completed)
        try audit(app)

        openLiveAccount(in: app)
        let signIn = app.buttons["settings.relayAccount.signIn"]
        focus(signIn, in: app, direction: .down)
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertTrue(signIn.label.localizedCaseInsensitiveContains("Sign in with Apple"))
        let connection = element("settings.relayAccount.connection", in: app)
        XCTAssertEqual(connection.label, "Relay Account")
        XCTAssertEqual(connection.value as? String, "Not connected")
        capture(app, "relay-sync-tv-native-apple-focused")
        try audit(app)
        XCTAssertFalse(app.buttons["settings.relayAccount.signOut"].exists)
    }

    func testIncreasedContrastAndReduceMotionKeepRemoteFocusUsable() throws {
        let app = launch(accessibility: true)
        let environment = element("relay.debug.accessibilityEnvironment", in: app)
        XCTAssertTrue(environment.waitForExistence(timeout: 20))
        let value = environment.value as? String ?? ""
        XCTAssertTrue(value.contains("contrast=increased"), value)
        XCTAssertTrue(value.contains("reduceMotion=true"), value)
        XCTAssertTrue(value.contains("systemReduceMotion=true"), value)
        XCTAssertTrue(value.contains("systemDarkerColors=true"), value)
        capture(app, "relay-sync-tv-effective-accessibility-environment")

        let provider = app.segmentedControls["settings.syncProvider"].buttons["Off"].firstMatch
        focus(provider, in: app, direction: .down)
        capture(app, "relay-sync-tv-provider-contrast-motion")
        try audit(app)
        openLiveAccount(in: app)
        let signIn = app.buttons["settings.relayAccount.signIn"]
        focus(signIn, in: app, direction: .down)
        XCTAssertTrue(signIn.isEnabled)
        capture(app, "relay-sync-tv-apple-contrast-motion")
        try audit(app)
    }

    func testActiveFixtureRemoteFocusAndSignOutDialog() throws {
        try qualifyFixture("active")
    }

    func testRecoveryFixtureRemoteFocusAndPausedUploads() throws {
        try qualifyFixture("recovery")
    }

    func testPurgedFixtureRemoteFocusAndLocalProgressCopy() throws {
        try qualifyFixture("purged")
    }

    func testErrorFixtureRemoteFocusReachesRetry() throws {
        try qualifyFixture("error")
    }

    func testConflictChoicesAndTransferProgressExposeCompleteLabels() throws {
        let app = launch(fixture: "conflict")
        XCTAssertTrue(element("relay.debug.fixture", in: app).waitForExistence(timeout: 20))
        let first = app.buttons["sync.conflict.keep.11111111-1111-4111-8111-111111111111"]
        focus(first, in: app, direction: .down)
        let firstLabel = first.label
        XCTAssertTrue(firstLabel.contains("Keep version 1"), firstLabel)
        XCTAssertTrue(firstLabel.contains("iPhone"), firstLabel)
        XCTAssertTrue(firstLabel.contains("saved"), firstLabel)
        capture(app, "relay-sync-conflict-first-choice")
        try audit(app)

        let second = app.buttons["sync.conflict.keep.22222222-2222-4222-8222-222222222222"]
        focus(second, in: app, direction: .right)
        let secondLabel = second.label
        XCTAssertTrue(secondLabel.contains("Keep version 2"), secondLabel)
        XCTAssertTrue(secondLabel.contains("Mac"), secondLabel)
        XCTAssertTrue(secondLabel.contains("saved"), secondLabel)
        XCTAssertNotEqual(firstLabel, secondLabel)
        capture(app, "relay-sync-conflict-second-choice")
        try audit(app)
        app.terminate()

        let transferApp = launch(fixture: "transfer")
        let transfer = transferApp.buttons["relay.debug.transfer"]
        focus(transfer, in: transferApp, direction: .down)
        XCTAssertTrue(transfer.label.contains("Downloading"), transfer.label)
        XCTAssertTrue(transfer.label.contains("42"), transfer.label)
        capture(transferApp, "relay-sync-transfer-progress")
        try audit(transferApp)
        transferApp.terminate()
    }

    private func qualifyFixture(_ scenario: String) throws {
        let app = launch(fixture: scenario)
        XCTAssertTrue(element("relay.debug.fixture", in: app).waitForExistence(timeout: 20))
        capture(app, "relay-sync-tv-fixture-\(scenario)-marker")
        let vault = element("settings.relayAccount.vault", in: app)
        if scenario == "active" || scenario == "error" {
            let connection = element("settings.relayAccount.connection", in: app)
            XCTAssertTrue(connection.waitForExistence(timeout: 10))
            XCTAssertEqual(connection.value as? String, "Connected")
            let plan = element("settings.relayAccount.plan", in: app)
            XCTAssertTrue((plan.label + " " + String(describing: plan.value ?? "")).contains("Relay Sync"))
            XCTAssertFalse(vault.exists, "Healthy storage should not repeat the account state")
        } else {
            let expected = scenario == "recovery" ? "Download your files" : "Online storage removed"
            XCTAssertTrue((vault.label + " " + String(describing: vault.value ?? "")).contains(expected))
        }
        try audit(app)
        let target = app.buttons[scenario == "error" ? "settings.relayAccount.retrySync" : "settings.relayAccount.refresh"]
        focus(target, in: app, direction: .down)
        XCTAssertTrue(target.isEnabled)
        capture(app, "relay-sync-tv-fixture-\(scenario)-focused-action")
        try audit(app)
        if scenario == "active" {
            let signOut = app.buttons["settings.relayAccount.signOut"]
            focus(signOut, in: app, direction: .down)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
            capture(app, "relay-sync-tv-fixture-sign-out-dialog")
            try audit(app)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        }
        app.terminate()
    }

    /// Preserve actual remote traversal through the new live account destination.
    /// Value-only fixtures intentionally bypass live Settings navigation.
    private func openLiveAccount(in app: XCUIApplication) {
        let account = element("settings.relayAccount.open", in: app)
        focus(account, in: app, direction: .down)
        XCTAssertTrue(account.isEnabled)
        XCTAssertFalse(account.label.isEmpty)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(element("settings.relayAccount.connection", in: app).waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(app.sheets.count, 1, "Account navigation must not add a sheet")
    }

    private func launch(accessibility: Bool = false, fixture: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-accessibility-evidence", "--relay-screen", "settings", "--relay-sync-off",
            "--relay-pro-test", "free",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        if let fixture { app.launchArguments += ["--relay-accessibility-fixture", fixture] }
        if accessibility {
            app.launchArguments += [
                "-UIAccessibilityReduceMotionEnabled", "YES",
                "-UIAccessibilityDarkerSystemColorsEnabled", "YES",
            ]
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func focus(_ control: XCUIElement, in app: XCUIApplication,
                       direction: XCUIRemote.Button,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(control.waitForExistence(timeout: 10), "Requested native control is absent", file: file, line: line)
        let identifier = control.identifier
        var path = ["Requested control: \(identifier); label=\(control.label)", "Initial: " + focusedElementDescription(in: app)]
        let reverse: XCUIRemote.Button
        switch direction {
        case .down: reverse = .up
        case .up: reverse = .down
        case .right: reverse = .left
        case .left: reverse = .right
        default:
            recordFocusPath(path)
            XCTFail("Focus search requires a directional remote button", file: file, line: line)
            return
        }
        for searchDirection in [direction, reverse] {
            var previous = focusedElementDescription(in: app)
            var unchanged = 0
            for step in 1...28 {
                let target = nativeFocusTarget(for: control, in: app)
                if target.exists && target.hasFocus {
                    path.append("Reached native focus host: type=\(target.elementType.rawValue); id=\(target.identifier); label=\(target.label); frame=\(target.frame)")
                    recordFocusPath(path)
                    XCTAssertTrue(target.hasFocus, identifier, file: file, line: line)
                    return
                }
                XCUIRemote.shared.press(searchDirection)
                let current = focusedElementDescription(in: app)
                path.append("\(String(describing: searchDirection)) #\(step): \(current)")
                unchanged = current == previous ? unchanged + 1 : 0
                previous = current
                if unchanged >= 3 { break }
            }
        }
        let target = nativeFocusTarget(for: control, in: app)
        // XCTest may interrupt execution at a failure without unwinding Swift
        // defer blocks. Persist the measured path before the final assertion.
        recordFocusPath(path)
        if !target.hasFocus { capture(app, "relay-sync-tv-focus-failure-" + identifier) }
        XCTAssertTrue(control.exists, identifier, file: file, line: line)
        XCTAssertTrue(target.hasFocus, "Native control focus was not reached: " + identifier, file: file, line: line)
    }

    private func recordFocusPath(_ path: [String]) {
        let attachment = XCTAttachment(string: path.joined(separator: "\n"))
        attachment.name = "relay-sync-tv-native-focus-path"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func nativeFocusTarget(for control: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        if control.hasFocus { return control }
        let identifier = control.identifier
        guard !identifier.isEmpty else { return control }
        // Native tvOS List buttons delegate focus to their containing cell.
        // Match the exact identified control, never an arbitrary nearby row.
        let cells = app.cells.containing(.button, identifier: identifier)
        return cells.count == 1 ? cells.firstMatch : control
    }

    private func focusedElementDescription(in app: XCUIApplication) -> String {
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        guard !focused.isEmpty else { return "No native focused element" }
        return focused.map {
            "type=\($0.elementType.rawValue); id=\($0.identifier); label=\($0.label); frame=\($0.frame)"
        }.joined(separator: " | ")
    }

    private func audit(_ app: XCUIApplication) throws {
        // Apple TV has no touchscreen. Touch hit-region size is not the Siri
        // Remote acceptance criterion; actual remote focus is asserted above.
        // Keep every other audit category, with explicit issue evidence.
        try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting(.hitRegion)) { issue in
            var details = "Type: \(issue.auditType.rawValue)\n\(issue.compactDescription)\n\(issue.detailedDescription)"
            if let target = issue.element {
                details += "\nElement exists: \(target.exists)"
                if target.exists {
                    details += "\nIdentifier: \(target.identifier)\nLabel: \(target.label)\nValue: \(String(describing: target.value))\nFrame: \(target.frame)"
                }
            }
            let attachment = XCTAttachment(string: details)
            attachment.name = "relay-sync-tv-accessibility-audit-issue"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            return false
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// library and installation identity; these tests never reset a user's library
/// or invoke Apple authentication. Audit results are not a VoiceOver user test.
@MainActor
final class RelaySyncAccessibilityUITests: XCTestCase {
    private var launchAccessibilityEvidence = ""
    private var interactionsOnly: Bool {
        ProcessInfo.processInfo.environment["RELAY_SYNC_QUALIFICATION_MODE"] == "interactions-only"
    }

    override func setUp() {
        continueAfterFailure = false
        let mode = ProcessInfo.processInfo.environment["RELAY_SYNC_QUALIFICATION_MODE"] ?? "native-audits"
        XCTAssertTrue(["native-audits", "interactions-only"].contains(mode), "Unknown qualification mode: \(mode)")
        let scope = XCTAttachment(string: interactionsOnly
            ? "Mode: interactions-only. Native accessibility audits are not executed. Results verify only the existing functional assertions and measured environment. Native audit findings remain separate for classification; functional results alone do not establish accessibility acceptance. This mode does not establish an audit PASS, VoiceOver acceptance, or criterion 48 acceptance."
            : "Mode: native-audits (default). Every native accessibility audit issue is retained as a failure. Functional assertions and audit findings remain separate from VoiceOver and criterion 48 acceptance.")
        scope.name = "relay-sync-qualification-execution-scope"
        scope.lifetime = .keepAlways
        add(scope)
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state == .runningForeground { capture(app, "relay-sync-final-state") }
        super.tearDown()
    }

    func testSignedOutSettingsExposeAccountAndNativeAppleControl() throws {
        let app = launch()
        openLiveAccount(in: app)
        let connection = element("settings.relayAccount.connection", in: app)
        reveal(connection, in: app)
        XCTAssertEqual(connection.label, "Relay Account")
        XCTAssertEqual(connection.value as? String, "Not connected")

        let signIn = app.buttons["settings.relayAccount.signIn"]
        reveal(signIn, in: app)
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertTrue(signIn.label.localizedCaseInsensitiveContains("Sign in with Apple"))
        // Native coordinate subtraction can report 44 as 43.99999999999997.
        XCTAssertGreaterThanOrEqual(signIn.frame.height, 44 - 1e-9)
        capture(app, "relay-sync-signed-out")
        try audit(app, anchor: signIn)

        let portal = app.buttons["settings.relayAccount.portal"]
        reveal(portal, in: app)
        XCTAssertFalse(portal.label.isEmpty)
        XCTAssertFalse(app.buttons["settings.relayAccount.signOut"].exists)
        capture(app, "relay-sync-account-footer")
        try audit(app, anchor: portal)
    }

    func testNativeProviderPickerSelectsRelayAndReturnsToOff() throws {
        let app = launch()
        let provider = element("settings.syncProvider", in: app)
        reveal(provider, in: app)
        XCTAssertTrue(provider.label.contains("Sync with"))
        capture(app, "relay-sync-provider-off")
        try audit(app, anchor: provider)
        reveal(provider, in: app, searchBackward: true)
        provider.tap()
        let relay = app.buttons["Relay Sync"].firstMatch
        XCTAssertTrue(relay.waitForExistence(timeout: 5), "native picker must expose Relay Sync")
        XCTAssertTrue(relay.isHittable)
        XCTAssertTrue(app.buttons["Off"].firstMatch.exists)
        capture(app, "relay-sync-provider-choices")
        // Audit stable Settings after choosing. Resizing audits can dismiss or
        // relocate a native menu, invalidating the intended next interaction.
        relay.tap()
        reveal(provider, in: app)
        assertProvider("Relay Sync", isAnnouncedBy: provider)
        capture(app, "relay-sync-provider-selected")
        try audit(app, anchor: provider)
        reveal(provider, in: app)
        provider.tap()
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        off.tap()
        reveal(provider, in: app)
        assertProvider("Off", isAnnouncedBy: provider)
    }

    func testAX5IncreasedContrastAndReduceMotionAreEffectiveAndUsable() throws {
        let app = launch(accessibility: true)
        // The root probe is read before Settings opens its native sheet, which
        // may remove the underlying root from the modal accessibility tree.
        let value = launchAccessibilityEvidence
        XCTAssertTrue(value.contains("dynamicType=accessibility5"), value)
        XCTAssertTrue(value.contains("contrast=increased"), value)
        XCTAssertTrue(value.contains("reduceMotion=true"), value)
        XCTAssertTrue(value.contains("systemReduceMotion=true"), value)
        XCTAssertTrue(value.contains("systemDarkerColors=true"), value)
        capture(app, "relay-sync-effective-accessibility-environment")

        let provider = element("settings.syncProvider", in: app)
        reveal(provider, in: app)
        capture(app, "relay-sync-provider-ax5-contrast-motion")
        try audit(app, anchor: provider)
        openLiveAccount(in: app)
        let signIn = app.buttons["settings.relayAccount.signIn"]
        reveal(signIn, in: app)
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertFalse(signIn.label.isEmpty)
        capture(app, "relay-sync-account-ax5-contrast-motion")
        try audit(app, anchor: signIn)
        let portal = app.buttons["settings.relayAccount.portal"]
        reveal(portal, in: app)
        capture(app, "relay-sync-footer-ax5-contrast-motion")
        try audit(app, anchor: portal)
    }

    func testActiveAccountPresentationAndSignOutDialog() throws {
        try qualifyFixture("active")
    }

    func testRecoveryPresentationDisablesUploadsAndShowsDeadline() throws {
        try qualifyFixture("recovery")
    }

    func testPurgedPresentationPreservesLocalProgressCopy() throws {
        try qualifyFixture("purged")
    }

    func testAccountErrorPresentationExposesRetry() throws {
        try qualifyFixture("error")
    }

    /// Run separately at actual system Large and AX5 settings. This captures
    /// observed glyph geometry; it does not override fonts or run native audits.
    func testMeasuredTextSizeSnapshots() throws {
        guard let expected = ProcessInfo.processInfo.environment["RELAY_SYNC_EXPECTED_DYNAMIC_TYPE"] else {
            throw XCTSkip("Separate text-size measurement requires an explicit expected system category")
        }
        XCTAssertTrue(["large", "accessibility5"].contains(expected))
        XCTAssertTrue(interactionsOnly, "Text-size measurement uses explicit interactions-only scope")
        let active = launch(fixture: "active", expectedDynamicType: expected)
        for suffix in ["connection", "usage", "quota", "syncStatus"] {
            let target = element("settings.relayAccount." + suffix, in: active)
            reveal(target, in: active)
            captureGeometry(target, in: active, name: "relay-sync-text-size-\(expected)-active-\(suffix)")
        }
        active.terminate()

        let settings = launch(expectedDynamicType: expected)
        let provider = element("settings.syncProvider", in: settings)
        reveal(provider, in: settings)
        XCTAssertTrue(provider.label.contains("Sync with"))
        captureGeometry(provider, in: settings, name: "relay-sync-text-size-\(expected)-provider")
        let footer = settings.staticTexts["Sync is off. Your games and saves stay on this device."]
        reveal(footer, in: settings)
        captureGeometry(footer, in: settings, name: "relay-sync-text-size-\(expected)-sync-off-copy")
        captureReadableText(footer, in: settings, name: "relay-sync-text-size-\(expected)-sync-off-copy")
        // Exact English copy is verified by the product catalog; launch() selects
        // English explicitly. These are the named remaining native-audit targets.
        let providerFooter = settings.staticTexts["Changing services keeps your games and saves on this device. Your files stay in the previous service too."]
        captureReadableText(providerFooter, in: settings, name: "relay-sync-text-size-\(expected)-provider-footer")
        openLiveAccount(in: settings)
        let connection = element("settings.relayAccount.connection", in: settings)
        reveal(connection, in: settings)
        XCTAssertEqual(connection.value as? String, "Not connected")
        XCTAssertFalse(settings.buttons["settings.relayAccount.signOut"].exists)
        let portal = settings.buttons["settings.relayAccount.portal"]
        reveal(portal, in: settings)
        XCTAssertEqual(portal.label, "Manage account online")
        captureGeometry(portal, in: settings, name: "relay-sync-text-size-\(expected)-signed-out-portal")
        let accountFooter = settings.staticTexts["Relay Sync is in testing. Turn on Sync game files to include them. Relay Sync does not provide end-to-end encryption."]
        captureReadableText(accountFooter, in: settings, name: "relay-sync-text-size-\(expected)-account-footer")
        settings.terminate()

        let conflict = launch(fixture: "conflict", expectedDynamicType: expected)
        for (index, identifier) in ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"].enumerated() {
            let choice = conflict.buttons["sync.conflict.keep." + identifier]
            reveal(choice, in: conflict)
            XCTAssertTrue(choice.label.contains("Keep version \(index + 1)"))
            captureGeometry(choice, in: conflict, name: "relay-sync-text-size-\(expected)-conflict-\(index + 1)")
        }
        conflict.terminate()
    }

    /// Matched native measurements for the remaining named Settings findings.
    /// Run at actual system Large and AX5; audit results remain separate.
    func testMeasuredRemainingSettingsText() throws {
        guard let expected = ProcessInfo.processInfo.environment["RELAY_SYNC_EXPECTED_DYNAMIC_TYPE"] else {
            throw XCTSkip("Separate text-size measurement requires an explicit expected system category")
        }
        XCTAssertTrue(["large", "accessibility5"].contains(expected))
        XCTAssertTrue(interactionsOnly)
        let app = launch(expectedDynamicType: expected)
        defer { app.terminate() }
        XCTAssertTrue(launchAccessibilityEvidence.contains("contrast=standard;"))
        for label in ["Haptics", "Touch Layout", "Show when a controller is connected"] {
            let text = app.staticTexts[label].firstMatch
            reveal(text, in: app)
            let scroll = app.collectionViews.allElementsBoundByIndex.last ?? app.scrollViews.firstMatch
            XCTAssertTrue(visibleContentFrame(in: scroll, app: app).contains(text.frame),
                          "Measure complete glyphs outside the navigation glass")
            captureGeometry(text, in: app, name: "remaining-settings-\(expected)-\(label)")
        }
        let account = element("settings.relayAccount.open", in: app)
        reveal(account, in: app)
        XCTAssertTrue(account.isEnabled && account.isHittable)
        XCTAssertTrue(account.label.contains("Relay Account"))
        captureGeometry(account, in: app, name: "remaining-settings-\(expected)-account-link")
        let aboutFooter = app.staticTexts["Relay includes no games. Bring the files you own."]
        captureReadableText(aboutFooter, in: app, name: "remaining-settings-\(expected)-about-footer")
    }

    /// Separate contrast-only viewport sample with the previously occluded
    /// Advanced Speeds row fully visible. The complete audit remains unchanged.
    func testVisibleAdvancedSpeedsContrastSample() throws {
        XCTAssertFalse(interactionsOnly, "This focused sample must execute its native contrast audit")
        let app = launch(expectedDynamicType: "large")
        defer { app.terminate() }
        XCTAssertTrue(launchAccessibilityEvidence.contains("contrast=standard;"),
                      "Reproduce the original standard-contrast conditions")
        let target = app.buttons["relay.proFeature.advancedSpeeds"]
        reveal(target, in: app)
        let scroll = app.collectionViews.allElementsBoundByIndex.last ?? app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        let visible = visibleContentFrame(in: scroll, app: app)
        XCTAssertTrue(target.isHittable && visible.contains(target.frame),
                      "The complete row must be outside navigation chrome before sampling")
        let title = target.staticTexts["Advanced Speeds"]
        XCTAssertTrue(title.exists && visible.contains(title.frame),
                      "The named glyph bounds must be visible, not a covered AX row")
        let scope = XCTAttachment(string: "Scope: a native contrast-only audit of the current viewport with Advanced Speeds fully visible. Every returned issue is retained. This is not an element-only audit and does not replace the complete Settings audit or establish Dynamic Type/VoiceOver acceptance.\nVisible content: \(visible)\nRow: \(target.frame)\nTitle: \(title.frame)")
        scope.name = "relay-settings-visible-advanced-speeds-contrast-scope"
        scope.lifetime = .keepAlways
        add(scope)
        captureGeometry(title, in: app, name: "relay-settings-visible-advanced-speeds-before")
        try performAudit(app, types: .contrast, group: "advanced-speeds-visible-contrast-only")
        captureGeometry(title, in: app, name: "relay-settings-visible-advanced-speeds-after")
    }

    func testConflictChoicesAndTransferProgressExposeCompleteLabels() throws {
        let app = launch(accessibility: true, fixture: "conflict")
        XCTAssertTrue(element("relay.debug.fixture", in: app).waitForExistence(timeout: 20))
        let evidence = launchAccessibilityEvidence
        XCTAssertTrue(evidence.contains("dynamicType=accessibility5"), evidence)
        let first = app.buttons["sync.conflict.keep.11111111-1111-4111-8111-111111111111"]
        reveal(first, in: app)
        let firstLabel = first.label
        XCTAssertTrue(firstLabel.contains("Keep version 1"), firstLabel)
        XCTAssertTrue(firstLabel.contains("iPhone"), firstLabel)
        XCTAssertTrue(firstLabel.contains("saved"), firstLabel)
        capture(app, "relay-sync-conflict-first-choice")
        try audit(app, anchor: first)

        let second = app.buttons["sync.conflict.keep.22222222-2222-4222-8222-222222222222"]
        reveal(second, in: app)
        let secondLabel = second.label
        XCTAssertTrue(secondLabel.contains("Keep version 2"), secondLabel)
        XCTAssertTrue(secondLabel.contains("Mac"), secondLabel)
        XCTAssertTrue(secondLabel.contains("saved"), secondLabel)
        XCTAssertNotEqual(firstLabel, secondLabel)
        capture(app, "relay-sync-conflict-second-choice")
        try audit(app, anchor: second)
        app.terminate()

        let transferApp = launch(accessibility: true, fixture: "transfer")
        let transfer = transferApp.buttons["relay.debug.transfer"]
        reveal(transfer, in: transferApp)
        XCTAssertTrue(transfer.label.contains("Downloading"), transfer.label)
        XCTAssertTrue(transfer.label.contains("42"), transfer.label)
        capture(transferApp, "relay-sync-transfer-progress")
        try audit(transferApp, anchor: transfer)
        transferApp.terminate()
    }

    private func qualifyFixture(_ scenario: String) throws {
        let app = launch(accessibility: true, fixture: scenario)
        XCTAssertTrue(element("relay.debug.fixture", in: app).waitForExistence(timeout: 20))
        let evidence = launchAccessibilityEvidence
        XCTAssertTrue(evidence.contains("dynamicType=accessibility5"), evidence)
        XCTAssertTrue(evidence.contains("contrast=increased"), evidence)
        XCTAssertTrue(evidence.contains("reduceMotion=true"), evidence)
        capture(app, "relay-sync-fixture-\(scenario)-marker")
        let vault = element("settings.relayAccount.vault", in: app)
        let accountAnchor: XCUIElement
        if scenario == "active" || scenario == "error" {
            let connection = element("settings.relayAccount.connection", in: app)
            reveal(connection, in: app)
            XCTAssertEqual(connection.value as? String, "Connected")
            let plan = element("settings.relayAccount.plan", in: app)
            reveal(plan, in: app)
            XCTAssertTrue((plan.label + " " + String(describing: plan.value ?? "")).contains("Relay Sync"))
            XCTAssertFalse(vault.exists, "Healthy storage should not repeat the account state")
            accountAnchor = plan
        } else {
            reveal(vault, in: app)
            let expected = scenario == "recovery" ? "Download your files" : "Online storage removed"
            XCTAssertTrue((vault.label + " " + String(describing: vault.value ?? "")).contains(expected))
            accountAnchor = vault
        }
        capture(app, "relay-sync-fixture-\(scenario)-account")
        try audit(app, anchor: accountAnchor)

        if scenario == "recovery" || scenario == "purged" {
            let recovery = element("settings.relayAccount.recovery", in: app)
            captureReadableText(recovery, in: app, name: "relay-sync-fixture-\(scenario)-lifecycle")
            XCTAssertFalse(recovery.label.isEmpty)
            try audit(app, anchor: recovery, textOnly: true)
            if scenario == "recovery" {
                let deadline = element("settings.relayAccount.recoveryEnds", in: app)
                reveal(deadline, in: app)
                try audit(app, anchor: deadline)
            }
        }
        let uploads = element("settings.relayGameFileSync", in: app)
        reveal(uploads, in: app)
        XCTAssertEqual(uploads.isEnabled, scenario == "active" || scenario == "error")
        var controlsAnchor = uploads
        if scenario == "error" {
            let retry = app.buttons["settings.relayAccount.retrySync"]
            reveal(retry, in: app)
            XCTAssertTrue(retry.isEnabled)
            let error = element("settings.relayAccount.error", in: app)
            reveal(error, in: app)
            XCTAssertTrue(error.label.contains("local progress is safe"))
            controlsAnchor = error
        }
        capture(app, "relay-sync-fixture-\(scenario)-controls")
        try audit(app, anchor: controlsAnchor)
        if scenario == "active" {
            let signOut = app.buttons["settings.relayAccount.signOut"]
            reveal(signOut, in: app)
            signOut.tap()
            let dialog = app.sheets["Sign out of Relay Sync?"]
            XCTAssertTrue(dialog.waitForExistence(timeout: 5))
            let message = dialog.staticTexts["Sync will stop on this device. Your games and saves are kept here and online."]
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            captureReadableText(message, in: app, scroll: dialog.scrollViews.firstMatch,
                                name: "relay-sync-fixture-sign-out-dialog")
            let confirmAction = dialog.buttons["Sign out"]
            XCTAssertTrue(confirmAction.waitForExistence(timeout: 5))
            XCTAssertTrue(confirmAction.isEnabled && confirmAction.isHittable)
            XCTAssertTrue(dialog.frame.intersection(app.frame).contains(confirmAction.frame),
                          "The native confirmation action must be fully visible")
            captureGeometry(confirmAction, in: app, name: "relay-sync-fixture-sign-out-action")
            try audit(app, anchor: confirmAction, fixedViewport: dialog)
            dismissConfirmation(dialog, in: app)
            XCTAssertTrue(signOut.waitForExistence(timeout: 5))
            XCTAssertTrue(signOut.isHittable)
        }
        app.terminate()
    }

    /// Only live Settings has this navigation row. Value-only account fixtures
    /// deliberately render their product section directly and do not call this.
    private func openLiveAccount(in app: XCUIApplication) {
        let account = element("settings.relayAccount.open", in: app)
        reveal(account, in: app)
        XCTAssertTrue(account.isEnabled)
        XCTAssertFalse(account.label.isEmpty)
        account.tap()
        XCTAssertTrue(element("settings.relayAccount.connection", in: app).waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(app.sheets.count, 1, "Account navigation must stay in the Settings presentation")
    }

    private func launch(accessibility: Bool = false, fixture: String? = nil, expectedDynamicType: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--relay-isolated-qualification", UUID().uuidString,
            "--relay-accessibility-evidence", "--relay-screen", "settings", "--relay-sync-off",
            "--relay-pro-test", "free",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        if let fixture { app.launchArguments += ["--relay-accessibility-fixture", fixture] }
        // Accessibility preferences are configured on the actual simulator or
        // device. App launch defaults can disagree with UIWindowScene traits.
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let probe = element("relay.debug.accessibilityEnvironment", in: app)
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "effective accessibility evidence must be available")
        if let expected = expectedDynamicType ?? (accessibility ? "accessibility5" : nil) {
            let effectiveCategory = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", "dynamicType=\(expected);"), object: probe
            )
            let observed = XCTWaiter.wait(for: [effectiveCategory], timeout: 10)
            XCTAssertEqual(observed, .completed, "Actual SwiftUI \(expected) did not propagate: \(probe.value as? String ?? "")")
        }
        launchAccessibilityEvidence = probe.value as? String ?? ""
        let measured = XCTAttachment(string: launchAccessibilityEvidence)
        measured.name = "relay-sync-measured-launch-accessibility-environment"
        measured.lifetime = .keepAlways
        add(measured)
        capture(app, "relay-sync-launch-accessibility-environment")
        // Keep the actual measurement, then remove instrumentation from the
        // viewport before auditing the product's full-height native content.
        probe.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "Debug environment readout must be removed before auditing")
        capture(app, "relay-sync-instrumentation-dismissed")
        if fixture == nil {
            let settings = app.navigationBars["Settings"].firstMatch
            if !settings.waitForExistence(timeout: 2) {
                // The compact iPhone shell keeps Settings behind its toolbar
                // button; debugInitialDestination only selects wider layouts.
                let openSettings = app.buttons["Settings"].firstMatch
                XCTAssertTrue(openSettings.waitForExistence(timeout: 20), "the native Settings button is missing")
                openSettings.tap()
            }
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "the native Settings sheet must be open before querying its rows")
        }
        return app
    }

    private func assertProvider(_ name: String, isAnnouncedBy provider: XCUIElement,
                                file: StaticString = #filePath, line: UInt = #line) {
        // Native menu pickers may expose the selection as part of their label.
        let announced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name), object: provider
        )
        XCTAssertEqual(XCTWaiter.wait(for: [announced], timeout: 10), .completed,
                       "Selected provider must be announced: \(provider.label), \(String(describing: provider.value))",
                       file: file, line: line)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reveal(_ target: XCUIElement, in app: XCUIApplication, searchBackward: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) {
        let scroll = app.collectionViews.allElementsBoundByIndex.last ?? app.scrollViews.firstMatch
        guard scroll.exists else {
            XCTFail("No native scrolling container is available", file: file, line: line)
            return
        }
        // Auditing Dynamic Type may move the collection to its end. Search the
        // actual viewport in both directions, stopping at observed boundaries.
        let initialPosition = scrollPosition(in: scroll)
        let startBackward = initialPosition.map { $0 >= 0.999 } == true || searchBackward
        for backward in [startBackward, !startBackward] {
            for _ in 0..<24 {
                if isVisiblyReachable(target, in: scroll, app: app) { return }
                if let position = scrollPosition(in: scroll) {
                    if backward && position <= 0.001 { break }
                    if !backward && position >= 0.999 { break }
                }
                // A controlled drag avoids flinging past short native controls.
                let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: backward ? 0.35 : 0.75))
                let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: backward ? 0.75 : 0.35))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        if isVisiblyReachable(target, in: scroll, app: app) { return }
        capture(app, "relay-sync-missing-scroll-target")
        XCTFail("The requested element remains unreachable after both bounded scroll directions", file: file, line: line)
    }

    private func isVisiblyReachable(_ target: XCUIElement, in scroll: XCUIElement, app: XCUIApplication) -> Bool {
        guard target.exists, target.isHittable else { return false }
        let visible = visibleContentFrame(in: scroll, app: app)
        let frame = target.frame
        // Hittable can mean only a sliver is visible. Keep ordinary controls
        // fully in the viewport before taking screenshots and auditing them.
        if frame.height <= visible.height {
            return frame.minY >= visible.minY && frame.maxY <= visible.maxY
        }
        return frame.intersection(visible).height >= visible.height * 0.8
    }

    private func visibleContentFrame(in scroll: XCUIElement, app: XCUIApplication) -> CGRect {
        var visible = scroll.frame.intersection(app.frame)
        if let navigation = app.navigationBars.allElementsBoundByIndex.last, navigation.exists {
            let top = max(visible.minY, navigation.frame.maxY)
            visible = CGRect(x: visible.minX, y: top, width: visible.width, height: max(0, visible.maxY - top))
        }
        let probe = element("relay.debug.accessibilityEnvironment", in: app)
        if probe.exists, probe.frame.minY > visible.midY {
            visible.size.height = max(0, min(visible.maxY, probe.frame.minY) - visible.minY)
        }
        return visible
    }

    private func captureReadableText(_ target: XCUIElement, in app: XCUIApplication,
                                     scroll explicitScroll: XCUIElement? = nil, name: String) {
        let scroll = explicitScroll ?? app.collectionViews.allElementsBoundByIndex.last ?? app.scrollViews.firstMatch
        revealTextEdge(target, in: scroll, app: app, end: false)
        captureGeometry(target, in: app, name: name + "-text-start")
        revealTextEdge(target, in: scroll, app: app, end: true)
        captureGeometry(target, in: app, name: name + "-text-end")
    }

    private func revealTextEdge(_ target: XCUIElement, in scroll: XCUIElement, app: XCUIApplication, end: Bool) {
        XCTAssertTrue(scroll.exists, "Readable text requires its native scrolling container")
        let startsBackward = scrollPosition(in: scroll).map { $0 >= 0.999 } == true
        for searchBackward in [startsBackward, !startsBackward] {
            for _ in 0..<24 {
                let visible = visibleContentFrame(in: scroll, app: app)
                var delta = visible.height * (searchBackward ? -0.4 : 0.4)
                if target.exists {
                    XCTAssertEqual(target.elementType, .staticText, "Text-edge reachability must never relax actionable-control checks")
                    let edge = end ? target.frame.maxY : target.frame.minY
                    let minimum = visible.minY + (end ? 44 : 1)
                    let maximum = visible.maxY - (end ? 1 : 44)
                    if edge >= minimum && edge <= maximum { return }
                    delta = edge - (end ? visible.maxY - 12 : visible.minY + 12)
                }
                let backward = delta < 0
                if let position = scrollPosition(in: scroll),
                   (backward && position <= 0.001) || (!backward && position >= 0.999) { break }
                let distance = min(max(abs(delta), 24), visible.height * 0.4)
                let direction: CGFloat = backward ? -1 : 1
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: visible.midX - app.frame.minX,
                                                       dy: visible.midY - app.frame.minY + direction * distance / 2))
                let finish = origin.withOffset(CGVector(dx: visible.midX - app.frame.minX,
                                                        dy: visible.midY - app.frame.minY - direction * distance / 2))
                start.press(forDuration: 0.05, thenDragTo: finish)
            }
        }
        capture(app, "relay-sync-missing-text-\(end ? "end" : "start")")
        XCTFail("Native scrolling did not expose the requested text edge")
    }

    private func dismissConfirmation(_ dialog: XCUIElement, in app: XCUIApplication) {
        let cancel = dialog.buttons["Cancel"]
        if cancel.exists {
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
        } else {
            // Native popover confirmation dialogs omit Cancel and dismiss on
            // an outside tap. Derive that tap from the actual sheet bounds.
            let bounds = dialog.frame
            let window = app.frame
            XCTAssertGreaterThan(bounds.minX - window.minX, 22, "Native popover needs a measured outside dismissal region")
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: (bounds.minX - window.minX) / 2,
                                     dy: bounds.midY - window.minY)).tap()
        }
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5), "Native confirmation must dismiss without signing out")
        capture(app, "relay-sync-fixture-sign-out-dismissed")
    }

    private func scrollPosition(in scroll: XCUIElement) -> Double? {
        let indicator = scroll.descendants(matching: .other)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar")).firstMatch
        guard indicator.exists, let value = indicator.value as? String,
              let percent = Double(value.replacingOccurrences(of: "%", with: "")) else { return nil }
        return percent / 100
    }

    private func audit(_ app: XCUIApplication, anchor: XCUIElement, textOnly: Bool = false,
                       fixedViewport: XCUIElement? = nil) throws {
        if interactionsOnly {
            let scope = XCTAttachment(string: "Native audit was not executed in explicit interactions-only mode. Anchor: \(anchor.identifier). No native audit PASS is claimed.")
            scope.name = "relay-sync-interaction-only-audit-not-executed"
            scope.lifetime = .keepAlways
            add(scope)
            return
        }
        // Dynamic Type and clipping audits resize the UI and can move native
        // List content. Preserve every category, restoring the actual target
        // before each group so later checks do not inherit a moved viewport.
        let resizing: XCUIAccessibilityAuditType = [.dynamicType, .textClipped]
        let groups: [(String, XCUIAccessibilityAuditType)] = [
            ("stable-appearance", .all.subtracting(resizing)),
            ("text-clipping", .textClipped),
            ("dynamic-type", .dynamicType),
        ]
        for (name, types) in groups {
            let scroll = app.collectionViews.allElementsBoundByIndex.last ?? app.scrollViews.firstMatch
            if let viewport = fixedViewport {
                // Confirmation actions sit in a fixed native footer. Validate
                // its actual bounds; never scroll the body or underlying List.
                XCTAssertTrue(viewport.exists && anchor.exists && anchor.isHittable)
                XCTAssertTrue(viewport.frame.intersection(app.frame).contains(anchor.frame))
            } else if scroll.exists {
                if textOnly {
                    revealTextEdge(anchor, in: scroll, app: app, end: false)
                } else {
                    reveal(anchor, in: app)
                }
            } else {
                XCTAssertTrue(anchor.waitForExistence(timeout: 5) && anchor.isHittable,
                              "Audit anchor must remain reachable")
            }
            capture(app, "relay-sync-audit-\(name)-before")
            try performAudit(app, types: types, group: name)
            capture(app, "relay-sync-audit-\(name)-after")
        }
    }

    private func performAudit(_ app: XCUIApplication, types: XCUIAccessibilityAuditType, group: String) throws {
        let originalContinuation = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = originalContinuation }
        var issueCount = 0
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                issueCount += 1
                var details = "Test: \(self.name)\nGroup: \(group)\nRequested types: \(types.rawValue)\nType: \(issue.auditType.rawValue)\n\(issue.compactDescription)\n\(issue.detailedDescription)"
                if let target = issue.element {
                    details += "\nElement exists: \(target.exists)"
                    if target.exists {
                        details += "\nIdentifier: \(target.identifier)\nLabel: \(target.label)\nValue: \(String(describing: target.value))\nFrame: \(target.frame)"
                    }
                } else {
                    details += "\nNo element supplied by XCTest"
                }
                let issueName = "relay-sync-accessibility-audit-issue-\(group)-\(issueCount)"
                let attachment = XCTAttachment(string: details)
                attachment.name = issueName
                attachment.lifetime = .keepAlways
                self.add(attachment)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = issueName + "-screen"
                screenshot.lifetime = .keepAlways
                self.add(screenshot)
                return false // Never suppress any native audit issue.
            }
        } catch {
            // A missing app, automation failure, or other error without a
            // reported audit issue remains fatal to the current test.
            guard issueCount > 0 else { throw error }
            let failure = XCTAttachment(string: "Native audit threw after \(issueCount) recorded issue(s): \(error)")
            failure.name = "relay-sync-accessibility-audit-failure-" + group
            failure.lifetime = .keepAlways
            add(failure)
        }
        if issueCount > 0 {
            XCTFail("Native accessibility audit \(group) reported \(issueCount) issue(s). Every issue is retained; continuing only to collect the remaining qualification evidence.")
        }
    }

    private func captureGeometry(_ target: XCUIElement, in app: XCUIApplication, name: String) {
        func description(_ item: XCUIElement) -> [String: Any] {
            let frame = item.frame
            return ["identifier": item.identifier, "label": item.label,
             "value": String(describing: item.value),
             "frame": [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]]
        }
        let visibleText = app.staticTexts.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.intersects(app.frame)
        }
        let measurements: [String: Any] = [
            "measuredEnvironment": launchAccessibilityEvidence,
            "target": description(target),
            "visibleText": visibleText.map(description),
        ]
        let data = try! JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(string: String(decoding: data, as: UTF8.self))
        attachment.name = name + "-geometry"
        attachment.lifetime = .keepAlways
        add(attachment)
        capture(app, name)
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

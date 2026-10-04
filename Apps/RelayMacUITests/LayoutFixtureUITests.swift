// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AppKit

/// Current native window geometry, full accessibility titles, and real action
/// activation. Fixture checks do not establish real workflow or keyboard acceptance.
@MainActor
final class LayoutFixtureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Opt-in task-window inventory with an explicit, bounded pose-button sequence.
    /// Never launch/terminate DeviceHub or select another device.
    /// The owner must already have the beta app and the task device window open.
    /// The generated run plan must discard automatic system screenshots
    /// (SystemAttachmentLifetime=keepNever) and keep these scoped user attachments.
    func testInspectExistingDuoDeviceHubWindow() throws {
        guard ProcessInfo.processInfo.environment["RELAY_DUO_DEVICEHUB_PROBE"] == "1" else {
            throw XCTSkip("Set RELAY_DUO_DEVICEHUB_PROBE=1 for the authorized local Mac inventory")
        }
        executionTimeAllowance = 30
        let bundleID = "com.apple.dt.Devices"
        let expectedPath = "/Applications/Xcode_27.1.app/Contents/Applications/DeviceHub.app"
        let taskWindowName = "Relay Duo Qualification"

        func retain(_ text: String, named name: String) {
            let attachment = XCTAttachment(string: text)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func instances() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        }

        let running = instances()
        retain(running.map {
            "pid=\($0.processIdentifier) path=\($0.bundleURL?.standardizedFileURL.path ?? "<unknown>")"
        }.joined(separator: "\n"), named: "duo-devicehub-running-inventory")
        guard running.count == 1, let existing = running.first,
              !existing.isTerminated,
              existing.bundleURL?.standardizedFileURL.path == expectedPath else {
            throw XCTSkip("Requires exactly one already-running DeviceHub at the approved beta path")
        }

        let hub = XCUIApplication(bundleIdentifier: bundleID)
        // activate() would launch a stopped app. Check both process ownership and
        // XCTest state immediately beforehand, then verify the same PID remains.
        let state = hub.state
        guard state == .runningForeground || state == .runningBackground,
              !existing.isTerminated,
              instances().map(\.processIdentifier) == [existing.processIdentifier] else {
            throw XCTSkip("DeviceHub is not a stable running instance; no activation attempted")
        }
        hub.activate()
        guard !existing.isTerminated,
              instances().map(\.processIdentifier) == [existing.processIdentifier] else {
            throw XCTSkip("DeviceHub process identity changed; stopping without window capture")
        }

        let windows = hub.windows.allElementsBoundByIndex
        guard windows.count <= 32 else {
            throw XCTSkip("Unexpectedly large DeviceHub window inventory; no capture attempted")
        }
        retain(windows.enumerated().map { index, window in
            "window[\(index)] title=\(window.label.debugDescription) " +
            "identifier=\(window.identifier.debugDescription) frame=\(window.frame)"
        }.joined(separator: "\n"), named: "duo-devicehub-window-inventory")

        // Match the task's explicit profile name, never a model or dimensions.
        let taskWindows = windows.filter { window in
            // DeviceHub exposes its window's AX title in the snapshot, while
            // XCUIElement.label is empty. Match the actual observed title.
            let attributes = window.debugDescription.split(separator: "\n").first ?? ""
            return window.label.contains(taskWindowName) || window.identifier == taskWindowName
                || attributes.contains("title: '\(taskWindowName) – iOS 27.1'")
        }
        if taskWindows.isEmpty, windows.count == 1, let manager = windows.first,
           manager.identifier == "com.apple.dt.DeviceKit.DeviceManagementWindow-AppWindow-1" {
            let taskDeviceID = "E662C51C-FD05-4CA2-9DCF-E8EAA4ADD4A1"
            let taskAnchor = NSPredicate(
                format: "label CONTAINS %@ OR identifier CONTAINS %@ OR label CONTAINS %@ OR identifier CONTAINS %@",
                taskWindowName, taskWindowName, taskDeviceID, taskDeviceID)
            let anchors = manager.descendants(matching: .any).matching(taskAnchor).allElementsBoundByIndex
            let inventory = anchors.prefix(32).enumerated().map { index, anchor in
                "anchor[\(index)] type=\(anchor.elementType.rawValue) label=\(anchor.label.debugDescription) " +
                "identifier=\(anchor.identifier.debugDescription) frame=\(anchor.frame) " +
                "selected=\(anchor.isSelected) hittable=\(anchor.isHittable)"
            }
            retain("Matching task anchors: \(anchors.count)\n" + inventory.joined(separator: "\n"),
                   named: "duo-devicehub-task-anchor-inventory")
            // Inspect only this exact beta DeviceHub window. Its selected device
            // is not yet verified, so this is manager evidence, not a Duo pass.
            // No device action is permitted here; selection is reviewed first.
            if manager.exists, manager.isHittable, !manager.frame.isEmpty {
                captureWindow(manager, "devicehub-manager-unverified-selection")
            }
        }
        guard taskWindows.count == 1, let taskWindow = taskWindows.first,
              taskWindow.exists, taskWindow.isHittable, !taskWindow.frame.isEmpty else {
            throw XCTSkip("Task window is absent, ambiguous or obscured; inspect the inventory only")
        }

        // The five controls were identified in the retained native snapshot.
        // Do not enumerate unrelated menus: each attribute is a remote AX call.
        // Deliberately no app/debugDescription or full-display screenshot: only
        // this uniquely identified task window may contribute visual evidence.
        captureWindow(taskWindow, "duo-devicehub-task-window")
        let requested = ProcessInfo.processInfo.environment["RELAY_DUO_POSE_BUTTONS"] ?? ""
        let steps = requested.split(separator: "|").map(String.init)
        let allowed: Set<String> = ["Closed", "Book", "Open", "Rotate Right", "Open in New Window"]
        XCTAssertLessThanOrEqual(steps.count, 6)
        for (index, label) in steps.enumerated() {
            guard allowed.contains(label) else {
                XCTFail("Unapproved DeviceHub control in pose sequence")
                return
            }
            let buttons = taskWindow.buttons.matching(NSPredicate(format: "label == %@", label))
            XCTAssertEqual(buttons.count, 1, "Use the exact observed DeviceHub control, not a guessed coordinate")
            let button = buttons.firstMatch
            XCTAssertTrue(button.isEnabled && button.isHittable)
            retain("step=\(index) label=\(label) frame=\(button.frame)", named: "duo-pose-action-\(index)")
            button.click()
            captureWindow(taskWindow, "duo-pose-after-\(index)-\(label.replacingOccurrences(of: " ", with: "-"))")
        }
    }

    /// Explicit screenshot preparation only. The caller supplies a separately
    /// prepared, isolated library containing redistributable test programs.
    func testWebsiteLibraryCapturesInEnglishAndFrench() throws {
        guard let profile = ProcessInfo.processInfo.environment["RELAY_WEBSITE_CAPTURE_PROFILE"],
              UUID(uuidString: profile) != nil else {
            throw XCTSkip("Requires an explicitly prepared isolated screenshot library")
        }
        for locale in ["en", "fr"] {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", profile,
                                   "--relay-screen", "library", "--relay-sync-off", "--relay-pro-test", "owned",
                                   "-ApplePersistenceIgnoreState", "YES",
                                   "-AppleLanguages", "(\(locale))", "-AppleLocale", locale == "fr" ? "fr_FR" : "en_US"]
            app.launch()
            defer { app.terminate() }
            app.activate()
            if !app.windows.firstMatch.waitForExistence(timeout: 2) {
                let bundle = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("RelayMac.app")
                XCTAssertTrue(NSWorkspace.shared.open(bundle))
            }
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
            XCTAssertEqual(app.windows.count, 1)
            let game = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Counter")).firstMatch
            XCTAssertTrue(game.waitForExistence(timeout: 20), "Use the prepared test library, never the owner's games")
            let window = app.windows.firstMatch
            let titlebar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 24))
            titlebar.press(forDuration: 0.1, thenDragTo: titlebar.withOffset(CGVector(dx: 0, dy: 80 - window.frame.minY)))
            resizeWindow(window, to: CGSize(width: 1200, height: 820))
            let importLabel = locale == "fr" ? "Importer des fichiers" : "Import Files"
            let importButtons = app.toolbars.buttons.matching(NSPredicate(format: "label == %@", importLabel))
            XCTAssertEqual(importButtons.count, 1, "The library must offer one clear import action")
            XCTAssertTrue(importButtons.firstMatch.isHittable)
            XCTAssertTrue(game.isHittable)
            assertHorizontalBounds(game, in: app)
            captureWindow(window, "website-mac-\(locale)-library")
        }
    }

    func testHostileTitlesAndActionsInEnglishAndFrench() {
        let titles = [
            ("120+", "Les Voyageurs de l’aube — L’énigme du phare oublié, édition complète (Europe) (En,Fr,De,Es,It,Nl,Ja) [Révision 12] [Homebrew 2026]"),
            ("Token", "Orbit_Chronicles_CompleteCollectorsEdition_Europe_EnFrDeEsItNlJa_Revision00000000000000000000000000000000000000000000000000000000000001"),
        ]
        for locale in ["en", "fr"] {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                                   "--relay-sync-off", "--relay-layout-fixture",
                                   "-AppleLanguages", "(\(locale))", "-AppleLocale", locale == "fr" ? "fr_FR" : "en_US"]
            app.launch()
            XCTAssertTrue(element("layout.fixture.marker", in: app).waitForExistence(timeout: 30))
            var actions = 0
            for (choice, fullTitle) in titles {
                // macOS 26 exposes SwiftUI's segmented Picker as an AXRadioGroup,
                // while older runners exposed it as an AXSegmentedControl. Match
                // the stable identifier instead of coupling the fixture to that
                // platform accessibility-role detail.
                let picker = element("layout.fixture.title", in: app)
                reveal(picker, in: app)
                let option = picker.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", choice)).firstMatch
                XCTAssertTrue(option.waitForExistence(timeout: 5))
                option.click()
                let hero = app.buttons["layout.fixture.continue"]
                reveal(hero, in: app, requireFullHeight: false)
                XCTAssertTrue(hero.label.contains(fullTitle), "The complete title must remain available to accessibility")
                assertHorizontalBounds(hero, in: app)
                capture(app, "layout-mac-\(locale)-\(choice)-continue")
                for identifier in ["layout.fixture.primary", "layout.fixture.secondary"] {
                    let action = app.buttons[identifier]
                    reveal(action, in: app)
                    XCTAssertGreaterThanOrEqual(action.frame.height, 40)
                    XCTAssertFalse(action.label.isEmpty)
                    assertHorizontalBounds(action, in: app)
                    capture(app, "layout-mac-\(locale)-\(choice)-\(identifier)")
                    action.click()
                    actions += 1
                }
                let feedback = element("layout.fixture.feedback", in: app)
                reveal(feedback, in: app)
                XCTAssertEqual(feedback.label, "Actions reached: \(actions)")
            }
            app.terminate()
        }
    }

    func testSettingsFitsNarrowDetailAndStandaloneWindowInEnglishAndFrench() throws {
        for locale in ["en", "fr"] {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                                   "--relay-screen", "settings", "--relay-sync-off", "--relay-pro-test", "owned",
                                   "-ApplePersistenceIgnoreState", "YES",
                                   "-AppleLanguages", "(\(locale))", "-AppleLocale", locale == "fr" ? "fr_FR" : "en_US"]
            app.launch()
            defer { app.terminate() }
            app.activate()
            let settings = element("settings.screen", in: app)
            // A directly launched macOS process can reach its event loop before
            // receiving the normal application-open event that creates its window.
            if !settings.waitForExistence(timeout: 2) {
                let bundle = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("RelayMac.app")
                XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
                XCTAssertTrue(NSWorkspace.shared.open(bundle))
            }
            XCTAssertTrue(settings.waitForExistence(timeout: 20))
            XCTAssertEqual(app.windows.count, 1)
            resizeWindow(app.windows.firstMatch, to: CGSize(width: 720, height: 760))
            let viewport = settings.frame.intersection(app.windows.firstMatch.frame)
            XCTAssertGreaterThan(viewport.width, 300)
            XCTAssertLessThan(viewport.width, 480, "Exercise Settings inside a detail pane below the standalone window minimum")
            let pro = element("settings.relayPro", in: app)
            XCTAssertTrue(pro.isHittable)
            XCTAssertGreaterThanOrEqual(pro.frame.minX, viewport.minX)
            XCTAssertLessThanOrEqual(pro.frame.maxX, viewport.maxX)
            let controls = settings.descendants(matching: .popUpButton).allElementsBoundByIndex
                .filter { $0.isHittable }
            XCTAssertFalse(controls.isEmpty, "Inspect native Settings picker controls")
            for control in controls {
                XCTAssertGreaterThanOrEqual(control.frame.minX, viewport.minX)
                XCTAssertLessThanOrEqual(control.frame.maxX, viewport.maxX,
                                         "Picker controls must fit the actual detail viewport")
            }
            if locale == "fr" {
                let description = element("settings.playDescription", in: app)
                XCTAssertGreaterThan(description.frame.height, 20,
                                     "The longer French play description must wrap instead of truncating")
            }
            captureWindow(app.windows.firstMatch, "settings-\(locale)-narrow-detail")

            // Open the real Settings scene through its native menu shortcut.
            // No preference, purchase, account or provider operation is performed.
            let mainFrame = app.windows.firstMatch.frame
            app.typeKey(",", modifierFlags: .command)
            XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 10))
            XCTAssertEqual(app.windows.count, 2)
            let standalone = try XCTUnwrap(app.windows.allElementsBoundByIndex.first { $0.frame != mainFrame },
                                           "Identify the newly opened Settings window separately from the main window")
            resizeWindow(standalone, to: CGSize(width: 360, height: 320))
            XCTAssertGreaterThanOrEqual(standalone.frame.width, 480)
            XCTAssertGreaterThanOrEqual(standalone.frame.height, 420)
            captureWindow(standalone, "settings-\(locale)-standalone")
        }
    }

    func testPushedProFitsMinimumWindowAndReturnsInFrenchAndGerman() async throws {
        for locale in ["fr", "de"] {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                                   "--relay-screen", "settings", "--relay-sync-off", "--relay-pro-test", "free",
                                   "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(\(locale))"]
            app.launch()
            defer { app.terminate() }
            app.activate()
            let settings = element("settings.screen", in: app)
            if !settings.waitForExistence(timeout: 2) {
                let bundle = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("RelayMac.app")
                XCTAssertTrue(NSWorkspace.shared.open(bundle))
            }
            XCTAssertTrue(settings.waitForExistence(timeout: 20))
            let window = app.windows.firstMatch
            resizeWindow(window, to: CGSize(width: 720, height: 612))
            let pro = element("settings.relayPro", in: app)
            XCTAssertTrue(pro.isHittable)
            pro.click()
            let back = app.buttons["chevron.backward"]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            XCTAssertEqual(app.sheets.count, 0, "Settings opens the pushed page, not the modal purchase surface")
            XCTAssertFalse(app.buttons["relayPro.dismiss"].exists)

            for size in [CGSize(width: 720, height: 612), CGSize(width: 1000, height: 760)] {
                resizeWindow(window, to: size)
                XCTAssertEqual(window.frame.width, size.width, accuracy: 2)
                XCTAssertEqual(window.frame.height, size.height, accuracy: 2)
                let bounds = window.frame.insetBy(dx: -1, dy: -1)
                let split = window.descendants(matching: .splitGroup).firstMatch
                XCTAssertTrue(split.exists)
                XCTAssertTrue(bounds.contains(split.frame), "The split view must not overflow the native window: \(split.frame) vs \(window.frame)")
                let sidebar = window.outlines.firstMatch
                XCTAssertTrue(sidebar.exists)
                XCTAssertTrue(bounds.contains(sidebar.frame), "The sidebar must not clip at the left or bottom window edge")
                let detail = try XCTUnwrap(window.scrollViews.allElementsBoundByIndex.first { $0.frame.minX >= sidebar.frame.maxX - 1 })
                XCTAssertTrue(bounds.contains(detail.frame), "The Pro viewport must fit its detail pane")
                XCTAssertTrue(back.isHittable)
                // Keep the immediate frame as evidence, then inspect a settled
                // compositor frame too. AX geometry can settle before glyph paint.
                captureWindow(window, "rc-mac-pro-pushed-\(locale)-\(Int(size.width))-immediate")
                let measuredFrame = window.frame
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(window.frame, measuredFrame, "The window must remain at the measured size")
                captureWindow(window, "rc-mac-pro-pushed-\(locale)-\(Int(size.width))")
                // Retain the actual display alongside the window capture to
                // distinguish compositing/occlusion from layout overflow.
                // Full-display evidence stays in the ignored result bundle.
                let display = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                display.name = "rc-mac-pro-pushed-\(locale)-\(Int(size.width))-display"
                display.lifetime = .keepAlways
                add(display)
            }
            back.click()
            XCTAssertTrue(pro.waitForExistence(timeout: 5) && pro.isHittable,
                          "Native Back must return to the existing Settings page")
        }
    }

    private func captureWindow(_ window: XCUIElement, _ name: String) {
        let geometry = XCTAttachment(string: "Observed window: \(window.frame)\n" + window.debugDescription)
        geometry.name = name + "-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func resizeWindow(_ window: XCUIElement, to requested: CGSize) {
        // Use XCTest's supported native input. No low-level Accessibility
        // permission or assumed device coordinates are required for this drag.
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: requested.width - 1, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)
        let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -1))
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: requested.height - 1))
        bottom.press(forDuration: 0.1, thenDragTo: top)
        let geometry = XCTAttachment(string: "Requested window: \(requested); actual: \(window.frame)")
        geometry.name = "settings-native-window-size"
        geometry.lifetime = .keepAlways
        add(geometry)
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ target: XCUIElement, in app: XCUIApplication, requireFullHeight: Bool = true) {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for delta in [CGFloat(-220), CGFloat(220)] {
            for _ in 0..<16 {
                let visible = scroll.frame.intersection(app.windows.firstMatch.frame)
                if target.exists && target.isHittable && (!requireFullHeight || visible.contains(target.frame)) { return }
                scroll.scroll(byDeltaX: 0, deltaY: delta)
            }
        }
        XCTFail("Fixture control is not fully reachable: \(target.identifier)")
    }

    private func assertHorizontalBounds(_ target: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(target.frame.width, 0)
        XCTAssertGreaterThanOrEqual(target.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(target.frame.maxX, window.maxX)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let geometry = XCTAttachment(string: "Observed window: \(app.windows.firstMatch.frame)\n" + app.debugDescription)
        geometry.name = name + "-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

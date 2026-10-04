// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import UIKit

/// Shipping component fixtures only. These checks do not qualify import,
/// gameplay, save handling, a real library, or VoiceOver user interaction.
@MainActor
final class LayoutFixtureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testHostileTitlesAndActionsInEnglishAndFrenchPortraitAndLandscape() {
        let titles = [
            ("120+", "Les Voyageurs de l’aube — L’énigme du phare oublié, édition complète (Europe) (En,Fr,De,Es,It,Nl,Ja) [Révision 12] [Homebrew 2026]"),
            ("Token", "Orbit_Chronicles_CompleteCollectorsEdition_Europe_EnFrDeEsItNlJa_Revision00000000000000000000000000000000000000000000000000000000000001"),
        ]
        defer { XCUIDevice.shared.orientation = .portrait }
        for locale in ["en", "fr"] {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                                   "--relay-sync-off", "--relay-layout-fixture",
                                   "-AppleLanguages", "(\(locale))", "-AppleLocale", locale == "fr" ? "fr_FR" : "en_US"]
            app.launch()
            XCTAssertTrue(element("layout.fixture.marker", in: app).waitForExistence(timeout: 30))
            var actions = 0
            for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
                XCUIDevice.shared.orientation = orientation
                for (choice, fullTitle) in titles {
                    let picker = app.segmentedControls["layout.fixture.title"]
                    reveal(picker, in: app)
                    picker.buttons[choice].tap()
                    let hero = app.buttons["layout.fixture.continue"]
                    reveal(hero, in: app, requireFullHeight: false)
                    XCTAssertTrue(hero.label.contains(fullTitle), "The complete title must remain available to accessibility")
                    assertHorizontalBounds(hero, in: app)
                    capture(app, "layout-\(locale)-\(name)-\(choice)-continue")

                    for identifier in ["layout.fixture.primary", "layout.fixture.secondary"] {
                        let action = app.buttons[identifier]
                        reveal(action, in: app)
                        XCTAssertGreaterThanOrEqual(action.frame.height, 44)
                        XCTAssertFalse(action.label.isEmpty)
                        assertHorizontalBounds(action, in: app)
                        capture(app, "layout-\(locale)-\(name)-\(choice)-\(identifier)")
                        action.tap()
                        actions += 1
                    }
                    let feedback = element("layout.fixture.feedback", in: app)
                    reveal(feedback, in: app)
                    XCTAssertEqual(feedback.label, "Actions reached: \(actions)", "Both visible actions must activate")
                }
            }
            app.terminate()
        }
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ target: XCUIElement, in app: XCUIApplication, requireFullHeight: Bool = true) {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for upward in [true, false] {
            for _ in 0..<16 {
                let visible = scroll.frame.intersection(app.frame)
                if target.exists && target.isHittable && (!requireFullHeight || visible.contains(target.frame)) { return }
                if upward { scroll.swipeUp() } else { scroll.swipeDown() }
            }
        }
        XCTFail("Fixture control is not fully reachable: \(target.identifier)")
    }

    private func assertHorizontalBounds(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertGreaterThan(target.frame.width, 0)
        XCTAssertGreaterThanOrEqual(target.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(target.frame.maxX, app.frame.maxX)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let geometry = XCTAttachment(string: "Observed viewport: \(app.frame)\n" + app.debugDescription)
        geometry.name = name + "-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Real Siri Remote focus/activation of shipping component fixtures. This does
/// not replace gameplay, library workflow, physical remote, or VoiceOver acceptance.
@MainActor
final class LayoutFixtureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testHostileTitlesAndRemoteActionsInEnglishAndFrench() {
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
                let picker = app.segmentedControls["layout.fixture.title"]
                let selected = picker.buttons.matching(NSPredicate(format: "selected == true")).firstMatch
                focus(selected, direction: .up, in: app)
                let option = picker.buttons[choice]
                focus(option, direction: .right, in: app)
                XCUIRemote.shared.press(.select)
                let hero = app.buttons["layout.fixture.continue"]
                focus(hero, direction: .down, in: app)
                XCTAssertTrue(hero.label.contains(fullTitle), "The complete title must remain available to accessibility")
                assertHorizontalBounds(hero, in: app)
                capture(app, "layout-tv-\(locale)-\(choice)-continue")
                for identifier in ["layout.fixture.primary", "layout.fixture.secondary"] {
                    let action = app.buttons[identifier]
                    let primary = app.buttons["layout.fixture.primary"]
                    let isBesidePrimary = identifier.hasSuffix("secondary") && action.frame.midY <= primary.frame.maxY
                    focus(action, direction: isBesidePrimary ? .right : .down, in: app)
                    XCTAssertFalse(action.label.isEmpty)
                    XCTAssertTrue(app.frame.contains(action.frame), "Focused actions must remain fully on screen")
                    assertHorizontalBounds(action, in: app)
                    capture(app, "layout-tv-\(locale)-\(choice)-\(identifier)")
                    XCUIRemote.shared.press(.select)
                    actions += 1
                }
                let feedback = element("layout.fixture.feedback", in: app)
                XCTAssertEqual(feedback.label, "Actions reached: \(actions)")
            }
            app.terminate()
        }
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func focus(_ target: XCUIElement, direction: XCUIRemote.Button, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let reverse: XCUIRemote.Button
        switch direction {
        case .up: reverse = .down
        case .down: reverse = .up
        case .left: reverse = .right
        case .right: reverse = .left
        default:
            XCTFail("Focus search requires a directional remote button")
            return
        }
        var path = ["Requested: \(target.identifier); label=\(target.label)"]
        for movement in [direction, reverse] {
            var previous = ""
            var unchanged = 0
            for step in 0..<24 {
                let focused = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
                let state = focused.map {
                    "type=\($0.elementType.rawValue); id=\($0.identifier); label=\($0.label); frame=\($0.frame)"
                }.joined(separator: " | ")
                path.append("\(String(describing: movement)) #\(step): " + (state.isEmpty ? "No native focused element" : state))
                if target.hasFocus {
                    recordFocusPath(path)
                    return
                }
                // tvOS moves geometrically: Down from a centered shelf card may
                // land on the secondary action beside the requested primary.
                // Follow the observed row with a real lateral remote press.
                let onTargetRow = focused.first { element in
                    let frame = element.frame
                    return frame.width > 0 && frame.height > 0
                        && frame.minY < target.frame.maxY && frame.maxY > target.frame.minY
                }
                if (movement == .up || movement == .down), let neighbor = onTargetRow {
                    let lateral: XCUIRemote.Button = neighbor.frame.midX > target.frame.midX ? .left : .right
                    path.append("Same action row: press " + String(describing: lateral))
                    XCUIRemote.shared.press(lateral)
                } else {
                    XCUIRemote.shared.press(movement)
                }
                unchanged = state == previous ? unchanged + 1 : 0
                previous = state
                if unchanged >= 3 { break }
            }
        }
        // Persist the path before XCTFail, since XCTest can stop without defer.
        recordFocusPath(path)
        capture(app, "layout-tv-focus-failure")
        XCTFail("Remote focus did not reach \(target.identifier): \(target.label)")
    }

    private func recordFocusPath(_ path: [String]) {
        let attachment = XCTAttachment(string: path.joined(separator: "\n"))
        attachment.name = "layout-tv-native-focus-path"
        attachment.lifetime = .keepAlways
        add(attachment)
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

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  TouchControlUITests.swift
//  RelayiOSUITests
//
//  The on-screen controls, exercised by a real touch.
//
//  Every touch-control test until now drove `PlayModel.touch` directly, so the
//  model was always right and the finger never arrived: on a physical iPhone and
//  iPad the controls did nothing at all, because a full-screen tap surface
//  belonging to the pause button sat above them and claimed every touch, and the
//  control on the real screen, which is the only way that class of defect shows

import XCTest

@MainActor
final class TouchControlUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The player element carries the touch state as its accessibility value.
    /// `firstMatch` because the identifier is set on a container and SwiftUI can
    /// publish more than one element for it.
    private static func playerElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "relay.player").firstMatch
    }

    /// A tap on the A button must reach the game. Against the pre-fix build the
    /// button is present and correctly placed but not hittable, because the
    /// layer above it takes the touch.
    func testTappingTheAButtonReachesTheGame() {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-reset-library", "--relay-autoplay-fixture",
                               "--relay-fixture", "relay-sram-counter",
                               "-AppleLanguages", "(en)"]
        app.launch()

        let player = Self.playerElement(app)
        XCTAssertTrue(player.waitForExistence(timeout: 60), "the fixture never reached the player")
        let before = player.value as? String ?? ""
        XCTAssertTrue(before.contains("last:"),
                      "the player carries no touch state to observe (value was \(before.isEmpty ? "empty" : before))")
        XCTAssertTrue(before.contains("last:-"),
                      "a control was already pressed before the test touched anything (value \(before))")

        let a = app.buttons["A"]
        XCTAssertTrue(a.waitForExistence(timeout: 15), "the A button is not on screen")
        XCTAssertTrue(a.isHittable,
                      "the A button is on screen but nothing can tap it: a layer above the touch controls is taking the touch")

        a.press(forDuration: 0.2)

        let delivered = expectation(
            for: NSPredicate(format: "value CONTAINS %@", "last:a"),
            evaluatedWith: player
        )
        wait(for: [delivered], timeout: 10)
    }

    /// The directional pad is one control with angular zones, so a tap on its
    /// upper half must arrive as Up rather than as nothing.
    func testTappingTheDirectionalPadReachesTheGame() {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-reset-library", "--relay-autoplay-fixture",
                               "--relay-fixture", "relay-sram-counter",
                               "-AppleLanguages", "(en)"]
        app.launch()

        let player = Self.playerElement(app)
        XCTAssertTrue(player.waitForExistence(timeout: 60), "the fixture never reached the player")

        let pad = app.buttons["Directional pad"]
        XCTAssertTrue(pad.waitForExistence(timeout: 15), "the directional pad is not on screen")
        XCTAssertTrue(pad.isHittable,
                      "the directional pad is on screen but nothing can tap it: a layer above the touch controls is taking the touch")

        // Above centre, outside the dead zone: Up.
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).press(forDuration: 0.2)

        let delivered = expectation(
            for: NSPredicate(format: "value CONTAINS %@", "last:up"),
            evaluatedWith: player
        )
        wait(for: [delivered], timeout: 10)
    }
}

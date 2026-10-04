// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  FirstRunUITests.swift
//
//  A fresh device is met by Relay's welcome; Get Started leads to how games get
//  in and to continuity; Done lands on Home with the brand in the bar; and
//  Settings ▸ Getting Started brings the tour back on request.

import XCTest

@MainActor
final class FirstRunUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFirstLaunchWalksThroughThreeStepsAndLandsOnHome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                               "--relay-reset-library", "--relay-onboarding", "--relay-sync-off", "-AppleLanguages", "(en)"]
        app.launch()

        let getStarted = app.buttons["onboarding.primary"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 20), "the first launch opens on the welcome")
        // The two lines of the promise are one accessibility element, read as one sentence.
        let promise = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Every Apple screen'")).firstMatch
        XCTAssertTrue(promise.exists, "the promise is on screen")
        getStarted.tap()

        let chooseGames = app.buttons["onboarding.chooseGames"]
        XCTAssertTrue(chooseGames.waitForExistence(timeout: 5), "step two offers the real import")
        XCTAssertTrue(app.staticTexts["Add your games."].exists)
        app.buttons["Not Now"].tap()

        let done = app.buttons["onboarding.primary"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Play here. Continue there."].exists)
        done.tap()

        // Home, with the brand in the navigation bar and no cover left.
        let lockup = app.navigationBars.staticTexts["Relay"]
        XCTAssertTrue(lockup.waitForExistence(timeout: 5), "the lockup lives in the bar")
        XCTAssertFalse(app.buttons["onboarding.primary"].exists)

        // Settings keeps the tour under Help.
        app.buttons["Settings"].firstMatch.tap()
        let replay = app.buttons["settings.gettingStarted"]
        // Rows below the fold do not exist until the list scrolls to them.
        for _ in 0..<6 where !replay.exists { app.swipeUp() }
        XCTAssertTrue(replay.waitForExistence(timeout: 5), "Settings ▸ Help ▸ Getting Started is missing")
        replay.tap()
        XCTAssertTrue(app.buttons["onboarding.primary"].waitForExistence(timeout: 5), "Getting Started replays the tour")
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(lockup.waitForExistence(timeout: 5))
    }

    /// The second launch of the same simulator is not a first launch.
    func testACompletedDeviceIsNotAskedAgain() throws {
        let qualificationID = UUID().uuidString
        let app = XCUIApplication()
        app.launchArguments = ["--relay-isolated-qualification", qualificationID,
                               "--relay-reset-library", "--relay-onboarding", "--relay-sync-off", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 20))
        app.buttons["onboarding.skip"].tap()
        app.terminate()

        // Keep the same isolated library, without resetting or forcing onboarding.
        let second = XCUIApplication()
        second.launchArguments = ["--relay-isolated-qualification", qualificationID,
                                  "--relay-sync-off", "-AppleLanguages", "(en)"]
        second.launch()
        XCTAssertTrue(second.navigationBars.staticTexts["Relay"].waitForExistence(timeout: 20))
        XCTAssertFalse(second.buttons["onboarding.primary"].exists, "a completed device goes straight to Home")
    }
}

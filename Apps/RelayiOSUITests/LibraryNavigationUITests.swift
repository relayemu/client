// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LibraryNavigationUITests.swift
//  RelayiOSUITests
//
//  Real taps on the real product UI. Every other Relay test drives LibraryModel
//  directly, which is why a dead game card — a NavigationLink whose label had hit
//  testing disabled — shipped through Phases 3, 4 and 5 unnoticed: the model was
//  always correct, only the gesture never arrived. These tests touch the screen.

import XCTest

@MainActor
final class LibraryNavigationUITests: XCTestCase {
    /// The Debug fixture's title, from the static metadata provider.
    private let fixtureTitle = "240p Test Suite"

    override func setUp() { continueAfterFailure = false }

    private func launchWithOneGame(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                               "--relay-reset-library", "--relay-import-fixture", "--relay-sync-off"] + extraArguments
        app.launch()
        return app
    }

    /// The element a person actually taps: whatever carries the game's name on Home.
    private func gameCard(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", fixtureTitle)
        let button = app.buttons.containing(predicate).firstMatch
        if button.waitForExistence(timeout: 20) { return button }
        return app.descendants(matching: .any).containing(predicate).firstMatch
    }

    func testTappingAGameCardOpensGameDetail() {
        let app = launchWithOneGame()
        let card = gameCard(in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the imported game never appeared on Home")
        XCTAssertTrue(card.isHittable, "the game card is on screen but cannot be tapped")
        card.tap()
        XCTAssertTrue(app.otherElements["relay.gameDetail"].waitForExistence(timeout: 10)
                        || app.scrollViews["relay.gameDetail"].waitForExistence(timeout: 1),
                      "tapping the game card did not open Game Detail")
    }

    /// Game Detail must offer a way to start the game. This is the button the owner
    /// reported as unreachable, one tap further along the same path.
    func testGameDetailOffersPlay() {
        let app = launchWithOneGame()
        let card = gameCard(in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        XCTAssertTrue(app.otherElements["relay.gameDetail"].waitForExistence(timeout: 10)
                        || app.scrollViews["relay.gameDetail"].waitForExistence(timeout: 1))
        let play = app.buttons.matching(NSPredicate(format:
            "label CONTAINS[c] 'Play' OR label CONTAINS[c] 'Jouer' OR label CONTAINS[c] 'Continue' OR label CONTAINS[c] 'Continuer'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Game Detail has no way to start the game")
        XCTAssertTrue(play.isHittable, "the start button exists but cannot be tapped")
        XCTAssertTrue(app.frame.contains(play.frame), "Game Detail must show the complete Play action without scrolling")
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
    }

    /// While a game is playing, the library chrome must be gone. It is drawn by
    /// UIKit rather than by the SwiftUI content, so making the shell transparent
    /// leaves the tab bar floating over the picture and keeps the library able to
    /// take input meant for the game.
    func testPlayingHidesTheLibraryChrome() {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                               "--relay-reset-library", "--relay-autoplay-fixture", "--relay-sync-off"]
        app.launch()
        // The game starts on its own; give the core a moment to come up.
        XCTAssertTrue(app.otherElements["relay.player"].waitForExistence(timeout: 20), "the game never started")
        // The tab bar stays in the accessibility tree even when the system has taken
        // it off screen, so the question is whether it is displayed, not whether the
        // element exists.
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "the tab bar is on screen over the game")
    }

    /// The integrated fixture is intentionally the exact V1 product catalog:
    /// twelve playable systems, including PlayStation and excluding deferred
    /// systems. This exercises the shipping adaptive System grid rather than a
    /// union of feature-branch catalog assumptions.
    func testSystemsGridShowsExactlyTheTwelveV1Systems() {
        let app = XCUIApplication()
        app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                               "--relay-reset-library", "--relay-demo-library", "--relay-sync-off",
                               "--relay-screen", "library",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let systems = app.buttons["Systems"].firstMatch
        XCTAssertTrue(systems.waitForExistence(timeout: 20), "Library segment picker did not appear")
        systems.tap()

        let playable = ["gb", "gbc", "gba", "nes", "snes", "nds", "sms", "gg", "pce", "ws", "wsc", "ps1"]
        for id in playable {
            XCTAssertTrue(app.buttons["relay.library.system.\(id)"].waitForExistence(timeout: 20),
                          "Missing V1 system tile: \(id)")
        }
        for id in ["n64", "md", "psp", "pcecd", "ngp"] {
            XCTAssertFalse(app.buttons["relay.library.system.\(id)"].exists,
                           "Deferred system appeared in the V1 System grid: \(id)")
        }
        capture("rc-twelve-system-grid", app: app)
    }

    func testLocalizedLibraryAndHomeCardsAreVisible() {
        for (language, systems, home) in [("en", "Systems", "Home"), ("fr", "Systèmes", "Accueil"), ("de", "Systeme", "Home")] {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                "--relay-demo-library", "--relay-sync-off", "--relay-screen", "library",
                "-AppleLanguages", "(\(language))"]
            app.launch()
            let systemPicker = app.buttons[systems].firstMatch
            XCTAssertTrue(systemPicker.waitForExistence(timeout: 30))
            capture("rc-library-cards-\(language)", app: app)
            systemPicker.tap()
            XCTAssertTrue(app.buttons["relay.library.system.ps1"].waitForExistence(timeout: 10))
            capture("rc-system-grid-\(language)", app: app)
            let homeTab = app.buttons[home].firstMatch
            XCTAssertTrue(homeTab.isHittable)
            homeTab.tap()
            capture("rc-home-cards-\(language)", app: app)
            app.terminate()
        }
    }

    func testLibraryAndHomeCardsAtActualAccessibilityXXXL() {
        for (language, home) in [("en", "Home"), ("fr", "Accueil")] {
            let app = XCUIApplication()
            app.launchArguments = ["--relay-isolated-qualification", UUID().uuidString,
                "--relay-demo-library", "--relay-sync-off", "--relay-screen", "library",
                "--relay-accessibility-evidence", "-AppleLanguages", "(\(language))",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            let probe = app.descendants(matching: .any)
                .matching(identifier: "relay.debug.accessibilityEnvironment").firstMatch
            XCTAssertTrue(probe.waitForExistence(timeout: 30))
            let actual = expectation(for: NSPredicate(format: "value CONTAINS %@", "dynamicType=accessibility5;"),
                                     evaluatedWith: probe)
            wait(for: [actual], timeout: 10)
            XCTAssertTrue((probe.value as? String ?? "").contains("systemContentSize=UICTContentSizeCategoryAccessibilityXXXL"))
            probe.tap()
            let firstCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Blue Sector'")).firstMatch
            XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
            XCTAssertTrue(firstCard.isHittable)
            capture("rc-library-actual-xxxl-\(language)", app: app)
            let homeTab = app.buttons[home].firstMatch
            XCTAssertTrue(homeTab.isHittable)
            homeTab.tap()
            let recentCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tiny Tower'")).firstMatch
            XCTAssertTrue(recentCard.waitForExistence(timeout: 10))
            XCTAssertGreaterThanOrEqual(recentCard.frame.width, 280,
                                       "Actual XXXL Home cards must grow with their text instead of keeping compact artwork widths")
            capture("rc-home-actual-xxxl-\(language)", app: app)
            app.terminate()
        }
    }

    /// Game Detail ▸ More ▸ Choose Cover… offers Photos and Files, and Files really
    /// presents the document browser from inside Game Detail (cover-art Plan D).
    func testChooseCoverOffersPhotosAndFiles() {
        let app = launchWithOneGame(["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        let card = gameCard(in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        XCTAssertTrue(app.otherElements["relay.gameDetail"].waitForExistence(timeout: 10)
                        || app.scrollViews["relay.gameDetail"].waitForExistence(timeout: 1))
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Game Detail has no More menu")
        more.tap()
        let choose = app.buttons["Choose Cover…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5), "More has no Choose Cover…")
        XCTAssertFalse(app.buttons["Reset Cover"].exists, "Reset Cover appears only once a cover was chosen")
        choose.tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 5))
        let files = app.buttons["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        capture("choose-cover-sources", app: app)
        files.tap()
        // The document browser is system UI and follows the simulator's own language.
        let browser = app.buttons.matching(NSPredicate(format: "label IN {'Browse', 'Recents', 'Cancel', 'Parcourir', 'Récents', 'Annuler'}")).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 15), "Files did not present the document browser")
        capture("choose-cover-files", app: app)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let geometry = XCTAttachment(string: app.debugDescription)
        geometry.name = name + "-geometry"; geometry.lifetime = .keepAlways; add(geometry)
    }
}

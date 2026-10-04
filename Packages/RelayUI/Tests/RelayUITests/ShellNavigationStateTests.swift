// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayDomain
import RelayEntitlements
@testable import RelayUI

final class ShellNavigationStateTests: XCTestCase {
    func testEverySidebarAreaRetainsItsGameRouteThroughTabAdaptation() {
        let system = SystemID(rawValue: "gba")
        let game = Route.game(GameID())
        let cases: [(Destination, Destination, [Route])] = [
            (.home, .home, [game]),
            (.allGames, .allGames, [game]),
            (.favorites, .allGames, [.library(.favorites), game]),
            (.system(system), .allGames, [.system(system), game]),
            (.search, .search, [game]),
            (.settings, .home, [.settings, game])
        ]
        for (area, tab, expectedPath) in cases {
            var navigation = RelayShellNavigationState()
            navigation.select(area)
            navigation.detailPath = [game]
            XCTAssertEqual(navigation.selectedTab, tab)
            XCTAssertEqual(navigation.tabPath(for: tab), expectedPath)
            // SwiftUI can write the same path while mounting the new shell.
            navigation.selectTab(tab)
            navigation.setTabPath(expectedPath, for: tab)
            XCTAssertEqual(navigation.selection, area)
            XCTAssertEqual(navigation.detailPath, [game])
        }
    }

    func testTabBackFromSystemGameKeepsSystemSelectedForTheSidebar() {
        let system = SystemID(rawValue: "gba")
        var navigation = RelayShellNavigationState()
        navigation.select(.system(system))
        navigation.detailPath = [.game(GameID())]
        navigation.setTabPath([.system(system)], for: .allGames)
        XCTAssertEqual(navigation.selection, .system(system))
        XCTAssertEqual(navigation.detailPath, [])
    }

    func testBackOutOfFavoritesReturnsToLibraryWithoutReopeningTheOldGame() {
        var navigation = RelayShellNavigationState()
        navigation.select(.favorites)
        navigation.detailPath = [.game(GameID())]
        navigation.setTabPath([], for: .allGames)
        XCTAssertEqual(navigation.selection, .allGames)
        XCTAssertEqual(navigation.detailPath, [])
        navigation.select(.favorites)
        XCTAssertEqual(navigation.detailPath, [])
    }

    func testSettingsCanReturnToHomeThroughTheNativeBackPath() {
        var navigation = RelayShellNavigationState()
        navigation.select(.settings)
        XCTAssertEqual(navigation.tabPath(for: .home), [.settings])
        navigation.setTabPath([], for: .home)
        XCTAssertEqual(navigation.selection, .home)
        XCTAssertEqual(navigation.tabPath(for: .home), [])
    }

    func testChangingTabsRetainsTheirIndependentRoutesAndLibraryArea() {
        var navigation = RelayShellNavigationState()
        let game = Route.game(GameID())
        navigation.select(.favorites)
        navigation.detailPath = [game]
        navigation.selectTab(.search)
        navigation.detailPath = [.library(.recentlyAdded)]
        navigation.selectTab(.allGames)
        XCTAssertEqual(navigation.selection, .favorites)
        XCTAssertEqual(navigation.detailPath, [game])
        navigation.selectTab(.search)
        XCTAssertEqual(navigation.detailPath, [.library(.recentlyAdded)])
    }

    func testInactiveTabCallbackCannotReplaceTheActiveSidebarArea() {
        var navigation = RelayShellNavigationState()
        navigation.select(.settings)
        navigation.setTabPath([], for: .search)
        XCTAssertEqual(navigation.selection, .settings)
        XCTAssertEqual(navigation.tabPath(for: .home), [.settings])
    }

    func testDebugEntrySelectsHomeAndReplacesOnlyItsRoute() {
        var navigation = RelayShellNavigationState()
        let game = Route.game(GameID())
        navigation.select(.favorites)
        navigation.detailPath = [game]
        navigation.showHomeRoute(.library(.recentlyPlayed))
        XCTAssertEqual(navigation.selection, .home)
        XCTAssertEqual(navigation.tabPath(for: .home), [.library(.recentlyPlayed)])
        navigation.selectTab(.allGames)
        XCTAssertEqual(navigation.selection, .favorites)
        XCTAssertEqual(navigation.detailPath, [game])
    }

    func testNestedSettingsPagesSurviveTabAdaptationAndRetainTheirBackPath() {
        let settingsPaths: [[Route]] = [
            [.relayPro(nil), .relayMembership],
            [.relayPro(.extendedRewind), .relayMembership],
            [.relayPro(.advancedSpeeds)],
            [.relayPro(.touchLayoutEditing)],
            [.relayAccount, .relayMembership],
            [.formats], [.diagnostics], [.about],
            [.about, .openSource],
            [.about, .openSource, .licenseComponent("mgba")]
        ]
        for path in settingsPaths {
            var navigation = RelayShellNavigationState()
            navigation.select(.settings)
            navigation.detailPath = path

            let restoredTabPath = navigation.tabPath(for: .home)
            XCTAssertEqual(restoredTabPath, [.settings] + path)
            navigation.selectTab(.home)
            navigation.setTabPath(restoredTabPath, for: .home)
            XCTAssertEqual(navigation.selection, .settings)
            XCTAssertEqual(navigation.detailPath, path)

            // Going Back on the adapted stack keeps the prior Settings page.
            navigation.setTabPath(Array(restoredTabPath.dropLast()), for: .home)
            XCTAssertEqual(navigation.selection, .settings)
            XCTAssertEqual(navigation.detailPath, Array(path.dropLast()))
            navigation.selectTab(.search)
            navigation.selectTab(.home)
            XCTAssertEqual(navigation.detailPath, Array(path.dropLast()))
        }
    }

    func testSearchQueryAndOpenedGameSurviveAdaptationAndOtherTabUpdates() {
        var navigation = RelayShellNavigationState()
        let game = Route.game(GameID())
        navigation.select(.search)
        var search = navigation.browsingState(for: .search)
        search.searchQuery = "Mario"
        navigation.setBrowsingState(search, for: .search)
        navigation.detailPath = [game]

        navigation.selectTab(.allGames)
        var library = navigation.browsingState(for: .allGames)
        var selection = library.libraryState(for: .all)
        selection.sort = .recentlyPlayed
        library.setLibraryState(selection, for: .all)
        navigation.setBrowsingState(library, for: .allGames)

        navigation.selectTab(.search)
        navigation.setTabPath(navigation.tabPath(for: .search), for: .search)
        XCTAssertEqual(navigation.detailPath, [game])
        XCTAssertEqual(navigation.browsingState(for: .search).searchQuery, "Mario")
        navigation.setTabPath([], for: .search)
        XCTAssertEqual(navigation.browsingState(for: .search).searchQuery, "Mario",
                       "Back to Search must retain the query used to open the game")
    }

    func testLibraryChoicesSurviveAdaptationWithoutLeakingToAnotherAreaOrFilter() {
        var navigation = RelayShellNavigationState()
        navigation.select(.allGames)
        var library = navigation.browsingState(for: .allGames)
        var choices = library.libraryState(for: .all)
        choices.segment = .favorites
        choices.sort = .recentlyPlayed
        choices.systemFilter = SystemID(rawValue: "gba")
        library.setLibraryState(choices, for: .all)
        navigation.setBrowsingState(library, for: .allGames)

        navigation.select(.favorites)
        navigation.setTabPath(navigation.tabPath(for: .allGames), for: .allGames)
        let favorites = navigation.browsingState(for: .favorites).libraryState(for: .favorites)
        XCTAssertEqual(favorites.segment, .favorites)
        XCTAssertEqual(favorites.sort, .title)
        XCTAssertNil(favorites.systemFilter)

        // Back out of the synthetic Favorites page into the original Library.
        navigation.setTabPath([], for: .allGames)
        XCTAssertEqual(navigation.selection, .allGames)
        let restored = navigation.browsingState(for: .allGames)
        XCTAssertEqual(restored.libraryState(for: .all), choices)
        let recentlyAdded = restored.libraryState(for: .recentlyAdded)
        XCTAssertEqual(recentlyAdded.segment, .all)
        XCTAssertEqual(recentlyAdded.sort, .recentlyAdded)
        XCTAssertNil(recentlyAdded.systemFilter)
        XCTAssertEqual(navigation.browsingState(for: .home).libraryState(for: .all),
                       RelayLibraryViewState(initialFilter: .all))
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayTitleCatalog

final class CatalogNameTests: XCTestCase {
    func testDisplayTitleDropsTagsAndFrontsTheArticle() {
        let vectors = [
            "007 - NightFire (USA, Europe) (En,Fr,De)": "007 - NightFire",
            "Pokemon - Emerald Version (USA, Europe)": "Pokemon - Emerald Version",
            "Legend of Zelda, The - A Link to the Past (USA)": "The Legend of Zelda - A Link to the Past",
            "Simpsons, The (USA)": "The Simpsons",
            "Final Fantasy VIII (USA) (Disc 1)": "Final Fantasy VIII",
            "Castlevania - Aria of Sorrow (USA) [b]": "Castlevania - Aria of Sorrow",
            "Tetris (World) (Rev A)": "Tetris",
            "(Unknown)": "(Unknown)",
        ]
        for (name, expected) in vectors { XCTAssertEqual(CatalogName.displayTitle(name), expected, name) }
    }

    func testMatchKeyFoldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(CatalogName.matchKey("Pokémon: Red Version"), "pokemon red version")
        XCTAssertEqual(CatalogName.matchKey("Pokemon - Red Version"), "pokemon red version")
        XCTAssertEqual(CatalogName.matchKey("  Kirby's  Dream Land!"), "kirby s dream land")
        XCTAssertEqual(CatalogName.matchKey(" - "), "")
    }

    func testRegionPreferenceFollowsTheDevice() {
        let france = CatalogName.regionPreference(for: "FR")
        XCTAssertEqual(Array(france.prefix(2)), ["France", "Europe"])
        XCTAssertLessThan(france.firstIndex(of: "World")!, france.firstIndex(of: "USA")!)
        XCTAssertEqual(CatalogName.regionPreference(for: "us").first, "USA")
        XCTAssertEqual(CatalogName.regionPreference(for: nil), ["World", "USA", "Europe", "Japan"])
        XCTAssertEqual(Set(france).count, france.count)
    }

    func testTagsAndRankingPutReleasesFirst() {
        XCTAssertEqual(CatalogName.tags("Tetris (USA) (Beta 1) [b]"), ["USA", "Beta 1", "b"])
        let preference = CatalogName.regionPreference(for: "US")
        let names = ["Tetris (USA) (Beta 1) (Tengen)", "Tetris (Europe)", "Tetris (USA) (Tengen)", "Tetris (USA)", "Tetris (China) (Pirate)"]
        XCTAssertEqual(names.min { CatalogName.rank($0, preference: preference) < CatalogName.rank($1, preference: preference) }, "Tetris (USA)")
    }

    func testRegionIsTheFirstTag() {
        XCTAssertEqual(CatalogName.region("Pokemon - Emerald Version (USA, Europe)"), "USA, Europe")
        XCTAssertEqual(CatalogName.region("Super Mario Bros. (World)"), "World")
        XCTAssertNil(CatalogName.region("Tetris"))
    }
}

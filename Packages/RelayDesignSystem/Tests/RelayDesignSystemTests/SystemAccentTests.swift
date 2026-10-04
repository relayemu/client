// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayDesignSystem

final class SystemAccentTests: XCTestCase {
    func testAssignedSystemsUseTheDesignTable() {
        XCTAssertEqual(SystemAccent.hue(for: .gameBoyAdvance), .indigo)
        XCTAssertEqual(SystemAccent.hue(for: "nes"), .brick)
        XCTAssertEqual(SystemAccent.hue(for: "snes"), .violet)
    }

    func testUnassignedSystemsGetAStableHueAndNeverEmber() {
        let a = SystemAccent.hue(for: "future-system")
        let b = SystemAccent.hue(for: "future-system")
        XCTAssertEqual(a, b)
        XCTAssertTrue(SystemHue.allCases.contains(a))
    }

    func testFifteenDistinctHuesWithDistinctValues() {
        XCTAssertEqual(SystemHue.allCases.count, 15)
        XCTAssertEqual(Set(SystemHue.allCases.map { $0.values.dark }).count, 15)
        XCTAssertEqual(Set(SystemHue.allCases.map { $0.values.light }).count, 15)
        XCTAssertFalse(SystemHue.allCases.map { $0.values.dark }.contains(0xFF6A45), "Ember is never a system colour")
    }
}

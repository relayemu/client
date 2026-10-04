// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RelayUI

/// Checks the contextual labels supplied to native buttons. Actual VoiceOver
/// navigation and activation are separately exercised in the platform pass.
@MainActor final class VersionChoiceAccessibilityTests: XCTestCase {
    private let savedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testChoiceLabelIncludesDeviceAndSaveTimeWithoutCardContext() {
        let device = Formatting.thisDevice(.mac)
        let label = VersionCard.keepLabel(version: 1, deviceName: device, savedAt: savedAt)
        XCTAssertTrue(label.contains(device))
        XCTAssertTrue(label.contains(savedAt.formatted(date: .abbreviated, time: .standard)))
        XCTAssertNotEqual(label, L("Keep This One"), "Buttons-rotor choices must identify their save")
    }

    func testChoicesStayDistinctForSameDeviceKindAndTimestamp() {
        let device = Formatting.deviceName(.iPhone)
        let first = VersionCard.keepLabel(version: 1, deviceName: device, savedAt: savedAt)
        let second = VersionCard.keepLabel(version: 2, deviceName: device, savedAt: savedAt)
        XCTAssertNotEqual(first, second, "Two matching summaries still need distinct spoken choices")
    }

    func testFrenchChoiceRetainsNumberDeviceAndTimestamp() throws {
        let fr = try LocalizationTests().frenchBundle()
        let template = fr.localizedString(forKey: "Keep version %lld: %@, saved %@", value: nil, table: "Localizable")
        let rendered = String.localizedStringWithFormat(template, 2, "cet iPhone", "14 nov. 2023 à 22:13:20")
        XCTAssertTrue(rendered.contains("version 2"))
        XCTAssertTrue(rendered.contains("cet iPhone"))
        XCTAssertTrue(rendered.contains("14 nov. 2023 à 22:13:20"))
        XCTAssertFalse(rendered.contains("%@"))
        XCTAssertFalse(rendered.contains("%lld"))
    }
}

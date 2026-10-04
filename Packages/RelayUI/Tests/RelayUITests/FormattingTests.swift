// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayDomain
@testable import RelayUI

@MainActor final class FormattingTests: XCTestCase {
    func testFinishedSessionUsesRecentEndForVisibleLastPlayedTime() {
        let now = Date()
        let started = now.addingTimeInterval(-5 * 60)
        let ended = now.addingTimeInterval(-10)
        let session = PlaySession(gameID: GameID(), coreID: "mgba", startedAt: started,
                                  endedAt: ended, deviceKind: .iPhone, origin: .local)

        XCTAssertEqual(Formatting.lastPlayedDate(session: session), ended)
        let status = Formatting.playedStatus(session: session, localInstallation: nil,
                                           thisDevice: .iPhone, now: now)
        XCTAssertEqual(status, Formatting.playedStatus(deviceKind: .iPhone, at: ended, now: now))
        XCTAssertTrue(status.contains(Formatting.thisDevice(.iPhone)))
        XCTAssertTrue(status.contains(L("just now")))
        XCTAssertNotEqual(status, Formatting.playedStatus(deviceKind: .iPhone, at: started, now: now))
    }

    func testUnfinishedSessionUsesKnownStartAndPreservesRemoteDeviceWording() {
        let now = Date()
        let started = now.addingTimeInterval(-5 * 60)
        let session = PlaySession(gameID: GameID(), coreID: "mgba", startedAt: started,
                                  deviceKind: .iPad, origin: .remote)

        XCTAssertEqual(Formatting.lastPlayedDate(session: session), started)
        let status = Formatting.playedStatus(session: session, localInstallation: nil,
                                           thisDevice: .iPhone, now: now)
        XCTAssertEqual(status, Formatting.playedElsewhereStatus(deviceKind: .iPad, at: started, now: now))
        XCTAssertTrue(status.contains(Formatting.deviceName(.iPad)))
        XCTAssertFalse(status.contains(Formatting.thisDevice(.iPhone)))
    }
}

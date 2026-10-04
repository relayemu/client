// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayDomain
import RelaySync
@testable import RelayUI

final class RootAlertRoutingTests: XCTestCase {
    func testUnsupportedCloudLayoutUsesLocalImportRecoveryNotConnectivityAdvice() {
        let message = ProductMessage.downloadFailed(
            SyncContentError.unsupportedLayout,
            title: "Multi Disc Game",
            deviceKind: .iPhone
        )

        XCTAssertTrue(message.headline.contains("Multi Disc Game"))
        XCTAssertEqual(message.action, .howToAdd)
        XCTAssertTrue(message.message.localizedCaseInsensitiveContains("device")
                      || message.message.localizedCaseInsensitiveContains("appareil"))
        XCTAssertFalse(message.message.localizedCaseInsensitiveContains("connection"))
        XCTAssertFalse(message.message.localizedCaseInsensitiveContains("connexion"))
    }

    func testTwoVersionsKeepsCompareActionWhenNoStorageErrorExists() throws {
        let gameID = GameID()
        let message = ProductMessage.twoVersions(gameID: gameID, title: "Counter", deviceA: .iPhone, deviceB: .mac)
        let alert = try XCTUnwrap(RelayRootAlert.pending(play: message, storage: nil, dismissedStorageID: nil))
        XCTAssertEqual(alert.origin, .play)
        XCTAssertEqual(alert.message.action, .compare(gameID))
        XCTAssertEqual(alert.id, message.id)
    }

    func testStorageErrorDoesNotShadowPlayAndRemainsQueued() throws {
        let play = ProductMessage(headline: "Review", message: "Choose progress", action: .compare(GameID()))
        let storage = ProductMessage(headline: "Storage", message: "Library unavailable", action: .showDiagnostics)
        XCTAssertEqual(RelayRootAlert.pending(play: play, storage: storage, dismissedStorageID: nil)?.id, play.id)
        let queued = try XCTUnwrap(RelayRootAlert.pending(play: nil, storage: storage, dismissedStorageID: nil))
        XCTAssertEqual(queued.origin, .storage)
        XCTAssertEqual(queued.message, storage)
    }

    func testDismissedStorageErrorStaysQuietAndANewErrorStillAppears() {
        let old = ProductMessage(headline: "Storage", message: "Old failure")
        let new = ProductMessage(headline: "Storage", message: "New failure")
        XCTAssertNil(RelayRootAlert.pending(play: nil, storage: old, dismissedStorageID: old.id))
        XCTAssertEqual(RelayRootAlert.pending(play: nil, storage: new, dismissedStorageID: old.id)?.id, new.id)
    }
}

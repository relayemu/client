// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelaySync
@testable import RelayUI

final class HostedSyncProblemCopyTests: XCTestCase {
    func testLegacyForeignHistoryUsesApprovedFailureCopy() {
        XCTAssertEqual(RelayHostedSyncProblemCopy.message(for: .failed("hosted history requires original installation")),
                       L("Some older progress belongs to another device and stays local here. Open Relay on the original device to sync it."))
    }

    func testLegacyRetentionUsesApprovedFailureCopy() {
        XCTAssertEqual(RelayHostedSyncProblemCopy.message(for: .failed("hosted state retention deletion unsupported")),
                       L("Relay Sync cannot automatically remove older save history yet. Your local saves are safe. You can keep playing while this sync action is paused."))
    }

    func testUnknownDetailsAreNeverPresentedAsProductCopy() {
        XCTAssertNil(RelayHostedSyncProblemCopy.message(for: .failed("untrusted server detail")))
        XCTAssertNil(RelayHostedSyncProblemCopy.message(for: .network))
    }
}

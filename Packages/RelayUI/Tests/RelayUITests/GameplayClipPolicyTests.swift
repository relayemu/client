// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayEntitlements
@testable import RelayUI

final class GameplayClipPolicyTests: XCTestCase {
    func testEveryExistingProSourceRemovesTimeAndFileCapsWhileFreeKeepsBoth() {
        let free = GameplayClipLimits(policy: RelayAccessPolicy(entitlement: .free))
        XCTAssertEqual(free.duration, 15)
        XCTAssertEqual(free.maximumBytes, 16 * 1024 * 1024)
        let grants = [
            RelayEntitlementState(activeProductIDs: [.proOnce]),
            RelayEntitlementState(activeProductIDs: [.proMonthly]),
            RelayEntitlementState(activeProductIDs: [.proOnce], familySharedProductIDs: [.proOnce]),
            RelayEntitlementState(activeProductIDs: [], additionalSources: [.relaySyncBundle]),
        ]
        for grant in grants {
            let limits = GameplayClipLimits(policy: RelayAccessPolicy(entitlement: grant))
            XCTAssertNil(limits.duration)
            XCTAssertNil(limits.maximumBytes)
        }
    }

    func testAnOldRecordingHeldByAPreviewSurvivesPruningUntilReleased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try GameplayShareFile.destination(.clip, root: root)
        try Data([1, 2, 3]).write(to: url)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -90_000)],
                                             ofItemAtPath: url.deletingLastPathComponent().path)
        var preview: GameplayShareFile? = GameplayShareFile(url: url, kind: .clip)
        XCTAssertEqual(preview?.url, url)
        _ = try GameplayShareFile.destination(.screenshot, root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        preview = nil
        _ = try GameplayShareFile.destination(.screenshot, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

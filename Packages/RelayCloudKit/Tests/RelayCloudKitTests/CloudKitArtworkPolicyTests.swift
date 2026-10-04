// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CloudKitArtworkPolicyTests.swift — when custom covers wait, and when an
//  engine must recover covers an older build fetched past. No network.

import XCTest
import CloudKit
@testable import RelayCloudKit

final class CloudKitArtworkPolicyTests: XCTestCase {
    func testOnlyAnEngineOlderThanArtworkCatchesUpOnce() {
        XCTAssertTrue(CloudKitSyncTransport.needsArtworkCatchUp(markerExists: false, hadEngineState: true), "state from an older build")
        XCTAssertFalse(CloudKitSyncTransport.needsArtworkCatchUp(markerExists: false, hadEngineState: false), "a fresh engine fetches every cover")
        XCTAssertFalse(CloudKitSyncTransport.needsArtworkCatchUp(markerExists: true, hadEngineState: true), "once")
    }

    func testARefusedTypeTurnsCoversOffButTransientFailuresDoNot() {
        for code: CKError.Code in [.invalidArguments, .serverRejectedRequest, .unknownItem, .constraintViolation] {
            XCTAssertTrue(CloudKitSyncTransport.refusesArtwork(CKError(code)), "\(code.rawValue)")
        }
        for code: CKError.Code in [.networkFailure, .networkUnavailable, .requestRateLimited, .quotaExceeded, .serverRecordChanged, .zoneBusy] {
            XCTAssertFalse(CloudKitSyncTransport.refusesArtwork(CKError(code)), "\(code.rawValue)")
        }
    }
}

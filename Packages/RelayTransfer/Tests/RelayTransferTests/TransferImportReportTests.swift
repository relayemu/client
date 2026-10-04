// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayLibrary
@testable import RelayTransfer

final class TransferImportReportTests: XCTestCase {
    func testArchiveHasItsOwnPartialCountsWithinMixedFolder() {
        let report = ImportReport(outcomes: [
            ImportOutcome(displayName: "games.zip/one.bin", result: .unsupported),
            ImportOutcome(displayName: "games.zip/two.bin", result: .failed(detail: "fixture")),
            ImportOutcome(displayName: "README.txt", result: .unsupported),
        ])
        let result = TransferImportResult.fromImportReport(report, sourceURLs: [URL(fileURLWithPath: "/games.zip"), URL(fileURLWithPath: "/README.txt")])
        XCTAssertEqual(result.sourceResults["games.zip"]?.state, "failed")
        XCTAssertEqual(result.sourceResults["games.zip"]?.counts.unsupported, 1)
        XCTAssertEqual(result.sourceResults["games.zip"]?.counts.failed, 1)
        XCTAssertEqual(result.sourceResults["README.txt"]?.state, "unsupported")
    }
    func testDiscCompanionUsesDiscResultInsteadOfUnrelatedFolderFailure() {
        let report = ImportReport(outcomes: [
            ImportOutcome(displayName: "disc.cue", result: .discRejected(.missingFiles)),
            ImportOutcome(displayName: "README.txt", result: .unsupported),
        ])
        let result = TransferImportResult.fromImportReport(report, sourceURLs: [URL(fileURLWithPath: "/disc.cue"), URL(fileURLWithPath: "/track.bin"), URL(fileURLWithPath: "/README.txt")])
        XCTAssertEqual(result.sourceResults["track.bin"]?.code, "disc_rejected")
        XCTAssertEqual(result.sourceResults["track.bin"]?.counts.failed, 1)
        XCTAssertEqual(result.sourceResults["track.bin"]?.counts.unsupported, 0)
        XCTAssertEqual(result.sourceResults["README.txt"]?.state, "unsupported")
    }
}

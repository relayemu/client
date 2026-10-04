// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayTransfer
@testable import RelayUI

@MainActor final class TransferModelTests: XCTestCase {
    private let file = TransferFile(id: "game", name: "game.gb", size: 32768,
                                   sha256: String(repeating: "0", count: 64))

    func testWaitingKeepsResultsButFailedNewConnectionCannotShowPreviousCompletion() {
        let model = TransferModel()
        model.receive(.manifest([file]))
        model.receive(.status(TransferStatus(id: file.id, state: "imported", receivedBytes: file.size)))
        model.receive(.outcomes(TransferCounts(imported: 1)))
        model.receive(.completed)
        model.receive(.route(.relay))
        model.receive(.waiting)
        XCTAssertTrue(model.isComplete)
        XCTAssertEqual(model.counts.imported, 1)
        XCTAssertEqual(model.fraction, 1)
        XCTAssertEqual(model.route, .relay)

        model.receive(.connecting)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.isComplete)
        XCTAssertNil(model.route)
        model.receive(.failed(.connectionFailed))
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(model.statuses.isEmpty)
        XCTAssertEqual(model.receivedBytes, 0)
        XCTAssertEqual(model.fraction, 0)
        XCTAssertEqual(model.counts, TransferCounts())
        XCTAssertFalse(model.isBusy)
    }

    func testFailureDuringReceiptKeepsCurrentProgressAndIndependentImportResults() {
        let model = TransferModel()
        model.receive(.connecting)
        model.receive(.manifest([file]))
        model.receive(.status(TransferStatus(id: file.id, state: "receiving", receivedBytes: 16384)))
        model.receive(.outcomes(TransferCounts(imported: 1)))
        model.receive(.failed(.interrupted))
        XCTAssertEqual(model.files, [file])
        XCTAssertEqual(model.receivedBytes, 16384)
        XCTAssertEqual(model.fraction, 0.5)
        XCTAssertEqual(model.counts.imported, 1)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isComplete)
        XCTAssertEqual(model.statuses[file.id]?.state, "failed")
        XCTAssertEqual(model.statuses[file.id]?.receivedBytes, 16384)
    }

    func testInterruptionPreservesIndependentSuccessAndStopsQueuedRows() {
        let queued = TransferFile(id: "queued", name: "queued.gb", size: 32768,
                                  sha256: String(repeating: "1", count: 64))
        let model = TransferModel()
        model.receive(.manifest([file, queued]))
        model.receive(.status(TransferStatus(id: file.id, state: "imported", receivedBytes: file.size)))
        model.receive(.outcomes(TransferCounts(imported: 1)))
        model.receive(.failed(.interrupted))
        XCTAssertEqual(model.statuses[file.id]?.state, "imported")
        XCTAssertEqual(model.counts.imported, 1)
        XCTAssertEqual(model.statuses[queued.id]?.state, "failed")
        XCTAssertFalse(model.isReceiving)
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
import RelayDomain
import RelaySync
@testable import RelayCloudKit

final class TransportLifecycleTests: XCTestCase {
    /// A stopped transport must reject direct content work before any CloudKit request is scheduled.
    func testStoppedTransportRejectsContentRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RelayCloudKitLifecycle-\(UUID())")
        let transport = CloudKitSyncTransport(configuration: .init(
            containerIdentifier: "iCloud.app.relayemu.relay",
            stateFileURL: root.appending(path: "state.json"),
            scratchDirectory: root.appending(path: "scratch"),
            automaticallySync: false
        ))
        await transport.stop()
        XCTAssertEqual(transport.engineDetail(), "engine stopped")
        let fingerprint = try ContentFingerprint(parsing: "sha256:" + String(repeating: "a", count: 64))
        let key = RecordKey.gameContent(fingerprint, part: 0)
        let record = SyncGameContent(fingerprint: fingerprint, partIndex: 0, partCount: 1, partFingerprint: fingerprint, partSize: 1)
        do {
            _ = try await transport.contentExists(key)
            XCTFail("Stopped metadata request must be refused")
        } catch { XCTAssertEqual(error as? CloudKitTransportError, .notStarted) }
        do {
            _ = try await transport.fetchContent(key, progress: { _ in })
            XCTFail("Stopped download must be refused")
        } catch { XCTAssertEqual(error as? CloudKitTransportError, .notStarted) }
        do {
            try await transport.uploadContent(.gameContent(record), fileURL: root.appending(path: "absent.gba"), progress: { _ in })
            XCTFail("Stopped upload must be refused before inspecting the file")
        } catch { XCTAssertEqual(error as? CloudKitTransportError, .notStarted) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Stopped calls must not create transport artifacts")
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayDomain
import RelayLibrary
import RelayEmulation
import RelaySync
@testable import RelayUI

@MainActor final class SyncStartupTests: XCTestCase {
    func testLocalLibraryLoadsAndImportsWhileTransportStartIsSuspended() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelaySyncStartup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = PlayFactory()
        let session = EmulationSession(factory: factory, storage: EmulationStorage(
            batterySavesDirectory: root.appendingPathComponent("saves"),
            saveStatesDirectory: root.appendingPathComponent("states"),
            firmwareDirectory: root.appendingPathComponent("firmware")))
        let transport = SuspendedStartupTransport()
        let environment = LibraryEnvironment(location: LibraryLocation(rootURL: root.appendingPathComponent("Library")),
            session: session, cores: factory.availableCores, transportFactory: { _ in transport })
        let model = LibraryModel(environment: environment)
        let load = Task { await model.load() }
        await transport.waitUntilStarted()
        // A regression must fail without leaving an indefinitely suspended test.
        for _ in 0..<100 where !model.isReady { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.isReady, "Library launch must not await remote startup")
        XCTAssertNotNil(environment.batterySaves)
        let fixture = root.appendingPathComponent("local.gba")
        try Data(GBABytes.make(payload: 0x11)).write(to: fixture)
        await model.importFiles([fixture])
        XCTAssertEqual(model.games.count, 1, "Local canonical writes remain available while remote startup waits")
        await transport.release()
        await load.value
        await model.sync.waitForStartup()
    }
}

private actor SuspendedStartupTransport: SyncTransport {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func start(host: any SyncTransportHost) async throws {
        started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func stop() async { release() }
    func resetState() async {}
    func requestSync(reason: SyncReason) async {}
    func fetchNow() async throws {}
    func uploadContent(_ record: SyncRecord, fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func fetchContent(_ key: RecordKey, progress: @escaping @Sendable (Double) -> Void) async throws -> InboundChange? { nil }
    func contentExists(_ key: RecordKey) async throws -> Bool { false }
    func deleteContent(_ key: RecordKey) async throws {}
}

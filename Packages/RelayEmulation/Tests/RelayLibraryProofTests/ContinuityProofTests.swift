// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ContinuityProofTests.swift
//  two independent Relay libraries (device A, device B) exchange progress
//  through the deterministic in-memory cloud while mGBA really runs the
//  Relay-authored SRAM counter fixture.
//
//  1. A plays (counter 2), saves, stops, syncs → B receives the library entry,
//     the battery revision, the session and the Auto Resume; B has no game file.
//  2. B adds the same file (save-only continuity), launches mGBA: the counter
//     boots from A's progress (3), B plays on (4), saves, syncs → A adopts (4).
//  3. Offline divergence: both save without syncing → Two versions on both;
//     A keeps B's version → both converge; the losing revision stays.
//  4. Performance: the emulated frame rate while sync is pending and the
//     apply time and asset sizes are printed for the docs.

import XCTest
import RelayDomain
import RelayLibrary
import RelayPersistence
import RelayEmulation
import RelayProvenanceAdapter
import RelaySync
import RelayCores

final class ContinuityProofTests: XCTestCase {
    static var counterROM: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/Fixtures/ROMs/relay-sram-counter/relay-sram-counter.gba")
    }

    /// One Relay installation.
    @MainActor
    final class Device {
        let name: String
        let root: URL
        let location: LibraryLocation
        let store: SQLiteLibraryStore
        let identity: SyncIdentity
        let battery: BatterySaveManager
        let states: SaveStateManager
        let coordinator: SyncCoordinator
        let transport: InMemoryCloudTransport
        let factory = RelayCores.standardFactory()

        init(name: String, kind: DeviceKind, cloud: InMemoryCloud) async throws {
            self.name = name
            root = FileManager.default.temporaryDirectory.appending(path: "RelayContinuityProof-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
            location = LibraryLocation(rootURL: root)
            try location.createDirectories()
            store = try SQLiteLibraryStore.open(at: location.databaseURL, deviceKind: kind)
            identity = try await store.syncStore.identity()
            battery = BatterySaveManager(store: store, location: location, identity: identity)
            states = SaveStateManager(store: store, location: location, artworkStore: ArtworkStore(location: location), identity: identity)
            transport = cloud.connect(device: name)
            coordinator = SyncCoordinator(store: store, syncStore: store.syncStore, location: location, batterySaves: battery,
                                          saveStates: states, identity: identity, configuration: .init(capabilities: .internalTesting))
            await coordinator.start(transport: transport)
        }

        func destroy() { try? store.close(); try? FileManager.default.removeItem(at: root) }

        func launch(_ game: Game) async throws -> (EmulationSession, EmulatorCoreDescriptor) {
            let launch = try await GameLaunchResolver(store: store, location: location, availableCores: factory.availableCores).resolve(gameID: game.id)
            try await battery.prepareForLaunch(gameID: game.id, romBaseName: launch.contentURL.deletingPathExtension().lastPathComponent)
            let storage = EmulationStorage(batterySavesDirectory: battery.workingDirectory(for: game.id),
                                           saveStatesDirectory: location.saveStatesDirectory(forGame: game.id),
                                           firmwareDirectory: root.appending(path: "Firmware"))
            let session = EmulationSession(factory: factory, storage: storage, rewindConfiguration: .disabled)
            try session.play(romURL: launch.contentURL, coreID: launch.core.id,
                             systemID: launch.game.systemID, audio: false)
            await coordinator.setGameplayActive(game.id)
            return (session, launch.core)
        }

        /// Safe point: battery snapshot + Auto Resume paired with the head + session end.
        func save(_ session: EmulationSession, game: Game, core: EmulatorCoreDescriptor, sessionRecord: PlaySession) async throws {
            let started = Date()
            _ = try await battery.snapshot(gameID: game.id, data: session.batterySaveBytes())
            let head = try await store.saves.activeBatteryRevisionID(for: game.id)
            let payload = try session.captureState()
            _ = try await states.create(kind: .auto, game: game, core: core, payload: payload, batteryRevisionID: head)
            try await store.playHistory.record(sessionRecord.ended(at: Date()))
            print("RELAY-MEASURE journal.safePoint.ms=\(String(format: "%.2f", Date().timeIntervalSince(started) * 1000)) state.bytes=\(payload.count)")
            session.stop()
            await coordinator.setGameplayActive(nil)
            await coordinator.flushSoon()
        }

        func counter(_ game: Game) throws -> UInt8 {
            try Data(contentsOf: location.url(for: try LibraryLocation.batterySaveLocation(gameID: game.id)))[0]
        }
    }

    var cloud: InMemoryCloud!
    var a: Device!
    var b: Device!

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.counterROM.path), "fixture missing")
        cloud = InMemoryCloud()
        a = try await Device(name: "a", kind: .mac, cloud: cloud)
        b = try await Device(name: "b", kind: .iPad, cloud: cloud)
    }

    override func tearDown() async throws { await a?.destroy(); await b?.destroy() }

    /// The counter after the fixture's boot increment. Fresh save memory is not
    /// the same on every system — mGBA maps 0xFF-filled SRAM, so the increment
    /// wraps to 0, while Mesen zero-fills cartridge RAM and it reads 1 — so the
    /// journey below is expressed relative to whatever this returns.
    @MainActor
    private func bootCounter(_ session: EmulationSession) async throws -> UInt8 {
        for _ in 0..<60 {
            if let bytes = session.batterySaveBytes(), !bytes.isEmpty { return bytes[0] }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("the fixture wrote no battery save")
    }

    @MainActor
    private func waitForCounter(_ session: EmulationSession, toReach value: UInt8) async -> Data? {
        var bytes: Data?
        for _ in 0..<60 {
            bytes = session.batterySaveBytes()
            if let b = bytes, !b.isEmpty, b[0] == value { return b }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return bytes
    }

    @MainActor
    private func pressA(_ session: EmulationSession) async {
        session.press(.a); try? await Task.sleep(for: .milliseconds(200)); session.release(.a)
        try? await Task.sleep(for: .milliseconds(200))
    }

    @MainActor
    func testProgressFollowsAcrossTwoDevicesWithRealEmulation() async throws {
        try await runProgressAcrossTwoDevices(rom: Self.counterROM, coreID: "mgba")
    }

    /// The same journey on a Mesen system (Master System, mapper cartridge RAM):
    /// a newly enabled system fits the existing sync semantics with no record
    @MainActor
    func testProgressFollowsAcrossTwoDevicesOnAMesenSystem() async throws {
        let rom = Self.counterROM.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "relay-sms-counter/relay-sms-counter.sms")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: rom.path), "fixture missing")
        try await runProgressAcrossTwoDevices(rom: rom, coreID: "mesen2")
    }

    @MainActor
    private func runProgressAcrossTwoDevices(rom counterROM: URL, coreID: CoreID) async throws {
        // 1. Device A: import, play to 2, save, sync.
        guard case .inserted(let gameA) = try await GameIngestion(store: a.store, location: a.location).ingestLocalFile(at: counterROM) else { return XCTFail() }
        await a.coordinator.flushSoon()
        let sessionA = PlaySession(gameID: gameA.id, coreID: coreID, startedAt: Date(), installationID: a.identity.installationID, deviceKind: .mac)
        try await a.store.playHistory.record(sessionA)
        let (runA, coreA) = try await a.launch(gameA)
        let base = try await bootCounter(runA)
        await pressA(runA); await pressA(runA)
        XCTAssertEqual(runA.batterySaveBytes()?[0], base &+ 2)
        try await a.save(runA, game: gameA, core: coreA, sessionRecord: sessionA)
        var t = Date()
        try await a.transport.pump()
        print("RELAY-MEASURE sync.push.ms=\(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) records=\(await cloud.saveCount)")
        let pendingA = try await a.store.syncStore.journal.pendingCount()
        XCTAssertEqual(pendingA, 0)
        let revisionRecord = await cloud.recordCount(ofType: .batteryRevision)
        XCTAssertEqual(revisionRecord, 1)
        if let stored = await cloud.record(.batteryRevision((try await a.battery.heads(for: gameA.id))[0].id)) {
            print("RELAY-MEASURE asset.battery.bytes=\(stored.assets[.data]?.count ?? 0)")
        }
        if let state = try await a.states.latestAutoResume(for: gameA.id), let stored = await cloud.record(.state(state.id)) {
            print("RELAY-MEASURE asset.state.bytes=\(stored.assets[.payload]?.count ?? 0)")
        }

        // 2. Device B: receives the library, the progress and the Auto Resume; no file yet.
        t = Date()
        try await b.transport.pump()
        print("RELAY-MEASURE sync.pull.apply.ms=\(String(format: "%.1f", Date().timeIntervalSince(t) * 1000))")
        let gameBOptional = try await b.store.games.game(fingerprint: gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        XCTAssertNotEqual(gameB.id, gameA.id, "own local id")
        let filesB = try await b.store.games.files(for: gameB.id)
        XCTAssertTrue(filesB.isEmpty, "metadata sync never brings the game file")
        XCTAssertEqual(try b.counter(gameB), base &+ 2, "battery progress adopted")
        let historyB = try await b.store.playHistory.recentlyPlayed(limit: 1).first
        XCTAssertEqual(historyB?.latestSession.deviceKind, .mac)
        let headB = try await b.store.saves.activeBatteryRevisionID(for: gameB.id)
        let autoB = try await b.states.latestAutoResume(for: gameB.id, activeRevision: headB)
        XCTAssertNotNil(autoB, "Auto Resume paired with the adopted head")
        XCTAssertTrue(autoB!.isRestorable(by: coreA))

        // B adds the same file (save-only continuity) and launches the same core:
        // it boots from A's progress, adds its own, saves and syncs.
        guard case .attached = try await GameIngestion(store: b.store, location: b.location).ingestLocalFile(at: counterROM) else { return XCTFail("expected attach") }
        let sessionB = PlaySession(gameID: gameB.id, coreID: coreID, startedAt: Date(), installationID: b.identity.installationID, deviceKind: .iPad)
        try await b.store.playHistory.record(sessionB)
        let (runB, coreB) = try await b.launch(gameB)
        let onB = await waitForCounter(runB, toReach: base &+ 3)
        XCTAssertEqual(onB?[0], base &+ 3, "the core on B continued from A's battery progress")
        // The Auto Resume from A restores on B's core (same core, same compatibility version).
        let bytes = try b.states.load(autoB!, game: gameB, for: coreB)
        try runB.restoreState(bytes)
        try await Task.sleep(for: .milliseconds(300))
        await pressA(runB)
        let afterPress = runB.batterySaveBytes()?[0]
        XCTAssertNotNil(afterPress)
        try await b.save(runB, game: gameB, core: coreB, sessionRecord: sessionB)
        try await b.transport.pump()
        try await a.transport.pump()
        let counterA = try a.counter(gameA)
        XCTAssertEqual(counterA, try b.counter(gameB), "A adopted B's progress safely")
        let headsA = try await a.battery.heads(for: gameA.id)
        XCTAssertEqual(headsA.count, 1)
        XCTAssertEqual(headsA[0].deviceKind, .iPad)
        let historyA = try await a.store.playHistory.recentlyPlayed(limit: 1).first
        XCTAssertEqual(historyA?.sessionCount, 2)
        XCTAssertEqual(historyA?.latestSession.deviceKind, .iPad)

        // 3. Divergence: both play from the same base without syncing, both save.
        // One at a time, as the product does: a device plays one game, and a
        // core may keep process-wide state (Mesen owns the save-folder override,
        // see Vendor/Mesen2/RelayBridge/README.md). Neither device syncs in
        // between, so both revisions still descend from the same head.
        let sA2 = PlaySession(gameID: gameA.id, coreID: coreID, startedAt: Date(), installationID: a.identity.installationID, deviceKind: .mac)
        let sB2 = PlaySession(gameID: gameB.id, coreID: coreID, startedAt: Date(), installationID: b.identity.installationID, deviceKind: .iPad)
        try await a.store.playHistory.record(sA2); try await b.store.playHistory.record(sB2)
        let (runA2, coreA2) = try await a.launch(gameA)
        _ = await waitForCounter(runA2, toReach: counterA &+ 1)
        await pressA(runA2)
        try await a.save(runA2, game: gameA, core: coreA2, sessionRecord: sA2)
        let (runB2, coreB2) = try await b.launch(gameB)
        _ = await waitForCounter(runB2, toReach: counterA &+ 1)
        await pressA(runB2); await pressA(runB2)
        try await b.save(runB2, game: gameB, core: coreB2, sessionRecord: sB2)
        let localA = try a.counter(gameA), localB = try b.counter(gameB)
        XCTAssertNotEqual(localA, localB)
        for _ in 0..<3 { try await a.transport.pump(); try await b.transport.pump() }
        let conflictA = await a.coordinator.conflict(for: gameA.id)
        let conflictB = await b.coordinator.conflict(for: gameB.id)
        XCTAssertNotNil(conflictA, "Two versions on A")
        XCTAssertNotNil(conflictB, "Two versions on B")
        XCTAssertEqual(try a.counter(gameA), localA, "nothing overwritten on A")
        XCTAssertEqual(try b.counter(gameB), localB, "nothing overwritten on B")
        // A keeps B's version.
        let keep = try XCTUnwrap(conflictA?.heads.first { $0.deviceKind == .iPad })
        try await a.coordinator.resolveConflict(gameID: gameA.id, keeping: keep.id)
        XCTAssertEqual(try a.counter(gameA), localB)
        for _ in 0..<3 { try await a.transport.pump(); try await b.transport.pump() }
        let afterA = await a.coordinator.conflict(for: gameA.id)
        let afterB = await b.coordinator.conflict(for: gameB.id)
        XCTAssertNil(afterA); XCTAssertNil(afterB)
        XCTAssertEqual(try b.counter(gameB), localB)
        let losing = try await a.battery.revisions(for: gameA.id).first { $0.deviceKind == .mac && (try? a.battery.verifiedData(of: $0))?[0] == localA }
        XCTAssertNotNil(losing, "the Mac version is kept as a previous version")
        // Launching A now continues from the kept version: the boot increment makes it localB + 1.
        let (runA3, coreA3) = try await a.launch(gameA)
        let resumed = await waitForCounter(runA3, toReach: localB &+ 1)
        XCTAssertEqual(resumed?[0], localB &+ 1)
        _ = coreA3
        runA3.stop()
        await a.coordinator.setGameplayActive(nil)
    }

    @MainActor
    func testGameplayFrameRateHoldsWhileSyncIsPending() async throws {
        guard case .inserted(let game) = try await GameIngestion(store: a.store, location: a.location).ingestLocalFile(at: Self.counterROM) else { return XCTFail() }
        let (session, core) = try await a.launch(game)
        _ = await waitForCounter(session, toReach: 0)
        try await Task.sleep(for: .seconds(1))
        let baseline = session.diagnostics.emulationFramesPerSecond
        // Sync activity during gameplay: journal writes (states every 100 ms) and the transport pumping every 50 ms.
        let memoryBefore = Self.residentBytes()
        let pumping = Task { [transport = a.transport] in
            for _ in 0..<40 { _ = try? await transport.pump(); try? await Task.sleep(for: .milliseconds(50)) }
        }
        var journalNanos: [UInt64] = []
        for i in 0..<20 {
            let payload = try session.captureState()
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await a.states.create(kind: .manual, game: game, core: core, payload: payload)
            journalNanos.append(DispatchTime.now().uptimeNanoseconds - started)
            if i % 5 == 0 { await a.coordinator.flushSoon() }
            try await Task.sleep(for: .milliseconds(100))
        }
        let during = session.diagnostics.emulationFramesPerSecond
        await pumping.value
        let memoryAfter = Self.residentBytes()
        session.stop()
        await a.coordinator.setGameplayActive(nil)
        // The pumping task runs on its own clock and stops before the last states
        // are written, so drain deliberately here: the property under test is that
        // everything queued during gameplay eventually leaves, not that a fixed
        // number of pumps happens to cover a fixed number of writes.
        for _ in 0..<20 where try await a.store.syncStore.journal.pendingCount() > 0 {
            await a.coordinator.flushSoon()
            _ = try? await a.transport.pump()
        }
        let pending = try await a.store.syncStore.journal.pendingCount()
        let uploaded = await cloud.recordCount(ofType: .state)
        print("RELAY-MEASURE fps.baseline=\(baseline) fps.duringSync=\(during) state.insert.avg.ms=\(String(format: "%.2f", Double(journalNanos.reduce(0, +)) / Double(journalNanos.count) / 1e6)) uploaded.states=\(uploaded) pending=\(pending) rss.before=\(memoryBefore) rss.after=\(memoryAfter)")
        XCTAssertGreaterThan(during, baseline * 0.9, "no material frame-rate regression while sync runs")
        XCTAssertEqual(pending, 0)
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

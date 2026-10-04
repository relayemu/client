// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
import RelayLibrary
@testable import RelaySync

final class GenerationBarrierTests: XCTestCase {
    private let millis: Int64 = 1_700_000_000_000
    private let scope = "generation.schema2"

    private func game(_ fp: ContentFingerprint, generation: Int64, system: String = "gba") -> SyncRecord {
        .game(SyncGameEntry(fingerprint: fp, systemID: system, title: "Generation", isFavorite: false,
                            addedAt: millis, updatedAt: millis, contentSize: nil, generation: generation))
    }
    private func retirement(_ fp: ContentFingerprint, generation: Int64) -> SyncRecord {
        .tombstone(SyncTombstone(targetKind: "game", targetKey: fp.canonicalString, deletedAt: millis,
                                 installationID: InstallationID(), generation: generation))
    }
    private func session(_ fp: ContentFingerprint, generation: Int64) -> SyncRecord {
        .session(SyncSession(sessionID: PlaySessionID(), fingerprint: fp, installationID: InstallationID(), deviceKind: "mac",
                             coreID: "fake", startedAt: millis, endedAt: millis + 1, pausedMs: 0, hasScreenshot: false, generation: generation))
    }
    private func changes(_ records: [SyncRecord]) -> [InboundChange] { records.map { InboundChange(key: $0.key, record: $0) } }

    func testPageRetirementPrecedesAllAssetsAndAcceptsOnlySuccessor() async throws {
        let device = try await SimulatedDevice(name: "barrier-page", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let fp = try SHA256ContentHasher().hash(data: gbaBytes(seed: 122)).fingerprint
        let staleBattery = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [],
            createdAt: millis + 100, dataFingerprint: fp, dataSize: 4, installationID: InstallationID(), deviceKind: "mac", hasScreenshot: false))
        let freshSession = session(fp, generation: 1)
        // Missing stale asset must never be read or poison this page; timestamps do not revive it.
        try await device.coordinator.applyHostedPage(changes: changes([staleBattery, game(fp, generation: 1), freshSession,
            game(fp, generation: 0), retirement(fp, generation: 0)]), deletions: [], cursor: 1, scope: scope)
        let current = try await device.game(fp)
        XCTAssertEqual(current?.generation, 1)
        if case .session(let s) = freshSession {
            let stored = try await device.store.playHistory.session(id: s.sessionID)
            XCTAssertEqual(stored?.generation, 1)
        }
        let cursor = try await device.coordinator.hostedCursor(scope: scope)
        XCTAssertEqual(cursor, 1)
        // Repeated older retirement must leave the successor intact.
        try await device.coordinator.applyHostedPage(changes: changes([retirement(fp, generation: 0), staleBattery]), deletions: [], cursor: 2, scope: scope)
        let preserved = try await device.game(fp)
        XCTAssertEqual(preserved?.id, current?.id)
    }

    func testFutureHistoryDefersUntilItsRetirementDependencyArrives() async throws {
        let device = try await SimulatedDevice(name: "future-generation", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let fp = try SHA256ContentHasher().hash(data: gbaBytes(seed: 123)).fingerprint
        let future = session(fp, generation: 2)
        try await device.coordinator.applyHostedPage(changes: changes([future]), deletions: [], cursor: 1, scope: scope)
        let pending = try await device.store.syncStore.deferredRecords()
        XCTAssertEqual(pending.count, 1)
        try await device.coordinator.applyHostedPage(changes: changes([game(fp, generation: 2), retirement(fp, generation: 1)]), deletions: [], cursor: 2, scope: scope)
        let remaining = try await device.store.syncStore.deferredRecords()
        XCTAssertTrue(remaining.isEmpty)
        if case .session(let s) = future {
            let stored = try await device.store.playHistory.session(id: s.sessionID)
            XCTAssertEqual(stored?.generation, 2)
        }
    }

    func testRetirementResolvesDeferredHistoryAndCleansInboxAssets() async throws {
        let device = try await SimulatedDevice(name: "retired-deferred", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let bytes = Data([1, 2, 3, 4])
        let fp = try SHA256ContentHasher().hash(data: gbaBytes(seed: 124)).fingerprint
        let hash = try SHA256ContentHasher().hash(data: bytes).fingerprint
        let asset = device.root.appending(path: "remote-battery")
        try bytes.write(to: asset)
        let battery = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [], createdAt: millis,
            dataFingerprint: hash, dataSize: 4, installationID: InstallationID(), deviceKind: "mac", hasScreenshot: false))
        try await device.coordinator.applyHostedPage(changes: [InboundChange(key: battery.key, record: battery, assets: [.data: asset])], deletions: [], cursor: 1, scope: scope)
        let deferred = try await device.store.syncStore.deferredRecords()
        let envelope = try JSONDecoder().decode(DeferredEnvelope.self, from: XCTUnwrap(deferred.first).payload)
        try await device.coordinator.applyHostedPage(changes: changes([retirement(fp, generation: 0), game(fp, generation: 1)]), deletions: [], cursor: 2, scope: scope)
        let remaining = try await device.store.syncStore.deferredRecords()
        XCTAssertTrue(remaining.isEmpty)
        for path in envelope.assets.values { XCTAssertFalse(FileManager.default.fileExists(atPath: device.location.syncInboxDirectory.appending(path: path).path)) }
        if case .batteryRevision(let r) = battery {
            let stored = try await device.store.saves.batteryRevision(id: r.revisionID)
            XCTAssertNil(stored)
        }
    }

    func testCrossGenerationParentsAndStatePairRejectBeforeInstallingAssets() async throws {
        let device = try await SimulatedDevice(name: "parent-membership", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let fp = try SHA256ContentHasher().hash(data: gbaBytes(seed: 126)).fingerprint
        let bytes = Data([9, 8, 7, 6])
        let hash = try SHA256ContentHasher().hash(data: bytes).fingerprint
        let parentID = BatteryRevisionID()
        let parent = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: parentID, fingerprint: fp, parentIDs: [], createdAt: millis,
            dataFingerprint: hash, dataSize: 4, installationID: InstallationID(), deviceKind: "mac", hasScreenshot: false))
        let asset = device.root.appending(path: "parent-data")
        try bytes.write(to: asset)
        try await device.coordinator.applyHostedPage(changes: changes([game(fp, generation: 0)]) + [InboundChange(key: parent.key, record: parent, assets: [.data: asset])],
            deletions: [], cursor: 1, scope: scope)
        let child = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [parentID], createdAt: millis,
            dataFingerprint: hash, dataSize: 4, installationID: InstallationID(), deviceKind: "mac", hasScreenshot: false, generation: 1))
        let state = SyncRecord.state(SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "auto", coreID: "fake", coreVersion: "1",
            stateCompatibilityVersion: "1", formatVersion: 2, createdAt: millis, payloadFingerprint: hash, payloadSize: 4,
            batteryRevisionID: parentID, installationID: InstallationID(), deviceKind: "mac", label: nil, hasScreenshot: false, generation: 1))
        let applier = RemoteApplier(store: device.store, syncStore: device.store.syncStore, location: device.location,
                                    saveStates: device.saveStates, identity: device.identity)
        let prepared = try await applier.prepare(changes: changes([retirement(fp, generation: 0), game(fp, generation: 1), parent, child, state]), deletions: [], now: device.clock.now)
        XCTAssertTrue(prepared.rejected.contains { $0.0 == child.key && $0.1.contains("another game generation") })
        XCTAssertTrue(prepared.rejected.contains { $0.0 == state.key && $0.1.contains("another game generation") })
        XCTAssertTrue(prepared.installedFiles.isEmpty)
        XCTAssertTrue(prepared.batch.revisions.isEmpty)
        XCTAssertTrue(prepared.batch.states.isEmpty)
    }

    func testConcurrentReimportsUseSameSuccessorAndKeepBothHistories() async throws {
        let cloud = InMemoryCloud(), clock = TestClock()
        let a = try await SimulatedDevice(name: "reimport-a", kind: .mac, cloud: cloud, clock: clock)
        let b = try await SimulatedDevice(name: "reimport-b", kind: .iPhone, cloud: cloud, clock: clock)
        defer { a.destroy(); b.destroy() }
        await a.start(); await b.start()
        let bytes = gbaBytes(seed: 127)
        let original = try await a.importGame(bytes)
        try await a.play(original, battery: Data([0]))
        try await a.sync(); try await b.sync()
        try await a.store.games.deleteGame(id: original.id)
        await a.coordinator.flushSoon()
        try await a.sync(); try await b.sync()
        let removedA = try await a.game(original.contentFingerprint)
        let removedB = try await b.game(original.contentFingerprint)
        XCTAssertNil(removedA); XCTAssertNil(removedB)
        // Both devices explicitly reimport while neither has observed the other's import.
        let freshA = try await a.importGame(bytes, title: "A")
        let freshB = try await b.importGame(bytes, title: "B")
        XCTAssertEqual(freshA.generation, 1); XCTAssertEqual(freshB.generation, 1)
        try await a.play(freshA, battery: Data([1]))
        try await b.play(freshB, battery: Data([2]))
        try await a.sync(); try await b.sync(); try await a.sync(); try await b.sync()
        for (device, game) in [(a, freshA), (b, freshB)] {
            let revisions = try await device.store.saves.batteryRevisions(for: game.id)
            let sessions = try await device.store.playHistory.sessions(for: game.id, limit: 20)
            XCTAssertEqual(revisions.count, 2)
            XCTAssertEqual(sessions.count, 2)
            XCTAssertTrue(revisions.allSatisfy { $0.generation == 1 })
            XCTAssertTrue(sessions.allSatisfy { $0.generation == 1 })
            let current = try await device.game(game.contentFingerprint)
            XCTAssertEqual(current?.generation, 1)
        }
    }

    func testStateTombstoneSuppressesReplayRegardlessOfCreationTime() async throws {
        let device = try await SimulatedDevice(name: "permanent-state-delete", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let fp = try SHA256ContentHasher().hash(data: gbaBytes(seed: 128)).fingerprint
        let id = SaveStateID()
        let deleted = SyncRecord.tombstone(SyncTombstone(targetKind: "state", targetKey: id.description, deletedAt: millis,
                                                        installationID: InstallationID(), generation: 0, gameFingerprint: fp))
        let stale = SyncRecord.state(SyncSaveState(stateID: id, fingerprint: fp, kind: "quick", coreID: "fake", coreVersion: "1",
            stateCompatibilityVersion: "1", formatVersion: 2, createdAt: millis + 60_000, payloadFingerprint: fp, payloadSize: 4,
            batteryRevisionID: nil, installationID: InstallationID(), deviceKind: "mac", label: nil, hasScreenshot: false))
        // An absent payload proves UUID suppression is checked before asset validation.
        try await device.coordinator.applyHostedPage(changes: changes([game(fp, generation: 0), stale, deleted]), deletions: [], cursor: 1, scope: scope)
        try await device.coordinator.applyHostedPage(changes: changes([stale]), deletions: [], cursor: 2, scope: scope)
        let state = try await device.store.saves.saveState(id: id)
        XCTAssertNil(state)
        let cursor = try await device.coordinator.hostedCursor(scope: scope)
        XCTAssertEqual(cursor, 2)
    }

    func testLegacyUploadedReimportHistoryMigratesWithOldRecordsFirst() async throws {
        try await verifyLegacyUploadedHistoryMigration(reverseDelivery: false)
    }

    func testLegacyUploadedReimportHistoryMigratesWithNewRecordsFirst() async throws {
        try await verifyLegacyUploadedHistoryMigration(reverseDelivery: true)
    }

    private func verifyLegacyUploadedHistoryMigration(reverseDelivery: Bool) async throws {
        let cloud = InMemoryCloud(), clock = TestClock()
        let author = try await SimulatedDevice(name: "migrated-author", kind: .mac, cloud: cloud, clock: clock)
        defer { author.destroy() }
        let bytes = gbaBytes(seed: 129)
        let original = try await author.importGame(bytes)
        try await author.store.games.deleteGame(id: original.id)
        let migrated = try await author.importGame(bytes)
        let authoredSession = try await author.play(migrated, battery: Data([31, 32]))
        let pending = try await author.store.syncStore.journal.pending(limit: 100)
        let built = await OutboundBuilder(store: author.store, syncStore: author.store.syncStore,
            location: author.location, identity: author.identity).build(from: pending)
        var legacyRecords: [SyncRecord] = []
        var canonicalHistory: [SyncRecord] = []
        // Seed the already-uploaded schema-1 representation of the surviving
        // post-delete history. SQLite's v6 fixture separately proves that these
        // FK-owned canonical rows migrate to generation 1 without changing UUIDs.
        for change in built.changes {
            guard case .save(let record, let urls) = change.payload else { continue }
            let legacy: SyncRecord
            switch record {
            case .game(var value): value.schema = 1; value.generation = 0; legacy = .game(value)
            case .session(var value): value.schema = 1; value.generation = 0; legacy = .session(value); canonicalHistory.append(record)
            case .batteryRevision(var value): value.schema = 1; value.generation = 0; legacy = .batteryRevision(value); canonicalHistory.append(record)
            case .state(var value): value.schema = 1; value.generation = 0; legacy = .state(value); canonicalHistory.append(record)
            default: continue
            }
            var assets: [SyncAssetName: Data] = [:]
            for (name, url) in urls { assets[name] = try Data(contentsOf: url) }
            await cloud.overwrite(legacy.key, record: legacy, assets: assets)
            legacyRecords.append(legacy)
        }
        XCTAssertEqual(canonicalHistory.count, 3)
        try await author.store.syncStore.journal.complete(pending.map(\.id))
        try await author.store.syncStore.setMetaValue("account-a", forKey: SyncMetaKey.accountIdentity)
        try await author.store.syncStore.setMetaValue("1", forKey: SyncMetaKey.reconciled)
        await author.start()
        try await author.sync()
        let outstanding = try await author.pendingCount()
        XCTAssertEqual(outstanding, 0)
        for record in canonicalHistory {
            let uploaded = await cloud.record(record.key)
            XCTAssertEqual(uploaded?.record, record, "Canonical generation-1 history is independently addressable")
        }
        for legacy in legacyRecords {
            let preserved = await cloud.record(legacy.key)
            XCTAssertEqual(preserved?.record, legacy, "Legacy generation-0 objects are never overwritten or relabelled")
        }
        let receiver = try await SimulatedDevice(name: "migration-receiver", kind: .iPhone, cloud: cloud, clock: clock)
        defer { receiver.destroy() }
        await receiver.start()
        if reverseDelivery { await cloud.reorderNextDelivery(for: receiver.name) }
        try await receiver.sync()
        let received = try await receiver.game(migrated.contentFingerprint)
        let game = try XCTUnwrap(received)
        XCTAssertEqual(game.generation, 1)
        XCTAssertEqual(try receiver.currentBattery(game), Data([31, 32]))
        let revisions = try await receiver.store.saves.batteryRevisions(for: game.id)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.generation, 1)
        XCTAssertEqual(revisions.first?.installationID, author.identity.installationID)
        let receivedSession = try await receiver.store.playHistory.session(id: authoredSession.id)
        XCTAssertEqual(receivedSession?.generation, 1)
        XCTAssertEqual(receivedSession?.installationID, author.identity.installationID)
        let states = try await receiver.saveStates.states(for: game.id)
        let state = try XCTUnwrap(states.first)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(state.generation, 1)
        XCTAssertEqual(state.batteryRevisionID, revisions.first?.id)
        XCTAssertEqual(state.installationID, author.identity.installationID)
        XCTAssertEqual(try receiver.saveStates.load(state, game: game, for: fakeCore), Data("auto-31.32".utf8))
        let deferred = await receiver.coordinator.deferredCount()
        XCTAssertEqual(deferred, 0)
    }

    func testClassificationConflictRejectsPageBeforeHistory() async throws {
        let device = try await SimulatedDevice(name: "classification", kind: .mac, cloud: InMemoryCloud(), clock: TestClock())
        defer { device.destroy() }
        await device.start()
        let fp = try SHA256ContentHasher().hash(data: gbaBytes(seed: 125)).fingerprint
        try await device.coordinator.applyHostedPage(changes: changes([game(fp, generation: 0)]), deletions: [], cursor: 1, scope: scope)
        do {
            try await device.coordinator.applyHostedPage(changes: changes([game(fp, generation: 0, system: "gbc"), session(fp, generation: 0)]), deletions: [], cursor: 2, scope: scope)
            XCTFail("Classification mutation must reject the page")
        } catch { XCTAssertEqual(error as? SyncPageError, .rejectedRecords) }
        let current = try await device.game(fp)
        XCTAssertEqual(current?.systemID.rawValue, "gba")
        let cursor = try await device.coordinator.hostedCursor(scope: scope)
        XCTAssertEqual(cursor, 1)
    }
}

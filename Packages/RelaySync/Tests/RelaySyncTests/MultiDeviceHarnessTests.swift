// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MultiDeviceHarnessTests.swift — the deterministic multi-device harness

import XCTest
import RelayDomain
import RelayLibrary
import RelayPersistence
@testable import RelaySync

final class MultiDeviceHarnessTests: XCTestCase {
    var cloud: InMemoryCloud!
    var clock: TestClock!
    var a: SimulatedDevice!
    var b: SimulatedDevice!
    let content = gbaBytes(seed: 0x11)

    override func setUp() async throws {
        cloud = InMemoryCloud()
        clock = TestClock()
        a = try await SimulatedDevice(name: "iphone", kind: .iPhone, cloud: cloud, clock: clock)
        b = try await SimulatedDevice(name: "tv", kind: .appleTV, cloud: cloud, clock: clock)
        await a.start(); await b.start()
    }

    override func tearDown() { a.destroy(); b.destroy() }

    /// Both devices exchange everything (bounded rounds).
    private func converge(_ devices: [SimulatedDevice]? = nil, rounds: Int = 4) async throws {
        for _ in 0..<rounds { for d in devices ?? [a, b] { try await d.sync() } }
    }

    // MARK: A uploads, B receives; Continue proof (save-only)

    func testAUploadsBReceivesLibraryProgressAndContinues() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]), seconds: 90)
        try await a.sync()
        let pendingA = try await a.pendingCount()
        XCTAssertEqual(pendingA, 0, "everything acknowledged")
        try await b.sync()
        // B has the logical game with its own GameID, no content (cloud-only or on another device).
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        XCTAssertNotEqual(gameB.id, gameA.id)
        XCTAssertEqual(gameB.title, "Counter")
        let observed1 = try await b.hasContent(gameB)
        XCTAssertFalse(observed1)
        let statusB = await b.coordinator.gameStatus(gameB, hasLocalContent: false)
        XCTAssertEqual(statusB, .onAnotherDevice, "no content index: the file is on another device")
        // Progress arrived: session from iPhone, battery head adopted, Auto Resume paired with it.
        let historyOptional = try await b.history(gameB)
        let history = try XCTUnwrap(historyOptional)
        XCTAssertEqual(history.latestSession.deviceKind, .iPhone)
        XCTAssertEqual(history.latestSession.origin, .remote)
        XCTAssertEqual(history.totalPlayDuration, 90)
        XCTAssertEqual(try b.currentBattery(gameB), Data([1]))
        let headB = try await b.store.saves.activeBatteryRevisionID(for: gameB.id)
        let auto = try await b.saveStates.latestAutoResume(for: gameB.id, activeRevision: headB)
        XCTAssertNotNil(auto)
        XCTAssertEqual(auto?.origin, .remote)
        XCTAssertTrue(auto!.isRestorable(by: fakeCore))
        XCTAssertEqual(try b.saveStates.load(auto!, game: gameB, for: fakeCore), Data("auto-1".utf8))
        // B imports the same content itself (save-only continuity) and continues: B's progress returns to A safely.
        _ = try await b.importGame(content, title: "Counter")
        let observed2 = try await b.hasContent(gameB)
        XCTAssertTrue(observed2)
        try await b.play(gameB, battery: Data([2]), seconds: 30)
        try await converge()
        XCTAssertEqual(try a.currentBattery(gameA), Data([2]))
        let headsA = try await a.heads(gameA)
        XCTAssertEqual(headsA.count, 1)
        XCTAssertEqual(headsA[0].deviceKind, .appleTV)
        let historyAOptional = try await a.history(gameA)
        let historyA = try XCTUnwrap(historyAOptional)
        XCTAssertEqual(historyA.sessionCount, 2)
        XCTAssertEqual(historyA.totalPlayDuration, 120)
        XCTAssertEqual(historyA.latestSession.deviceKind, .appleTV)
        let conflicts = await a.status.conflictGameIDs
        XCTAssertTrue(conflicts.isEmpty)
        let cloudRecords = await cloud.recordCount(ofType: .batteryRevision)
        XCTAssertEqual(cloudRecords, 2)
    }

    func testLaunchGraceNeverWaitsWhenNoFetchIsInFlight() async throws {
        // Local-first policy: with no fetch running the grace is a no-op, whatever the budget.
        let started = Date()
        await a.coordinator.graceForInFlightFetch(maxWait: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "a game that is playable here never waits for the network")
        let status = await a.status
        XCTAssertFalse(status.isFetching)
    }

    // MARK: Delivery faults

    func testDuplicateAndOutOfOrderDeliveryAreIdempotent() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]))
        try await a.play(gameA, battery: Data([2]))
        try await a.sync()
        await cloud.duplicateNextDelivery(for: "tv")
        try await b.sync()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        var revisions = try await b.store.saves.batteryRevisions(for: gameB.id)
        XCTAssertEqual(revisions.count, 2)
        var sessions = try await b.store.playHistory.sessions(for: gameB.id, limit: 10)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(try b.currentBattery(gameB), Data([2]))
        // A third device receives everything reversed.
        let c = try await SimulatedDevice(name: "mac", kind: .mac, cloud: cloud, clock: clock)
        defer { c.destroy() }
        await c.start()
        await cloud.reorderNextDelivery(for: "mac")
        try await c.sync()
        let gameCOptional = try await c.game(gameA.contentFingerprint)
        let gameC = try XCTUnwrap(gameCOptional)
        revisions = try await c.store.saves.batteryRevisions(for: gameC.id)
        XCTAssertEqual(revisions.count, 2)
        sessions = try await c.store.playHistory.sessions(for: gameC.id, limit: 10)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(try c.currentBattery(gameC), Data([2]))
        let headsC = try await c.heads(gameC)
        XCTAssertEqual(headsC.count, 1)
        let deferred = await c.coordinator.deferredCount()
        XCTAssertEqual(deferred, 0)
    }

    func testRestartWithPendingOutboxAndOfflineUploadsLater() async throws {
        await cloud.setOffline("iphone", true)
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]))
        await XCTAssertThrowsErrorAsync(try await a.sync()) { _ in }
        let pendingBefore = try await a.pendingCount()
        XCTAssertGreaterThan(pendingBefore, 0)
        let statusOffline = await a.status
        XCTAssertEqual(statusOffline.problem, .network)
        XCTAssertEqual(statusOffline.pendingCount, pendingBefore)
        a = try await a.restart()
        let pendingAfterRestart = try await a.pendingCount()
        XCTAssertEqual(pendingAfterRestart, pendingBefore, "the journal survives a restart")
        await cloud.setOffline("iphone", false)
        try await a.sync()
        let pendingA = try await a.pendingCount()
        XCTAssertEqual(pendingA, 0)
        let statusOnline = await a.status
        XCTAssertNil(statusOnline.problem)
        try await b.sync()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        XCTAssertEqual(try b.currentBattery(gameB), Data([1]))
    }

    func testCrashAfterServerSaveBeforeAcknowledgementReplaysIdempotently() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]))
        a.transport.dropNextSendResults = true
        try await a.sync()
        let stillPending = try await a.pendingCount()
        XCTAssertGreaterThan(stillPending, 0, "results were lost: the journal keeps the intents")
        a = try await a.restart()   // the process died; nothing is in flight any more
        try await a.sync()   // server already has the records: identical → accepted
        let pendingA = try await a.pendingCount()
        XCTAssertEqual(pendingA, 0)
        let records = await cloud.recordCount(ofType: .batteryRevision)
        XCTAssertEqual(records, 1)
        // Crash after apply, before the cursor advanced: the fetch replays and nothing duplicates.
        b.transport.replayNextFetch = true
        try await b.sync()
        try await b.sync()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        let sessions = try await b.store.playHistory.sessions(for: gameB.id, limit: 10)
        XCTAssertEqual(sessions.count, 1)
        let revisions = try await b.store.saves.batteryRevisions(for: gameB.id)
        XCTAssertEqual(revisions.count, 1)
        let all = try await b.store.games.allGames()
        XCTAssertEqual(all.count, 1)
    }

    // MARK: Identity

    func testSameFingerprintDifferentGameIDsReconcileWithoutDuplicates() async throws {
        let gameA = try await a.importGame(content, title: "Counter A")
        let gameB = try await b.importGame(content, title: "Counter B")
        XCTAssertNotEqual(gameA.id, gameB.id)
        try await converge()
        let allA = try await a.store.games.allGames()
        let allB = try await b.store.games.allGames()
        XCTAssertEqual(allA.count, 1); XCTAssertEqual(allB.count, 1)
        XCTAssertEqual(allA[0].id, gameA.id, "local ids never change")
        XCTAssertEqual(allB[0].id, gameB.id)
        XCTAssertEqual(allA[0].title, allB[0].title, "entries merged by last write")
        let entries = await cloud.recordCount(ofType: .game)
        XCTAssertEqual(entries, 1)
        // Favourite toggled on A reaches B.
        var favourite = allA[0]; favourite.isFavorite = true; favourite.updatedAt = clock.now.addingTimeInterval(1)
        try await a.store.games.update(favourite)
        try await converge()
        let onB = try await b.store.games.game(id: gameB.id)
        XCTAssertEqual(onB?.isFavorite, true)
    }

    // MARK: Divergence → Two versions

    func testOfflineDivergenceProducesTwoVersionsAndResolutionConverges() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]))
        try await converge()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        _ = try await b.importGame(content)
        XCTAssertEqual(try b.currentBattery(gameB), Data([1]))
        // Both play offline from the same base.
        await cloud.setOffline("iphone", true); await cloud.setOffline("tv", true)
        try await a.play(gameA, battery: Data([2]))
        try await b.play(gameB, battery: Data([3]))
        await cloud.setOffline("iphone", false); await cloud.setOffline("tv", false)
        try await converge()
        for (device, game) in [(a!, gameA), (b!, gameB)] {
            let heads = try await device.heads(game)
            XCTAssertEqual(heads.count, 2, "\(device.name) sees two versions")
            let conflict = await device.coordinator.conflict(for: game.id)
            XCTAssertNotNil(conflict)
            let status = await device.status
            XCTAssertEqual(status.conflictGameIDs, [game.id])
            let gameStatus = await device.coordinator.gameStatus(game, hasLocalContent: true)
            XCTAssertEqual(gameStatus, .conflict)
        }
        XCTAssertEqual(try a.currentBattery(gameA), Data([2]), "nothing overwritten on A")
        XCTAssertEqual(try b.currentBattery(gameB), Data([3]), "nothing overwritten on B")
        // The player keeps the Apple TV version on the iPhone.
        let headsA = try await a.heads(gameA)
        let tvHead = try XCTUnwrap(headsA.first { $0.deviceKind == .appleTV })
        try await a.coordinator.resolveConflict(gameID: gameA.id, keeping: tvHead.id)
        XCTAssertEqual(try a.currentBattery(gameA), Data([3]))
        try await converge()
        for (device, game) in [(a!, gameA), (b!, gameB)] {
            let heads = try await device.heads(game)
            XCTAssertEqual(heads.count, 1, "\(device.name) converged")
            XCTAssertEqual(heads[0].parentIDs.count, 2)
            XCTAssertEqual(try device.currentBattery(game), Data([3]))
            let status = await device.status
            XCTAssertTrue(status.conflictGameIDs.isEmpty)
            // The losing iPhone branch is still there with its bytes.
            let losing = try await device.batterySaves.revisions(for: game.id).first { $0.deviceKind == .iPhone && $0.parentIDs.count == 1 && $0.dataFingerprint != heads[0].dataFingerprint }
            XCTAssertNotNil(losing, "\(device.name) keeps the other version")
            XCTAssertEqual(try device.batterySaves.verifiedData(of: losing!), Data([2]))
        }
        // previous.sav on A is the local rollback of the last write, untouched by the cloud logic.
        XCTAssertEqual(try Data(contentsOf: a.batterySaves.previousSnapshotURL(for: gameA.id)!), Data([2]))
    }

    func testConcurrentResolutionsWithTheSameChoiceJoinAutomatically() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]))
        try await converge()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        _ = try await b.importGame(content)
        await cloud.setOffline("iphone", true); await cloud.setOffline("tv", true)
        try await a.play(gameA, battery: Data([2]))
        try await b.play(gameB, battery: Data([3]))
        await cloud.setOffline("iphone", false); await cloud.setOffline("tv", false)
        try await converge()
        let keepAOptional = try await a.heads(gameA).first { $0.deviceKind == .appleTV }
        let keepA = try XCTUnwrap(keepAOptional)
        let keepBOptional = try await b.heads(gameB).first { $0.deviceKind == .appleTV }
        let keepB = try XCTUnwrap(keepBOptional)
        try await a.coordinator.resolveConflict(gameID: gameA.id, keeping: keepA.id)
        try await b.coordinator.resolveConflict(gameID: gameB.id, keeping: keepB.id)
        try await converge(rounds: 6)
        for (device, game) in [(a!, gameA), (b!, gameB)] {
            let heads = try await device.heads(game)
            XCTAssertEqual(heads.count, 1, "identical merges joined on \(device.name)")
            XCTAssertEqual(try device.currentBattery(game), Data([3]))
        }
    }

    // MARK: Deletion

    func testTombstoneBeatsStaleUploadAndRemoveDownloadIsLocalOnly() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]))
        try await converge()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        _ = try await b.importGame(content)
        // B goes offline and keeps playing; A deletes the game everywhere.
        await cloud.setOffline("tv", true)
        try await b.play(gameB, battery: Data([2]))
        try await a.ingestion.remove(gameID: gameA.id)
        await a.coordinator.flushSoon()
        try await a.sync()
        let tombstones = await cloud.recordCount(ofType: .tombstone)
        XCTAssertEqual(tombstones, 1)
        await cloud.setOffline("tv", false)
        try await converge()
        let onB = try await b.game(gameA.contentFingerprint)
        XCTAssertNil(onB, "the stale device applied the deletion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.location.directory(forGame: gameB.id).path))
        let onA = try await a.game(gameA.contentFingerprint)
        XCTAssertNil(onA, "B's stale upload never resurrected the game on A")
        // Re-importing after the deletion is legitimate and syncs again.
        clock.advance(10)
        let again = try await a.importGame(content, title: "Counter again")
        XCTAssertEqual(again.generation, gameA.generation + 1)
        try await converge()
        let onBAgain = try await b.game(again.contentFingerprint)
        XCTAssertEqual(onBAgain?.title, "Counter again")
        // Remove Download on B keeps the library entry, the saves and the cloud untouched.
        _ = try await b.importGame(content)
        let gameB2Optional = try await b.game(again.contentFingerprint)
        let gameB2 = try XCTUnwrap(gameB2Optional)
        try await b.play(gameB2, battery: Data([5]))
        try await b.ingestion.removeLocalContent(gameID: gameB2.id)
        let observed3 = try await b.hasContent(gameB2)
        XCTAssertFalse(observed3)
        let stillThere = try await b.game(again.contentFingerprint)
        XCTAssertNotNil(stillThere)
        XCTAssertEqual(try b.currentBattery(gameB2), Data([5]), "saves stay")
        let entries = await cloud.recordCount(ofType: .game)
        XCTAssertEqual(entries, 2, "The retired initial record and successor use distinct immutable membership keys")
        let pendingB = try await b.pendingCount()
        try await converge()
        _ = pendingB
        let onA2 = try await a.game(again.contentFingerprint)
        XCTAssertNotNil(onA2, "no tombstone was emitted by Remove Download")
    }

    func testManualStatesUnionAndManualDeletionTombstones() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        try await converge()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        let stateA = try await a.saveStates.create(kind: .manual, game: gameA, core: fakeCore, payload: Data("manual-a".utf8), now: clock.now)
        let stateB = try await b.saveStates.create(kind: .manual, game: gameB, core: fakeCore, payload: Data("manual-b".utf8), now: clock.now)
        let incompatible = try await b.saveStates.create(kind: .manual, game: gameB, core: otherCore, payload: Data("manual-b2".utf8), now: clock.now)
        await a.coordinator.flushSoon(); await b.coordinator.flushSoon()
        try await converge()
        let onA = try await a.saveStates.browserStates(for: gameA.id).manual
        let onB = try await b.saveStates.browserStates(for: gameB.id).manual
        XCTAssertEqual(Set(onA.map(\.id)), [stateA.id, stateB.id, incompatible.id])
        XCTAssertEqual(Set(onB.map(\.id)), [stateA.id, stateB.id, incompatible.id])
        let remoteOnA = try XCTUnwrap(onA.first { $0.id == stateB.id })
        XCTAssertEqual(remoteOnA.origin, .remote)
        XCTAssertEqual(remoteOnA.deviceKind, .appleTV)
        XCTAssertEqual(try a.saveStates.load(remoteOnA, game: gameA, for: fakeCore), Data("manual-b".utf8))
        let incompatibleOnA = try XCTUnwrap(onA.first { $0.id == incompatible.id })
        XCTAssertFalse(incompatibleOnA.isRestorable(by: fakeCore), "stored, listed, refused")
        XCTAssertThrowsError(try a.saveStates.load(incompatibleOnA, game: gameA, for: fakeCore))
        // Deleting a manual state on A tombstones it; B does not resurrect it.
        try await a.saveStates.delete(remoteOnA)
        await a.coordinator.flushSoon()
        try await converge()
        let afterB = try await b.saveStates.browserStates(for: gameB.id).manual
        XCTAssertFalse(afterB.contains { $0.id == stateB.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.location.url(for: stateB.location).path))
        let tombstone = try await b.store.syncStore.tombstone(for: .saveState(stateB.id))
        XCTAssertNotNil(tombstone)
    }

    func testAutoResumeConvergesOnlyWithItsBatteryHead() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]))
        try await converge()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        _ = try await b.importGame(content)
        let headB = try await b.store.saves.activeBatteryRevisionID(for: gameB.id)
        let autoFromA = try await b.saveStates.latestAutoResume(for: gameB.id, activeRevision: headB)
        XCTAssertEqual(autoFromA?.deviceKind, .iPhone)
        // A diverging auto state (paired with a head that is not ours) is never offered.
        await cloud.setOffline("tv", true)
        try await a.play(gameA, battery: Data([2]))
        try await b.play(gameB, battery: Data([3]))
        await cloud.setOffline("tv", false)
        try await converge()
        let headB2 = try await b.store.saves.activeBatteryRevisionID(for: gameB.id)
        let offered = try await b.saveStates.latestAutoResume(for: gameB.id, activeRevision: headB2)
        XCTAssertEqual(offered?.deviceKind, .appleTV, "only the state paired with the local head")
        let newest = try await b.saveStates.latestAutoResume(for: gameB.id)
        XCTAssertEqual(newest?.deviceKind, .appleTV, "A's newer auto state is not paired with B's head")
        let anyIPhone = try await b.store.saves.saveStates(for: gameB.id).contains { $0.kind == .auto && $0.deviceKind == .iPhone && $0.batteryRevisionID != headB2 }
        XCTAssertTrue(anyIPhone, "kept, just not offered")
    }

    // MARK: Cloud behaviour

    func testQuotaFullKeepsProgressLocalAndReportsHonestly() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        await cloud.setQuotaFull(true)
        try await a.play(gameA, battery: Data([1]))
        try await a.sync()
        let status = await a.status
        XCTAssertEqual(status.problem, .quotaFull)
        XCTAssertNotNil(status.problemSince)
        XCTAssertGreaterThan(status.pendingCount, 0)
        XCTAssertNil(status.lastPushAt, "never claim a push that did not happen")
        let gameStatus = await a.coordinator.gameStatus(gameA, hasLocalContent: true)
        guard case .pending = gameStatus else { return XCTFail("\(gameStatus)") }
        XCTAssertEqual(try a.currentBattery(gameA), Data([1]))
        await cloud.setQuotaFull(false)
        try await a.sync()
        let recovered = await a.status
        XCTAssertNil(recovered.problem)
        XCTAssertEqual(recovered.pendingCount, 0)
        XCTAssertNotNil(recovered.lastPushAt)
        let upToDate = await a.coordinator.gameStatus(gameA, hasLocalContent: true)
        XCTAssertEqual(upToDate, .upToDate)
    }

    func testAccountChangeFreezesUntilTheOwnerDecides() async throws {
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.sync()
        await cloud.setAccountIdentity("account-b")
        await cloud.clear()
        a = try await a.restart()
        let frozen = await a.status
        XCTAssertTrue(frozen.accountChangePending)
        XCTAssertFalse(frozen.isActive)
        try await a.play(gameA, battery: Data([1]))
        await XCTAssertThrowsErrorAsync(try await a.sync()) { _ in }
        let uploaded = await cloud.recordCount(ofType: .game)
        XCTAssertEqual(uploaded, 0, "nothing leaks into the new account")
        await a.coordinator.acceptAccountChange(identityHash: "account-b")
        let accepted = await a.status
        XCTAssertFalse(accepted.accountChangePending)
        XCTAssertTrue(accepted.isActive)
        try await a.sync()
        let entries = await cloud.recordCount(ofType: .game)
        XCTAssertEqual(entries, 1)
        let revisions = await cloud.recordCount(ofType: .batteryRevision)
        XCTAssertEqual(revisions, 1, "the whole library was reconciled into the new account after consent")
        let stored = try await a.store.syncStore.metaValue(forKey: SyncMetaKey.accountIdentity)
        XCTAssertEqual(stored, "account-b")
        // Declining leaves sync off.
        await cloud.setAccountIdentity("account-c")
        a = try await a.restart()
        await a.coordinator.declineAccountChange()
        let declined = await a.status
        XCTAssertFalse(declined.isEnabled)
        XCTAssertFalse(declined.isActive)
    }

    func testDisabledSyncKeepsLocalPlayFullyFunctional() async throws {
        await a.coordinator.setEnabled(false)
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]))
        let states = try await a.saveStates.states(for: gameA.id)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(try a.currentBattery(gameA), Data([1]))
        await XCTAssertThrowsErrorAsync(try await a.sync()) { XCTAssertEqual($0 as? SyncTransportError, .notStarted) }
        let status = await a.status
        XCTAssertFalse(status.isActive)
        let gameStatus = await a.coordinator.gameStatus(gameA, hasLocalContent: true)
        XCTAssertEqual(gameStatus, .localOnly)
        await a.coordinator.setEnabled(true)
        try await a.sync()
        let records = await cloud.recordCount(ofType: .batteryRevision)
        XCTAssertEqual(records, 1, "re-enabling reconciles the library")
    }

    // MARK: Game content (Free opt-in, on demand)

    func testGameContentIsUploadedOnceAndDownloadedOnDemandWithVerification() async throws {
        await a.coordinator.setGameFilesEnabled(true)
        await b.coordinator.setGameFilesEnabled(true)
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.play(gameA, battery: Data([1]))
        try await a.coordinator.uploadContent(gameID: gameA.id)
        let saves = await cloud.contentUploadCount
        try await a.coordinator.uploadContent(gameID: gameA.id)
        let savesAgain = await cloud.contentUploadCount
        XCTAssertEqual(saves, savesAgain, "the same fingerprint is never uploaded twice")
        try await converge()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        let observed4 = try await b.hasContent(gameB)
        XCTAssertFalse(observed4, "metadata sync never downloads content")
        let status = await b.coordinator.gameStatus(gameB, hasLocalContent: false)
        XCTAssertEqual(status, .cloudOnly(size: Int64(content.count)))
        let summary = await b.status
        XCTAssertEqual(summary.cloudOnlyCount, 1)
        XCTAssertEqual(summary.approximateCloudBytes, Int64(content.count))
        // Download & Play: verified, installed, launchable.
        let file = try await b.coordinator.downloadContent(gameID: gameB.id, ingestion: b.ingestion)
        XCTAssertEqual(file.fingerprint, gameA.contentFingerprint)
        let observed5 = try await b.hasContent(gameB)
        XCTAssertTrue(observed5)
        let resolved = try await GameLaunchResolver(store: b.store, location: b.location, availableCores: [fakeCore]).resolve(gameID: gameB.id)
        XCTAssertEqual(try Data(contentsOf: resolved.contentURL), content)
        XCTAssertEqual(try b.currentBattery(gameB), Data([1]), "progress was already there")
        let inbox = (try? FileManager.default.contentsOfDirectory(atPath: b.location.syncInboxDirectory.path)) ?? []
        XCTAssertTrue(inbox.isEmpty, "staging cleaned")
        // B does not re-upload what exists.
        try await b.coordinator.uploadContent(gameID: gameB.id)
        let savesAfterB = await cloud.contentUploadCount
        XCTAssertEqual(savesAfterB, saves)
    }

    func testCorruptedContentIsRejectedAndInterruptedDownloadIsRetryable() async throws {
        await a.coordinator.setGameFilesEnabled(true)
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.coordinator.uploadContent(gameID: gameA.id)
        try await converge()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        let key = RecordKey.gameContent(gameA.contentFingerprint, part: 0)
        let storedRecord = await cloud.record(key)
        let stored = try XCTUnwrap(storedRecord)
        var corrupt = content; corrupt[100] ^= 0xFF
        await cloud.overwrite(key, record: stored.record, assets: [.data: corrupt])
        await XCTAssertThrowsErrorAsync(try await b.coordinator.downloadContent(gameID: gameB.id, ingestion: b.ingestion)) {
            XCTAssertEqual($0 as? SyncContentError, .verificationFailed)
        }
        let observed6 = try await b.hasContent(gameB)
        XCTAssertFalse(observed6, "nothing installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.location.directory(forGame: gameB.id).path))
        let failed = await b.coordinator.gameStatus(gameB, hasLocalContent: false)
        XCTAssertEqual(failed, .failed(.failed("download")))
        // Interrupted (offline) download, then a retry succeeds once the content is right again.
        await cloud.overwrite(key, record: stored.record, assets: [.data: content])
        await cloud.setOffline("tv", true)
        await XCTAssertThrowsErrorAsync(try await b.coordinator.downloadContent(gameID: gameB.id, ingestion: b.ingestion)) { _ in }
        await cloud.setOffline("tv", false)
        _ = try await b.coordinator.downloadContent(gameID: gameB.id, ingestion: b.ingestion)
        let observed7 = try await b.hasContent(gameB)
        XCTAssertTrue(observed7)
        let ok = await b.coordinator.gameStatus(gameB, hasLocalContent: true)
        XCTAssertNotEqual(ok, .failed(.failed("download")))
    }

    func testDeleteFromLibraryRemovesCloudContentAndRemoveDownloadKeepsIt() async throws {
        await a.coordinator.setGameFilesEnabled(true)
        let gameA = try await a.importGame(content, title: "Counter")
        try await a.coordinator.uploadContent(gameID: gameA.id)
        try await converge()
        let gameBOptional = try await b.game(gameA.contentFingerprint)
        let gameB = try XCTUnwrap(gameBOptional)
        _ = try await b.coordinator.downloadContent(gameID: gameB.id, ingestion: b.ingestion)
        try await b.ingestion.removeLocalContent(gameID: gameB.id)
        let stillInCloud = await cloud.record(.gameContent(gameA.contentFingerprint, part: 0))
        XCTAssertNotNil(stillInCloud)
        let cloudOnly = await b.coordinator.gameStatus(gameB, hasLocalContent: false)
        XCTAssertEqual(cloudOnly, .cloudOnly(size: Int64(content.count)))
        try await a.ingestion.remove(gameID: gameA.id)
        await a.coordinator.flushSoon()
        try await converge()
        let gone = await cloud.record(.gameContent(gameA.contentFingerprint, part: 0))
        XCTAssertNil(gone, "Delete from Library removed the content record")
        let indexGone = await cloud.record(.contentIndex(gameA.contentFingerprint))
        XCTAssertNil(indexGone)
        let onB = try await b.game(gameA.contentFingerprint)
        XCTAssertNil(onB)
    }

    func testGameFileSyncStaysOffWhenTransportBuildCannotCarryAssets() async throws {
        let lightweight = try await SimulatedDevice(name: "lightweight", kind: .mac, cloud: cloud, clock: clock, capabilities: .savesOnly)
        defer { lightweight.destroy() }
        await lightweight.start()
        await lightweight.coordinator.setGameFilesEnabled(true)
        let status = await lightweight.status
        XCTAssertFalse(status.gameFilesAllowed)
        XCTAssertFalse(status.gameFilesEnabled)
        let game = try await lightweight.importGame(content, title: "Counter")
        try await lightweight.coordinator.uploadContent(gameID: game.id)
        let uploaded = await cloud.record(.gameContent(game.contentFingerprint, part: 0))
        XCTAssertNil(uploaded)
    }

    func testTransportCapabilityChangePreservesOptInAndExistingContent() async throws {
        await a.coordinator.setGameFilesEnabled(true)
        await a.coordinator.setCapabilities(.savesOnly)
        await a.coordinator.setCapabilities(.internalTesting)
        let restored = await a.status
        XCTAssertTrue(restored.gameFilesAllowed)
        XCTAssertTrue(restored.gameFilesEnabled, "the player's prior opt-in is preserved")
    }
}

func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Any,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ handler: (Error) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

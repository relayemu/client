// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  BatteryRevisionGraphTests.swift — the battery version graph
//  divergence, resolution, identical bytes, missing parents, out-of-order
//  ancestry, corrupt revisions, restore, previous.sav untouched by cloud logic.

import XCTest
import RelayDomain
@testable import RelayLibrary

final class BatteryRevisionGraphTests: XCTestCase {
    var root: URL!
    var location: LibraryLocation!
    var store: InMemoryLibraryStore!
    var game: Game!
    let phone = SyncIdentity(installationID: InstallationID(), deviceKind: .iPhone)
    let tv = SyncIdentity(installationID: InstallationID(), deviceKind: .appleTV)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        root = try TestSupport.temporaryDirectory()
        location = LibraryLocation(rootURL: root)
        try location.createDirectories()
        store = InMemoryLibraryStore()
        game = Game(systemID: .gameBoyAdvance, title: "Counter", contentFingerprint: try ContentFingerprint(sha256: [UInt8](repeating: 7, count: 32)), addedAt: t0)
        try await store.games.insert(game, files: [])
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func manager(_ identity: SyncIdentity) -> BatterySaveManager {
        BatterySaveManager(store: store, location: location, identity: identity)
    }

    /// Simulates a revision arriving from another device: its file installed and its row inserted (no head change).
    private func receive(_ data: Data, parents: [BatteryRevisionID], from identity: SyncIdentity, at date: Date, id: BatteryRevisionID = BatteryRevisionID()) async throws -> BatteryRevision {
        let loc = try LibraryLocation.batteryRevisionLocation(gameID: game.id, revisionID: id)
        try AtomicFile().write(data, to: location.url(for: loc))
        let revision = BatteryRevision(id: id, gameID: game.id, parentIDs: parents, createdAt: date,
                                       dataFingerprint: try SHA256ContentHasher().hash(data: data).fingerprint, sizeInBytes: Int64(data.count),
                                       installationID: identity.installationID, deviceKind: identity.deviceKind, location: loc, origin: .remote)
        try await store.saves.insertBatteryRevision(revision)
        return revision
    }

    private func current() throws -> Data {
        try Data(contentsOf: location.url(for: try LibraryLocation.batterySaveLocation(gameID: game.id)))
    }

    func testSequentialWritesFormAChainWithOneHead() async throws {
        let m = manager(phone)
        _ = try await m.snapshot(gameID: game.id, data: Data([1]), now: t0)
        _ = try await m.snapshot(gameID: game.id, data: Data([2]), now: t0.addingTimeInterval(1))
        _ = try await m.snapshot(gameID: game.id, data: Data([2]), now: t0.addingTimeInterval(2))   // unchanged bytes: no revision
        _ = try await m.snapshot(gameID: game.id, data: Data([3]), now: t0.addingTimeInterval(3))
        let revisions = try await m.revisions(for: game.id)
        XCTAssertEqual(revisions.count, 3)
        XCTAssertEqual(revisions[0].parentIDs, [revisions[1].id])
        XCTAssertEqual(revisions[1].parentIDs, [revisions[2].id])
        XCTAssertEqual(revisions[2].parentIDs, [])
        let heads = try await m.heads(for: game.id)
        XCTAssertEqual(heads.map(\.id), [revisions[0].id])
        let active = try await store.saves.activeBatteryRevisionID(for: game.id)
        XCTAssertEqual(active, revisions[0].id)
        let conflict = try await m.conflict(for: game.id)
        XCTAssertNil(conflict)
        for r in revisions { XCTAssertTrue(FileManager.default.fileExists(atPath: location.url(for: r.location).path), "revision files are immutable and kept") }
        XCTAssertEqual(try current(), Data([3]))
    }

    func testRemoteDescendantIsAdoptedByReconcile() async throws {
        let m = manager(phone)
        _ = try await m.snapshot(gameID: game.id, data: Data([1]), now: t0)
        let a = try await m.heads(for: game.id)[0]
        let b = try await receive(Data([2]), parents: [a.id], from: tv, at: t0.addingTimeInterval(10))
        let outcome = try await m.reconcile(gameID: game.id, now: t0.addingTimeInterval(11))
        XCTAssertEqual(outcome, .adopted(b))
        XCTAssertEqual(try current(), Data([2]))
        let active = try await store.saves.activeBatteryRevisionID(for: game.id)
        XCTAssertEqual(active, b.id)
        let save = try await m.currentSave(for: game.id)
        XCTAssertEqual(save?.fingerprint, b.dataFingerprint)
        XCTAssertEqual(try Data(contentsOf: m.previousSnapshotURL(for: game.id)!), Data([1]), "previous.sav is the local rollback of the write, nothing more")
        // A second reconcile is a no-op.
        let again = try await m.reconcile(gameID: game.id)
        XCTAssertEqual(again, .unchanged)
    }

    func testDivergentRevisionsAreAConflictThatPreservesBoth() async throws {
        let m = manager(phone)
        _ = try await m.snapshot(gameID: game.id, data: Data([1]), now: t0)
        let a = try await m.heads(for: game.id)[0]
        _ = try await m.snapshot(gameID: game.id, data: Data([2]), now: t0.addingTimeInterval(5))       // B (local)
        let c = try await receive(Data([3]), parents: [a.id], from: tv, at: t0.addingTimeInterval(6))   // C (remote)
        let outcome = try await m.reconcile(gameID: game.id, now: t0.addingTimeInterval(7))
        guard case .conflict(let conflict) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(Set(conflict.heads.map(\.dataFingerprint)).count, 2)
        XCTAssertEqual(try current(), Data([2]), "nothing adopted automatically")
        let reported = try await m.conflict(for: game.id)
        XCTAssertEqual(reported?.heads.map(\.id).sorted(by: { $0.description < $1.description }), conflict.heads.map(\.id).sorted(by: { $0.description < $1.description }))
        // Resolve keeping the remote branch C.
        let merged = try await m.resolve(gameID: game.id, keeping: c.id, now: t0.addingTimeInterval(8))
        XCTAssertEqual(Set(merged.parentIDs), Set(conflict.heads.map(\.id)))
        XCTAssertEqual(merged.parentIDs.first, c.id)
        XCTAssertEqual(merged.dataFingerprint, c.dataFingerprint)
        XCTAssertEqual(try current(), Data([3]))
        let heads = try await m.heads(for: game.id)
        XCTAssertEqual(heads.map(\.id), [merged.id])
        let none = try await m.conflict(for: game.id)
        XCTAssertNil(none)
        // The losing branch B is still a revision with its file.
        let revisions = try await m.revisions(for: game.id)
        let b = revisions.first { $0.dataFingerprint == (try? SHA256ContentHasher().hash(data: Data([2])).fingerprint) }
        XCTAssertNotNil(b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.url(for: b!.location).path))
        await XCTAssertThrowsErrorAsync(try await m.resolve(gameID: game.id, keeping: c.id)) { XCTAssertEqual($0 as? BatterySaveError, .noConflict(game.id)) }
    }

    func testIdenticalBytesOnTwoDevicesJoinWithoutADialog() async throws {
        let m = manager(phone)
        _ = try await m.snapshot(gameID: game.id, data: Data([1]), now: t0)
        let a = try await m.heads(for: game.id)[0]
        _ = try await m.snapshot(gameID: game.id, data: Data([9, 9]), now: t0.addingTimeInterval(5))
        _ = try await receive(Data([9, 9]), parents: [a.id], from: tv, at: t0.addingTimeInterval(6))
        let outcome = try await m.reconcile(gameID: game.id, now: t0.addingTimeInterval(7))
        guard case .joinedIdentical(let merged) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(merged.parentIDs.count, 2)
        let conflict = try await m.conflict(for: game.id)
        XCTAssertNil(conflict)
        XCTAssertEqual(try current(), Data([9, 9]))
    }

    func testMissingParentArrivingLaterCausesNoTransientConflict() async throws {
        let m = manager(phone)
        _ = try await m.snapshot(gameID: game.id, data: Data([1]), now: t0)
        let a = try await m.heads(for: game.id)[0]
        let bID = BatteryRevisionID()
        // C (child of B) arrives before B.
        let c = try await receive(Data([3]), parents: [bID], from: tv, at: t0.addingTimeInterval(20))
        var outcome = try await m.reconcile(gameID: game.id)
        XCTAssertEqual(outcome, .unchanged, "C is incomplete: not a head, not adopted, not a conflict")
        let transient = try await m.conflict(for: game.id)
        XCTAssertNil(transient)
        XCTAssertEqual(try current(), Data([1]))
        _ = try await receive(Data([2]), parents: [a.id], from: tv, at: t0.addingTimeInterval(10), id: bID)
        outcome = try await m.reconcile(gameID: game.id)
        XCTAssertEqual(outcome, .adopted(c))
        XCTAssertEqual(try current(), Data([3]))
    }

    func testHeadsComputationIsOrderIndependent() throws {
        let g = GameID()
        func rev(_ id: BatteryRevisionID, _ parents: [BatteryRevisionID], _ t: TimeInterval, _ byte: UInt8) throws -> BatteryRevision {
            BatteryRevision(id: id, gameID: g, parentIDs: parents, createdAt: t0.addingTimeInterval(t),
                            dataFingerprint: try SHA256ContentHasher().hash(data: Data([byte])).fingerprint, sizeInBytes: 1,
                            installationID: phone.installationID, deviceKind: .iPhone,
                            location: try LibraryLocation.batteryRevisionLocation(gameID: g, revisionID: id), origin: .remote)
        }
        let a = BatteryRevisionID(), b = BatteryRevisionID(), c = BatteryRevisionID(), d = BatteryRevisionID()
        let all = [try rev(d, [b, c], 4, 4), try rev(c, [a], 3, 3), try rev(b, [a], 2, 2), try rev(a, [], 1, 1)]
        for permutation in [all, all.reversed(), [all[1], all[3], all[0], all[2]]] {
            XCTAssertEqual(BatterySaveManager.heads(of: permutation).map(\.id), [d])
        }
        XCTAssertEqual(BatterySaveManager.heads(of: Array(all.dropFirst())).map(\.id), [c, b], "without the merge, B and C are heads (newest first)")
        XCTAssertEqual(BatterySaveManager.heads(of: [all[0], all[1]]).map(\.id), [], "D and C without A are incomplete")
    }

    func testCorruptRevisionFileIsRefusedNotAdopted() async throws {
        let m = manager(phone)
        _ = try await m.snapshot(gameID: game.id, data: Data([1]), now: t0)
        let a = try await m.heads(for: game.id)[0]
        let bad = try await receive(Data([2]), parents: [a.id], from: tv, at: t0.addingTimeInterval(10))
        try Data([7]).write(to: location.url(for: bad.location))   // bytes no longer match the fingerprint
        await XCTAssertThrowsErrorAsync(try await m.reconcile(gameID: game.id)) { XCTAssertEqual($0 as? BatterySaveError, .revisionDataMismatch(bad.id)) }
        XCTAssertEqual(try current(), Data([1]), "local progress untouched")
        let active = try await store.saves.activeBatteryRevisionID(for: game.id)
        XCTAssertEqual(active, a.id)
    }

    func testRestoreCreatesANewRevisionInsteadOfRewritingHistory() async throws {
        let m = manager(phone)
        _ = try await m.snapshot(gameID: game.id, data: Data([1]), now: t0)
        let old = try await m.heads(for: game.id)[0]
        _ = try await m.snapshot(gameID: game.id, data: Data([2]), now: t0.addingTimeInterval(1))
        let head = try await m.heads(for: game.id)[0]
        let restored = try await m.restore(old, now: t0.addingTimeInterval(2))
        XCTAssertEqual(restored.parentIDs, [head.id])
        XCTAssertEqual(restored.dataFingerprint, old.dataFingerprint)
        XCTAssertEqual(try current(), Data([1]))
        let count = try await m.revisions(for: game.id).count
        XCTAssertEqual(count, 3)
    }

    func testPhaseFourSaveGetsARootRevisionOnFirstUse() async throws {
        let loc = try LibraryLocation.batterySaveLocation(gameID: game.id)
        try AtomicFile().write(Data([5, 5]), to: location.url(for: loc))
        try await store.saves.upsert(Save(gameID: game.id, location: loc, sizeInBytes: 2, fingerprint: try SHA256ContentHasher().hash(data: Data([5, 5])).fingerprint, updatedAt: t0))
        let m = manager(phone)
        try await m.prepareForLaunch(gameID: game.id, romBaseName: "counter")
        let heads = try await m.heads(for: game.id)
        XCTAssertEqual(heads.count, 1)
        XCTAssertEqual(heads[0].parentIDs, [])
        XCTAssertEqual(heads[0].createdAt, t0)
        XCTAssertEqual(try m.verifiedData(of: heads[0]), Data([5, 5]))
        let active = try await store.saves.activeBatteryRevisionID(for: game.id)
        XCTAssertEqual(active, heads[0].id)
        // The next snapshot descends from that root.
        _ = try await m.snapshot(gameID: game.id, data: Data([6]), now: t0.addingTimeInterval(1))
        let newHead = try await m.heads(for: game.id)[0]
        XCTAssertEqual(newHead.parentIDs, [heads[0].id])
    }

    func testFailedCommitLeavesRowsUnchangedAndFilesReclaimable() async throws {
        let m = manager(phone)
        _ = try await m.snapshot(gameID: game.id, data: Data([1]), now: t0)
        let before = try await store.saves.activeBatteryRevisionID(for: game.id)
        await store.state.setFailNextCommit(true)
        await XCTAssertThrowsErrorAsync(try await m.snapshot(gameID: game.id, data: Data([2]), now: t0.addingTimeInterval(1))) { _ in }
        let after = try await store.saves.activeBatteryRevisionID(for: game.id)
        XCTAssertEqual(after, before)
        let count = try await m.revisions(for: game.id).count
        XCTAssertEqual(count, 1)
        // current.sav already holds the new bytes; the next snapshot re-creates the revision (nothing lost).
        _ = try await m.snapshot(gameID: game.id, data: Data([2]), now: t0.addingTimeInterval(2))
        let recovered = try await m.revisions(for: game.id).count
        XCTAssertEqual(recovered, 2)
    }
}

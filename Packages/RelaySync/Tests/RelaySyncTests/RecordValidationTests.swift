// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RecordValidationTests.swift — remote records are untrusted input.

import XCTest
import RelayDomain
import RelayLibrary
@testable import RelaySync

final class RecordValidationTests: XCTestCase {
    let validator = SyncRecordValidator()
    let fp = try! ContentFingerprint(sha256: [UInt8](repeating: 1, count: 32))
    let install = InstallationID()

    func testKeysAreDeterministicAndZoned() {
        XCTAssertEqual(RecordKey.game(fp).name, "game:" + fp.hexDigest)
        XCTAssertEqual(RecordKey.game(fp).zone, .sync)
        XCTAssertEqual(RecordKey.gameContent(fp, part: 0).zone, .content)
        let id = SaveStateID()
        XCTAssertEqual(RecordKey.state(id).name, "state:\(id)")
        XCTAssertEqual(RecordKey.state(id, generation: 1).name, "state:\(id):generation:1")
        XCTAssertEqual(RecordKey.state(id, generation: 1).stateID, id)
        XCTAssertEqual(RecordKey.tombstone(.game(fp)).name, "tombstone:game:\(fp.canonicalString)")
    }

    func testRecordsRoundTripThroughJSON() throws {
        let record = SyncRecord.state(SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "manual", coreID: "mgba", coreVersion: "0.10.3",
                                                    stateCompatibilityVersion: "0.10.3", formatVersion: 2, createdAt: 1_700_000_000_000,
                                                    payloadFingerprint: fp, payloadSize: 397_312, batteryRevisionID: BatteryRevisionID(),
                                                    installationID: install, deviceKind: "iphone", label: nil, hasScreenshot: true))
        let decoded = try JSONDecoder().decode(SyncRecord.self, from: try JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.key, record.key)
        XCTAssertEqual(decoded.gameFingerprint, fp)
    }

    func testLegacyGenerationDecodeAndVersionedIdentity() throws {
        let entry = SyncGameEntry(fingerprint: fp, systemID: "gba", title: "T", isFavorite: false,
                                  addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: nil, generation: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["schema"] = 1
        object.removeValue(forKey: "generation")
        let legacy = try JSONDecoder().decode(SyncGameEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.generation, 0)
        object["schema"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(SyncGameEntry.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertNotEqual(SyncRecord.game(entry).key, SyncRecord.game(legacy).key)
        XCTAssertEqual(RecordKey.contentIndex(fp, generation: 2).contentMembership?.generation, 2)
        var invalid = entry; invalid.generation = -1
        XCTAssertThrowsError(try validator.validate(.game(invalid)))
        invalid.generation = Int64(Int32.max) + 1
        XCTAssertThrowsError(try validator.validate(.game(invalid)))
        invalid.generation = 1; invalid.schema = 1
        XCTAssertThrowsError(try validator.validate(.game(invalid)))
    }

    func testImmutableMembershipAndClassificationCannotMerge() {
        let first = SyncGameEntry(fingerprint: fp, systemID: "gba", title: "A", isFavorite: false, addedAt: 1, updatedAt: 1, contentSize: nil)
        var conflict = first; conflict.systemID = "gbc"; conflict.updatedAt = 2
        guard case .integrityError = SyncResolution.resolve(local: .game(first), server: .game(conflict)) else { return XCTFail() }
        conflict = first; conflict.generation = 1
        guard case .integrityError = SyncResolution.resolve(local: .game(first), server: .game(conflict)) else { return XCTFail() }
    }

    func testNewerSchemaIsRefused() {
        var entry = SyncGameEntry(fingerprint: fp, systemID: "gba", title: "T", isFavorite: false, addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: 10)
        entry.schema = SyncSchema.version + 1
        XCTAssertThrowsError(try validator.validate(.game(entry))) { XCTAssertEqual($0 as? SyncValidationError, .unsupportedSchema(SyncSchema.version + 1)) }
    }

    func testTitlesSystemsAndNamesAreSanitised() throws {
        let long = String(repeating: "x", count: 400)
        let entry = SyncGameEntry(fingerprint: fp, systemID: "GBA", title: "  Bad\u{0}Title\u{1F}\n ", isFavorite: true, addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: 10)
        guard case .game(let cleaned) = try validator.validate(.game(entry)) else { return XCTFail() }
        XCTAssertEqual(cleaned.systemID, "gba")
        XCTAssertEqual(cleaned.title, "BadTitle")
        let longEntry = SyncGameEntry(fingerprint: fp, systemID: "gba", title: long, isFavorite: false, addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: nil)
        guard case .game(let bounded) = try validator.validate(.game(longEntry)) else { return XCTFail() }
        XCTAssertEqual(bounded.title.count, SyncLimits.maxTitleLength)
        XCTAssertThrowsError(try validator.validate(.game(SyncGameEntry(fingerprint: fp, systemID: "../etc", title: "T", isFavorite: false, addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: nil))))
        let index = SyncContentIndex(fingerprint: fp, size: 100, fileName: "../../escape/../evil.gba", systemID: "gba", partCount: 1, uploadedAt: 1_700_000_000_000, installationID: install)
        guard case .contentIndex(let safe) = try validator.validate(.contentIndex(index)) else { return XCTFail() }
        XCTAssertEqual(safe.fileName, "evil.gba")
        XCTAssertFalse(safe.fileName.contains("/"))
    }

    func testEnumerationsAndSizesAreChecked() {
        let badKind = SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "turbo", coreID: "mgba", coreVersion: "1", stateCompatibilityVersion: "1", formatVersion: 2,
                                    createdAt: 1_700_000_000_000, payloadFingerprint: fp, payloadSize: 10, batteryRevisionID: nil, installationID: install, deviceKind: "iphone", label: nil, hasScreenshot: false)
        XCTAssertThrowsError(try validator.validate(.state(badKind))) { XCTAssertEqual($0 as? SyncValidationError, .unknownEnumValue(field: "kind", value: "turbo")) }
        let huge = SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [], createdAt: 1_700_000_000_000, dataFingerprint: fp,
                                       dataSize: SyncLimits.maxBatterySize + 1, installationID: install, deviceKind: "mac", hasScreenshot: false)
        XCTAssertThrowsError(try validator.validate(.batteryRevision(huge))) { XCTAssertEqual($0 as? SyncValidationError, .sizeOutOfRange(field: "dataSize", value: SyncLimits.maxBatterySize + 1)) }
        let future = SyncSession(sessionID: PlaySessionID(), fingerprint: fp, installationID: install, deviceKind: "visionpro", coreID: "mgba",
                                 startedAt: 1_700_000_000_000, endedAt: 1_600_000_000_000, pausedMs: 0, hasScreenshot: false)
        XCTAssertThrowsError(try validator.validate(.session(future)))
        let okSession = SyncSession(sessionID: PlaySessionID(), fingerprint: fp, installationID: install, deviceKind: "visionpro", coreID: "mgba",
                                    startedAt: 1_700_000_000_000, endedAt: 1_700_000_060_000, pausedMs: 0, hasScreenshot: false)
        guard case .session(let lenient)? = try? validator.validate(.session(okSession)) else { return XCTFail() }
        XCTAssertEqual(lenient.deviceKind, "unknown", "future device kinds degrade, never fail")
        let badTombstone = SyncTombstone(targetKind: "planet", targetKey: "x", deletedAt: 1_700_000_000_000, installationID: install)
        XCTAssertThrowsError(try validator.validate(.tombstone(badTombstone)))
        let otherFingerprint = try! ContentFingerprint(sha256: [UInt8](repeating: 8, count: 32))
        let conflictingTombstone = SyncTombstone(targetKind: "game", targetKey: fp.canonicalString,
            deletedAt: 1_700_000_000_000, installationID: install, gameFingerprint: otherFingerprint)
        XCTAssertThrowsError(try validator.validate(.tombstone(conflictingTombstone)))
        let badPart = SyncGameContent(fingerprint: fp, partIndex: 3, partCount: 2, partFingerprint: fp, partSize: 10)
        XCTAssertThrowsError(try validator.validate(.gameContent(badPart)))
    }

    func testResolutionByRecordSemantics() {
        let mine = SyncGameEntry(fingerprint: fp, systemID: "gba", title: "Mine", isFavorite: true, addedAt: 20, updatedAt: 100, contentSize: 1)
        let theirs = SyncGameEntry(fingerprint: fp, systemID: "gba", title: "Theirs", isFavorite: false, addedAt: 10, updatedAt: 50, contentSize: nil)
        guard case .resend(.game(let merged)) = SyncResolution.resolve(local: .game(mine), server: .game(theirs)) else { return XCTFail() }
        XCTAssertEqual(merged.title, "Mine"); XCTAssertEqual(merged.addedAt, 10)
        // The server is newer but our addedAt is earlier: resend the server's fields with the earliest addedAt.
        guard case .resend(.game(let pushed)) = SyncResolution.resolve(local: .game(theirs), server: .game(mine)) else { return XCTFail() }
        XCTAssertEqual(pushed.title, "Mine"); XCTAssertEqual(pushed.addedAt, 10)
        var sameAdded = theirs; sameAdded.addedAt = 20
        XCTAssertEqual(SyncResolution.resolve(local: .game(sameAdded), server: .game(mine)), .acceptServer)
        let r1 = SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [], createdAt: 1, dataFingerprint: fp, dataSize: 1, installationID: install, deviceKind: "mac", hasScreenshot: false)
        var r2 = r1; r2.dataFingerprint = try! ContentFingerprint(sha256: [UInt8](repeating: 2, count: 32))
        XCTAssertEqual(SyncResolution.resolve(local: .batteryRevision(r1), server: .batteryRevision(r1)), .acceptServer)
        guard case .integrityError = SyncResolution.resolve(local: .batteryRevision(r1), server: .batteryRevision(r2)) else { return XCTFail() }
        let t1 = SyncTombstone(targetKind: "game", targetKey: fp.canonicalString, deletedAt: 5, installationID: install)
        var t2 = t1; t2.deletedAt = 9
        XCTAssertEqual(SyncResolution.resolve(local: .tombstone(t2), server: .tombstone(t1)), .resend(.tombstone(t2)))
        XCTAssertEqual(SyncResolution.resolve(local: .tombstone(t1), server: .tombstone(t2)), .acceptServer)
    }
}

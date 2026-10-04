// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RecordCodecTests.swift — CKRecord ⇄ SyncRecord round trips, defensive
//  decoding, and the schema file listing every field the codec writes.
//  No network: CKRecord values are plain objects.

import XCTest
import CloudKit
import RelayDomain
import RelaySync
@testable import RelayCloudKit

final class RecordCodecTests: XCTestCase {
    let codec = RecordCodec()
    let zone = CKRecordZone.ID(zoneName: "RelaySync", ownerName: CKCurrentUserDefaultName)
    let fp = try! ContentFingerprint(sha256: [UInt8](repeating: 4, count: 32))
    let install = InstallationID()

    private func roundTrip(_ record: SyncRecord, assets: [SyncAssetName: URL] = [:]) throws -> (SyncRecord, [SyncAssetName: URL]) {
        let ck = CKRecord(recordType: record.type.rawValue, recordID: RecordCodec.recordID(for: record.key, zoneID: zone))
        codec.encode(record, assets: assets, into: ck)
        return try codec.decode(ck)
    }

    func testEveryRecordTypeRoundTrips() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "codec-\(UUID().uuidString)")
        try Data([1, 2, 3]).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let records: [SyncRecord] = [
            .game(SyncGameEntry(fingerprint: fp, systemID: "gba", title: "Title", isFavorite: true, addedAt: 1_700_000_000_000, updatedAt: 1_700_000_001_000, contentSize: 61104)),
            .session(SyncSession(sessionID: PlaySessionID(), fingerprint: fp, installationID: install, deviceKind: "ipad", coreID: "mgba", startedAt: 1_700_000_000_000, endedAt: 1_700_000_060_000, pausedMs: 1200, hasScreenshot: true)),
            .batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [BatteryRevisionID(), BatteryRevisionID()], createdAt: 1_700_000_000_000, dataFingerprint: fp, dataSize: 3, installationID: install, deviceKind: "mac", hasScreenshot: false)),
            .state(SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "auto", coreID: "mgba", coreVersion: "0.10.3", stateCompatibilityVersion: "0.10.3", formatVersion: 2, createdAt: 1_700_000_000_000, payloadFingerprint: fp, payloadSize: 3, batteryRevisionID: BatteryRevisionID(), installationID: install, deviceKind: "iphone", label: "Boss", hasScreenshot: false)),
            .tombstone(SyncTombstone(targetKind: "game", targetKey: fp.canonicalString, deletedAt: 1_700_000_000_000, installationID: install)),
            .contentIndex(SyncContentIndex(fingerprint: fp, size: 61104, fileName: "game.gba", systemID: "gba", partCount: 1, uploadedAt: 1_700_000_000_000, installationID: install)),
            .gameContent(SyncGameContent(fingerprint: fp, partIndex: 0, partCount: 1, partFingerprint: fp, partSize: 3)),
            .artwork(SyncArtwork(fingerprint: fp, artworkFingerprint: fp, artworkSize: 3, updatedAt: 1_700_000_002_000, installationID: install, generation: 1)),
            .artwork(SyncArtwork(fingerprint: fp, artworkFingerprint: nil, artworkSize: nil, updatedAt: 1_700_000_003_000, installationID: install)),
        ]
        for record in records {
            var assets: [SyncAssetName: URL] = [:]
            switch record {
            case .session: assets[.screenshot] = temp
            case .batteryRevision, .gameContent: assets[.data] = temp
            case .artwork(let r) where !r.isCleared: assets[.data] = temp
            case .state: assets[.payload] = temp
            default: break
            }
            let (decoded, decodedAssets) = try roundTrip(record, assets: assets)
            XCTAssertEqual(decoded, record, "\(record.type)")
            XCTAssertEqual(Set(decodedAssets.keys), Set(assets.keys), "\(record.type)")
            XCTAssertEqual(decoded.key, record.key)
        }
    }

    func testGenerationKeysAndLegacyDecode() throws {
        let entry = SyncRecord.game(SyncGameEntry(fingerprint: fp, systemID: "gba", title: "New import", isFavorite: false,
            addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: nil, generation: 2))
        XCTAssertEqual(try roundTrip(entry).0, entry)
        let tombstone = SyncRecord.tombstone(SyncTombstone(targetKind: "game", targetKey: fp.canonicalString,
            deletedAt: 1_700_000_000_000, installationID: install, generation: 1, gameFingerprint: fp))
        XCTAssertEqual(try roundTrip(tombstone).0, tombstone)
        let history: [SyncRecord] = [
            .session(SyncSession(sessionID: PlaySessionID(), fingerprint: fp, installationID: install, deviceKind: "mac", coreID: "fake",
                startedAt: 1_700_000_000_000, endedAt: nil, pausedMs: 0, hasScreenshot: false, generation: 1)),
            .batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [], createdAt: 1_700_000_000_000,
                dataFingerprint: fp, dataSize: 4, installationID: install, deviceKind: "mac", hasScreenshot: false, generation: 1)),
            .state(SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "auto", coreID: "fake", coreVersion: "1", stateCompatibilityVersion: "1",
                formatVersion: 2, createdAt: 1_700_000_000_000, payloadFingerprint: fp, payloadSize: 4, batteryRevisionID: nil,
                installationID: install, deviceKind: "mac", label: nil, hasScreenshot: false, generation: 1))
        ]
        for record in history {
            XCTAssertTrue(record.key.name.hasSuffix(":generation:1"))
            XCTAssertEqual(try roundTrip(record).0, record)
        }
        let legacy = CKRecord(recordType: "RelayGame", recordID: RecordCodec.recordID(for: .game(fp), zoneID: zone))
        codec.encode(entry, assets: [:], into: legacy)
        legacy["schema"] = Int64(1); legacy["generation"] = nil
        XCTAssertEqual(try codec.decode(legacy).0.generation, 0)
        legacy["schema"] = Int64(2)
        XCTAssertThrowsError(try codec.decode(legacy))
    }

    func testDefensiveDecoding() throws {
        let entry = SyncRecord.game(SyncGameEntry(fingerprint: fp, systemID: "gba", title: "T", isFavorite: false, addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: nil))
        // Newer schema.
        var ck = CKRecord(recordType: "RelayGame", recordID: RecordCodec.recordID(for: entry.key, zoneID: zone))
        codec.encode(entry, assets: [:], into: ck)
        ck["schema"] = Int64(SyncSchema.version + 1)
        XCTAssertThrowsError(try codec.decode(ck)) { XCTAssertEqual($0 as? RecordCodecError, .unsupportedSchema(SyncSchema.version + 1)) }
        // Wrong type in a field.
        ck = CKRecord(recordType: "RelayGame", recordID: RecordCodec.recordID(for: entry.key, zoneID: zone))
        codec.encode(entry, assets: [:], into: ck)
        ck["addedAt"] = "yesterday"
        XCTAssertThrowsError(try codec.decode(ck)) { XCTAssertEqual($0 as? RecordCodecError, .missingField("addedAt")) }
        // Missing required field.
        ck = CKRecord(recordType: "RelayGame", recordID: RecordCodec.recordID(for: entry.key, zoneID: zone))
        codec.encode(entry, assets: [:], into: ck)
        ck["fingerprint"] = nil
        XCTAssertThrowsError(try codec.decode(ck))
        // Malformed fingerprint and renamed record.
        ck = CKRecord(recordType: "RelayGame", recordID: RecordCodec.recordID(for: entry.key, zoneID: zone))
        codec.encode(entry, assets: [:], into: ck)
        ck["fingerprint"] = "md5:abc"
        XCTAssertThrowsError(try codec.decode(ck)) { XCTAssertEqual($0 as? RecordCodecError, .invalidField("fingerprint")) }
        let renamed = CKRecord(recordType: "RelayGame", recordID: CKRecord.ID(recordName: "game:somebodyelse", zoneID: zone))
        codec.encode(entry, assets: [:], into: renamed)
        XCTAssertThrowsError(try codec.decode(renamed)) { XCTAssertEqual($0 as? RecordCodecError, .invalidField("recordName")) }
        // Unknown record type.
        let alien = CKRecord(recordType: "RelayAlien", recordID: CKRecord.ID(recordName: "x", zoneID: zone))
        XCTAssertThrowsError(try codec.decode(alien)) { XCTAssertEqual($0 as? RecordCodecError, .unknownRecordType("RelayAlien")) }
        // Optional fields may be absent (older records).
        ck = CKRecord(recordType: "RelaySession", recordID: RecordCodec.recordID(for: .session(PlaySessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)), zoneID: zone))
        ck["schema"] = Int64(1); ck["sessionID"] = "00000000-0000-0000-0000-000000000001"; ck["fingerprint"] = fp.canonicalString
        ck["installationID"] = install.description; ck["deviceKind"] = "mac"; ck["coreID"] = "mgba"; ck["startedAt"] = Int64(1_700_000_000_000)
        let (decoded, _) = try codec.decode(ck)
        guard case .session(let s) = decoded else { return XCTFail() }
        XCTAssertNil(s.endedAt); XCTAssertEqual(s.pausedMs, 0); XCTAssertFalse(s.hasScreenshot)
    }

    func testErrorClassification() {
        XCTAssertEqual(CloudKitErrorClassifier.classify(CKError(.quotaExceeded)), .quotaFull)
        XCTAssertEqual(CloudKitErrorClassifier.classify(CKError(.networkUnavailable)), .network)
        XCTAssertEqual(CloudKitErrorClassifier.classify(CKError(.notAuthenticated)), .accountUnavailable)
        XCTAssertEqual(CloudKitErrorClassifier.classify(CKError(.serverRecordChanged)), .serverRecordChanged)
        XCTAssertEqual(CloudKitErrorClassifier.classify(CKError(.zoneNotFound)), .zoneMissing)
        XCTAssertEqual(CloudKitErrorClassifier.classify(CKError(.userDeletedZone)), .zoneMissing)
        XCTAssertEqual(CloudKitErrorClassifier.classify(CKError(.unknownItem)), .unknownItem)
        XCTAssertEqual(CloudKitErrorClassifier.classify(CKError(.limitExceeded)), .limitExceeded)
        XCTAssertEqual(CloudKitErrorClassifier.classify(CKError(.requestRateLimited)), .rateLimited(retryAfterSeconds: nil))
        XCTAssertEqual(CloudKitErrorClassifier.availability(.noAccount), .noAccount)
        XCTAssertEqual(CloudKitErrorClassifier.availability(.restricted), .restricted)
        XCTAssertEqual(CloudKitSyncTransport.hash("_abc").count, 64)
        XCTAssertNotEqual(CloudKitSyncTransport.hash("_abc"), CloudKitSyncTransport.hash("_abd"))
    }

    /// Artwork exists only in schema 3; the other types never accept it.
    func testArtworkCarriesSchemaThreeOnly() throws {
        let cover = SyncRecord.artwork(SyncArtwork(fingerprint: fp, artworkFingerprint: fp, artworkSize: 3,
                                                   updatedAt: 1_700_000_000_000, installationID: install))
        let ck = CKRecord(recordType: cover.type.rawValue, recordID: RecordCodec.recordID(for: cover.key, zoneID: zone))
        codec.encode(cover, assets: [:], into: ck)
        XCTAssertEqual(ck[RecordCodec.Field.schema] as? Int64, 3)
        ck[RecordCodec.Field.schema] = Int64(2)
        XCTAssertThrowsError(try codec.decode(ck)) { XCTAssertEqual($0 as? RecordCodecError, .unsupportedSchema(2)) }

        let game = SyncRecord.game(SyncGameEntry(fingerprint: fp, systemID: "gba", title: "Title", isFavorite: false,
                                                 addedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, contentSize: nil))
        let gameRecord = CKRecord(recordType: game.type.rawValue, recordID: RecordCodec.recordID(for: game.key, zoneID: zone))
        codec.encode(game, assets: [:], into: gameRecord)
        gameRecord[RecordCodec.Field.schema] = Int64(3)
        XCTAssertThrowsError(try codec.decode(gameRecord)) { XCTAssertEqual($0 as? RecordCodecError, .unsupportedSchema(3)) }
    }

    func testSchemaFileListsEveryFieldTheCodecWrites() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Scripts/relay-cloudkit-schema.ckdb")
        let text = try String(contentsOf: url, encoding: .utf8)
        for (type, fields) in RecordCodec.fieldsByType {
            guard let start = text.range(of: "RECORD TYPE \(type.rawValue) (") else { return XCTFail("schema lacks \(type.rawValue)") }
            let body = text[start.upperBound...]
            let end = body.range(of: ");")?.lowerBound ?? body.endIndex
            let block = String(body[..<end])
            for field in fields {
                XCTAssertTrue(block.contains("\(field) "), "\(type.rawValue).\(field) missing from the schema file")
            }
        }
    }

    /// Real CloudKit, 2026-09-03: a just-in-time schema cannot infer a field
    /// type from an empty list, and refuses the whole record. A root revision
    /// must therefore omit `parentIDs` entirely rather than send `[]`, while a
    /// child still carries its parents and still decodes to the same values.
    func testRootBatteryRevisionOmitsTheEmptyParentList() throws {
        let root = SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [],
                                       createdAt: 1_700_000_000_000, dataFingerprint: fp, dataSize: 3,
                                       installationID: install, deviceKind: "mac", hasScreenshot: false)
        let record = CKRecord(recordType: SyncRecordType.batteryRevision.rawValue,
                              recordID: RecordCodec.recordID(for: SyncRecord.batteryRevision(root).key, zoneID: zone))
        codec.encode(.batteryRevision(root), assets: [:], into: record)
        XCTAssertNil(record[RecordCodec.Field.parentIDs], "an empty parent list must not reach CloudKit")
        guard case .batteryRevision(let decoded) = try codec.decode(record).0 else { return XCTFail("wrong type") }
        XCTAssertEqual(decoded.parentIDs, [], "an absent field means a root revision")

        let parent = BatteryRevisionID()
        let child = SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [parent],
                                        createdAt: 1_700_000_001_000, dataFingerprint: fp, dataSize: 3,
                                        installationID: install, deviceKind: "mac", hasScreenshot: false)
        let childRecord = CKRecord(recordType: SyncRecordType.batteryRevision.rawValue,
                                   recordID: RecordCodec.recordID(for: SyncRecord.batteryRevision(child).key, zoneID: zone))
        codec.encode(.batteryRevision(child), assets: [:], into: childRecord)
        XCTAssertEqual(childRecord[RecordCodec.Field.parentIDs] as? [String], [parent.description])
        guard case .batteryRevision(let decodedChild) = try codec.decode(childRecord).0 else { return XCTFail("wrong type") }
        XCTAssertEqual(decodedChild.parentIDs, [parent])
    }
}

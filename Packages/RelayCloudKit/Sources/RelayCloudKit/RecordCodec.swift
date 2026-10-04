// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RecordCodec.swift
//  RelayCloudKit
//
//  The only place CloudKit field names appear. Maps RelaySync's portable
//  Decoding is defensive: every field is type-checked, `schema` is bounded,
//  and a record that does not decode is skipped with a classification —
//  never partially applied. Assets come back as the temporary file URLs
//  CloudKit provides; the sync layer copies them into Relay storage.

import CloudKit
import Foundation
import RelayDomain
import RelaySync

public enum RecordCodecError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownRecordType(String)
    case missingField(String)
    case invalidField(String)
    case unsupportedSchema(Int)

    public var description: String {
        switch self {
        case .unknownRecordType(let t): return "unknown record type \(t)"
        case .missingField(let f): return "missing field \(f)"
        case .invalidField(let f): return "invalid field \(f)"
        case .unsupportedSchema(let v): return "unsupported schema \(v)"
        }
    }
}

public struct RecordCodec: Sendable {
    public init() {}

    /// Field names per record type (also listed in Scripts/relay-cloudkit-schema.ckdb).
    public enum Field {
        public static let schema = "schema"
        public static let generation = "generation"
        public static let gameFingerprint = "gameFingerprint"
        public static let fingerprint = "fingerprint"
        public static let systemID = "systemID"
        public static let title = "title"
        public static let isFavorite = "isFavorite"
        public static let addedAt = "addedAt"
        public static let updatedAt = "updatedAt"
        public static let contentSize = "contentSize"
        public static let sessionID = "sessionID"
        public static let installationID = "installationID"
        public static let deviceKind = "deviceKind"
        public static let coreID = "coreID"
        public static let startedAt = "startedAt"
        public static let endedAt = "endedAt"
        public static let pausedMs = "pausedMs"
        public static let screenshot = "screenshot"
        public static let revisionID = "revisionID"
        public static let parentIDs = "parentIDs"
        public static let createdAt = "createdAt"
        public static let dataFingerprint = "dataFingerprint"
        public static let dataSize = "dataSize"
        public static let data = "data"
        public static let stateID = "stateID"
        public static let kind = "kind"
        public static let coreVersion = "coreVersion"
        public static let stateCompatibilityVersion = "stateCompatibilityVersion"
        public static let formatVersion = "formatVersion"
        public static let payloadFingerprint = "payloadFingerprint"
        public static let payloadSize = "payloadSize"
        public static let batteryRevisionID = "batteryRevisionID"
        public static let label = "label"
        public static let payload = "payload"
        public static let targetKind = "targetKind"
        public static let targetKey = "targetKey"
        public static let deletedAt = "deletedAt"
        public static let size = "size"
        public static let fileName = "fileName"
        public static let partCount = "partCount"
        public static let uploadedAt = "uploadedAt"
        public static let partIndex = "partIndex"
        public static let partFingerprint = "partFingerprint"
        public static let partSize = "partSize"
        public static let artworkFingerprint = "artworkFingerprint"
        public static let artworkSize = "artworkSize"
    }

    /// Every field the codec writes, per record type (checked against the schema file in tests).
    public static let fieldsByType: [SyncRecordType: [String]] = [
        .game: [Field.schema, Field.generation, Field.fingerprint, Field.systemID, Field.title, Field.isFavorite, Field.addedAt, Field.updatedAt, Field.contentSize],
        .session: [Field.schema, Field.generation, Field.sessionID, Field.fingerprint, Field.installationID, Field.deviceKind, Field.coreID, Field.startedAt, Field.endedAt, Field.pausedMs, Field.screenshot],
        .batteryRevision: [Field.schema, Field.generation, Field.revisionID, Field.fingerprint, Field.parentIDs, Field.createdAt, Field.dataFingerprint, Field.dataSize, Field.installationID, Field.deviceKind, Field.data, Field.screenshot],
        .state: [Field.schema, Field.generation, Field.stateID, Field.fingerprint, Field.kind, Field.coreID, Field.coreVersion, Field.stateCompatibilityVersion, Field.formatVersion, Field.createdAt, Field.payloadFingerprint, Field.payloadSize, Field.batteryRevisionID, Field.installationID, Field.deviceKind, Field.label, Field.payload, Field.screenshot],
        .tombstone: [Field.schema, Field.generation, Field.gameFingerprint, Field.targetKind, Field.targetKey, Field.deletedAt, Field.installationID],
        .contentIndex: [Field.schema, Field.generation, Field.fingerprint, Field.size, Field.fileName, Field.systemID, Field.partCount, Field.uploadedAt, Field.installationID],
        .gameContent: [Field.schema, Field.generation, Field.fingerprint, Field.partIndex, Field.partCount, Field.partFingerprint, Field.partSize, Field.data],
        .artwork: [Field.schema, Field.generation, Field.fingerprint, Field.artworkFingerprint, Field.artworkSize, Field.updatedAt, Field.installationID, Field.data],
    ]

    // MARK: Encoding

    /// Writes `record` and its assets into `target` (a fresh record or the cached server record for change tags).
    public func encode(_ record: SyncRecord, assets: [SyncAssetName: URL], into target: CKRecord) {
        target[Field.schema] = Int64(record.schema)
        target[Field.generation] = record.generation
        switch record {
        case .game(let r):
            target[Field.fingerprint] = r.fingerprint.canonicalString
            target[Field.systemID] = r.systemID
            target[Field.title] = r.title
            target[Field.isFavorite] = Int64(r.isFavorite ? 1 : 0)
            target[Field.addedAt] = r.addedAt
            target[Field.updatedAt] = r.updatedAt
            target[Field.contentSize] = r.contentSize
        case .session(let r):
            target[Field.sessionID] = r.sessionID.description
            target[Field.fingerprint] = r.fingerprint.canonicalString
            target[Field.installationID] = r.installationID.description
            target[Field.deviceKind] = r.deviceKind
            target[Field.coreID] = r.coreID
            target[Field.startedAt] = r.startedAt
            target[Field.endedAt] = r.endedAt
            target[Field.pausedMs] = r.pausedMs
            target[Field.screenshot] = assets[.screenshot].map { CKAsset(fileURL: $0) }
        case .batteryRevision(let r):
            target[Field.revisionID] = r.revisionID.description
            target[Field.fingerprint] = r.fingerprint.canonicalString
            // An empty list gives CloudKit nothing to infer a field type from, and a
            // just-in-time schema refuses the record. Absent means "no parents" (a root).
            let parents = r.parentIDs.map(\.description)
            target[Field.parentIDs] = parents.isEmpty ? nil : parents
            target[Field.createdAt] = r.createdAt
            target[Field.dataFingerprint] = r.dataFingerprint.canonicalString
            target[Field.dataSize] = r.dataSize
            target[Field.installationID] = r.installationID.description
            target[Field.deviceKind] = r.deviceKind
            target[Field.data] = assets[.data].map { CKAsset(fileURL: $0) }
            target[Field.screenshot] = assets[.screenshot].map { CKAsset(fileURL: $0) }
        case .state(let r):
            target[Field.stateID] = r.stateID.description
            target[Field.fingerprint] = r.fingerprint.canonicalString
            target[Field.kind] = r.kind
            target[Field.coreID] = r.coreID
            target[Field.coreVersion] = r.coreVersion
            target[Field.stateCompatibilityVersion] = r.stateCompatibilityVersion
            target[Field.formatVersion] = Int64(r.formatVersion)
            target[Field.createdAt] = r.createdAt
            target[Field.payloadFingerprint] = r.payloadFingerprint.canonicalString
            target[Field.payloadSize] = r.payloadSize
            target[Field.batteryRevisionID] = r.batteryRevisionID?.description
            target[Field.installationID] = r.installationID.description
            target[Field.deviceKind] = r.deviceKind
            target[Field.label] = r.label
            target[Field.payload] = assets[.payload].map { CKAsset(fileURL: $0) }
            target[Field.screenshot] = assets[.screenshot].map { CKAsset(fileURL: $0) }
        case .tombstone(let r):
            target[Field.gameFingerprint] = r.gameFingerprint?.canonicalString
            target[Field.targetKind] = r.targetKind
            target[Field.targetKey] = r.targetKey
            target[Field.deletedAt] = r.deletedAt
            target[Field.installationID] = r.installationID.description
        case .contentIndex(let r):
            target[Field.fingerprint] = r.fingerprint.canonicalString
            target[Field.size] = r.size
            target[Field.fileName] = r.fileName
            target[Field.systemID] = r.systemID
            target[Field.partCount] = Int64(r.partCount)
            target[Field.uploadedAt] = r.uploadedAt
            target[Field.installationID] = r.installationID.description
        case .gameContent(let r):
            target[Field.fingerprint] = r.fingerprint.canonicalString
            target[Field.partIndex] = Int64(r.partIndex)
            target[Field.partCount] = Int64(r.partCount)
            target[Field.partFingerprint] = r.partFingerprint.canonicalString
            target[Field.partSize] = r.partSize
            target[Field.data] = assets[.data].map { CKAsset(fileURL: $0) }
        case .artwork(let r):
            // A reset is a value: no cover fingerprint, size or asset.
            target[Field.fingerprint] = r.fingerprint.canonicalString
            target[Field.artworkFingerprint] = r.artworkFingerprint?.canonicalString
            target[Field.artworkSize] = r.artworkSize
            target[Field.updatedAt] = r.updatedAt
            target[Field.installationID] = r.installationID.description
            target[Field.data] = assets[.data].map { CKAsset(fileURL: $0) }
        }
    }

    // MARK: Decoding

    /// Decodes a record and the temporary URLs of its assets. Throws on anything malformed.
    public func decode(_ record: CKRecord) throws -> (SyncRecord, assets: [SyncAssetName: URL]) {
        guard let type = SyncRecordType(rawValue: record.recordType) else { throw RecordCodecError.unknownRecordType(record.recordType) }
        let schema = try int(record, Field.schema)
        // Artwork exists only from schema 3; every other type stays within 1...2.
        let supported = type == .artwork ? SyncSchema.artwork...SyncSchema.artwork : 1...SyncSchema.version
        guard supported.contains(schema) else { throw RecordCodecError.unsupportedSchema(schema) }
        let generation = schema == 1 ? (optionalInt64(record, Field.generation) ?? 0) : try int64(record, Field.generation)
        guard (0...Int64(Int32.max)).contains(generation), schema != 1 || generation == 0 else { throw RecordCodecError.invalidField(Field.generation) }
        var assets: [SyncAssetName: URL] = [:]
        func asset(_ name: SyncAssetName, field: String) {
            if let a = record[field] as? CKAsset, let url = a.fileURL { assets[name] = url }
        }
        let decoded: SyncRecord
        switch type {
        case .game:
            var r = SyncGameEntry(fingerprint: try fingerprint(record, Field.fingerprint), systemID: try string(record, Field.systemID),
                                  title: try string(record, Field.title), isFavorite: try int64(record, Field.isFavorite) != 0,
                                  addedAt: try int64(record, Field.addedAt), updatedAt: try int64(record, Field.updatedAt),
                                  contentSize: optionalInt64(record, Field.contentSize))
            r.schema = schema
            r.generation = generation
            decoded = .game(r)
        case .session:
            asset(.screenshot, field: Field.screenshot)
            var r = SyncSession(sessionID: try entity(record, Field.sessionID), fingerprint: try fingerprint(record, Field.fingerprint),
                                installationID: try entity(record, Field.installationID), deviceKind: try string(record, Field.deviceKind),
                                coreID: try string(record, Field.coreID), startedAt: try int64(record, Field.startedAt),
                                endedAt: optionalInt64(record, Field.endedAt), pausedMs: optionalInt64(record, Field.pausedMs) ?? 0,
                                hasScreenshot: assets[.screenshot] != nil)
            r.schema = schema
            r.generation = generation
            decoded = .session(r)
        case .batteryRevision:
            asset(.data, field: Field.data); asset(.screenshot, field: Field.screenshot)
            let parents = (record[Field.parentIDs] as? [String]) ?? []
            let parentIDs = try parents.map { s -> BatteryRevisionID in guard let id = BatteryRevisionID(s) else { throw RecordCodecError.invalidField(Field.parentIDs) }; return id }
            var r = SyncBatteryRevision(revisionID: try entity(record, Field.revisionID), fingerprint: try fingerprint(record, Field.fingerprint),
                                        parentIDs: parentIDs, createdAt: try int64(record, Field.createdAt),
                                        dataFingerprint: try fingerprint(record, Field.dataFingerprint), dataSize: try int64(record, Field.dataSize),
                                        installationID: try entity(record, Field.installationID), deviceKind: try string(record, Field.deviceKind),
                                        hasScreenshot: assets[.screenshot] != nil)
            r.schema = schema
            r.generation = generation
            decoded = .batteryRevision(r)
        case .state:
            asset(.payload, field: Field.payload); asset(.screenshot, field: Field.screenshot)
            var r = SyncSaveState(stateID: try entity(record, Field.stateID), fingerprint: try fingerprint(record, Field.fingerprint),
                                  kind: try string(record, Field.kind), coreID: try string(record, Field.coreID),
                                  coreVersion: try string(record, Field.coreVersion),
                                  stateCompatibilityVersion: try string(record, Field.stateCompatibilityVersion),
                                  formatVersion: try int(record, Field.formatVersion), createdAt: try int64(record, Field.createdAt),
                                  payloadFingerprint: try fingerprint(record, Field.payloadFingerprint), payloadSize: try int64(record, Field.payloadSize),
                                  batteryRevisionID: try optionalEntity(record, Field.batteryRevisionID),
                                  installationID: try entity(record, Field.installationID), deviceKind: try string(record, Field.deviceKind),
                                  label: record[Field.label] as? String, hasScreenshot: assets[.screenshot] != nil)
            r.schema = schema
            r.generation = generation
            decoded = .state(r)
        case .tombstone:
            var r = SyncTombstone(targetKind: try string(record, Field.targetKind), targetKey: try string(record, Field.targetKey),
                                  deletedAt: try int64(record, Field.deletedAt), installationID: try entity(record, Field.installationID))
            r.schema = schema
            r.generation = generation
            if record[Field.gameFingerprint] != nil { r.gameFingerprint = try fingerprint(record, Field.gameFingerprint) }
            decoded = .tombstone(r)
        case .contentIndex:
            var r = SyncContentIndex(fingerprint: try fingerprint(record, Field.fingerprint), size: try int64(record, Field.size),
                                     fileName: try string(record, Field.fileName), systemID: try string(record, Field.systemID),
                                     partCount: try int(record, Field.partCount), uploadedAt: try int64(record, Field.uploadedAt),
                                     installationID: try entity(record, Field.installationID))
            r.schema = schema
            r.generation = generation
            decoded = .contentIndex(r)
        case .gameContent:
            asset(.data, field: Field.data)
            var r = SyncGameContent(fingerprint: try fingerprint(record, Field.fingerprint), partIndex: try int(record, Field.partIndex),
                                    partCount: try int(record, Field.partCount), partFingerprint: try fingerprint(record, Field.partFingerprint),
                                    partSize: try int64(record, Field.partSize))
            r.schema = schema
            r.generation = generation
            decoded = .gameContent(r)
        case .artwork:
            asset(.data, field: Field.data)
            var r = SyncArtwork(fingerprint: try fingerprint(record, Field.fingerprint),
                                artworkFingerprint: record[Field.artworkFingerprint] == nil ? nil : try fingerprint(record, Field.artworkFingerprint),
                                artworkSize: optionalInt64(record, Field.artworkSize), updatedAt: try int64(record, Field.updatedAt),
                                installationID: try entity(record, Field.installationID))
            r.schema = schema
            r.generation = generation
            decoded = .artwork(r)
        }
        // The record name must be the deterministic key for its content (a renamed record is refused).
        guard decoded.key.name == record.recordID.recordName else { throw RecordCodecError.invalidField("recordName") }
        return (decoded, assets)
    }

    // MARK: Record identity

    public static func recordID(for key: RecordKey, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: key.name, zoneID: zoneID)
    }

    /// The key a CloudKit record ID names, when it is one of ours.
    public static func key(for recordID: CKRecord.ID, type: String) -> RecordKey? {
        guard let recordType = SyncRecordType(rawValue: type) else { return nil }
        return RecordKey(type: recordType, name: recordID.recordName)
    }

    // MARK: Typed field access

    private func string(_ r: CKRecord, _ f: String) throws -> String {
        guard let v = r[f] as? String else { throw RecordCodecError.missingField(f) }
        guard v.count <= 4096 else { throw RecordCodecError.invalidField(f) }
        return v
    }

    private func int64(_ r: CKRecord, _ f: String) throws -> Int64 {
        if let v = r[f] as? Int64 { return v }
        if let v = r[f] as? Int { return Int64(v) }
        if let v = r[f] as? NSNumber { return v.int64Value }
        throw RecordCodecError.missingField(f)
    }

    private func optionalInt64(_ r: CKRecord, _ f: String) -> Int64? {
        if let v = r[f] as? Int64 { return v }
        if let v = r[f] as? Int { return Int64(v) }
        if let v = r[f] as? NSNumber { return v.int64Value }
        return nil
    }

    private func int(_ r: CKRecord, _ f: String) throws -> Int {
        let v = try int64(r, f)
        guard v >= Int64(Int32.min), v <= Int64(Int32.max) else { throw RecordCodecError.invalidField(f) }
        return Int(v)
    }

    private func fingerprint(_ r: CKRecord, _ f: String) throws -> ContentFingerprint {
        do { return try ContentFingerprint(parsing: try string(r, f)) } catch { throw RecordCodecError.invalidField(f) }
    }

    private func entity<T: EntityIdentifier>(_ r: CKRecord, _ f: String) throws -> T {
        guard let id = T(try string(r, f)) else { throw RecordCodecError.invalidField(f) }
        return id
    }

    private func optionalEntity<T: EntityIdentifier>(_ r: CKRecord, _ f: String) throws -> T? {
        guard let s = r[f] as? String else { return nil }
        guard let id = T(s) else { throw RecordCodecError.invalidField(f) }
        return id
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncRecords.swift
//  RelayPersistence
//
//  journal, meta, tombstones, deferred remote records, cloud content
//  descriptors) and the journal writer every mutating repository call uses
//  inside its own transaction. Internal: nothing outside this package sees a
//  GRDB type.

import Foundation
import GRDB
import RelayDomain
import RelayLibrary

// MARK: battery_revision / battery_head

struct BatteryRevisionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "battery_revision"

    var id: String
    var gameId: String
    var parentIds: String
    var createdAt: Int64
    var dataFingerprint: String
    var sizeInBytes: Int64
    var installationId: String
    var deviceKind: String
    var locationRoot: String
    var locationPath: String
    var screenshotRoot: String?
    var screenshotPath: String?
    var origin: String

    var generation: Int64

    enum CodingKeys: String, CodingKey {
        case generation
        case id, origin
        case gameId = "game_id"
        case parentIds = "parent_ids"
        case createdAt = "created_at"
        case dataFingerprint = "data_fingerprint"
        case sizeInBytes = "size_in_bytes"
        case installationId = "installation_id"
        case deviceKind = "device_kind"
        case locationRoot = "location_root"
        case locationPath = "location_path"
        case screenshotRoot = "screenshot_root"
        case screenshotPath = "screenshot_path"
    }

    init(_ r: BatteryRevision) {
        id = r.id.description
        generation = r.generation
        gameId = r.gameID.description
        parentIds = JSON.encode(r.parentIDs.map(\.description))
        createdAt = Timestamps.millis(r.createdAt)
        dataFingerprint = r.dataFingerprint.canonicalString
        sizeInBytes = r.sizeInBytes
        installationId = r.installationID.description
        deviceKind = r.deviceKind.rawValue
        locationRoot = r.location.root.rawValue
        locationPath = r.location.relativePath
        screenshotRoot = r.screenshotLocation?.root.rawValue
        screenshotPath = r.screenshotLocation?.relativePath
        origin = r.origin.rawValue
    }

    func toDomain() throws -> BatteryRevision {
        guard let revisionID = BatteryRevisionID(id), let gameID = GameID(gameId), let installation = InstallationID(installationId) else {
            throw LibraryError.storage("invalid battery_revision ids '\(id)'")
        }
        let parents = JSON.decode([String].self, parentIds).compactMap(BatteryRevisionID.init)
        var screenshot: ContentLocation?
        if let screenshotRoot, let screenshotPath { screenshot = try ContentLocation(root: screenshotRoot, path: screenshotPath) }
        return BatteryRevision(id: revisionID, gameID: gameID, parentIDs: parents, createdAt: Timestamps.date(createdAt),
                               dataFingerprint: try ContentFingerprint(parsing: dataFingerprint), sizeInBytes: sizeInBytes,
                               installationID: installation, deviceKind: DeviceKind(lenient: deviceKind),
                               location: try ContentLocation(root: locationRoot, path: locationPath),
                               screenshotLocation: screenshot, origin: SyncOrigin(rawValue: origin) ?? .remote, generation: generation)
    }
}

struct BatteryHeadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "battery_head"
    var gameId: String
    var revisionId: String
    enum CodingKeys: String, CodingKey {
        case gameId = "game_id"
        case revisionId = "revision_id"
    }
}

// MARK: sync_journal

struct SyncJournalRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_journal"

    var sequence: Int64?
    var kind: String
    var key: String
    var operation: String
    var createdAt: Int64
    var attempts: Int
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case sequence, kind, key, operation, attempts
        case createdAt = "created_at"
        case lastError = "last_error"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        sequence = inserted.rowID
    }

    func toEntry() throws -> SyncJournalEntry {
        guard let sequence, let kind = SyncIntent.Kind(rawValue: kind), let operation = SyncIntent.Operation(rawValue: operation) else {
            throw LibraryError.storage("invalid sync_journal row '\(key)'")
        }
        return SyncJournalEntry(id: sequence, intent: SyncIntent(kind: kind, key: key, operation: operation),
                                createdAt: Timestamps.date(createdAt), attempts: attempts, lastError: lastError)
    }
}

/// Records intents inside the caller's transaction. Coalesces: a pending
/// intent for the same (kind, key, operation) is replaced by a newer one at
/// the end of the queue.
enum JournalWriter {
    static func record(_ intent: SyncIntent, in db: Database, now: Date = Date()) throws {
        try db.execute(sql: "DELETE FROM sync_journal WHERE kind = ? AND key = ? AND operation = ?",
                       arguments: [intent.kind.rawValue, intent.key, intent.operation.rawValue])
        let row = SyncJournalRecord(sequence: nil, kind: intent.kind.rawValue, key: intent.key, operation: intent.operation.rawValue,
                                    createdAt: Timestamps.millis(now), attempts: 0, lastError: nil)
        try row.insert(db)
    }

    static func record(_ intents: [SyncIntent], in db: Database, now: Date = Date()) throws {
        for intent in intents { try record(intent, in: db, now: now) }
    }
}

// MARK: sync_meta

enum SyncMeta {
    static let installationID = "installation_id"
    static let deviceKind = "device_kind"

    static func value(_ key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM sync_meta WHERE key = ?", arguments: [key])
    }

    static func set(_ value: String?, key: String, in db: Database) throws {
        if let value {
            try db.execute(sql: "INSERT INTO sync_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM sync_meta WHERE key = ?", arguments: [key])
        }
    }

    static func identity(in db: Database) throws -> SyncIdentity {
        guard let raw = try value(installationID, in: db), let id = InstallationID(raw) else {
            throw LibraryError.storage("sync_meta has no installation id")
        }
        return SyncIdentity(installationID: id, deviceKind: DeviceKind(lenient: try value(deviceKind, in: db) ?? "unknown"))
    }
}

// MARK: sync_tombstone

struct SyncTombstoneRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_tombstone"
    var targetKind: String
    var targetKey: String
    var generation: Int64
    var gameFingerprint: String?
    var deletedAt: Int64
    var installationId: String

    enum CodingKeys: String, CodingKey {
        case generation
        case targetKind = "target_kind"
        case targetKey = "target_key"
        case gameFingerprint = "game_fingerprint"
        case deletedAt = "deleted_at"
        case installationId = "installation_id"
    }

    init(_ tombstone: DeletionTombstone) {
        targetKind = tombstone.target.kindName
        targetKey = tombstone.target.keyString
        generation = tombstone.generation
        gameFingerprint = tombstone.gameFingerprint?.canonicalString
        deletedAt = Timestamps.millis(tombstone.deletedAt)
        installationId = tombstone.installationID.description
    }

    func toDomain() throws -> DeletionTombstone {
        guard let installation = InstallationID(installationId) else { throw LibraryError.storage("invalid tombstone installation id") }
        let target: DeletionTombstone.Target
        switch targetKind {
        case "game": target = .game(try ContentFingerprint(parsing: targetKey))
        case "state":
            guard let id = SaveStateID(targetKey) else { throw LibraryError.storage("invalid tombstone state id") }
            target = .saveState(id)
        default: throw LibraryError.storage("unknown tombstone kind")
        }
        return DeletionTombstone(target: target, deletedAt: Timestamps.date(deletedAt), installationID: installation,
                                 generation: generation, gameFingerprint: try gameFingerprint.map(ContentFingerprint.init(parsing:)))
    }

    static func fetch(_ target: DeletionTombstone.Target, generation: Int64 = 0, in db: Database) throws -> DeletionTombstone? {
        let request = SyncTombstoneRecord.filter(Column("target_kind") == target.kindName && Column("target_key") == target.keyString)
        if case .game = target { return try request.filter(Column("generation") == generation).fetchOne(db)?.toDomain() }
        // State UUID suppression is permanent, including legacy orphan tombstones.
        return try request.order(Column("deleted_at").desc).fetchOne(db)?.toDomain()
    }

    static func upsert(_ tombstone: DeletionTombstone, in db: Database) throws {
        try GenerationRules.validate(tombstone.generation)
        if case .game(let fingerprint) = tombstone.target {
            try GenerationRules.retire(fingerprint, through: tombstone.generation, in: db)
        }
        try db.execute(sql: """
            INSERT INTO sync_tombstone (target_kind, target_key, generation, game_fingerprint, deleted_at, installation_id)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(target_kind, target_key, generation) DO UPDATE SET
              deleted_at = MAX(deleted_at, excluded.deleted_at),
              game_fingerprint = COALESCE(game_fingerprint, excluded.game_fingerprint),
              installation_id = CASE WHEN excluded.deleted_at > deleted_at THEN excluded.installation_id ELSE installation_id END
            """, arguments: [tombstone.target.kindName, tombstone.target.keyString, tombstone.generation,
                              tombstone.gameFingerprint?.canonicalString, Timestamps.millis(tombstone.deletedAt), tombstone.installationID.description])
    }
}

// MARK: sync_deferred

struct SyncDeferredRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_deferred"
    var key: String
    var kind: String
    var payload: Data
    var reason: String
    var receivedAt: Int64

    var remoteScope: String

    enum CodingKeys: String, CodingKey {
        case remoteScope = "remote_scope"
        case key, kind, payload, reason
        case receivedAt = "received_at"
    }

    init(_ d: DeferredRemoteRecord, remoteScope: String = "cloudkit") {
        self.remoteScope = remoteScope
        key = d.key
        kind = d.kind
        payload = d.payload
        reason = d.reason
        receivedAt = Timestamps.millis(d.receivedAt)
    }

    func toDomain() -> DeferredRemoteRecord {
        DeferredRemoteRecord(key: key, kind: kind, payload: payload, reason: reason, receivedAt: Timestamps.date(receivedAt))
    }
}

// MARK: game_content

struct GameContentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "game_content"
    var fingerprint: String
    var sizeInBytes: Int64
    var fileName: String
    var systemId: String
    var parts: String
    var uploadedAt: Int64

    var remoteScope: String

    var generation: Int64

    enum CodingKeys: String, CodingKey {
        case generation
        case remoteScope = "remote_scope"
        case fingerprint, parts
        case sizeInBytes = "size_in_bytes"
        case fileName = "file_name"
        case systemId = "system_id"
        case uploadedAt = "uploaded_at"
    }

    struct PartJSON: Codable { var index: Int; var fingerprint: String; var size: Int64 }

    init(_ d: GameContentDescriptor, remoteScope: String = "cloudkit") {
        self.remoteScope = remoteScope
        fingerprint = d.fingerprint.canonicalString
        generation = d.generation
        sizeInBytes = d.sizeInBytes
        fileName = d.fileName
        systemId = d.systemID.rawValue
        parts = JSON.encode(d.parts.map { PartJSON(index: $0.index, fingerprint: $0.fingerprint.canonicalString, size: $0.sizeInBytes) })
        uploadedAt = Timestamps.millis(d.uploadedAt)
    }

    func toDomain() throws -> GameContentDescriptor {
        let decodedParts = try JSON.decode([PartJSON].self, parts).map {
            GameContentDescriptor.Part(index: $0.index, fingerprint: try ContentFingerprint(parsing: $0.fingerprint), sizeInBytes: $0.size)
        }
        return GameContentDescriptor(fingerprint: try ContentFingerprint(parsing: fingerprint), sizeInBytes: sizeInBytes, fileName: fileName,
                                     systemID: SystemID(rawValue: systemId), parts: decodedParts, uploadedAt: Timestamps.date(uploadedAt), generation: generation)
    }
}

// MARK: JSON helper

enum JSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(value)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ string: String) -> T where T: ExpressibleByArrayLiteral {
        (try? JSONDecoder().decode(type, from: Data(string.utf8))) ?? []
    }
}

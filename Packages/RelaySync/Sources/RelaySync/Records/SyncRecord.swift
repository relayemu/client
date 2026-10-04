// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncRecord.swift
//  RelaySync
//
//  The portable envelope of everything Relay synchronizes. No CloudKit type
//  appears here: the CloudKit adapter maps these values to records, and any
//  future transport (Relay Sync) can carry the same envelope.
//
//    - every record has a `schema` version; readers refuse newer versions;
//    - games are keyed by content fingerprint, never by a local GameID;
//    - timestamps are Int64 milliseconds since 1970 UTC;
//    - record names are deterministic from the logical key (idempotent uploads);
//    - binary content travels as named assets next to the record.

import Foundation
import RelayDomain

/// The two zones of the private database: lightweight (engine-managed) and heavy content (on demand).
public enum SyncZone: String, Codable, Sendable, CaseIterable {
    case sync = "RelaySync"
    case content = "RelayContent"
}

public enum SyncRecordType: String, Codable, Sendable, CaseIterable {
    case game = "RelayGame"
    case session = "RelaySession"
    case batteryRevision = "RelayBatteryRevision"
    case state = "RelayState"
    case tombstone = "RelayTombstone"
    case contentIndex = "RelayContentIndex"
    case gameContent = "RelayGameContent"
    /// A game's custom cover (semantic schema 3). Older builds skip this type.
    case artwork = "RelayArtwork"

    public var zone: SyncZone { self == .gameContent ? .content : .sync }
}

/// Deterministic identity of one cloud record.
public struct RecordKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let type: SyncRecordType
    public let name: String

    public init(type: SyncRecordType, name: String) {
        self.type = type
        self.name = name
    }

    public var zone: SyncZone { type.zone }
    public var description: String { "\(type.rawValue)/\(name)" }

    /// Logical membership encoded by generation-aware content keys.
    public var contentMembership: GameMembership? {
        let prefix: String
        switch type {
        case .contentIndex: prefix = "content-index:"
        case .gameContent: prefix = "content:"
        default: return nil
        }
        guard name.hasPrefix(prefix) else { return nil }
        let pieces = String(name.dropFirst(prefix.count)).components(separatedBy: ":generation:")
        guard pieces.count <= 2 else { return nil }
        let generation = pieces.count == 2 ? Int64(pieces[1]) : 0
        guard let generation, (0...Int64(Int32.max)).contains(generation) else { return nil }
        let digest = type == .gameContent ? String(pieces[0].prefix(64)) : pieces[0]
        guard let fp = try? ContentFingerprint(parsing: "sha256:" + digest) else { return nil }
        let expected: RecordKey
        if type == .contentIndex { expected = Self.contentIndex(fp, generation: generation) }
        else {
            guard let part = Int(pieces[0].dropFirst(65)), part >= 0 else { return nil }
            expected = Self.gameContent(fp, part: part, generation: generation)
        }
        guard expected == self else { return nil }
        return GameMembership(fingerprint: fp, generation: generation)
    }

    /// Raw CloudKit deletion notifications retain the semantic UUID even when
    /// the storage key names a later generation. State suppression is permanent.
    public var stateID: SaveStateID? {
        guard type == .state, name.hasPrefix("state:") else { return nil }
        let pieces = String(name.dropFirst("state:".count)).components(separatedBy: ":generation:")
        guard pieces.count <= 2, let id = SaveStateID(pieces[0]),
              let generation = pieces.count == 2 ? Int64(pieces[1]) : 0,
              (0...Int64(Int32.max)).contains(generation), Self.state(id, generation: generation) == self else { return nil }
        return id
    }

    private static func generationSuffix(_ generation: Int64) -> String { generation == 0 ? "" : ":generation:\(generation)" }

    public static func game(_ fingerprint: ContentFingerprint, generation: Int64 = 0) -> RecordKey { RecordKey(type: .game, name: "game:\(fingerprint.hexDigest)" + generationSuffix(generation)) }
    public static func session(_ id: PlaySessionID, generation: Int64 = 0) -> RecordKey { RecordKey(type: .session, name: "session:\(id)" + generationSuffix(generation)) }
    public static func batteryRevision(_ id: BatteryRevisionID, generation: Int64 = 0) -> RecordKey { RecordKey(type: .batteryRevision, name: "battery:\(id)" + generationSuffix(generation)) }
    public static func state(_ id: SaveStateID, generation: Int64 = 0) -> RecordKey { RecordKey(type: .state, name: "state:\(id)" + generationSuffix(generation)) }
    public static func tombstone(_ target: DeletionTombstone.Target, generation: Int64 = 0) -> RecordKey { RecordKey(type: .tombstone, name: "tombstone:\(target.kindName):\(target.keyString)" + (target.kindName == "game" ? generationSuffix(generation) : "")) }
    public static func contentIndex(_ fingerprint: ContentFingerprint, generation: Int64 = 0) -> RecordKey { RecordKey(type: .contentIndex, name: "content-index:\(fingerprint.hexDigest)" + generationSuffix(generation)) }
    public static func gameContent(_ fingerprint: ContentFingerprint, part: Int, generation: Int64 = 0) -> RecordKey { RecordKey(type: .gameContent, name: "content:\(fingerprint.hexDigest):\(part)" + generationSuffix(generation)) }
    public static func artwork(_ fingerprint: ContentFingerprint, generation: Int64 = 0) -> RecordKey { RecordKey(type: .artwork, name: "artwork:\(fingerprint.hexDigest)" + generationSuffix(generation)) }
}

/// Names of the binary assets a record can carry.
public enum SyncAssetName: String, Codable, Sendable, CaseIterable {
    /// Battery bytes (`RelayBatteryRevision`) or game content bytes (`RelayGameContent`).
    case data
    /// The `.relaystate` container (`RelayState`).
    case payload
    /// PNG screenshot (`RelaySession`, `RelayBatteryRevision`, `RelayState`).
    case screenshot
}

public enum SyncSchema {
    /// The record schema this build writes and the highest it accepts for every
    /// schema-2 kind. It stays 2 so older builds keep reading those records.
    public static let version = 2
    /// Semantic schema 3 adds only the artwork kind, which carries this version.
    public static let artwork = 3
}

/// A game membership's custom cover (cover-art spec §3): one last-writer-wins
/// value, ordered by (updatedAt ms, "sha256:<hex>" or "" when cleared), the same
/// order Relay Sync applies. A cleared value has no fingerprint, size or asset;
/// a cover travels as the `data` asset (normalised HEIC, at most 1 MiB).
public struct SyncArtwork: Hashable, Codable, Sendable {
    public var schema: Int = SyncSchema.artwork
    public var generation: Int64
    public var fingerprint: ContentFingerprint
    public var artworkFingerprint: ContentFingerprint?
    public var artworkSize: Int64?
    public var updatedAt: Int64
    public var installationID: InstallationID

    public init(fingerprint: ContentFingerprint, artworkFingerprint: ContentFingerprint?, artworkSize: Int64?, updatedAt: Int64,
                installationID: InstallationID, generation: Int64 = 0) {
        self.generation = generation
        self.fingerprint = fingerprint
        self.artworkFingerprint = artworkFingerprint
        self.artworkSize = artworkSize
        self.updatedAt = updatedAt
        self.installationID = installationID
    }

    public var isCleared: Bool { artworkFingerprint == nil }

    /// Whether (updatedAt, cover) orders after another value of the same register.
    public static func isLater(updatedAt: Int64, cover: ContentFingerprint?, than otherUpdatedAt: Int64, _ otherCover: ContentFingerprint?) -> Bool {
        if updatedAt != otherUpdatedAt { return updatedAt > otherUpdatedAt }
        return (cover?.canonicalString ?? "") > (otherCover?.canonicalString ?? "")
    }
}

public struct SyncGameEntry: Hashable, Codable, Sendable {
    public var schema: Int = SyncSchema.version
    public var generation: Int64
    public var fingerprint: ContentFingerprint
    public var systemID: String
    public var title: String
    public var isFavorite: Bool
    public var addedAt: Int64
    public var updatedAt: Int64
    public var contentSize: Int64?

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        generation = schema <= 1 ? (try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0) : (try values.decode(Int64.self, forKey: .generation))
        fingerprint = try values.decode(ContentFingerprint.self, forKey: .fingerprint)
        systemID = try values.decode(String.self, forKey: .systemID)
        title = try values.decode(String.self, forKey: .title)
        isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
        addedAt = try values.decode(Int64.self, forKey: .addedAt)
        updatedAt = try values.decode(Int64.self, forKey: .updatedAt)
        contentSize = try values.decodeIfPresent(Int64.self, forKey: .contentSize)
    }

    public init(fingerprint: ContentFingerprint, systemID: String, title: String, isFavorite: Bool, addedAt: Int64, updatedAt: Int64, contentSize: Int64?, generation: Int64 = 0) {
        self.generation = generation
        self.fingerprint = fingerprint
        self.systemID = systemID
        self.title = title
        self.isFavorite = isFavorite
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.contentSize = contentSize
    }
}

public struct SyncSession: Hashable, Codable, Sendable {
    public var schema: Int = SyncSchema.version
    public var generation: Int64
    public var sessionID: PlaySessionID
    public var fingerprint: ContentFingerprint
    public var installationID: InstallationID
    public var deviceKind: String
    public var coreID: String
    public var startedAt: Int64
    public var endedAt: Int64?
    public var pausedMs: Int64
    public var hasScreenshot: Bool

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        generation = schema <= 1 ? (try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0) : (try values.decode(Int64.self, forKey: .generation))
        sessionID = try values.decode(PlaySessionID.self, forKey: .sessionID)
        fingerprint = try values.decode(ContentFingerprint.self, forKey: .fingerprint)
        installationID = try values.decode(InstallationID.self, forKey: .installationID)
        deviceKind = try values.decode(String.self, forKey: .deviceKind)
        coreID = try values.decode(String.self, forKey: .coreID)
        startedAt = try values.decode(Int64.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Int64.self, forKey: .endedAt)
        pausedMs = try values.decode(Int64.self, forKey: .pausedMs)
        hasScreenshot = try values.decode(Bool.self, forKey: .hasScreenshot)
    }

    public init(sessionID: PlaySessionID, fingerprint: ContentFingerprint, installationID: InstallationID, deviceKind: String, coreID: String,
                startedAt: Int64, endedAt: Int64?, pausedMs: Int64, hasScreenshot: Bool, generation: Int64 = 0) {
        self.generation = generation
        self.sessionID = sessionID
        self.fingerprint = fingerprint
        self.installationID = installationID
        self.deviceKind = deviceKind
        self.coreID = coreID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedMs = pausedMs
        self.hasScreenshot = hasScreenshot
    }
}

public struct SyncBatteryRevision: Hashable, Codable, Sendable {
    public var schema: Int = SyncSchema.version
    public var generation: Int64
    public var revisionID: BatteryRevisionID
    public var fingerprint: ContentFingerprint
    public var parentIDs: [BatteryRevisionID]
    public var createdAt: Int64
    public var dataFingerprint: ContentFingerprint
    public var dataSize: Int64
    public var installationID: InstallationID
    public var deviceKind: String
    public var hasScreenshot: Bool

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        generation = schema <= 1 ? (try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0) : (try values.decode(Int64.self, forKey: .generation))
        revisionID = try values.decode(BatteryRevisionID.self, forKey: .revisionID)
        fingerprint = try values.decode(ContentFingerprint.self, forKey: .fingerprint)
        parentIDs = try values.decode([BatteryRevisionID].self, forKey: .parentIDs)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        dataFingerprint = try values.decode(ContentFingerprint.self, forKey: .dataFingerprint)
        dataSize = try values.decode(Int64.self, forKey: .dataSize)
        installationID = try values.decode(InstallationID.self, forKey: .installationID)
        deviceKind = try values.decode(String.self, forKey: .deviceKind)
        hasScreenshot = try values.decode(Bool.self, forKey: .hasScreenshot)
    }

    public init(revisionID: BatteryRevisionID, fingerprint: ContentFingerprint, parentIDs: [BatteryRevisionID], createdAt: Int64,
                dataFingerprint: ContentFingerprint, dataSize: Int64, installationID: InstallationID, deviceKind: String, hasScreenshot: Bool, generation: Int64 = 0) {
        self.generation = generation
        self.revisionID = revisionID
        self.fingerprint = fingerprint
        self.parentIDs = parentIDs
        self.createdAt = createdAt
        self.dataFingerprint = dataFingerprint
        self.dataSize = dataSize
        self.installationID = installationID
        self.deviceKind = deviceKind
        self.hasScreenshot = hasScreenshot
    }
}

public struct SyncSaveState: Hashable, Codable, Sendable {
    public var schema: Int = SyncSchema.version
    public var generation: Int64
    public var stateID: SaveStateID
    public var fingerprint: ContentFingerprint
    public var kind: String
    public var coreID: String
    public var coreVersion: String
    public var stateCompatibilityVersion: String
    public var formatVersion: Int
    public var createdAt: Int64
    public var payloadFingerprint: ContentFingerprint
    public var payloadSize: Int64
    public var batteryRevisionID: BatteryRevisionID?
    public var installationID: InstallationID
    public var deviceKind: String
    public var label: String?
    public var hasScreenshot: Bool

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        generation = schema <= 1 ? (try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0) : (try values.decode(Int64.self, forKey: .generation))
        stateID = try values.decode(SaveStateID.self, forKey: .stateID)
        fingerprint = try values.decode(ContentFingerprint.self, forKey: .fingerprint)
        kind = try values.decode(String.self, forKey: .kind)
        coreID = try values.decode(String.self, forKey: .coreID)
        coreVersion = try values.decode(String.self, forKey: .coreVersion)
        stateCompatibilityVersion = try values.decode(String.self, forKey: .stateCompatibilityVersion)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        payloadFingerprint = try values.decode(ContentFingerprint.self, forKey: .payloadFingerprint)
        payloadSize = try values.decode(Int64.self, forKey: .payloadSize)
        batteryRevisionID = try values.decodeIfPresent(BatteryRevisionID.self, forKey: .batteryRevisionID)
        installationID = try values.decode(InstallationID.self, forKey: .installationID)
        deviceKind = try values.decode(String.self, forKey: .deviceKind)
        label = try values.decodeIfPresent(String.self, forKey: .label)
        hasScreenshot = try values.decode(Bool.self, forKey: .hasScreenshot)
    }

    public init(stateID: SaveStateID, fingerprint: ContentFingerprint, kind: String, coreID: String, coreVersion: String,
                stateCompatibilityVersion: String, formatVersion: Int, createdAt: Int64, payloadFingerprint: ContentFingerprint,
                payloadSize: Int64, batteryRevisionID: BatteryRevisionID?, installationID: InstallationID, deviceKind: String,
                label: String?, hasScreenshot: Bool, generation: Int64 = 0) {
        self.generation = generation
        self.stateID = stateID
        self.fingerprint = fingerprint
        self.kind = kind
        self.coreID = coreID
        self.coreVersion = coreVersion
        self.stateCompatibilityVersion = stateCompatibilityVersion
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.payloadFingerprint = payloadFingerprint
        self.payloadSize = payloadSize
        self.batteryRevisionID = batteryRevisionID
        self.installationID = installationID
        self.deviceKind = deviceKind
        self.label = label
        self.hasScreenshot = hasScreenshot
    }
}

public struct SyncTombstone: Hashable, Codable, Sendable {
    public var schema: Int = SyncSchema.version
    public var generation: Int64
    public var gameFingerprint: ContentFingerprint?
    public var targetKind: String
    public var targetKey: String
    public var deletedAt: Int64
    public var installationID: InstallationID

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        generation = schema <= 1 ? (try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0) : (try values.decode(Int64.self, forKey: .generation))
        gameFingerprint = try values.decodeIfPresent(ContentFingerprint.self, forKey: .gameFingerprint)
        targetKind = try values.decode(String.self, forKey: .targetKind)
        targetKey = try values.decode(String.self, forKey: .targetKey)
        deletedAt = try values.decode(Int64.self, forKey: .deletedAt)
        installationID = try values.decode(InstallationID.self, forKey: .installationID)
    }

    public init(targetKind: String, targetKey: String, deletedAt: Int64, installationID: InstallationID, generation: Int64 = 0, gameFingerprint: ContentFingerprint? = nil) {
        self.generation = generation
        self.gameFingerprint = gameFingerprint
        self.targetKind = targetKind
        self.targetKey = targetKey
        self.deletedAt = deletedAt
        self.installationID = installationID
    }

    public init(_ tombstone: DeletionTombstone) {
        self.init(targetKind: tombstone.target.kindName, targetKey: tombstone.target.keyString,
                  deletedAt: SyncTime.millis(tombstone.deletedAt), installationID: tombstone.installationID, generation: tombstone.generation, gameFingerprint: tombstone.gameFingerprint)
    }

    public var target: DeletionTombstone.Target? {
        switch targetKind {
        case "game": return (try? ContentFingerprint(parsing: targetKey)).map { .game($0) }
        case "state": return SaveStateID(targetKey).map { .saveState($0) }
        default: return nil
        }
    }
}

public struct SyncContentIndex: Hashable, Codable, Sendable {
    public var schema: Int = SyncSchema.version
    public var generation: Int64
    public var fingerprint: ContentFingerprint
    public var size: Int64
    public var fileName: String
    public var systemID: String
    public var partCount: Int
    public var uploadedAt: Int64
    public var installationID: InstallationID

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        generation = schema <= 1 ? (try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0) : (try values.decode(Int64.self, forKey: .generation))
        fingerprint = try values.decode(ContentFingerprint.self, forKey: .fingerprint)
        size = try values.decode(Int64.self, forKey: .size)
        fileName = try values.decode(String.self, forKey: .fileName)
        systemID = try values.decode(String.self, forKey: .systemID)
        partCount = try values.decode(Int.self, forKey: .partCount)
        uploadedAt = try values.decode(Int64.self, forKey: .uploadedAt)
        installationID = try values.decode(InstallationID.self, forKey: .installationID)
    }

    public init(fingerprint: ContentFingerprint, size: Int64, fileName: String, systemID: String, partCount: Int, uploadedAt: Int64, installationID: InstallationID, generation: Int64 = 0) {
        self.generation = generation
        self.fingerprint = fingerprint
        self.size = size
        self.fileName = fileName
        self.systemID = systemID
        self.partCount = partCount
        self.uploadedAt = uploadedAt
        self.installationID = installationID
    }
}

public struct SyncGameContent: Hashable, Codable, Sendable {
    public var schema: Int = SyncSchema.version
    public var generation: Int64
    public var fingerprint: ContentFingerprint
    public var partIndex: Int
    public var partCount: Int
    public var partFingerprint: ContentFingerprint
    public var partSize: Int64

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        generation = schema <= 1 ? (try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0) : (try values.decode(Int64.self, forKey: .generation))
        fingerprint = try values.decode(ContentFingerprint.self, forKey: .fingerprint)
        partIndex = try values.decode(Int.self, forKey: .partIndex)
        partCount = try values.decode(Int.self, forKey: .partCount)
        partFingerprint = try values.decode(ContentFingerprint.self, forKey: .partFingerprint)
        partSize = try values.decode(Int64.self, forKey: .partSize)
    }

    public init(fingerprint: ContentFingerprint, partIndex: Int, partCount: Int, partFingerprint: ContentFingerprint, partSize: Int64, generation: Int64 = 0) {
        self.generation = generation
        self.fingerprint = fingerprint
        self.partIndex = partIndex
        self.partCount = partCount
        self.partFingerprint = partFingerprint
        self.partSize = partSize
    }
}

public enum SyncRecord: Hashable, Codable, Sendable {
    case game(SyncGameEntry)
    case session(SyncSession)
    case batteryRevision(SyncBatteryRevision)
    case state(SyncSaveState)
    case tombstone(SyncTombstone)
    case contentIndex(SyncContentIndex)
    case gameContent(SyncGameContent)
    case artwork(SyncArtwork)

    public var type: SyncRecordType {
        switch self {
        case .game: return .game
        case .session: return .session
        case .batteryRevision: return .batteryRevision
        case .state: return .state
        case .tombstone: return .tombstone
        case .contentIndex: return .contentIndex
        case .gameContent: return .gameContent
        case .artwork: return .artwork
        }
    }

    public var schema: Int {
        switch self {
        case .game(let r): return r.schema
        case .session(let r): return r.schema
        case .batteryRevision(let r): return r.schema
        case .state(let r): return r.schema
        case .tombstone(let r): return r.schema
        case .contentIndex(let r): return r.schema
        case .gameContent(let r): return r.schema
        case .artwork(let r): return r.schema
        }
    }

    public var generation: Int64 {
        switch self {
        case .game(let r): return r.generation
        case .session(let r): return r.generation
        case .batteryRevision(let r): return r.generation
        case .state(let r): return r.generation
        case .tombstone(let r): return r.generation
        case .contentIndex(let r): return r.generation
        case .gameContent(let r): return r.generation
        case .artwork(let r): return r.generation
        }
    }

    public var key: RecordKey {
        switch self {
        case .game(let r): return .game(r.fingerprint, generation: r.generation)
        case .session(let r): return .session(r.sessionID, generation: r.generation)
        case .batteryRevision(let r): return .batteryRevision(r.revisionID, generation: r.generation)
        case .state(let r): return .state(r.stateID, generation: r.generation)
        case .tombstone(let r):
            if let target = r.target { return .tombstone(target, generation: r.generation) }
            return RecordKey(type: .tombstone, name: "tombstone:\(r.targetKind):\(r.targetKey)")
        case .contentIndex(let r): return .contentIndex(r.fingerprint, generation: r.generation)
        case .gameContent(let r): return .gameContent(r.fingerprint, part: r.partIndex, generation: r.generation)
        case .artwork(let r): return .artwork(r.fingerprint, generation: r.generation)
        }
    }

    /// The game this record concerns, when it concerns one.
    public var gameFingerprint: ContentFingerprint? {
        switch self {
        case .game(let r): return r.fingerprint
        case .session(let r): return r.fingerprint
        case .batteryRevision(let r): return r.fingerprint
        case .state(let r): return r.fingerprint
        case .tombstone(let r): if case .game(let fp)? = r.target { return fp } else { return r.gameFingerprint }
        case .contentIndex(let r): return r.fingerprint
        case .gameContent(let r): return r.fingerprint
        case .artwork(let r): return r.fingerprint
        }
    }

    /// Whether two records with the same key carry the same immutable content.
    public var isImmutable: Bool {
        switch self {
        case .game, .session, .artwork: return false
        case .batteryRevision, .state, .tombstone, .contentIndex, .gameContent: return true
        }
    }
}

public enum SyncTime {
    public static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    public static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

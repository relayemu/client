// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain
import RelaySync

/// Integer-preserving JSON used only at the protocol boundary, never as domain state.
public enum HostedJSON: Codable, Equatable, Sendable {
    case string(String), integer(Int64), bool(Bool), array([HostedJSON]), object([String: HostedJSON]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Int64.self) { self = .integer(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([HostedJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: HostedJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var integer: Int64? { if case .integer(let n) = self { n } else { nil } }
}

public struct HostedOperation: Codable, Equatable, Sendable {
    public var operationId: String
    public var schema: Int
    public var kind: String
    public var action: String
    public var object: [String: HostedJSON]
}
public struct HostedChange: Codable, Sendable {
    public var sequence: Int64
    public var kind: String
    public var objectKey: String
    public var operation: String
    public var object: [String: HostedJSON]
}
struct HostedChangesPage: Decodable, Sendable {
    var schema: Int
    var changes: [HostedChange]
    var nextCursor: Int64
    var hasMore: Bool
}
struct HostedPushResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        var operationId: String
        var status: String
        var sequence: Int64?
        var error: String?
    }
    var results: [Result]
}

public enum HostedWireCodec {
    /// Every operation carries the schema its request negotiates (2, or 3 with artwork).
    public static func encode(_ record: SyncRecord, operationID: UUID, schema: Int,
                              screenshot: ContentFingerprint? = nil) throws -> HostedOperation {
        _ = try SyncRecordValidator().validate(record)
        guard (SyncSchema.version...SyncSchema.artwork).contains(schema) else { throw HostedHTTPError.invalidResponse }
        var value: [String: HostedJSON]
        let kind: String
        var action = "upsert"
        switch record {
        case .game(let r): kind = "game"; value = try dictionary(r); value["contentSize"] = nil
        case .batteryRevision(let r): kind = "battery_revision"; value = try dictionary(r)
        case .state(let r):
            kind = "save_state"; value = try dictionary(r)
            value["stateKind"] = value.removeValue(forKey: "kind")
        case .session(let r): kind = "play_session"; value = try dictionary(r)
        case .tombstone(let r):
            kind = "tombstone"; value = try dictionary(r)
            value["fingerprint"] = value.removeValue(forKey: "gameFingerprint")
        case .contentIndex(let r):
            guard r.partCount == 1 else { throw HostedHTTPError.invalidResponse }
            kind = "content_availability"
            value = ["fingerprint": .string(r.fingerprint.description), "stored": .bool(true),
                     "generation": .integer(r.generation), "payloadFingerprint": .string(r.fingerprint.description), "size": .integer(r.size), "fileName": .string(r.fileName)]
        case .gameContent: throw HostedHTTPError.invalidResponse
        case .artwork(let r):
            guard schema >= SyncSchema.artwork else { throw HostedHTTPError.invalidResponse }
            // A reset is the `delete` action and names no cover.
            kind = "artwork"; action = r.isCleared ? "delete" : "upsert"
            value = ["fingerprint": .string(r.fingerprint.description), "generation": .integer(r.generation),
                     "updatedAt": .integer(r.updatedAt), "installationID": .string(r.installationID.description)]
            if let cover = r.artworkFingerprint, let size = r.artworkSize {
                value["artworkFingerprint"] = .string(cover.description); value["artworkSize"] = .integer(size)
            }
        }
        value["schema"] = nil
        let advertised = value.removeValue(forKey: "hasScreenshot")
        if advertised == .bool(true) && screenshot == nil { throw HostedHTTPError.invalidResponse }
        if let screenshot { value["screenshotFingerprint"] = .string(screenshot.description) }
        try validateIdentifiers(value)
        return HostedOperation(operationId: operationID.uuidString.lowercased(), schema: schema, kind: kind,
                               action: action, object: value)
    }

    /// Asset descriptors stay beside the canonical record. The coordinator retains all resolution rules.
    public struct Decoded: Sendable {
        public var record: SyncRecord?
        public var deletion: RecordKey?
        public var screenshot: ContentFingerprint?
    }
    /// `schema` is the page's; only a schema-3 page may carry artwork.
    public static func decode(_ change: HostedChange, schema: Int = SyncSchema.version, gameSystemID: String = "unknown") throws -> Decoded {
        guard change.sequence > 0, change.operation == "upsert" || change.operation == "delete" else { throw HostedHTTPError.invalidResponse }
        if change.kind == "artwork" { return try decodeArtwork(change, schema: schema) }
        var value = change.object
        try validateIdentifiers(value)
        guard let generation = value["generation"]?.integer, (0...2_147_483_647).contains(generation) else { throw HostedHTTPError.invalidResponse }
        if let schema = value["schema"], schema != .integer(2) { throw HostedHTTPError.invalidResponse }
        let screenshot = try value["screenshotFingerprint"].flatMap { item -> ContentFingerprint? in
            if item == .null { return nil }
            guard let raw = item.string else { throw HostedHTTPError.invalidResponse }
            return try ContentFingerprint(parsing: raw)
        }
        value["schema"] = .integer(2)
        value["hasScreenshot"] = .bool(screenshot != nil)
        let record: SyncRecord
        let expectedKey: String
        switch change.kind {
        case "game":
            let r: SyncGameEntry = try decodeValue(value); record = .game(r); expectedKey = r.fingerprint.description
        case "battery_revision":
            if value["parentIDs"] == .null || value["parentIDs"] == nil { value["parentIDs"] = .array([]) }
            let r: SyncBatteryRevision = try decodeValue(value); record = .batteryRevision(r); expectedKey = r.revisionID.description
        case "save_state":
            value["kind"] = value.removeValue(forKey: "stateKind")
            let r: SyncSaveState = try decodeValue(value); record = .state(r); expectedKey = r.stateID.description
        case "play_session":
            let r: SyncSession = try decodeValue(value); record = .session(r); expectedKey = r.sessionID.description
        case "tombstone":
            value["gameFingerprint"] = value.removeValue(forKey: "fingerprint")
            let r: SyncTombstone = try decodeValue(value); record = .tombstone(r); expectedKey = r.targetKind + ":" + r.targetKey
        case "content_availability":
            guard change.operation == "upsert", let raw = value["fingerprint"]?.string, let stored = value["stored"],
                  change.objectKey == raw else { throw HostedHTTPError.invalidResponse }
            let fp = try ContentFingerprint(parsing: raw)
            if stored == .bool(false) {
                return Decoded(record: nil, deletion: .contentIndex(fp, generation: generation), screenshot: nil)
            }
            guard stored == .bool(true), value["payloadFingerprint"]?.string == raw,
                  let size = value["size"]?.integer, let fileName = value["fileName"]?.string else { throw HostedHTTPError.invalidResponse }
            // Availability has no device/time/system provenance. Use an explicit unknown source;
            // the game's canonical system is resolved from its own semantic record.
            record = .contentIndex(SyncContentIndex(fingerprint: fp, size: size, fileName: fileName, systemID: gameSystemID,
                partCount: 1, uploadedAt: 946_684_800_000,
                installationID: InstallationID(rawValue: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))), generation: generation))
            expectedKey = raw
        default: throw HostedHTTPError.invalidResponse
        }
        guard change.objectKey == expectedKey else { throw HostedHTTPError.invalidResponse }
        // Deletion semantics travel as tombstones. A raw delete of an immutable record is invalid.
        guard change.operation == "upsert" || change.kind == "tombstone" else { throw HostedHTTPError.invalidResponse }
        return Decoded(record: try SyncRecordValidator().validate(record), deletion: nil, screenshot: screenshot)
    }

    private static func decodeArtwork(_ change: HostedChange, schema: Int) throws -> Decoded {
        let value = change.object
        try validateIdentifiers(value)
        let upsert = change.operation == "upsert"
        guard schema >= SyncSchema.artwork, Set(value.keys).isSubset(of: ["fingerprint", "generation", "updatedAt", "installationID", "artworkFingerprint", "artworkSize"]),
              let raw = value["fingerprint"]?.string, change.objectKey == raw,
              let generation = value["generation"]?.integer, (0...2_147_483_647).contains(generation),
              let updatedAt = value["updatedAt"]?.integer,
              let rawInstallation = value["installationID"]?.string, let installation = InstallationID(rawInstallation),
              upsert == (value["artworkFingerprint"] != nil), upsert == (value["artworkSize"] != nil) else { throw HostedHTTPError.invalidResponse }
        var cover: ContentFingerprint?, size: Int64?
        if upsert {
            guard let rawCover = value["artworkFingerprint"]?.string, let bytes = value["artworkSize"]?.integer else { throw HostedHTTPError.invalidResponse }
            cover = try ContentFingerprint(parsing: rawCover); size = bytes
        }
        let record = SyncRecord.artwork(SyncArtwork(fingerprint: try ContentFingerprint(parsing: raw), artworkFingerprint: cover, artworkSize: size,
                                                    updatedAt: updatedAt, installationID: installation, generation: generation))
        return Decoded(record: try SyncRecordValidator().validate(record), deletion: nil, screenshot: nil)
    }

    static func dictionary<T: Encodable>(_ value: T) throws -> [String: HostedJSON] {
        try JSONDecoder().decode([String: HostedJSON].self, from: JSONEncoder().encode(value))
    }
    static func decodeValue<T: Decodable>(_ value: [String: HostedJSON]) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)) }
        catch { throw HostedHTTPError.invalidResponse }
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func validateIdentifiers(_ value: [String: HostedJSON]) throws {
        for key in ["revisionID", "stateID", "sessionID", "installationID", "batteryRevisionID"] {
            if let item = value[key], item != .null {
                guard let s = item.string, let id = UUID(uuidString: s), id.uuidString.lowercased() == s,
                      id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else { throw HostedHTTPError.invalidResponse }
            }
        }
        if let parents = value["parentIDs"], parents != .null {
            guard case .array(let ids) = parents else { throw HostedHTTPError.invalidResponse }
            for id in ids { try validateIdentifiers(["revisionID": id]) }
            guard Set(ids.compactMap(\.string)).count == ids.count else { throw HostedHTTPError.invalidResponse }
        }
        for key in ["fingerprint", "gameFingerprint", "dataFingerprint", "payloadFingerprint", "screenshotFingerprint", "artworkFingerprint"] {
            if let item = value[key], item != .null {
                guard let raw = item.string, let fp = try? ContentFingerprint(parsing: raw), fp.description == raw else { throw HostedHTTPError.invalidResponse }
            }
        }
        if let raw = value["deviceKind"]?.string,
           !["iphone", "ipad", "appletv", "mac", "android", "unknown"].contains(raw) { throw HostedHTTPError.invalidResponse }
    }
}

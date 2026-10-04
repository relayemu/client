// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncRecordValidator.swift
//  RelaySync
//
//  Remote data is untrusted. Every inbound record passes here before any
//  file is staged or any row is written: schema version, enumerations,
//  sizes, string lengths, path-safe names. Identifiers and fingerprints are
//  already typed (decoding validated them). Sanitisable fields are cleaned;
//  anything else is rejected with a classification, never partially applied.

import Foundation
import RelayDomain
import RelayLibrary

public enum SyncValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case unknownEnumValue(field: String, value: String)
    case sizeOutOfRange(field: String, value: Int64)
    case invalidField(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let v): return "record schema \(v) is newer than this Relay"
        case .unknownEnumValue(let f, let v): return "unknown value '\(v)' for \(f)"
        case .sizeOutOfRange(let f, let v): return "\(f) = \(v) is out of range"
        case .invalidField(let f): return "invalid field \(f)"
        }
    }
}

public enum SyncLimits {
    public static let maxTitleLength = 200
    public static let maxBatterySize: Int64 = 8 * 1024 * 1024
    public static let maxStateSize: Int64 = 256 * 1024 * 1024
    public static let maxContentSize: Int64 = 4 * 1024 * 1024 * 1024
    public static let maxContentPartSize: Int64 = 64 * 1024 * 1024
    public static let maxScreenshotSize: Int64 = 4 * 1024 * 1024
    public static let maxPartCount = 256
    /// A custom cover (normalised HEIC); matches `CoverImage.maximumBytes` and the server's bound.
    public static let maxArtworkSize = Int64(CoverImage.maximumBytes)
}

public struct SyncRecordValidator: Sendable {
    public init() {}

    /// Returns a sanitised copy or throws.
    public func validate(_ record: SyncRecord) throws -> SyncRecord {
        // Artwork exists only in schema 3; every other kind stays within 1...2.
        if case .artwork = record {
            guard record.schema == SyncSchema.artwork else { throw SyncValidationError.unsupportedSchema(record.schema) }
        } else {
            guard record.schema <= SyncSchema.version, record.schema >= 1 else { throw SyncValidationError.unsupportedSchema(record.schema) }
        }
        guard (0...Int64(Int32.max)).contains(record.generation), record.schema != 1 || record.generation == 0 else { throw SyncValidationError.invalidField("generation") }
        switch record {
        case .game(var r):
            r.systemID = try Self.systemID(r.systemID)
            r.title = Self.sanitizedTitle(r.title)
            if let size = r.contentSize { try Self.size(size, field: "contentSize", max: SyncLimits.maxContentSize) }
            try Self.time(r.addedAt, field: "addedAt"); try Self.time(r.updatedAt, field: "updatedAt")
            return .game(r)
        case .session(var r):
            r.deviceKind = Self.deviceKind(r.deviceKind)
            r.coreID = try Self.identifier(r.coreID, field: "coreID")
            try Self.time(r.startedAt, field: "startedAt")
            if let ended = r.endedAt { try Self.time(ended, field: "endedAt"); guard ended >= r.startedAt else { throw SyncValidationError.invalidField("endedAt < startedAt") } }
            guard r.pausedMs >= 0 else { throw SyncValidationError.sizeOutOfRange(field: "pausedMs", value: r.pausedMs) }
            return .session(r)
        case .batteryRevision(var r):
            r.deviceKind = Self.deviceKind(r.deviceKind)
            try Self.size(r.dataSize, field: "dataSize", max: SyncLimits.maxBatterySize, min: 1)
            try Self.time(r.createdAt, field: "createdAt")
            guard r.parentIDs.count <= 64, Set(r.parentIDs).count == r.parentIDs.count, !r.parentIDs.contains(r.revisionID) else { throw SyncValidationError.invalidField("parentIDs") }
            return .batteryRevision(r)
        case .state(var r):
            r.deviceKind = Self.deviceKind(r.deviceKind)
            guard SaveState.Kind(rawValue: r.kind) != nil else { throw SyncValidationError.unknownEnumValue(field: "kind", value: r.kind) }
            r.coreID = try Self.identifier(r.coreID, field: "coreID")
            guard !r.coreVersion.isEmpty, r.coreVersion.count <= 64, !r.stateCompatibilityVersion.isEmpty, r.stateCompatibilityVersion.count <= 64 else {
                throw SyncValidationError.invalidField("coreVersion")
            }
            guard r.formatVersion >= 1, r.formatVersion <= SaveState.currentFormatVersion else { throw SyncValidationError.invalidField("formatVersion") }
            try Self.size(r.payloadSize, field: "payloadSize", max: SyncLimits.maxStateSize, min: 1)
            try Self.time(r.createdAt, field: "createdAt")
            if let label = r.label { r.label = String(Self.sanitizedTitle(label).prefix(SyncLimits.maxTitleLength)) }
            return .state(r)
        case .tombstone(let r):
            guard r.target != nil else { throw SyncValidationError.unknownEnumValue(field: "targetKind", value: r.targetKind) }
            if case .game(let fingerprint)? = r.target, let context = r.gameFingerprint, context != fingerprint {
                throw SyncValidationError.invalidField("tombstone game fingerprint")
            }
            try Self.time(r.deletedAt, field: "deletedAt")
            return .tombstone(r)
        case .contentIndex(var r):
            r.systemID = try Self.systemID(r.systemID)
            r.fileName = LibraryLocation.sanitizedFileName(r.fileName)
            try Self.size(r.size, field: "size", max: SyncLimits.maxContentSize, min: 1)
            guard r.partCount >= 1, r.partCount <= SyncLimits.maxPartCount else { throw SyncValidationError.invalidField("partCount") }
            try Self.time(r.uploadedAt, field: "uploadedAt")
            return .contentIndex(r)
        case .gameContent(let r):
            guard r.partCount >= 1, r.partCount <= SyncLimits.maxPartCount, r.partIndex >= 0, r.partIndex < r.partCount else {
                throw SyncValidationError.invalidField("partIndex")
            }
            // This is a logical content object. The active transport decides
            // its physical transfer chunks (CloudKit assets or hosted multipart).
            try Self.size(r.partSize, field: "partSize", max: SyncLimits.maxContentSize, min: 1)
            return .gameContent(r)
        case .artwork(let r):
            // A cover names its image and size together; a cleared value names neither.
            guard (r.artworkFingerprint == nil) == (r.artworkSize == nil) else { throw SyncValidationError.invalidField("artwork") }
            if let size = r.artworkSize { try Self.size(size, field: "artworkSize", max: SyncLimits.maxArtworkSize, min: 1) }
            try Self.time(r.updatedAt, field: "updatedAt")
            return .artwork(r)
        }
    }

    // MARK: Field rules

    static func systemID(_ raw: String) throws -> String {
        let value = raw.lowercased()
        guard (1...32).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw SyncValidationError.invalidField("systemID")
        }
        return value
    }

    static func identifier(_ raw: String, field: String) throws -> String {
        guard (1...64).contains(raw.count), raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else {
            throw SyncValidationError.invalidField(field)
        }
        return raw
    }

    static func deviceKind(_ raw: String) -> String { DeviceKind(lenient: raw).rawValue }

    static func sanitizedTitle(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.filter { !($0.value < 0x20 || $0.value == 0x7f) }
        let trimmed = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(trimmed.prefix(SyncLimits.maxTitleLength))
        return bounded.isEmpty ? "Game" : bounded
    }

    static func size(_ value: Int64, field: String, max: Int64, min: Int64 = 0) throws {
        guard value >= min, value <= max else { throw SyncValidationError.sizeOutOfRange(field: field, value: value) }
    }

    /// Between 2000-01-01 and 2200-01-01 (a sanity window; the value is not otherwise interpreted).
    static func time(_ millis: Int64, field: String) throws {
        guard millis >= 946_684_800_000, millis <= 7_258_118_400_000 else { throw SyncValidationError.invalidField(field) }
    }
}

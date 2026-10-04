// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SaveStateContainer.swift
//  RelayLibrary
//
//  Relay's on-disk save-state file (`.relaystate`):
//
//      "RLAYSTAT" (8 bytes) · header length (UInt32 LE) · header JSON · payload
//
//  The header repeats the identity the database row carries (game, core, core
//  version, kind, creation time) plus the payload length and SHA-256, so a
//  file can be checked without trusting the row and a truncated or tampered
//  file is refused as corrupt. The payload is the core's opaque machine state.
//
//  game identity that means the same thing on every device — and the core's

import Foundation
import RelayDomain

public struct SaveStateContainer: Equatable, Sendable {
    public static let magic = Data("RLAYSTAT".utf8)
    public static let currentFormatVersion = SaveState.currentFormatVersion
    /// Upper bound on a header (JSON of a few hundred bytes in practice).
    static let maxHeaderLength = 64 * 1024
    /// Upper bound on a payload; the largest planned systems' states stay below this.
    public static let maxPayloadLength = 256 * 1024 * 1024

    public struct Header: Codable, Equatable, Sendable {
        public var formatVersion: Int
        /// Local `GameID` of the writer (bookkeeping; differs across devices).
        public var gameID: GameID
        /// Content identity of the game (format 2+; nil in version 1 files).
        public var gameFingerprint: ContentFingerprint?
        public var coreID: CoreID
        public var coreVersion: String
        /// Format 2+; nil in version 1 files (then equal to `coreVersion` by policy).
        public var stateCompatibilityVersion: String?
        public var kind: SaveState.Kind
        /// Milliseconds since 1970 (portable; matches the database).
        public var createdAtMillis: Int64
        public var payloadLength: Int
        public var payloadFingerprint: ContentFingerprint

        /// The compatibility version the header declares (version 1 files: the core version).
        public var effectiveCompatibilityVersion: String { stateCompatibilityVersion ?? coreVersion }
    }

    public enum ContainerError: Error, Equatable, Sendable, CustomStringConvertible {
        case notAContainer
        case unsupportedFormatVersion(Int)
        case malformedHeader(String)
        case truncated(expected: Int, actual: Int)
        case fingerprintMismatch
        case tooLarge(Int)

        public var description: String {
            switch self {
            case .notAContainer: return "not a Relay save state"
            case .unsupportedFormatVersion(let v): return "save state format \(v) is newer than this Relay"
            case .malformedHeader(let s): return "malformed save state header: \(s)"
            case .truncated(let e, let a): return "save state truncated: expected \(e) bytes, found \(a)"
            case .fingerprintMismatch: return "save state payload does not match its fingerprint"
            case .tooLarge(let n): return "save state of \(n) bytes exceeds the limit"
            }
        }
    }

    public let header: Header
    public let payload: Data

    public init(header: Header, payload: Data) {
        self.header = header
        self.payload = payload
    }

    /// Builds a format-2 container for `payload` produced by `core` for a game.
    public init(gameID: GameID, contentFingerprint: ContentFingerprint, core: EmulatorCoreDescriptor, kind: SaveState.Kind,
                createdAt: Date, payload: Data) throws {
        guard payload.count <= Self.maxPayloadLength else { throw ContainerError.tooLarge(payload.count) }
        let fingerprint = try SHA256ContentHasher().hash(data: payload).fingerprint
        header = Header(formatVersion: Self.currentFormatVersion, gameID: gameID, gameFingerprint: contentFingerprint,
                        coreID: core.id, coreVersion: core.version, stateCompatibilityVersion: core.stateCompatibilityVersion,
                        kind: kind, createdAtMillis: Int64((createdAt.timeIntervalSince1970 * 1000).rounded()),
                        payloadLength: payload.count, payloadFingerprint: fingerprint)
        self.payload = payload
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headerData = try encoder.encode(header)
        var out = Data(capacity: Self.magic.count + 4 + headerData.count + payload.count)
        out.append(Self.magic)
        var length = UInt32(headerData.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(headerData)
        out.append(payload)
        return out
    }

    /// Decodes and fully validates a container (magic, header, length, fingerprint).
    public static func decode(_ data: Data) throws -> SaveStateContainer {
        guard data.count >= magic.count + 4, data.prefix(magic.count) == magic else { throw ContainerError.notAContainer }
        let lengthRange = magic.count..<(magic.count + 4)
        let headerLength = Int(data[lengthRange].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard headerLength > 0, headerLength <= maxHeaderLength else { throw ContainerError.malformedHeader("length \(headerLength)") }
        let headerStart = magic.count + 4
        guard data.count >= headerStart + headerLength else { throw ContainerError.truncated(expected: headerStart + headerLength, actual: data.count) }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data[headerStart..<(headerStart + headerLength)])
        } catch {
            throw ContainerError.malformedHeader(String(describing: error))
        }
        guard header.formatVersion <= currentFormatVersion else { throw ContainerError.unsupportedFormatVersion(header.formatVersion) }
        guard header.formatVersion >= 1 else { throw ContainerError.malformedHeader("format version \(header.formatVersion)") }
        if header.formatVersion >= 2 {
            guard header.gameFingerprint != nil, header.stateCompatibilityVersion != nil else {
                throw ContainerError.malformedHeader("format 2 header without game fingerprint or compatibility version")
            }
        }
        guard header.payloadLength >= 0, header.payloadLength <= maxPayloadLength else { throw ContainerError.tooLarge(header.payloadLength) }
        let payloadStart = headerStart + headerLength
        let expected = payloadStart + header.payloadLength
        guard data.count == expected else { throw ContainerError.truncated(expected: expected, actual: data.count) }
        let payload = Data(data[payloadStart..<expected])
        let fingerprint = try SHA256ContentHasher().hash(data: payload).fingerprint
        guard fingerprint == header.payloadFingerprint else { throw ContainerError.fingerprintMismatch }
        return SaveStateContainer(header: header, payload: payload)
    }

    /// Reads only the header of a container file (cheap; no payload validation).
    public static func readHeader(at url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: magic.count + 4), prefix.count == magic.count + 4, prefix.prefix(magic.count) == magic else {
            throw ContainerError.notAContainer
        }
        let headerLength = Int(prefix[magic.count..<(magic.count + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard headerLength > 0, headerLength <= maxHeaderLength, let headerData = try handle.read(upToCount: headerLength), headerData.count == headerLength else {
            throw ContainerError.malformedHeader("length \(headerLength)")
        }
        do { return try JSONDecoder().decode(Header.self, from: headerData) } catch { throw ContainerError.malformedHeader(String(describing: error)) }
    }
}

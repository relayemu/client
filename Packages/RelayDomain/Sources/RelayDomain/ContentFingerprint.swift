// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ContentFingerprint.swift
//  RelayDomain
//
//  Content identity. A fingerprint is a cryptographic digest of game content,
//  used for de-duplication and for reconciling the same content imported
//  independently on several devices. It is never an object identity: a game
//  keeps its `GameID` if its content is re-imported or re-fingerprinted.
//
//    - algorithm: SHA-256, always;
//    - single-file games: SHA-256 of the complete file bytes as imported
//      (no header stripping, no byte swapping) — for such games the game
//      fingerprint equals the primary file fingerprint;
//    - multi-file games (future): the game fingerprint is the SHA-256 of a
//      canonical manifest of the member file fingerprints; the member files
//    - MD5/CRC are never Relay identity. They may be computed on demand for
//      external metadata databases or legacy migration only.
//
//  String form: "sha256:" followed by 64 lowercase hexadecimal characters.

import Foundation

public struct ContentFingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Algorithm: String, Codable, Sendable, CaseIterable {
        case sha256

        /// Digest length in bytes.
        public var digestSize: Int {
            switch self {
            case .sha256: return 32
            }
        }
    }

    public let algorithm: Algorithm
    /// Raw digest bytes (`algorithm.digestSize` bytes).
    public let digest: [UInt8]

    /// Creates a SHA-256 fingerprint from a 32-byte digest.
    public init(sha256 digest: [UInt8]) throws {
        try self.init(algorithm: .sha256, digest: digest)
    }

    public init(algorithm: Algorithm, digest: [UInt8]) throws {
        guard digest.count == algorithm.digestSize else {
            throw ContentFingerprintError.invalidDigestLength(expected: algorithm.digestSize, actual: digest.count)
        }
        self.algorithm = algorithm
        self.digest = digest
    }

    /// Parses the canonical string form, e.g. `sha256:9f86d0…`.
    /// Hexadecimal digits are accepted in either case; the stored form is lowercase.
    public init(parsing string: String) throws {
        guard let separator = string.firstIndex(of: ":") else {
            throw ContentFingerprintError.malformed(string)
        }
        let name = String(string[..<separator])
        guard let algorithm = Algorithm(rawValue: name) else {
            throw ContentFingerprintError.unsupportedAlgorithm(name)
        }
        let hex = string[string.index(after: separator)...]
        guard hex.count == algorithm.digestSize * 2, let bytes = Self.bytes(fromHex: hex) else {
            throw ContentFingerprintError.malformed(string)
        }
        try self.init(algorithm: algorithm, digest: bytes)
    }

    /// Lowercase hexadecimal digest without the algorithm prefix.
    public var hexDigest: String {
        digest.map { Self.hexTable[Int($0)] }.joined()
    }

    /// Canonical string form: `<algorithm>:<hex digest>`.
    public var canonicalString: String { "\(algorithm.rawValue):\(hexDigest)" }

    public var description: String { canonicalString }

    // MARK: Codable (single string value)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(parsing: string)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid content fingerprint '\(string)': \(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalString)
    }

    // MARK: Hex helpers

    private static let hexTable: [String] = (0..<256).map { String(format: "%02x", $0) }

    private static func bytes(fromHex hex: Substring) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next > index, let byte = UInt8(hex[index..<next], radix: 16), hex.distance(from: index, to: next) == 2 else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public enum ContentFingerprintError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformed(String)
    case unsupportedAlgorithm(String)
    case invalidDigestLength(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .malformed(let s): return "Malformed content fingerprint '\(s)'"
        case .unsupportedAlgorithm(let s): return "Unsupported fingerprint algorithm '\(s)'"
        case .invalidDigestLength(let expected, let actual): return "Invalid digest length: expected \(expected) bytes, got \(actual)"
        }
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ContentHashing.swift
//  RelayLibrary
//
//  SHA-256 fingerprinting of local files. Streams the file in chunks off the
//  calling actor so hashing a large disc image never blocks the main actor.
//
//  CryptoKit is the only Apple-specific import in RelayLibrary; it is isolated
//  in this file so a non-Apple port swaps one implementation (swift-crypto
//  exposes the same API surface).

import Foundation
import RelayDomain
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct HashedContent: Sendable, Hashable {
    public let fingerprint: ContentFingerprint
    public let sizeInBytes: Int64

    public init(fingerprint: ContentFingerprint, sizeInBytes: Int64) {
        self.fingerprint = fingerprint
        self.sizeInBytes = sizeInBytes
    }
}

public protocol ContentHasher: Sendable {
    /// Fingerprints the file at `url` (its complete bytes).
    func hash(fileAt url: URL) async throws -> HashedContent
    /// Fingerprints in-memory bytes (tests, small manifests).
    func hash(data: Data) throws -> HashedContent
}

public enum ContentHashingError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileNotFound(URL)
    case unreadable(URL, reason: String)

    public var description: String {
        switch self {
        case .fileNotFound(let url): return "File not found: \(url.path)"
        case .unreadable(let url, let reason): return "Cannot read \(url.path): \(reason)"
        }
    }
}

public struct SHA256ContentHasher: ContentHasher {
    public static let chunkSize = 1 << 20  // 1 MiB

    public init() {}

    public func hash(fileAt url: URL) async throws -> HashedContent {
        // Detached so the blocking file reads run on a background thread, whatever actor calls us.
        try await Task.detached(priority: .utility) { try Self.hashSynchronously(fileAt: url) }.value
    }

    public func hash(data: Data) throws -> HashedContent {
        let digest = SHA256.hash(data: data)
        return HashedContent(fingerprint: try ContentFingerprint(sha256: Array(digest)), sizeInBytes: Int64(data.count))
    }

    /// Synchronous streaming implementation; call off the main actor.
    public static func hashSynchronously(fileAt url: URL) throws -> HashedContent {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ContentHashingError.fileNotFound(url) }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ContentHashingError.unreadable(url, reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let byteCount: Int
            do {
                // Foundation reads can autorelease their NSData backing. Drain
                // each chunk so a full-file scan keeps a bounded working set.
                let readChunk = {
                    let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                    if chunk.isEmpty { return 0 }
                    hasher.update(data: chunk)
                    return chunk.count
                }
                #if canImport(ObjectiveC)
                byteCount = try autoreleasepool(invoking: readChunk)
                #else
                byteCount = try readChunk()
                #endif
            } catch {
                throw ContentHashingError.unreadable(url, reason: error.localizedDescription)
            }
            if byteCount == 0 { break }
            total += Int64(byteCount)
        }
        let digest = hasher.finalize()
        return HashedContent(fingerprint: try ContentFingerprint(sha256: Array(digest)), sizeInBytes: total)
    }
}

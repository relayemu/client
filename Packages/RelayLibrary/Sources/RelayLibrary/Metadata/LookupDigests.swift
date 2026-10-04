// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LookupDigests.swift
//  RelayLibrary
//
//  Keys used only to look a game up in a metadata catalog: the SHA-1 that
//  No-Intro and Redump publish, and a PlayStation disc serial. They are never
//  Relay identity (SHA-256 is) and are never synchronized.

import Foundation
import RelayDomain
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct LookupDigests: Hashable, Sendable, Codable {
    /// Lowercase hex SHA-1 of the whole file; for a disc package, of its first track.
    public var sha1: String
    /// SHA-1 without a 512-byte copier header (SNES and PC Engine dumps that carry one).
    public var headerlessSHA1: String?
    /// Disc serial named by SYSTEM.CNF, in Redump's form ("SLUS-01234").
    public var discSerial: String?

    public init(sha1: String, headerlessSHA1: String? = nil, discSerial: String? = nil) {
        self.sha1 = sha1
        self.headerlessSHA1 = headerlessSHA1
        self.discSerial = discSerial
    }
}

public enum LookupDigester {
    /// Systems whose dumps may carry a copier header that No-Intro strips.
    static let copierHeaderSystems: Set<SystemID> = [.snes, .pcEngine]

    /// Reads the stored file once, off the calling actor.
    public static func digests(forFileAt url: URL, systemID: SystemID) async throws -> LookupDigests {
        try await Task.detached(priority: .utility) {
            if systemID == .playStation { return try PlayStationDiscPackage.lookupDigests(package: url) }
            return try cartridgeDigests(url, systemID: systemID)
        }.value
    }

    static func cartridgeDigests(_ url: URL, systemID: SystemID) throws -> LookupDigests {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let headered = copierHeaderSystems.contains(systemID) && size % 1024 == 512
        var whole = Insecure.SHA1(), body = Insecure.SHA1(), offset: UInt64 = 0
        while true {
            let readChunk = { try handle.read(upToCount: SHA256ContentHasher.chunkSize) ?? Data() }
            #if canImport(ObjectiveC)
            let chunk = try autoreleasepool(invoking: readChunk)
            #else
            let chunk = try readChunk()
            #endif
            if chunk.isEmpty { break }
            whole.update(data: chunk)
            if headered {
                let skip = offset < 512 ? Int(min(512 - offset, UInt64(chunk.count))) : 0
                if skip < chunk.count { body.update(data: chunk.dropFirst(skip)) }
            }
            offset += UInt64(chunk.count)
        }
        return LookupDigests(sha1: hex(whole.finalize()), headerlessSHA1: headered ? hex(body.finalize()) : nil)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ZipReader.swift
//  RelayLibrary
//
//  A minimal, defensive ZIP reader for imports. Reads the central directory,
//  supports stored (0) and deflate (8) entries, rejects everything else
//  (encryption, ZIP64, data descriptors without sizes, unknown methods) and
//  enforces hard limits before and during extraction. No third-party
//  dependency: deflate goes through Apple's Compression framework.
//
//  Safety (owner rule §15):
//    - entry names are normalised and must stay inside the destination;
//    - absolute paths, `..`, drive letters, NUL and control characters are rejected;
//    - counts and byte totals are capped from the central directory (declared
//      sizes) and again while writing (actual bytes), so a lying header cannot
//      exceed the limit; a suspicious compression ratio is rejected;
//    - extraction happens into the caller's staging directory only.

import Foundation
import Compression

public struct ArchiveLimits: Sendable, Equatable {
    public var maxEntries: Int
    public var maxTotalBytes: Int64
    public var maxEntryBytes: Int64
    /// Maximum uncompressed/compressed ratio tolerated for a single entry.
    public var maxCompressionRatio: Int64

    public init(maxEntries: Int, maxTotalBytes: Int64, maxEntryBytes: Int64, maxCompressionRatio: Int64) {
        self.maxEntries = maxEntries
        self.maxTotalBytes = maxTotalBytes
        self.maxEntryBytes = maxEntryBytes
        self.maxCompressionRatio = maxCompressionRatio
    }

    /// Conservative defaults: game archives are one to a few files, never huge.
    public static let standard = ArchiveLimits(maxEntries: 64,
                                               maxTotalBytes: 256 * 1024 * 1024,
                                               maxEntryBytes: 128 * 1024 * 1024,
                                               maxCompressionRatio: 200)
}

public enum ArchiveError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAnArchive
    case malformed(String)
    case unsupportedFeature(String)
    case unsafePath(String)
    case tooManyEntries(Int, limit: Int)
    case tooLarge(declared: Int64, limit: Int64)
    case entryTooLarge(String, declared: Int64, limit: Int64)
    case suspiciousCompression(String)
    case sizeMismatch(String)

    public var description: String {
        switch self {
        case .notAnArchive: return "Not a ZIP archive"
        case .malformed(let s): return "Malformed archive: \(s)"
        case .unsupportedFeature(let s): return "Unsupported archive feature: \(s)"
        case .unsafePath(let p): return "Unsafe path in archive: '\(p)'"
        case .tooManyEntries(let n, let limit): return "Archive has \(n) entries (limit \(limit))"
        case .tooLarge(let d, let limit): return "Archive expands to \(d) bytes (limit \(limit))"
        case .entryTooLarge(let e, let d, let limit): return "Entry '\(e)' expands to \(d) bytes (limit \(limit))"
        case .suspiciousCompression(let e): return "Entry '\(e)' has a suspicious compression ratio"
        case .sizeMismatch(let e): return "Entry '\(e)' did not expand to its declared size"
        }
    }
}

public struct ZipEntry: Sendable, Equatable {
    public let name: String
    /// Normalised relative path (forward slashes, no leading slash, no dot components).
    public let relativePath: String
    public let isDirectory: Bool
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    let method: UInt16
    let localHeaderOffset: Int64
    let crc32: UInt32
}

public struct ZipReader: Sendable {
    public let limits: ArchiveLimits

    public init(limits: ArchiveLimits = .standard) {
        self.limits = limits
    }

    /// True when the file starts with a ZIP local-file signature (cheap sniff).
    public static func looksLikeZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
    }

    /// Parses the central directory and validates every entry against the limits.
    public func entries(of url: URL) throws -> [ZipEntry] {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ArchiveError.malformed("unreadable") }
        guard data.count >= 22 else { throw ArchiveError.notAnArchive }
        guard data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) || data.prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]) else {
            throw ArchiveError.notAnArchive
        }

        // End of central directory record: scan back at most 64 KiB + 22 for the signature.
        let minEOCD = max(0, data.count - 22 - 65_535)
        var eocd = -1
        var i = data.count - 22
        while i >= minEOCD {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.malformed("missing end of central directory") }
        let entryCount = Int(le16(data, eocd + 10))
        let cdSize = Int(le32(data, eocd + 12))
        let cdOffset = Int(le32(data, eocd + 16))
        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw ArchiveError.unsupportedFeature("ZIP64")
        }
        guard entryCount <= limits.maxEntries else { throw ArchiveError.tooManyEntries(entryCount, limit: limits.maxEntries) }
        guard cdOffset + cdSize <= eocd, cdOffset >= 0 else { throw ArchiveError.malformed("central directory out of bounds") }

        var entries: [ZipEntry] = []
        var declaredTotal: Int64 = 0
        var p = cdOffset
        for _ in 0..<entryCount {
            guard p + 46 <= data.count, le32(data, p) == 0x0201_4B50 else { throw ArchiveError.malformed("bad central directory entry") }
            let flags = le16(data, p + 8)
            let method = le16(data, p + 10)
            let crc = le32(data, p + 16)
            let compressed = Int64(le32(data, p + 20))
            let uncompressed = Int64(le32(data, p + 24))
            let nameLength = Int(le16(data, p + 28))
            let extraLength = Int(le16(data, p + 30))
            let commentLength = Int(le16(data, p + 32))
            let localOffset = Int64(le32(data, p + 42))
            guard p + 46 + nameLength <= data.count else { throw ArchiveError.malformed("truncated entry name") }
            let nameData = data[(p + 46)..<(p + 46 + nameLength)]
            guard let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) else {
                throw ArchiveError.malformed("undecodable entry name")
            }
            p += 46 + nameLength + extraLength + commentLength

            if flags & 0x0001 != 0 { throw ArchiveError.unsupportedFeature("encryption") }
            if flags & 0x0008 != 0, uncompressed == 0, compressed == 0 { throw ArchiveError.unsupportedFeature("data descriptor without sizes") }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF { throw ArchiveError.unsupportedFeature("ZIP64") }
            guard method == 0 || method == 8 else { throw ArchiveError.unsupportedFeature("compression method \(method)") }

            let isDirectory = name.hasSuffix("/")
            let relativePath = try Self.safeRelativePath(name)
            if !isDirectory {
                guard uncompressed <= limits.maxEntryBytes else {
                    throw ArchiveError.entryTooLarge(name, declared: uncompressed, limit: limits.maxEntryBytes)
                }
                if method == 8, compressed > 0, uncompressed / max(compressed, 1) > limits.maxCompressionRatio {
                    throw ArchiveError.suspiciousCompression(name)
                }
                declaredTotal += uncompressed
                guard declaredTotal <= limits.maxTotalBytes else {
                    throw ArchiveError.tooLarge(declared: declaredTotal, limit: limits.maxTotalBytes)
                }
            }
            entries.append(ZipEntry(name: name, relativePath: relativePath, isDirectory: isDirectory,
                                    compressedSize: compressed, uncompressedSize: uncompressed,
                                    method: method, localHeaderOffset: localOffset, crc32: crc))
        }
        return entries
    }

    /// Extracts all file entries into `destination` (must exist, must be a directory
    /// Relay owns). Returns the URLs of the extracted files. Directory entries are
    /// created implicitly; empty directories are not created.
    @discardableResult
    public func extract(_ url: URL, into destination: URL) throws -> [URL] {
        let entries = try entries(of: url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let root = destination.standardizedFileURL
        let fm = FileManager.default
        var written: [URL] = []
        var totalWritten: Int64 = 0

        for entry in entries where !entry.isDirectory {
            let target = root.appending(path: entry.relativePath).standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else { throw ArchiveError.unsafePath(entry.name) }

            // Local header: skip its variable-length name and extra fields.
            let lh = Int(entry.localHeaderOffset)
            guard lh >= 0, lh + 30 <= data.count, le32(data, lh) == 0x0403_4B50 else { throw ArchiveError.malformed("bad local header for '\(entry.name)'") }
            let lhName = Int(le16(data, lh + 26))
            let lhExtra = Int(le16(data, lh + 28))
            let start = lh + 30 + lhName + lhExtra
            let end = start + Int(entry.compressedSize)
            guard start <= end, end <= data.count else { throw ArchiveError.malformed("entry data out of bounds for '\(entry.name)'") }
            let payload = data[start..<end]

            let bytes: Data
            switch entry.method {
            case 0:
                bytes = Data(payload)
            case 8:
                bytes = try Self.inflate(Data(payload), expectedSize: Int(entry.uncompressedSize),
                                         limit: Int(min(limits.maxEntryBytes, limits.maxTotalBytes - totalWritten)), name: entry.name)
            default:
                throw ArchiveError.unsupportedFeature("compression method \(entry.method)")
            }
            guard Int64(bytes.count) == entry.uncompressedSize else { throw ArchiveError.sizeMismatch(entry.name) }
            totalWritten += Int64(bytes.count)
            guard totalWritten <= limits.maxTotalBytes else { throw ArchiveError.tooLarge(declared: totalWritten, limit: limits.maxTotalBytes) }
            guard Self.crc32(bytes) == entry.crc32 else { throw ArchiveError.malformed("CRC mismatch for '\(entry.name)'") }

            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
            written.append(target)
        }
        return written
    }

    // MARK: Helpers

    /// Normalises an entry name to a safe relative path or throws.
    static func safeRelativePath(_ name: String) throws -> String {
        let unified = name.replacingOccurrences(of: "\\", with: "/")
        if unified.isEmpty || unified.hasPrefix("/") || unified.contains("\0") { throw ArchiveError.unsafePath(name) }
        if unified.count >= 2, unified[unified.index(unified.startIndex, offsetBy: 1)] == ":" { throw ArchiveError.unsafePath(name) }
        if unified.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { throw ArchiveError.unsafePath(name) }
        var components: [String] = []
        for component in unified.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { throw ArchiveError.unsafePath(name) }
            components.append(String(component))
        }
        guard !components.isEmpty else { throw ArchiveError.unsafePath(name) }
        return components.joined(separator: "/")
    }

    static func inflate(_ input: Data, expectedSize: Int, limit: Int, name: String) throws -> Data {
        guard expectedSize <= limit else { throw ArchiveError.entryTooLarge(name, declared: Int64(expectedSize), limit: Int64(limit)) }
        var output = Data(capacity: expectedSize)
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: bufferSize, src_ptr: buffer, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ArchiveError.malformed("inflate init failed")
        }
        defer { compression_stream_destroy(&stream) }

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base
            stream.src_size = raw.count
            var status = COMPRESSION_STATUS_OK
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw ArchiveError.malformed("corrupt deflate stream in '\(name)'") }
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(buffer, count: produced)
                    // Hard stop on actual bytes, independent of the declared size.
                    guard output.count <= limit, output.count <= expectedSize else {
                        throw ArchiveError.sizeMismatch(name)
                    }
                }
            } while status == COMPRESSION_STATUS_OK
        }
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    private func le16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[d.startIndex + i]) | (UInt16(d[d.startIndex + i + 1]) << 8)
    }

    private func le32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[d.startIndex + i]) | (UInt32(d[d.startIndex + i + 1]) << 8) | (UInt32(d[d.startIndex + i + 2]) << 16) | (UInt32(d[d.startIndex + i + 3]) << 24)
    }
}

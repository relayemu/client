// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import RelayDomain

/// Files are processed on the utility executor, in 1 MiB chunks, with propagated cancellation.
enum HostedContentFiles {
    static let chunkSize = 1 << 20

    static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func fingerprint(file: URL) throws -> (ContentFingerprint, Int64) {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            // Drain Foundation's temporary NSData backing before reading the
            // next chunk; streaming alone does not bound autoreleased memory.
            let readChunk = {
                let bytes = try input.read(upToCount: chunkSize) ?? Data()
                if bytes.isEmpty { return 0 }
                hash.update(data: bytes)
                return bytes.count
            }
            #if canImport(ObjectiveC)
            let byteCount = try autoreleasepool(invoking: readChunk)
            #else
            let byteCount = try readChunk()
            #endif
            if byteCount == 0 { break }
            count += Int64(byteCount)
        }
        return (try ContentFingerprint(sha256: Array(hash.finalize())), count)
    }

    /// Copy a bounded range to an owned file. No untrusted name is used for a destination.
    static func copy(file: URL, to destination: URL, offset: Int64, count: Int64) throws {
        guard offset >= 0, count > 0 else { throw HostedContentError.invalidUpload }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset))
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { throw HostedContentError.invalidUpload }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let copyChunk = {
                let bytes = try input.read(upToCount: Int(min(Int64(chunkSize), remaining))) ?? Data()
                guard !bytes.isEmpty else { throw HostedContentError.integrityMismatch }
                try output.write(contentsOf: bytes)
                remaining -= Int64(bytes.count)
            }
            #if canImport(ObjectiveC)
            try autoreleasepool(invoking: copyChunk)
            #else
            try copyChunk()
            #endif
        }
        try output.synchronize()
    }
}

public enum HostedProofOfPossession {
    /// Encoding is separate from production challenge policy so the immutable compact vector can be tested.
    public static func digest(fileURL: URL, nonceHex: String, ranges: [HostedProofRange]) async throws -> String {
        try await HostedContentFiles.background {
            guard nonceHex.count == 64, nonceHex.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }),
                  !ranges.isEmpty, ranges.count <= 4 else { throw HostedContentError.invalidChallenge }
            var nonce = Data()
            var index = nonceHex.startIndex
            for _ in 0..<32 {
                let end = nonceHex.index(index, offsetBy: 2)
                guard let byte = UInt8(nonceHex[index..<end], radix: 16) else { throw HostedContentError.invalidChallenge }
                nonce.append(byte); index = end
            }
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            let size = try input.seekToEnd()
            var hash = SHA256()
            hash.update(data: Data("relay-pop-v1".utf8)); hash.update(data: Data([0])); hash.update(data: nonce)
            var previousEnd: UInt64 = 0
            for range in ranges {
                try Task.checkCancellation()
                guard range.offset >= 0, range.length > 0, range.length <= 65536 else { throw HostedContentError.invalidChallenge }
                let offset = UInt64(range.offset), length = UInt64(range.length)
                guard offset >= previousEnd, offset <= size, length <= size - offset else { throw HostedContentError.invalidChallenge }
                previousEnd = offset + length
                var offsetBE = offset.bigEndian, lengthBE = length.bigEndian
                withUnsafeBytes(of: &offsetBE) { hash.update(data: Data($0)) }
                withUnsafeBytes(of: &lengthBE) { hash.update(data: Data($0)) }
                try input.seek(toOffset: offset)
                let bytes = try input.read(upToCount: Int(length)) ?? Data()
                guard bytes.count == Int(length) else { throw HostedContentError.integrityMismatch }
                hash.update(data: bytes)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}

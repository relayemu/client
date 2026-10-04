// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Compression

/// Test helpers: synthetic GBA files with valid headers, and ZIP archives built by hand.
enum GBAFixture {
    /// A minimal file that passes `GBAHeaderSignature`: ARM branch entry, fixed 0x96, valid checksum.
    static func bytes(title: String = "TEST", payload: UInt8 = 0x11, size: Int = 0x400) -> [UInt8] {
        precondition(size >= 0xC0)
        var b = [UInt8](repeating: payload, count: size)
        b[0] = 0x2E; b[1] = 0x00; b[2] = 0x00; b[3] = 0xEA        // b entry
        for i in 0x04..<0xA0 { b[i] = 0x00 }                       // logo area (not checked)
        for i in 0xA0..<0xC0 { b[i] = 0x00 }
        for (i, c) in title.utf8.prefix(12).enumerated() { b[0xA0 + i] = c }
        b[0xB0] = 0x30; b[0xB1] = 0x31                             // maker "01"
        b[0xB2] = 0x96
        var sum: UInt32 = 0
        for i in 0xA0...0xBC { sum &+= UInt32(b[i]) }
        b[0xBD] = UInt8(truncatingIfNeeded: (0 &- (sum &+ 0x19)) & 0xFF)
        return b
    }

    /// The real 240p Test Suite fixture (GPL-2.0) if present in the repository.
    static var realFixtureURL: URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/Fixtures/ROMs/240p-test-suite-gba/240pee_mb.gba")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Hand-rolled ZIP writer for tests (stored and deflate entries, arbitrary names).
struct TestZip {
    struct Entry {
        var name: String
        var data: Data
        var deflate: Bool = false
        /// Override the declared uncompressed size (to test lying headers).
        var declaredSize: UInt32? = nil
        var flags: UInt16 = 0
        var method: UInt16? = nil
    }

    static func build(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for e in entries {
            let name = Data(e.name.utf8)
            let payload: Data = e.deflate ? rawDeflate(e.data) : e.data
            let method: UInt16 = e.method ?? (e.deflate ? 8 : 0)
            let crc = crc32(e.data)
            let offset = UInt32(out.count)
            let declared = e.declaredSize ?? UInt32(e.data.count)
            // local header
            out.append(le32(0x0403_4B50)); out.append(le16(20)); out.append(le16(e.flags)); out.append(le16(method))
            out.append(le16(0)); out.append(le16(0)); out.append(le32(crc)); out.append(le32(UInt32(payload.count)))
            out.append(le32(declared)); out.append(le16(UInt16(name.count))); out.append(le16(0)); out.append(name); out.append(payload)
            // central directory
            central.append(le32(0x0201_4B50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(e.flags)); central.append(le16(method))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(crc)); central.append(le32(UInt32(payload.count)))
            central.append(le32(declared)); central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset)); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x0605_4B50)); out.append(le16(0)); out.append(le16(0)); out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(cdOffset)); out.append(le16(0))
        return out
    }

    static func rawDeflate(_ data: Data) -> Data {
        let dstSize = max(64, data.count * 2 + 64)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { raw -> Int in
            compression_encode_buffer(dst, dstSize, raw.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: dst, count: n)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
}

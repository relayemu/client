// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayLibrary

final class ZipReaderTests: XCTestCase {
    var dir: URL!
    var out: URL!

    override func setUp() async throws {
        dir = try TestSupport.temporaryDirectory()
        out = dir.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ zip: Data, _ name: String = "a.zip") throws -> URL {
        let url = dir.appending(path: name); try zip.write(to: url); return url
    }

    func testExtractsStoredAndDeflatedEntriesIntoDestination() throws {
        let gba = Data(GBAFixture.bytes(title: "ZIPPED"))
        let zip = TestZip.build([
            .init(name: "game.gba", data: gba, deflate: true),
            .init(name: "notes/readme.txt", data: Data("hello".utf8)),
            .init(name: "empty-dir/", data: Data()),
        ])
        let url = try write(zip)
        XCTAssertTrue(ZipReader.looksLikeZip(url))
        let files = try ZipReader().extract(url, into: out)
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["game.gba", "readme.txt"])
        XCTAssertEqual(try Data(contentsOf: out.appending(path: "game.gba")), gba)
        XCTAssertEqual(try String(contentsOf: out.appending(path: "notes/readme.txt"), encoding: .utf8), "hello")
        for f in files { XCTAssertTrue(f.path.hasPrefix(out.standardizedFileURL.path)) }
    }

    func testPathTraversalAndAbsolutePathsAreRejected() throws {
        for name in ["../escape.gba", "sub/../../escape.gba", "/abs.gba", "C:\\win.gba", "a\\..\\b.gba", "bad\u{0}name", "..", "./."] {
            let url = try write(TestZip.build([.init(name: name, data: Data([1, 2, 3]))]), "t.zip")
            XCTAssertThrowsError(try ZipReader().entries(of: url), name) { error in
                guard case .unsafePath = error as? ArchiveError else { return XCTFail("\(name): \(error)") }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "nothing may be written for \(name)")
        }
    }

    func testDotComponentsAreNormalisedNotRejected() throws {
        XCTAssertEqual(try ZipReader.safeRelativePath("./a/./b.gba"), "a/b.gba")
        XCTAssertEqual(try ZipReader.safeRelativePath("a//b.gba"), "a/b.gba")
    }

    func testEntryCountAndSizeLimits() throws {
        let limits = ArchiveLimits(maxEntries: 2, maxTotalBytes: 1000, maxEntryBytes: 600, maxCompressionRatio: 50)
        let three = TestZip.build((0..<3).map { .init(name: "f\($0).bin", data: Data([1])) })
        XCTAssertThrowsError(try ZipReader(limits: limits).entries(of: try write(three, "three.zip"))) {
            XCTAssertEqual($0 as? ArchiveError, .tooManyEntries(3, limit: 2))
        }
        let big = TestZip.build([.init(name: "big.bin", data: Data(repeating: 7, count: 601))])
        XCTAssertThrowsError(try ZipReader(limits: limits).entries(of: try write(big, "big.zip"))) {
            XCTAssertEqual($0 as? ArchiveError, .entryTooLarge("big.bin", declared: 601, limit: 600))
        }
        let total = TestZip.build([.init(name: "a.bin", data: Data(repeating: 1, count: 550)), .init(name: "b.bin", data: Data(repeating: 2, count: 550))])
        XCTAssertThrowsError(try ZipReader(limits: limits).entries(of: try write(total, "total.zip"))) {
            XCTAssertEqual($0 as? ArchiveError, .tooLarge(declared: 1100, limit: 1000))
        }
    }

    func testSuspiciousCompressionRatioIsRejected() throws {
        // 100 KiB of zeros deflates to a few hundred bytes: ratio far above 50.
        let zeros = Data(repeating: 0, count: 100 * 1024)
        let zip = TestZip.build([.init(name: "bomb.bin", data: zeros, deflate: true)])
        let limits = ArchiveLimits(maxEntries: 10, maxTotalBytes: 1 << 30, maxEntryBytes: 1 << 30, maxCompressionRatio: 50)
        XCTAssertThrowsError(try ZipReader(limits: limits).entries(of: try write(zip))) {
            XCTAssertEqual($0 as? ArchiveError, .suspiciousCompression("bomb.bin"))
        }
    }

    func testLyingDeclaredSizeIsCaughtDuringExtraction() throws {
        let data = Data(repeating: 9, count: 5000)
        // Declares 100 bytes but inflates to 5000: must fail, never write more than declared.
        let zip = TestZip.build([.init(name: "liar.bin", data: data, deflate: true, declaredSize: 100)])
        XCTAssertThrowsError(try ZipReader().extract(try write(zip), into: out)) {
            XCTAssertEqual($0 as? ArchiveError, .sizeMismatch("liar.bin"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appending(path: "liar.bin").path))
    }

    func testEncryptedAndUnknownMethodsAreRejected() throws {
        let enc = TestZip.build([.init(name: "x.bin", data: Data([1]), flags: 0x0001)])
        XCTAssertThrowsError(try ZipReader().entries(of: try write(enc, "enc.zip"))) {
            XCTAssertEqual($0 as? ArchiveError, .unsupportedFeature("encryption"))
        }
        let bzip = TestZip.build([.init(name: "x.bin", data: Data([1]), method: 12)])
        XCTAssertThrowsError(try ZipReader().entries(of: try write(bzip, "bz.zip"))) {
            XCTAssertEqual($0 as? ArchiveError, .unsupportedFeature("compression method 12"))
        }
    }

    func testGarbageIsNotAnArchive() throws {
        let url = try TestSupport.writeFile([UInt8](repeating: 0x42, count: 100), named: "junk.zip", in: dir)
        XCTAssertFalse(ZipReader.looksLikeZip(url))
        XCTAssertThrowsError(try ZipReader().entries(of: url)) { XCTAssertEqual($0 as? ArchiveError, .notAnArchive) }
        let truncated = try write(TestZip.build([.init(name: "a.bin", data: Data([1, 2]))]).prefix(40), "trunc.zip")
        XCTAssertThrowsError(try ZipReader().entries(of: truncated))
    }

    func testCRCMismatchIsRejected() throws {
        var zip = TestZip.build([.init(name: "a.bin", data: Data(repeating: 3, count: 64))])
        // Flip a payload byte after the local header (30 + name length 5).
        zip[35] ^= 0xFF
        XCTAssertThrowsError(try ZipReader().extract(try write(zip), into: out)) { error in
            guard case .malformed = error as? ArchiveError else { return XCTFail("\(error)") }
        }
    }
}

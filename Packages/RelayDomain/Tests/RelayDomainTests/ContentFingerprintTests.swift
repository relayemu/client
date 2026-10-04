// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayDomain

final class ContentFingerprintTests: XCTestCase {
    // SHA-256("") — a well-known vector.
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func testParseAndSerialize() throws {
        let fp = try ContentFingerprint(parsing: "sha256:" + Self.emptySHA256)
        XCTAssertEqual(fp.algorithm, .sha256)
        XCTAssertEqual(fp.digest.count, 32)
        XCTAssertEqual(fp.digest.first, 0xe3)
        XCTAssertEqual(fp.digest.last, 0x55)
        XCTAssertEqual(fp.hexDigest, Self.emptySHA256)
        XCTAssertEqual(fp.canonicalString, "sha256:" + Self.emptySHA256)
        XCTAssertEqual(fp.description, fp.canonicalString)
    }

    func testUppercaseHexIsNormalised() throws {
        let fp = try ContentFingerprint(parsing: "sha256:" + Self.emptySHA256.uppercased())
        XCTAssertEqual(fp.canonicalString, "sha256:" + Self.emptySHA256)
        XCTAssertEqual(fp, try ContentFingerprint(parsing: "sha256:" + Self.emptySHA256))
    }

    func testDigestConstructor() throws {
        let bytes = [UInt8](repeating: 0xab, count: 32)
        let fp = try ContentFingerprint(sha256: bytes)
        XCTAssertEqual(fp.hexDigest, String(repeating: "ab", count: 32))
        XCTAssertThrowsError(try ContentFingerprint(sha256: [1, 2, 3])) { error in
            XCTAssertEqual(error as? ContentFingerprintError, .invalidDigestLength(expected: 32, actual: 3))
        }
    }

    func testRejectsMalformedStrings() {
        let bad = [
            "", "sha256", "sha256:", "md5:" + Self.emptySHA256, ":" + Self.emptySHA256,
            "sha256:" + String(Self.emptySHA256.dropLast()), "sha256:" + Self.emptySHA256 + "0",
            "sha256:" + String(repeating: "zz", count: 32), "SHA256:" + Self.emptySHA256,
        ]
        for s in bad {
            XCTAssertThrowsError(try ContentFingerprint(parsing: s), "should reject '\(s)'")
        }
    }

    func testEqualityAndHashingDependOnContentOnly() throws {
        let a = try ContentFingerprint(parsing: "sha256:" + Self.emptySHA256)
        let b = try ContentFingerprint(sha256: a.digest)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testCodableRoundTripAsString() throws {
        let fp = try ContentFingerprint(parsing: "sha256:" + Self.emptySHA256)
        let data = try JSONEncoder().encode(fp)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"sha256:\(Self.emptySHA256)\"")
        XCTAssertEqual(try JSONDecoder().decode(ContentFingerprint.self, from: data), fp)
        XCTAssertThrowsError(try JSONDecoder().decode(ContentFingerprint.self, from: Data("\"md5:00\"".utf8)))
    }
}

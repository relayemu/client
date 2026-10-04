// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayLibrary

final class ContentHashingTests: XCTestCase {
    let hasher = SHA256ContentHasher()

    func testKnownVectors() throws {
        XCTAssertEqual(try hasher.hash(data: Data()).fingerprint.hexDigest,
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try hasher.hash(data: Data("abc".utf8)).fingerprint.hexDigest,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try hasher.hash(data: Data("abc".utf8)).sizeInBytes, 3)
    }

    func testFileHashingMatchesDataHashingAcrossChunkBoundaries() async throws {
        let dir = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 2.5 MiB of deterministic bytes → three chunks with a partial last one.
        var bytes = [UInt8](repeating: 0, count: SHA256ContentHasher.chunkSize * 2 + SHA256ContentHasher.chunkSize / 2)
        var seed: UInt32 = 0x1234_5678
        for i in bytes.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; bytes[i] = UInt8(truncatingIfNeeded: seed >> 24) }
        let url = try TestSupport.writeFile(bytes, named: "big.bin", in: dir)
        let fromFile = try await hasher.hash(fileAt: url)
        let fromData = try hasher.hash(data: Data(bytes))
        XCTAssertEqual(fromFile, fromData)
        XCTAssertEqual(fromFile.sizeInBytes, Int64(bytes.count))
    }

    func testMissingFile() async {
        let url = URL(fileURLWithPath: "/nonexistent/relay-\(UUID()).bin")
        do {
            _ = try await hasher.hash(fileAt: url)
            XCTFail("expected an error")
        } catch let error as ContentHashingError {
            XCTAssertEqual(error, .fileNotFound(url))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

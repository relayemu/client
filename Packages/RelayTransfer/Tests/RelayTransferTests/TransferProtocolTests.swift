// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayTransfer

final class TransferProtocolTests: XCTestCase {
    func testRouteUsesOnlyTheSelectedPairAndRequiresBothKnownCandidateTypes() {
        XCTAssertEqual(TransferRoute.selected(localType: "host", remoteType: "host"), .direct)
        XCTAssertEqual(TransferRoute.selected(localType: "srflx", remoteType: "prflx"), .direct)
        XCTAssertEqual(TransferRoute.selected(localType: "relay", remoteType: "host"), .relay)
        XCTAssertEqual(TransferRoute.selected(localType: "host", remoteType: "relay"), .relay)
        XCTAssertEqual(TransferRoute.selected(localType: "relay", remoteType: "relay"), .relay)
        XCTAssertNil(TransferRoute.selected(localType: nil, remoteType: "relay"))
        XCTAssertNil(TransferRoute.selected(localType: "host", remoteType: "unknown"))
    }
    func testManifestLimitsAndPathSafety() throws {
        let digest = String(repeating: "a", count: 64)
        let valid = TransferFile(id: "f1", name: "Game.bin", size: 2_000_000_000, sha256: digest)
        try TransferFile.validate([valid], availableBytes: 7_000_000_000)
        XCTAssertThrowsError(try TransferFile.validate([valid], availableBytes: 2_000_000_000))
        for name in ["../Game.bin", "/Game.bin", "A:Game.bin", "Game\\file.bin", ".hidden.bin"] {
            XCTAssertThrowsError(try TransferFile.validate([TransferFile(id: "f1", name: name, size: 0, sha256: digest)], availableBytes: Int64.max))
        }
        XCTAssertThrowsError(try TransferFile.validate([valid, valid], availableBytes: Int64.max))
    }
    func testTURNUserinfoIsEscapedAndNativeUsesUDP() {
        let server = TransferICEServer(urls: ["stun:turn.relayemu.app:3478", "turn:turn.relayemu.app:3478?transport=udp", "turns:turn.relayemu.app:5349?transport=tcp"], username: "123:abc", credential: "a+/=")
        XCTAssertEqual(server.nativeURLs(), ["stun:turn.relayemu.app:3478", "turn:123%3Aabc:a%2B%2F%3D@turn.relayemu.app:3478?transport=udp"])
        XCTAssertEqual(String(describing: server), "TransferICEServer(redacted)")
        XCTAssertFalse(String(reflecting: server).contains("123:abc"))
        XCTAssertFalse(String(describing: Mirror(reflecting: server).children.map { $0.value }).contains("a+/="))
    }

    func testNineGBFilesAndLargerBatchAreLimitedByAvailableStorage() throws {
        let digest = String(repeating: "a", count: 64)
        let files = [TransferFile(id: "f1", name: "First.iso", size: 9_000_000_000, sha256: digest),
                     TransferFile(id: "f2", name: "Second.iso", size: 9_000_000_000, sha256: digest)]
        let required: Int64 = 54_000_000_000 + 512 * 1024 * 1024
        try TransferFile.validate(files, availableBytes: required)
        XCTAssertThrowsError(try TransferFile.validate(files, availableBytes: required - 1)) {
            XCTAssertEqual($0 as? TransferError, .storageFull)
        }
    }

    func testExactBrowserByteCountsPreventOverflowAndRetainBatchBound() throws {
        let digest = String(repeating: "a", count: 64)
        let largest = TransferFile(id: "f1", name: "Largest.iso", size: 9_007_199_254_740_991, sha256: digest)
        try TransferFile.validate([largest], availableBytes: Int64.max)
        let extra = TransferFile(id: "f2", name: "Extra.iso", size: 1, sha256: digest)
        XCTAssertThrowsError(try TransferFile.validate([largest, extra], availableBytes: Int64.max))
        for size in [Int64(-1), 9_007_199_254_740_992, Int64.max] {
            XCTAssertThrowsError(try TransferFile.validate([TransferFile(id: "f1", name: "Invalid.iso", size: size, sha256: digest)], availableBytes: Int64.max))
        }
        let files = (1...65).map { TransferFile(id: "f\($0)", name: "Disc\($0).iso", size: 9_000_000_000, sha256: digest) }
        try TransferFile.validate(Array(files.prefix(64)), availableBytes: Int64.max)
        XCTAssertThrowsError(try TransferFile.validate(files, availableBytes: Int64.max))
    }
}

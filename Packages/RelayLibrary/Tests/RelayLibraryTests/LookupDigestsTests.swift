// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CryptoKit
import RelayDomain
@testable import RelayLibrary

final class LookupDigestsTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = try TestSupport.temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testCartridgeDigestIsWholeFileSHA1() async throws {
        let url = try TestSupport.writeFile(Array("abc".utf8), named: "a.gba", in: root)
        let digests = try await LookupDigester.digests(forFileAt: url, systemID: .gameBoyAdvance)
        XCTAssertEqual(digests, LookupDigests(sha1: "a9993e364706816aba3e25717850c26c9cd0d89d"))
    }

    func testCopierHeaderAddsHeaderlessDigestOnlyWhereNoIntroOmitsIt() async throws {
        let body = (0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let headered = Array(repeating: UInt8(0xEE), count: 512) + body
        let snes = try TestSupport.writeFile(headered, named: "a.smc", in: root)
        let digests = try await LookupDigester.digests(forFileAt: snes, systemID: .snes)
        XCTAssertEqual(digests.sha1, sha1(Data(headered)))
        XCTAssertEqual(digests.headerlessSHA1, sha1(Data(body)))
        let gba = try await LookupDigester.digests(forFileAt: snes, systemID: .gameBoyAdvance)
        XCTAssertNil(gba.headerlessSHA1)
    }

    func testDiscSerialFromBootPath() {
        XCTAssertEqual(PlayStationDiscPackage.discSerial(fromBootPath: "SLUS_012.34"), "SLUS-01234")
        XCTAssertEqual(PlayStationDiscPackage.discSerial(fromBootPath: "BIN/scps_100.01"), "SCPS-10001")
        XCTAssertNil(PlayStationDiscPackage.discSerial(fromBootPath: "RELAY.EXE"))
        XCTAssertNil(PlayStationDiscPackage.discSerial(fromBootPath: "PSX.EXE"))
    }

    func testCoverKeyVector() {
        let key = CoverKey.make(system: .gameBoyAdvance, catalogName: "Pokemon - Emerald Version (USA, Europe)")
        XCTAssertEqual(key, "gba/11c673d5b4ea0f184639700a14097cd81b5c4e10a4efb92a29ca9ecc83144436")
        XCTAssertTrue(CoverKey.isValid(key))
        XCTAssertFalse(CoverKey.isValid("gba/../x"))
        XCTAssertFalse(CoverKey.isValid("GBA/" + String(repeating: "a", count: 64)))
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
import RelayLibrary
@testable import RelayTitleCatalog

final class TitleCatalogTests: XCTestCase {
    private func request(_ system: SystemID, _ digests: LookupDigests) throws -> MetadataRequest {
        MetadataRequest(fingerprint: try ContentFingerprint(sha256: Array(repeating: 1, count: 32)), systemID: system,
                        fileName: "x", sizeInBytes: 1, lookupDigests: digests)
    }

    func testBundledCatalogIsThePinnedRevision() throws {
        XCTAssertEqual(try TitleCatalog.bundled().revision, "6a23a64fea8b0498e69ab534dda1c602ed064544")
    }

    func testRealVectors() async throws {
        let provider = TitleCatalogProvider(catalog: try TitleCatalog.bundled())
        let emerald = try await provider.match(request(.gameBoyAdvance, LookupDigests(sha1: "f3ae088181bf583e55daf962a92bb46f4f1d07b7")))
        XCTAssertEqual(emerald.first?.title, "Pokemon - Emerald Version")
        XCTAssertEqual(emerald.first?.region, "USA, Europe")
        XCTAssertEqual(emerald.first?.coverKey, "gba/11c673d5b4ea0f184639700a14097cd81b5c4e10a4efb92a29ca9ecc83144436")

        let headered = try await provider.match(request(.nes, LookupDigests(sha1: "33d23c2f2cfa4c9efec87f7bc1321ce3ce6c89bd")))
        let headerless = try await provider.match(request(.nes, LookupDigests(sha1: "facee9c577a5262dbe33ac4930bb0b58c8c037f7")))
        XCTAssertEqual(headered.first?.title, "Super Mario Bros.")
        XCTAssertEqual(headered.first?.coverKey, headerless.first?.coverKey)

        let byHeaderless = try await provider.match(request(.snes, LookupDigests(sha1: String(repeating: "0", count: 40),
                                                                             headerlessSHA1: "6d4f10a8b10e10dbe624cb23cf03b88bb8252973")))
        XCTAssertEqual(byHeaderless.first?.title, "The Legend of Zelda - A Link to the Past")

        let disc = try await provider.match(request(.playStation, LookupDigests(sha1: String(repeating: "0", count: 40), discSerial: "SLUS-00892")))
        XCTAssertEqual(disc.first?.title, "Final Fantasy VIII")
    }

    func testWrongSystemDoesNotMatchButFamilyDoes() async throws {
        let provider = TitleCatalogProvider(catalog: try TitleCatalog.bundled())
        let wrong = try await provider.match(request(.nes, LookupDigests(sha1: "f3ae088181bf583e55daf962a92bb46f4f1d07b7")))
        XCTAssertTrue(wrong.isEmpty)
        XCTAssertEqual(TitleCatalogProvider.family(of: .gameBoy), [.gameBoy, .gameBoyColor])
        XCTAssertEqual(TitleCatalogProvider.family(of: .wonderSwanColor), [.wonderSwanColor, .wonderSwan])
        XCTAssertEqual(TitleCatalogProvider.family(of: .gameGear), [.gameGear])
    }

    private func titleRequest(_ system: SystemID, _ title: String) throws -> MetadataRequest {
        MetadataRequest(fingerprint: try ContentFingerprint(sha256: Array(repeating: 2, count: 32)), systemID: system,
                        fileName: "", sizeInBytes: 0, title: title)
    }

    func testSyncedTitleMatchesTheRegionOfThisDevice() async throws {
        let catalog = try TitleCatalog.bundled()
        let france = TitleCatalogProvider(catalog: catalog, regionCode: "FR")
        let usa = TitleCatalogProvider(catalog: catalog, regionCode: "US")

        let kartFR = try await france.match(titleRequest(.gameBoyAdvance, "Mario Kart - Super Circuit"))
        XCTAssertEqual(kartFR.first?.coverKey, CoverKey.make(system: .gameBoyAdvance, catalogName: "Mario Kart - Super Circuit (Europe)"))
        let kartUS = try await usa.match(titleRequest(.gameBoyAdvance, "Mario Kart - Super Circuit"))
        XCTAssertEqual(kartUS.first?.coverKey, CoverKey.make(system: .gameBoyAdvance, catalogName: "Mario Kart - Super Circuit (USA)"))
        XCTAssertEqual(kartUS.first?.region, "USA")

        let tetrisUS = try await usa.match(titleRequest(.nes, "Tetris"))
        XCTAssertEqual(tetrisUS.first?.coverKey, CoverKey.make(system: .nes, catalogName: "Tetris (USA)"))
        let tetrisFR = try await france.match(titleRequest(.nes, "Tetris"))
        XCTAssertEqual(tetrisFR.first?.coverKey, CoverKey.make(system: .nes, catalogName: "Tetris (Europe)"))
    }

    func testSyncedTitleUsesTheFamilyAndTheSharedVector() async throws {
        let provider = TitleCatalogProvider(catalog: try TitleCatalog.bundled(), regionCode: "FR")
        let emerald = try await provider.match(titleRequest(.gameBoyAdvance, "Pokemon - Emerald Version"))
        XCTAssertEqual(emerald.first?.coverKey, "gba/11c673d5b4ea0f184639700a14097cd81b5c4e10a4efb92a29ca9ecc83144436")
        // Relay files dual-mode Game Boy games as Game Boy Color; the pirate release ranks last.
        let red = try await provider.match(titleRequest(.gameBoyColor, "Pokémon: Red Version"))
        XCTAssertEqual(red.first?.coverKey, CoverKey.make(system: .gameBoy, catalogName: "Pokemon - Red Version (USA, Europe) (SGB Enhanced)"))
        let unknown = try await provider.match(titleRequest(.gameBoyAdvance, "Not A Catalog Game"))
        XCTAssertTrue(unknown.isEmpty)
    }

    func testNoDigestsNoMatch() async throws {
        let provider = TitleCatalogProvider(catalog: try TitleCatalog.bundled())
        let none = try await provider.match(MetadataRequest(fingerprint: try ContentFingerprint(sha256: Array(repeating: 1, count: 32)),
                                                            systemID: .gameBoyAdvance, fileName: "x", sizeInBytes: 1))
        XCTAssertTrue(none.isEmpty)
    }
}

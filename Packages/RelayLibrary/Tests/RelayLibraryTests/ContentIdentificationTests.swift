// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayLibrary

final class ContentIdentificationTests: XCTestCase {
    var dir: URL!
    let identifier = ContentIdentifier.standard

    override func setUp() async throws { dir = try TestSupport.temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testValidHeaderIdentifiesGBAWhateverTheExtension() throws {
        let url = try TestSupport.writeFile(GBAFixture.bytes(title: "HOMEBREW"), named: "mystery.bin", in: dir)
        let id = try identifier.identify(fileAt: url)
        XCTAssertEqual(id.systemID, .gameBoyAdvance)
        XCTAssertEqual(id.confidence, .header)
        XCTAssertEqual(id.suggestedTitle, "HOMEBREW")
    }

    func testRealFixtureIdentifiesByHeader() throws {
        guard let real = GBAFixture.realFixtureURL else { throw XCTSkip("fixture missing") }
        let id = try identifier.identify(fileAt: real)
        XCTAssertEqual(id.systemID, .gameBoyAdvance)
        XCTAssertEqual(id.confidence, .header)
        XCTAssertNil(id.suggestedTitle, "the 240p suite has an empty internal title")
    }

    func testGBAExtensionWithBrokenHeaderIsInvalidNotUnsupported() throws {
        var bytes = GBAFixture.bytes()
        bytes[0xBD] ^= 0xFF   // corrupt the checksum
        let url = try TestSupport.writeFile(bytes, named: "broken.gba", in: dir)
        XCTAssertThrowsError(try identifier.identify(fileAt: url)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .invalid(fileName: "broken.gba", systemID: .gameBoyAdvance))
        }
        let tiny = try TestSupport.writeFile([1, 2, 3], named: "tiny.gba", in: dir)
        XCTAssertThrowsError(try identifier.identify(fileAt: tiny)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .invalid(fileName: "tiny.gba", systemID: .gameBoyAdvance))
        }
    }

    func testUnknownExtensionWithoutHeaderIsUnsupported() throws {
        let url = try TestSupport.writeFile([UInt8](repeating: 0x41, count: 512), named: "readme.txt", in: dir)
        XCTAssertThrowsError(try identifier.identify(fileAt: url)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .unsupported(fileName: "readme.txt"))
        }
    }

    /// B2-IMP-001: a document that happens to carry a game extension is not a game.
    func testMarkdownDocumentIsNotIdentifiedAsAGame() throws {
        let readme = """
        # Relay QA fixture

        This file is plain text. It is not a cartridge image, and importing it
        must not add a Mega Drive row to the library.
        """
        let url = try TestSupport.writeFile([UInt8](readme.utf8), named: "README.md", in: dir)
        XCTAssertThrowsError(try identifier.identify(fileAt: url)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .unsupported(fileName: "README.md"))
        }
    }

    /// The same rule for the other extensions a deferred system claims.
    func testTextWithDeferredSystemExtensionsIsUnsupported() throws {
        let text = [UInt8](String(repeating: "written notes, no cartridge here. ", count: 40).utf8)
        for name in ["notes.gen", "notes.bin", "notes.n64", "notes.ngp", "notes.iso"] {
            let url = try TestSupport.writeFile(text, named: name, in: dir)
            XCTAssertThrowsError(try identifier.identify(fileAt: url), name) { error in
                XCTAssertEqual(error as? ContentIdentificationError, .unsupported(fileName: name), name)
            }
        }
    }

    /// A real cartridge that shares Markdown's extension is still recognised by
    /// its content: a deferred system stays recognisable on import.
    func testRealMegaDriveImageNamedMDIsRecognisedByContent() throws {
        let url = try TestSupport.writeFile(Self.megaDriveImage(), named: "README.md", in: dir)
        let id = try identifier.identify(fileAt: url)
        XCTAssertEqual(id.systemID, .megaDrive)
        XCTAssertEqual(id.confidence, .fileExtension)
        XCTAssertFalse(SystemCatalog.descriptor(for: .megaDrive)?.isPlayable ?? true, "Mega Drive stays deferred")
    }

    /// Every deferred system Relay names keeps working the same way.
    func testBinaryImageForDeferredSystemKeepsItsRow() throws {
        let url = try TestSupport.writeFile(Self.megaDriveImage(), named: "Sonic (USA).gen", in: dir)
        let id = try identifier.identify(fileAt: url)
        XCTAssertEqual(id.systemID, .megaDrive)
        XCTAssertEqual(id.confidence, .fileExtension)
    }

    /// An extension two systems share stays ambiguous, whatever the bytes are.
    func testAmbiguousExtensionIsStillRejected() throws {
        let url = try TestSupport.writeFile(Self.megaDriveImage(), named: "disc.chd", in: dir)
        XCTAssertThrowsError(try identifier.identify(fileAt: url)) { error in
            guard case .ambiguous(let name, let candidates)? = error as? ContentIdentificationError else {
                return XCTFail("expected ambiguity, got \(error)")
            }
            XCTAssertEqual(name, "disc.chd")
            XCTAssertEqual(Set(candidates), [.playStation, .pcEngineCD])
        }
    }

    /// A minimal but well-formed Mega Drive cartridge image: reset vectors, then
    /// the "SEGA" console signature every Mega Drive cartridge carries at 0x100.
    static func megaDriveImage() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x8000)
        bytes[0x100] = 0x53; bytes[0x101] = 0x45; bytes[0x102] = 0x47; bytes[0x103] = 0x41  // "SEGA"
        let console = Array("SEGA MEGA DRIVE ".utf8)
        bytes.replaceSubrange(0x110..<(0x110 + console.count), with: console)
        bytes[0x1A0] = 0x00; bytes[0x1A1] = 0x00  // SRAM: none
        bytes[0x1A5] = 0x00; bytes[0x1A6] = 0x00; bytes[0x1A7] = 0x00; bytes[0x1A8] = 0x00
        return bytes
    }

    func testOversizedFileIsNotAGBACartridge() {
        let sig = GBAHeaderSignature()
        let header = Data(GBAFixture.bytes())
        XCTAssertNotNil(sig.identify(header: header, fileSize: 1024))
        XCTAssertNil(sig.identify(header: header, fileSize: GBAHeaderSignature.maxSize + 1))
    }
}

/// The Game Boy signature reads the cartridge header, so a renamed file, a
/// colour cartridge with a plain `.gb` name and a damaged image all get the
/// right answer.
final class GameBoyIdentificationTests: XCTestCase {
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Tests/Fixtures/ROMs/relay-gb-counter")
    }
    static var gb: URL { fixtures.appending(path: "relay-gb-counter.gb") }
    static var gbc: URL { fixtures.appending(path: "relay-gbc-counter.gbc") }

    private var temp: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.gb.path), "fixture missing")
        temp = FileManager.default.temporaryDirectory.appending(path: "RelayGBID-\(UUID().uuidString)",
                                                                directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: temp) }

    private func copy(_ source: URL, as name: String) throws -> URL {
        let destination = temp.appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func testGameBoyCartridgeIsIdentifiedFromItsHeader() throws {
        let id = try ContentIdentifier.standard.identify(fileAt: Self.gb)
        XCTAssertEqual(id.systemID, .gameBoy)
        XCTAssertEqual(id.confidence, .header)
        XCTAssertEqual(id.suggestedTitle, "RELAY GB CNT")
    }

    func testColourCartridgeIsIdentifiedAsGameBoyColor() throws {
        let id = try ContentIdentifier.standard.identify(fileAt: Self.gbc)
        XCTAssertEqual(id.systemID, .gameBoyColor)
        XCTAssertEqual(id.confidence, .header)
        XCTAssertEqual(id.suggestedTitle, "RELAY GBC CNT")
    }

    /// The cartridge's own colour flag decides, not the file name.
    func testTheHeaderBeatsTheFileName() throws {
        let mislabelled = try copy(Self.gbc, as: "looks-like-a-game-boy.gb")
        XCTAssertEqual(try ContentIdentifier.standard.identify(fileAt: mislabelled).systemID, .gameBoyColor)
        let other = try copy(Self.gb, as: "looks-like-colour.gbc")
        XCTAssertEqual(try ContentIdentifier.standard.identify(fileAt: other).systemID, .gameBoy)
    }

    func testExtensionAloneDoesNotMakeAGameBoyGame() throws {
        let junk = temp.appending(path: "broken.gb")
        try Data(repeating: 0x5A, count: 0x8000).write(to: junk)
        XCTAssertThrowsError(try ContentIdentifier.standard.identify(fileAt: junk)) {
            XCTAssertEqual($0 as? ContentIdentificationError,
                           .invalid(fileName: "broken.gb", systemID: .gameBoy))
        }
    }

    /// A cartridge whose header checksum is wrong is damaged, not unsupported.
    func testCorruptedHeaderChecksumIsRefused() throws {
        let damaged = try copy(Self.gb, as: "damaged.gb")
        var bytes = try Data(contentsOf: damaged)
        bytes[0x14D] = bytes[0x14D] &+ 1
        try bytes.write(to: damaged)
        XCTAssertThrowsError(try ContentIdentifier.standard.identify(fileAt: damaged))
    }

    func testAGameBoyImageIsNeverMistakenForAnAdvanceOne() throws {
        XCTAssertNotEqual(try ContentIdentifier.standard.identify(fileAt: Self.gb).systemID, .gameBoyAdvance)
        // And the Advance fixture is still identified as an Advance game.
        let advance = Self.fixtures.deletingLastPathComponent()
            .appending(path: "relay-sram-counter/relay-sram-counter.gba")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: advance.path))
        XCTAssertEqual(try ContentIdentifier.standard.identify(fileAt: advance).systemID, .gameBoyAdvance)
    }
}

/// The NES signature reads the iNES container: magic, declared bank sizes and
/// the file length they imply.
final class NESIdentificationTests: XCTestCase {
    static var fixture: URL {
        GameBoyIdentificationTests.fixtures.deletingLastPathComponent()
            .appending(path: "relay-nes-counter/relay-nes-counter.nes")
    }
    private var temp: URL!
    let identifier = ContentIdentifier.standard

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixture.path), "fixture missing")
        temp = try TestSupport.temporaryDirectory()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: temp) }

    func testFixtureIsIdentifiedFromItsHeader() throws {
        let id = try identifier.identify(fileAt: Self.fixture)
        XCTAssertEqual(id.systemID, .nes)
        XCTAssertEqual(id.confidence, .header)
    }

    func testTheHeaderBeatsTheFileName() throws {
        let renamed = temp.appending(path: "mystery.bin")
        try FileManager.default.copyItem(at: Self.fixture, to: renamed)
        XCTAssertEqual(try identifier.identify(fileAt: renamed).systemID, .nes)
    }

    func testExtensionAloneDoesNotMakeAnNESGame() throws {
        let junk = try TestSupport.writeFile([UInt8](repeating: 0x41, count: 40_000), named: "junk.nes", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: junk)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .invalid(fileName: "junk.nes", systemID: .nes))
        }
    }

    func testTruncatedImageIsRefused() throws {
        var bytes = [UInt8](try Data(contentsOf: Self.fixture))
        bytes.removeLast(4096)
        let url = try TestSupport.writeFile(bytes, named: "short.nes", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: url))
    }
}

/// The Super NES signature finds the cartridge header where the console's
/// boot code would (LoROM or HiROM, with or without a copier header) and
/// trusts the checksum pair, never the file name.
final class SNESIdentificationTests: XCTestCase {
    static var fixture: URL {
        GameBoyIdentificationTests.fixtures.deletingLastPathComponent()
            .appending(path: "relay-snes-counter/relay-snes-counter.sfc")
    }
    private var temp: URL!
    let identifier = ContentIdentifier.standard

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixture.path), "fixture missing")
        temp = try TestSupport.temporaryDirectory()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: temp) }

    func testFixtureIsIdentifiedFromItsHeaderWithItsTitle() throws {
        let id = try identifier.identify(fileAt: Self.fixture)
        XCTAssertEqual(id.systemID, .snes)
        XCTAssertEqual(id.confidence, .header)
        XCTAssertEqual(id.suggestedTitle, "RELAY SNES COUNTER")
    }

    func testCopierHeaderIsSkipped() throws {
        let bytes = [UInt8](repeating: 0, count: 512) + [UInt8](try Data(contentsOf: Self.fixture))
        let url = try TestSupport.writeFile(bytes, named: "copier.smc", in: temp)
        let id = try identifier.identify(fileAt: url)
        XCTAssertEqual(id.systemID, .snes)
        XCTAssertEqual(id.confidence, .header)
    }

    func testTheHeaderBeatsTheFileName() throws {
        let renamed = temp.appending(path: "mystery.bin")
        try FileManager.default.copyItem(at: Self.fixture, to: renamed)
        XCTAssertEqual(try identifier.identify(fileAt: renamed).systemID, .snes)
    }

    func testCorruptedChecksumIsRefused() throws {
        var bytes = [UInt8](try Data(contentsOf: Self.fixture))
        bytes[0x7FDE] ^= 0xFF
        let url = try TestSupport.writeFile(bytes, named: "broken.sfc", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: url)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .invalid(fileName: "broken.sfc", systemID: .snes))
        }
    }

    func testAnNESImageIsNeverMistakenForASuperNESOne() throws {
        let id = try identifier.identify(fileAt: NESIdentificationTests.fixture)
        XCTAssertEqual(id.systemID, .nes)
    }
}

/// The DS signature trusts the header checksum the console verifies at boot.
final class NDSIdentificationTests: XCTestCase {
    static var fixture: URL {
        GameBoyIdentificationTests.fixtures.deletingLastPathComponent()
            .appending(path: "relay-ds-counter/relay-ds-counter.nds")
    }
    private var temp: URL!
    let identifier = ContentIdentifier.standard

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixture.path), "fixture missing")
        temp = try TestSupport.temporaryDirectory()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: temp) }

    func testFixtureIsIdentifiedFromItsHeaderWithItsTitle() throws {
        let id = try identifier.identify(fileAt: Self.fixture)
        XCTAssertEqual(id.systemID, .nintendoDS)
        XCTAssertEqual(id.confidence, .header)
        XCTAssertEqual(id.suggestedTitle, "RELAY DS CNT")
    }

    func testTheHeaderBeatsTheFileName() throws {
        let renamed = temp.appending(path: "mystery.bin")
        try FileManager.default.copyItem(at: Self.fixture, to: renamed)
        XCTAssertEqual(try identifier.identify(fileAt: renamed).systemID, .nintendoDS)
    }

    func testCorruptedHeaderChecksumIsRefused() throws {
        var bytes = [UInt8](try Data(contentsOf: Self.fixture))
        bytes[0x15E] ^= 0xFF
        let url = try TestSupport.writeFile(bytes, named: "broken.nds", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: url)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .invalid(fileName: "broken.nds", systemID: .nintendoDS))
        }
    }

    func testTruncatedImageIsRefused() throws {
        let bytes = [UInt8](try Data(contentsOf: Self.fixture)).prefix(0x8100)
        let url = try TestSupport.writeFile(Array(bytes), named: "short.nds", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: url))
    }
}

/// The Sega signature reads the "TMR SEGA" header and its region code, which
/// tells a Master System cartridge from a Game Gear one whatever the file name.
final class SegaIdentificationTests: XCTestCase {
    static var fixtures: URL { GameBoyIdentificationTests.fixtures.deletingLastPathComponent().appending(path: "relay-sms-counter") }
    static var sms: URL { fixtures.appending(path: "relay-sms-counter.sms") }
    static var gg: URL { fixtures.appending(path: "relay-gg-counter.gg") }
    private var temp: URL!
    let identifier = ContentIdentifier.standard

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.sms.path), "fixture missing")
        temp = try TestSupport.temporaryDirectory()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: temp) }

    func testMasterSystemAndGameGearAreToldApartByTheRegionCode() throws {
        XCTAssertEqual(try identifier.identify(fileAt: Self.sms).systemID, .masterSystem)
        XCTAssertEqual(try identifier.identify(fileAt: Self.gg).systemID, .gameGear)
        XCTAssertEqual(try identifier.identify(fileAt: Self.gg).confidence, .header)
    }

    func testTheHeaderBeatsTheFileName() throws {
        let renamed = temp.appending(path: "mystery.sms")
        try FileManager.default.copyItem(at: Self.gg, to: renamed)
        XCTAssertEqual(try identifier.identify(fileAt: renamed).systemID, .gameGear, "a Game Gear header in a .sms file is a Game Gear game")
    }

    func testExtensionAloneDoesNotMakeASegaGame() throws {
        let junk = try TestSupport.writeFile([UInt8](repeating: 0x41, count: 0x8000), named: "junk.sms", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: junk)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .invalid(fileName: "junk.sms", systemID: .masterSystem))
        }
    }

    func testAnUnknownRegionCodeIsNotClaimed() throws {
        var bytes = [UInt8](try Data(contentsOf: Self.sms))
        bytes[0x7FFF] = 0x0E                                   // region nibble 0: not a console Relay knows
        let url = try TestSupport.writeFile(bytes, named: "odd.sms", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: url))
    }
}

/// HuCards have no header; the signature checks whole banks and a plausible
/// reset vector, which a random binary almost never has.
final class PCEngineIdentificationTests: XCTestCase {
    static var fixture: URL { GameBoyIdentificationTests.fixtures.deletingLastPathComponent().appending(path: "relay-pce-counter/relay-pce-counter.pce") }
    private var temp: URL!
    let identifier = ContentIdentifier.standard

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixture.path), "fixture missing")
        temp = try TestSupport.temporaryDirectory()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: temp) }

    func testFixtureIsIdentified() throws {
        let id = try identifier.identify(fileAt: Self.fixture)
        XCTAssertEqual(id.systemID, .pcEngine)
        XCTAssertEqual(id.confidence, .header)
    }

    func testCopierHeaderIsTolerated() throws {
        let bytes = [UInt8](repeating: 0, count: 512) + [UInt8](try Data(contentsOf: Self.fixture))
        let url = try TestSupport.writeFile(bytes, named: "copier.pce", in: temp)
        XCTAssertEqual(try identifier.identify(fileAt: url).systemID, .pcEngine)
    }

    func testPartialBankIsRefused() throws {
        let bytes = [UInt8](try Data(contentsOf: Self.fixture)).dropLast(100)
        let url = try TestSupport.writeFile(Array(bytes), named: "short.pce", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: url))
    }

    /// Found with a real Pokemon Red dump: about one cartridge in eight has a word
    /// at 0x1FFE that looks like a HuCard reset vector. A verified header (magic
    /// plus checksum) must win instead of making the import "unsupported".
    func testHeuristicMatchNeverOverridesAVerifiedHeader() throws {
        var bytes = [UInt8](try Data(contentsOf: GameBoyIdentificationTests.gb))
        XCTAssertEqual(bytes.count % 0x2000, 0)
        bytes[0x1FFE] = 0x00; bytes[0x1FFF] = 0xE0
        let url = try TestSupport.writeFile(bytes, named: "collision.gb", in: temp)
        XCTAssertNotNil(PCEngineHuCardSignature().identify(header: Data(bytes.prefix(0x2200)), fileSize: Int64(bytes.count)),
                        "precondition: the HuCard heuristic claims this Game Boy image")
        let id = try identifier.identify(fileAt: url)
        XCTAssertEqual(id.systemID, .gameBoy)
        XCTAssertEqual(id.confidence, .header)
    }

    func testImplausibleResetVectorIsRefused() throws {
        var bytes = [UInt8](try Data(contentsOf: Self.fixture))
        bytes[0x1FFF] = 0x20
        let url = try TestSupport.writeFile(bytes, named: "vector.pce", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: url)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .invalid(fileName: "vector.pce", systemID: .pcEngine))
        }
    }
}

/// The WonderSwan signature reads the footer the boot ROM reads and verifies
/// its checksum over the whole image; the Color bit decides the system.
final class WonderSwanIdentificationTests: XCTestCase {
    static var fixtures: URL { GameBoyIdentificationTests.fixtures.deletingLastPathComponent().appending(path: "relay-ws-counter") }
    static var ws: URL { fixtures.appending(path: "relay-ws-counter.ws") }
    static var wsc: URL { fixtures.appending(path: "relay-wsc-counter.wsc") }
    private var temp: URL!
    let identifier = ContentIdentifier.standard

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.ws.path), "fixture missing")
        temp = try TestSupport.temporaryDirectory()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: temp) }

    func testMonochromeAndColorAreToldApartByTheFooter() throws {
        XCTAssertEqual(try identifier.identify(fileAt: Self.ws).systemID, .wonderSwan)
        XCTAssertEqual(try identifier.identify(fileAt: Self.wsc).systemID, .wonderSwanColor)
        XCTAssertEqual(try identifier.identify(fileAt: Self.ws).confidence, .header)
    }

    func testTheFooterBeatsTheFileName() throws {
        let renamed = temp.appending(path: "mystery.ws")
        try FileManager.default.copyItem(at: Self.wsc, to: renamed)
        XCTAssertEqual(try identifier.identify(fileAt: renamed).systemID, .wonderSwanColor)
    }

    func testCorruptedChecksumIsRefused() throws {
        var bytes = [UInt8](try Data(contentsOf: Self.ws))
        bytes[0x100] ^= 0xFF                                    // any byte: the checksum covers them all
        let url = try TestSupport.writeFile(bytes, named: "broken.ws", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: url)) { error in
            XCTAssertEqual(error as? ContentIdentificationError, .invalid(fileName: "broken.ws", systemID: .wonderSwan))
        }
    }

    func testTruncatedImageIsRefused() throws {
        let bytes = [UInt8](try Data(contentsOf: Self.ws)).dropLast(0x1000)
        let url = try TestSupport.writeFile(Array(bytes), named: "short.ws", in: temp)
        XCTAssertThrowsError(try identifier.identify(fileAt: url))
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CryptoKit
import RelayDomain
@testable import RelayLibrary

final class PlayStationImportTests: XCTestCase {
    var root: URL!
    var store: InMemoryLibraryStore!
    var location: LibraryLocation!
    var importer: GameImporter!
    override func setUp() async throws {
        root = try TestSupport.temporaryDirectory()
        store = InMemoryLibraryStore(); location = LibraryLocation(rootURL: root.appendingPathComponent("Library"))
        try location.createDirectories(); importer = GameImporter(store: store, location: location)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func fixture() throws -> Data {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        return try Data(contentsOf: repo.appendingPathComponent("Tests/Fixtures/ROMs/relay-ps1-counter/relay-ps1-counter.bin"))
    }
    private func disc(_ name: String = "Game", bytes: Data? = nil) throws -> [URL] {
        let bin = root.appendingPathComponent(name + ".bin"), cue = root.appendingPathComponent(name + ".cue")
        try (bytes ?? fixture()).write(to: bin)
        try Data("FILE \"\(name).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".utf8).write(to: cue)
        return [cue, bin]
    }
    private let core = EmulatorCoreDescriptor(id: "test-ps1", name: "test", version: "1", license: "GPL-3.0-or-later", supportedSystems: [.playStation], capabilities: [.saveStates, .diskSwap])

    func testSelectedTracksBecomeOneHashedGameAndLaunchablePackage() async throws {
        let selected = try disc()
        let report = await importer.importFiles(selected)
        XCTAssertEqual(report.outcomes.count, 1)
        let game = try XCTUnwrap(report.addedGames.first, "\(report)")
        XCTAssertEqual(game.systemID, .playStation)
        let files = try await store.games.files(for: game.id)
        XCTAssertEqual(files.count, 1)
        let primary = try XCTUnwrap(files.first)
        let hashed = try await SHA256ContentHasher().hash(fileAt: location.url(for: primary.location))
        XCTAssertEqual(hashed.fingerprint, game.contentFingerprint)
        let launch = try await GameLaunchResolver(store: store, location: location, availableCores: [core]).resolve(gameID: game.id)
        XCTAssertEqual(try PlayStationDiscPackage.playlistReferences(launch.contentURL), ["disc01.cue"])
        let binary = launch.contentURL.deletingLastPathComponent().appendingPathComponent("disc01-track01.bin")
        XCTAssertEqual(try Data(contentsOf: binary), try fixture())
        for file in selected { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }
    func testCHDConvertsAudioEndianAndTrackPaddingToSamePackage() async throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let fixtures = repo.appendingPathComponent("Tests/Fixtures/ROMs/relay-ps1-counter")
        let cue = await importer.importFiles(["relay-ps1-audio.cue", "relay-ps1-counter.bin", "relay-ps1-tone.bin"].map { fixtures.appendingPathComponent($0) })
        XCTAssertEqual(cue.addedGames.count, 1, "\(cue)")
        for name in ["relay-ps1-audio.chd", "relay-ps1-audio.compressed.chd"] {
            let chd = await importer.importFiles([fixtures.appendingPathComponent(name)])
            XCTAssertEqual(chd.duplicateCount, 1, "CHD must preserve raw sectors, audio endian and four-frame padding: \(chd)")
        }
    }
    func testNegativeSBISectorAndTruncatedRecordAreRejected() async throws {
        let files = try disc()
        let sbi = root.appendingPathComponent("Game.sbi")
        for body in [Data([0x53,0x42,0x49,0,0,0,0,1] + Array(repeating: UInt8(0), count: 10)), Data([0x53,0x42,0x49,0,0,2,0,1])] {
            try body.write(to: sbi)
            let report = await importer.importFiles(files + [sbi])
            XCTAssertTrue(report.addedGames.isEmpty, "\(report)")
        }
    }
    func testCompatibleSBIIsPartOfGameIdentity() async throws {
        let files = try disc()
        let baseline = await importer.importFiles(files)
        let sbi = root.appendingPathComponent("Game.sbi")
        try Data([0x53,0x42,0x49,0,0,2,0,1] + Array(repeating: UInt8(0), count: 10)).write(to: sbi)
        let protected = await importer.importFiles(files + [sbi])
        XCTAssertEqual(protected.outcomes.count, 1)
        XCTAssertEqual(protected.addedGames.count, 1)
        XCTAssertNotEqual(baseline.addedGames.first?.contentFingerprint, protected.addedGames.first?.contentFingerprint)
    }
    func testWindowsLineEndingsAndTabSeparatedFieldsPreserveIdentity() async throws {
        let files = try disc()
        let baseline = await importer.importFiles(files)
        try Data("FILE\t\"Game.bin\" BINARY\r\n\tTRACK\t01\tMODE2/2352\r\n\tINDEX\t01\t00:00:00\r\n".utf8).write(to: files[0])
        let windows = await importer.importFiles(files)
        XCTAssertEqual(baseline.addedGames.count, 1)
        XCTAssertEqual(windows.duplicateCount, 1, "\(windows)")
    }

    func testRenamingEverySelectedFileKeepsIdentity() async throws {
        let a = await importer.importFiles(try disc("Original"))
        let b = await importer.importFiles(try disc("Other name"))
        XCTAssertEqual(a.addedGames.count, 1); XCTAssertEqual(b.duplicateCount, 1)
    }
    func testPlaylistIsOneGameAndOrderChangesIdentity() async throws {
        let a = try disc("Disc One")
        var changed = try fixture(); changed[200 * 2352 + 100] ^= 1
        let b = try disc("Disc Two", bytes: changed)
        let playlist = root.appendingPathComponent("Complete Game.m3u")
        try Data("Disc One.cue\nDisc Two.cue\n".utf8).write(to: playlist)
        let first = await importer.importFiles([playlist] + a + b)
        XCTAssertEqual(first.outcomes.count, 1); let game = try XCTUnwrap(first.addedGames.first, "\(first)")
        let launch = try await GameLaunchResolver(store: store, location: location, availableCores: [core]).resolve(gameID: game.id)
        XCTAssertEqual(try PlayStationDiscPackage.playlistReferences(launch.contentURL), ["disc01.cue", "disc02.cue"])
        try Data("Disc Two.cue\nDisc One.cue\n".utf8).write(to: playlist)
        let second = await importer.importFiles([playlist] + a + b)
        XCTAssertEqual(second.addedGames.count, 1)
        XCTAssertNotEqual(game.contentFingerprint, second.addedGames.first?.contentFingerprint)
    }
    func testMissingMemberNeverReadsUnselectedNeighbour() async throws {
        let source = try disc()
        let report = await importer.importFiles([source[0]])
        XCTAssertEqual(report.addedGames.count, 0)
        let games = try await store.games.allGames()
        XCTAssertEqual(games.count, 0)
    }
    func testRawBinAndPBPHaveActionableRejections() async throws {
        let files = try disc()
        let bin = await importer.importFiles([files[1]])
        XCTAssertEqual(bin.outcomes.map(\.result), [.discRejected(.missingFiles)])
        let pbp = root.appendingPathComponent("Game.pbp")
        try Data([0, 0x50, 0x42, 0x50]).write(to: pbp)
        let report = await importer.importFiles([pbp])
        XCTAssertEqual(report.outcomes.map(\.result), [.discRejected(.unsupportedDisc)])
        let cartridge = root.appendingPathComponent("Cartridge.bin")
        try Data(GBAFixture.bytes()).write(to: cartridge)
        let renamed = await importer.importFiles([cartridge])
        XCTAssertEqual(renamed.addedGames.first?.systemID, .gameBoyAdvance)
    }
    func testFirmwareRejectsWrongSizeUnknownBytesAndDamagedInstallation() throws {
        let firmware = PlayStationFirmwareStore(firmwareDirectory: root.appendingPathComponent("Firmware"))
        XCTAssertEqual(try firmware.installed(), [])
        for data in [Data([1]), Data(repeating: 0, count: PlayStationFirmwareStore.size)] {
            XCTAssertThrowsError(try firmware.importData(data)) { error in
                XCTAssertEqual(error as? PlayStationFirmwareError, .incompatibleFile)
            }
        }
        try FileManager.default.createDirectory(at: firmware.directory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: PlayStationFirmwareStore.size).write(to: firmware.directory.appendingPathComponent("scph5502.bin"))
        XCTAssertThrowsError(try firmware.verifiedDirectory()) { error in
            XCTAssertEqual(error as? PlayStationFirmwareError, .damagedInstalledFile)
        }
    }
    func testMixedDiscAndArchivesStayIsolatedAndDoNotRecurse() async throws {
        let files = try disc()
        let a = root.appendingPathComponent("A.zip"), b = root.appendingPathComponent("B.zip")
        let nested = TestZip.build([.init(name: "nested.gba", data: Data(GBAFixture.bytes(payload: 3)))])
        try TestZip.build([.init(name: "same.gba", data: Data(GBAFixture.bytes(payload: 1))), .init(name: "inner.zip", data: nested)]).write(to: a)
        try TestZip.build([.init(name: "same.gba", data: Data(GBAFixture.bytes(payload: 2)))]).write(to: b)
        let report = await importer.importFiles(files + [a, b])
        XCTAssertEqual(report.addedGames.count, 3, "\(report)")
        XCTAssertEqual(report.outcomes.filter { $0.result == .unsupported }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.stagingDirectory.path), [])
    }
    func testTraversalAndSymlinkAreRejected() async throws {
        let cue = root.appendingPathComponent("Bad.cue")
        try Data("FILE \"../outside.bin\" BINARY\n TRACK 01 MODE2/2352\n INDEX 01 00:00:00\n".utf8).write(to: cue)
        let report = await importer.importFiles([cue]); XCTAssertEqual(report.addedGames.count, 0)
        let files = try disc(); let link = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: files[1])
        let linked = await importer.importFiles([files[0], link]); XCTAssertEqual(linked.addedGames.count, 0)
    }
    func testCDSignatureWithoutPS1ExecutableIsRejected() async throws {
        var bytes = try fixture(); bytes[22 * 2352 + 24] = 0
        let report = await importer.importFiles(try disc(bytes: bytes))
        XCTAssertEqual(report.addedGames.count, 0)
    }
    func testInvalidTrackNumberIndexAndTimeAreRejected() async throws {
        let files = try disc()
        for body in ["TRACK 100 MODE2/2352\n INDEX 01 00:00:00", "TRACK 01 MODE2/2352\n INDEX 01 00:99:00", "TRACK 01 MODE2/2352\n INDEX 01 80:00:00"] {
            try Data("FILE \"Game.bin\" BINARY\n \(body)\n".utf8).write(to: files[0])
            let report = await importer.importFiles(files); XCTAssertTrue(report.addedGames.isEmpty)
        }
    }
    func testAlteredPackageNeverProducesLaunchFiles() async throws {
        let report = await importer.importFiles(try disc()); let game = try XCTUnwrap(report.addedGames.first)
        let files = try await store.games.files(for: game.id)
        let primary = try XCTUnwrap(files.first)
        let url = location.url(for: primary.location)
        var bytes = try Data(contentsOf: url); bytes[bytes.count - 1] ^= 1; try bytes.write(to: url)
        do {
            _ = try await GameLaunchResolver(store: store, location: location, availableCores: [core]).resolve(gameID: game.id)
            XCTFail("altered package accepted")
        } catch { XCTAssertEqual(error as? PlayStationImportError, .damagedPackage) }
    }

    func testPackageLookupDigestsHashTrackOneAndReadTheSerial() async throws {
        let plainReport = await importer.importFiles(try disc("Plain"))
        let plain = try XCTUnwrap(plainReport.addedGames.first)
        let plainFiles = try await store.games.files(for: plain.id)
        let plainFile = try XCTUnwrap(plainFiles.first)
        let digests = try PlayStationDiscPackage.lookupDigests(package: location.url(for: plainFile.location))
        XCTAssertEqual(digests.sha1, Insecure.SHA1.hash(data: try fixture()).map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(digests.discSerial, "the fixture boots RELAY.EXE")

        // Same-length rename of the boot file in both SYSTEM.CNF and the directory record.
        let serialised = try fixture().replacing(Data("RELAY.EXE;1".utf8), with: Data("SLUS_999.99".utf8))
        let serialReport = await importer.importFiles(try disc("Serial", bytes: serialised))
        let game = try XCTUnwrap(serialReport.addedGames.first)
        let files = try await store.games.files(for: game.id)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(try PlayStationDiscPackage.lookupDigests(package: location.url(for: file.location)).discSerial, "SLUS-99999")
    }
}

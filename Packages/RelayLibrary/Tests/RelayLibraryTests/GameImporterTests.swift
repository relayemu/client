// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayLibrary

final class GameImporterTests: XCTestCase {
    var dir: URL!
    var store: InMemoryLibraryStore!
    var location: LibraryLocation!
    var importer: GameImporter!
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        dir = try TestSupport.temporaryDirectory()
        store = InMemoryLibraryStore()
        location = LibraryLocation(rootURL: dir.appending(path: "Library"))
        try location.createDirectories()
        importer = GameImporter(store: store, location: location, clock: { [fixedDate] in fixedDate })
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func gba(_ name: String, title: String = "GAME", payload: UInt8 = 0x11) throws -> URL {
        try TestSupport.writeFile(GBAFixture.bytes(title: title, payload: payload), named: name, in: dir)
    }

    func testValidGBAIsAddedIntoManagedStorage() async throws {
        let source = try gba("My_Game (USA).gba")
        let report = await importer.importFiles([source])
        XCTAssertEqual(report.outcomes.count, 1)
        guard case .added(let game, let confidence) = report.outcomes[0].result else { return XCTFail("\(report)") }
        XCTAssertEqual(confidence, .header)
        XCTAssertEqual(game.title, "My Game (USA)", "display title from the file name, underscores → spaces")
        XCTAssertEqual(game.systemID, .gameBoyAdvance)
        XCTAssertEqual(game.addedAt, fixedDate)
        let files = try await store.games.files(for: game.id)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].location.relativePath, "Games/\(game.id)/My_Game (USA).gba")
        XCTAssertEqual(files[0].originalFileName, "My_Game (USA).gba")
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.url(for: files[0].location).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "external source untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.stagingDirectory.path), [], "staging cleaned")
    }

    func testPS3ISOCannotBecomePSPThroughExtensionFallback() async throws {
        var image = Data(repeating: 0, count: 96 * 1024)
        image.replaceSubrange(32769..<32774, with: Data("CD001".utf8))
        let marker = Data("PLAYSTATION(R)3".utf8)
        image.replaceSubrange(65882..<65882 + marker.count, with: marker)
        let source = try TestSupport.writeFile([UInt8](image), named: "Unsupported.iso", in: dir)
        let report = await importer.importFiles([source])
        XCTAssertEqual(report.outcomes.count, 1)
        guard case .unsupported = report.outcomes.first?.result else { return XCTFail("PS3 ISO was accepted") }
        XCTAssertTrue(report.addedGames.isEmpty)
        let games = try await store.games.games(matching: .init())
        XCTAssertTrue(games.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.stagingDirectory.path), [])
    }

    func testRealFixtureImports() async throws {
        guard let real = GBAFixture.realFixtureURL else { throw XCTSkip("fixture missing") }
        let report = await importer.importFiles([real])
        XCTAssertEqual(report.addedGames.count, 1)
        XCTAssertEqual(report.addedGames[0].contentFingerprint.hexDigest, "47844f7140738a06f8f3bc09780da3ab095539a250b870f614feed561d9d6f34")
    }

    func testDuplicateRenamedFileIsReportedNotDuplicated() async throws {
        let first = await importer.importFiles([try gba("a.gba")])
        let second = await importer.importFiles([try gba("renamed copy.gba")])
        XCTAssertEqual(second.outcomes[0].result, .duplicate(existing: first.addedGames[0]))
        XCTAssertEqual(second.duplicateCount, 1)
        let all = try await store.games.allGames()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.gamesDirectory.path).count, 1)
    }

    func testUnsupportedInvalidAndMissingFiles() async throws {
        let txt = try TestSupport.writeFile([0x41, 0x42], named: "notes.txt", in: dir)
        var broken = GBAFixture.bytes(); broken[0xB2] = 0
        let bad = try TestSupport.writeFile(broken, named: "bad.gba", in: dir)
        let missing = dir.appending(path: "missing.gba")
        let report = await importer.importFiles([txt, bad, missing])
        XCTAssertEqual(report.outcomes.map(\.result), [.unsupported, .invalid(systemID: .gameBoyAdvance), .failed(detail: "source file not found")])
        XCTAssertEqual(report.problemCount, 3)
        let all = try await store.games.allGames()
        XCTAssertEqual(all, [])
    }

    /// B2-IMP-001: importing ROMs plus a plain README reports only the ROMs.
    func testMarkdownReadmeAmongRomsIsNotAdded() async throws {
        let readme = try TestSupport.writeFile([UInt8]("# Notes\n\nNot a cartridge.\n".utf8), named: "README.md", in: dir)
        let rom = try gba("Relay QA Long Title Counter for Save Resume and Screenshot Checks.gba", title: "COUNTER")
        let report = await importer.importFiles([readme, rom])

        XCTAssertEqual(report.addedGames.count, 1, "only the cartridge is a game")
        XCTAssertEqual(report.problemCount, 1)
        XCTAssertEqual(report.outcomes.count, 2)
        XCTAssertEqual(report.outcomes[0].result, .unsupported)
        guard case .added(let game, let confidence) = report.outcomes[1].result else { return XCTFail("\(report)") }
        XCTAssertEqual(game.systemID, .gameBoyAdvance)
        XCTAssertEqual(confidence, .header)
        let all = try await store.games.allGames()
        XCTAssertEqual(all.map(\.systemID), [.gameBoyAdvance], "no Mega Drive row is created")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.stagingDirectory.path), [])
    }

    /// A deferred system keeps its honest "recognised, not playable" row.
    func testDeferredSystemImageIsStillAddedAsARow() async throws {
        let url = try TestSupport.writeFile(ContentIdentificationTests.megaDriveImage(), named: "Sonic (USA).md", in: dir)
        let report = await importer.importFiles([url])
        guard case .added(let game, let confidence) = report.outcomes[0].result else { return XCTFail("\(report)") }
        XCTAssertEqual(game.systemID, .megaDrive)
        XCTAssertEqual(confidence, .fileExtension)
        XCTAssertFalse(SystemCatalog.descriptor(for: .megaDrive)?.isPlayable ?? true)
    }

    func testZipArchiveMembersAreImportedIndividually() async throws {
        let zip = TestZip.build([
            .init(name: "pack/one.gba", data: Data(GBAFixture.bytes(title: "ONE", payload: 1)), deflate: true),
            .init(name: "pack/two.gba", data: Data(GBAFixture.bytes(title: "TWO", payload: 2))),
            .init(name: "pack/readme.txt", data: Data("x".utf8)),
        ])
        let url = dir.appending(path: "pack.zip"); try zip.write(to: url)
        let report = await importer.importFiles([url])
        XCTAssertEqual(report.outcomes.map(\.displayName), ["pack.zip/one.gba", "pack.zip/readme.txt", "pack.zip/two.gba"])
        XCTAssertEqual(report.addedGames.map(\.title).sorted(), ["one", "two"])
        XCTAssertEqual(report.outcomes[1].result, .unsupported)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.stagingDirectory.path), [])
    }

    func testUnsafeArchiveIsRejectedAsAWholeWithoutWritingAnything() async throws {
        let zip = TestZip.build([
            .init(name: "good.gba", data: Data(GBAFixture.bytes())),
            .init(name: "../../evil.gba", data: Data(GBAFixture.bytes(payload: 9))),
        ])
        let url = dir.appending(path: "evil.zip"); try zip.write(to: url)
        let report = await importer.importFiles([url])
        XCTAssertEqual(report.outcomes.count, 1)
        guard case .archiveRejected = report.outcomes[0].result else { return XCTFail("\(report)") }
        let all = try await store.games.allGames()
        XCTAssertEqual(all, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "evil.gba").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.stagingDirectory.path), [])
    }

    func testOversizedArchiveIsRejectedByLimits() async throws {
        let small = GameImporter(store: store, location: location,
                                 archiveLimits: ArchiveLimits(maxEntries: 1, maxTotalBytes: 1 << 20, maxEntryBytes: 1 << 20, maxCompressionRatio: 200))
        let zip = TestZip.build([.init(name: "a.gba", data: Data(GBAFixture.bytes(payload: 1))), .init(name: "b.gba", data: Data(GBAFixture.bytes(payload: 2)))])
        let url = dir.appending(path: "two.zip"); try zip.write(to: url)
        let report = await small.importFiles([url])
        XCTAssertEqual(report.outcomes[0].result, .archiveRejected(reason: ArchiveError.tooManyEntries(2, limit: 1).description))
    }

    func testInterruptedImportLeavesOnlyStagingWhichIsSwept() async throws {
        // Simulate a crash mid-import: a staging directory with content and no rows.
        let staging = try location.makeStagingDirectory()
        _ = try TestSupport.writeFile(GBAFixture.bytes(), named: "half.gba", in: staging)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.stagingDirectory.path).count, 1)
        XCTAssertEqual(location.sweepStaging(), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.stagingDirectory.path), [])
        let all = try await store.games.allGames()
        XCTAssertEqual(all, [], "no row without content")
    }

    func testInsertFailureRollsBackContentAndReportsStorageFailure() async throws {
        await store.state.setFailNextInsert(true)
        let report = await importer.importFiles([try gba("x.gba")])
        guard case .failed = report.outcomes[0].result else { return XCTFail("\(report)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.gamesDirectory.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.stagingDirectory.path), [])
    }

    func testMetadataProviderEnrichesTitleAndStoresArtwork() async throws {
        let bytes = GBAFixture.bytes(title: "META")
        let fingerprint = try SHA256ContentHasher().hash(data: Data(bytes)).fingerprint
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // header only; storage does not decode
        let provider = StaticMetadataProvider(id: "test", entries: [
            fingerprint: MetadataCandidate(title: "Proper Title", alternateTitles: ["Alt"], developer: "Dev Co",
                                           publisher: "Pub Co", releaseYear: 2001, genre: "Puzzle", region: "EU",
                                           summary: "A game.", artwork: ArtworkPayload(data: png, fileExtension: "png")),
        ])
        let enriched = GameImporter(store: store, location: location, metadataProvider: provider, clock: { [fixedDate] in fixedDate })
        let report = await enriched.importFiles([try TestSupport.writeFile(bytes, named: "meta.gba", in: dir)])
        let game = report.addedGames[0]
        XCTAssertEqual(game.title, "Proper Title")
        let metadata = try await store.games.metadata(for: game.id)
        XCTAssertEqual(metadata?.developer, "Dev Co")
        XCTAssertEqual(metadata?.releaseYear, 2001)
        XCTAssertEqual(metadata?.source, "test")
        XCTAssertEqual(metadata?.artworkLocation?.relativePath, "Artwork/\(game.id)/cover.png")
        XCTAssertEqual(try Data(contentsOf: location.url(for: metadata!.artworkLocation!)), png)
        // Provider failure never blocks the import.
        struct Failing: MetadataProvider { let id = "fail"; func match(_ r: MetadataRequest) async throws -> [MetadataCandidate] { throw LibraryError.storage("boom") } }
        let failing = GameImporter(store: store, location: location, metadataProvider: Failing())
        let second = await failing.importFiles([try gba("plain.gba", payload: 0x22)])
        XCTAssertEqual(second.addedGames.count, 1)
        XCTAssertEqual(second.addedGames[0].title, "plain")
    }

    func testRemoveGameDeletesRowsContentAndArtwork() async throws {
        let game = (await importer.importFiles([try gba("r.gba")])).addedGames[0]
        let artwork = ArtworkStore(location: location)
        _ = try artwork.storeArtwork(ArtworkPayload(data: Data([1]), fileExtension: "jpg"), for: game.id)
        try await importer.removeGame(id: game.id)
        let gone = try await store.games.game(id: game.id)
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory(forGame: game.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.artworkDirectory.appending(path: game.id.description).path))
    }
}

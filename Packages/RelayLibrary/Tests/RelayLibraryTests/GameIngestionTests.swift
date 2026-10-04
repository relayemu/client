// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayLibrary

final class GameIngestionTests: XCTestCase {
    var dir: URL!
    var source: URL!
    var store: InMemoryLibraryStore!
    var location: LibraryLocation!
    var ingestion: GameIngestion!
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        dir = try TestSupport.temporaryDirectory()
        source = try TestSupport.writeFile([UInt8](1...200), named: "Homebrew Test.gba", in: dir)
        store = InMemoryLibraryStore()
        location = LibraryLocation(rootURL: dir.appending(path: "Library"))
        try location.createDirectories()
        ingestion = GameIngestion(store: store, location: location, clock: { [fixedDate] in fixedDate })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testIngestCreatesGameFileAndCopiesContent() async throws {
        let outcome = try await ingestion.ingestLocalFile(at: source)
        guard case .inserted(let game) = outcome else { return XCTFail("expected insertion") }
        XCTAssertEqual(game.systemID, .gameBoyAdvance)
        XCTAssertEqual(game.title, "Homebrew Test")
        XCTAssertEqual(game.addedAt, fixedDate)
        XCTAssertEqual(game.contentFingerprint, try SHA256ContentHasher().hash(data: Data([UInt8](1...200))).fingerprint)

        let files = try await store.games.files(for: game.id)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].role, .primary)
        XCTAssertEqual(files[0].sizeInBytes, 200)
        XCTAssertEqual(files[0].originalFileName, "Homebrew Test.gba")
        XCTAssertEqual(files[0].location.relativePath, "Games/\(game.id)/Homebrew Test.gba")
        XCTAssertEqual(try Data(contentsOf: location.url(for: files[0].location)), Data([UInt8](1...200)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "source must be untouched")
    }

    func testDuplicateContentIsDetectedBeforeCopying() async throws {
        let first = try await ingestion.ingestLocalFile(at: source)
        let renamed = try TestSupport.writeFile([UInt8](1...200), named: "Other Name.gba", in: dir)
        let second = try await ingestion.ingestLocalFile(at: renamed)
        XCTAssertEqual(second, .duplicate(existing: first.game))
        let count1 = try await store.games.allGames().count
        XCTAssertEqual(count1, 1)
        let gameDirs = try FileManager.default.contentsOfDirectory(atPath: location.gamesDirectory.path)
        XCTAssertEqual(gameDirs.count, 1, "no second content directory")
    }

    func testInsertFailureRemovesCopiedContent() async throws {
        await store.state.setFailNextInsert(true)
        do {
            _ = try await ingestion.ingestLocalFile(at: source)
            XCTFail("expected failure")
        } catch LibraryError.storage {
            // expected
        }
        let gameDirs = try FileManager.default.contentsOfDirectory(atPath: location.gamesDirectory.path)
        XCTAssertEqual(gameDirs, [])
        let count0 = try await store.games.allGames().count
        XCTAssertEqual(count0, 0)
    }

    func testUnsupportedAndMissingFiles() async throws {
        let txt = try TestSupport.writeFile([1, 2, 3], named: "notes.txt", in: dir)
        do {
            _ = try await ingestion.ingestLocalFile(at: txt)
            XCTFail("expected unsupported")
        } catch let error as GameIngestionError {
            XCTAssertEqual(error, .unsupportedFile(extension: "txt"))
        }
        let missing = dir.appending(path: "missing.gba")
        do {
            _ = try await ingestion.ingestLocalFile(at: missing)
            XCTFail("expected not found")
        } catch let error as GameIngestionError {
            XCTAssertEqual(error, .fileNotFound(missing))
        }
    }

    func testExplicitSystemAndTitleOverrideDerivation() async throws {
        let outcome = try await ingestion.ingestLocalFile(at: source, systemID: .gameBoyAdvance, title: "Custom")
        XCTAssertEqual(outcome.game.title, "Custom")
    }

    func testDownloadedContentDatabaseFailurePreservesExistingPrimaryBytes() async throws {
        let game = try await ingestion.ingestLocalFile(at: source).game
        let original = try await store.games.files(for: game.id).first!
        let originalURL = location.url(for: original.location)
        let before = try Data(contentsOf: originalURL)
        let staged = try TestSupport.writeFile([UInt8](1...200), named: "download.gba", in: dir)
        let descriptor = GameContentDescriptor.singleFile(fingerprint: game.contentFingerprint,
            sizeInBytes: 200, fileName: original.originalFileName, systemID: game.systemID, uploadedAt: fixedDate)
        do {
            _ = try await ingestion.installDownloadedContent(gameID: game.id, stagedURL: staged, descriptor: descriptor)
            XCTFail("An existing primary row must reject a second primary")
        } catch LibraryError.invalidRelationship {}
        let after = try await store.games.files(for: game.id)
        XCTAssertEqual(after, [original])
        XCTAssertEqual(try Data(contentsOf: originalURL), before)
        let managedNames = try FileManager.default.contentsOfDirectory(atPath: location.directory(forGame: game.id).path)
        XCTAssertEqual(managedNames, [originalURL.lastPathComponent], "Only the failed attempt's new file is removed")
    }

    func testDownloadedContentMoveFailurePreservesExistingPrimaryBytes() async throws {
        let game = try await ingestion.ingestLocalFile(at: source).game
        let original = try await store.games.files(for: game.id).first!
        let originalURL = location.url(for: original.location)
        let before = try Data(contentsOf: originalURL)
        let staged = try TestSupport.writeFile([UInt8](1...200), named: "vanishing.gba", in: dir)
        let descriptor = GameContentDescriptor.singleFile(fingerprint: game.contentFingerprint,
            sizeInBytes: 200, fileName: original.originalFileName, systemID: game.systemID, uploadedAt: fixedDate)
        let failing = GameIngestion(store: store, location: location, hasher: VanishingStagedFileHasher())
        do {
            _ = try await failing.installDownloadedContent(gameID: game.id, stagedURL: staged, descriptor: descriptor)
            XCTFail("The staged file disappears after verification so publication must fail")
        } catch {}
        let after = try await store.games.files(for: game.id)
        XCTAssertEqual(after, [original])
        XCTAssertEqual(try Data(contentsOf: originalURL), before)
    }

    func testDownloadedContentUsesIndependentPathAndKeepsOriginalName() async throws {
        let game = try await ingestion.ingestLocalFile(at: source).game
        let original = try await store.games.files(for: game.id).first!
        let originalURL = location.url(for: original.location)
        // Simulate a retained file with no row, such as an interrupted prior import.
        try await store.games.removeLocalContent(gameID: game.id)
        let staged = try TestSupport.writeFile([UInt8](1...200), named: "download.gba", in: dir)
        let descriptor = GameContentDescriptor.singleFile(fingerprint: game.contentFingerprint,
            sizeInBytes: 200, fileName: original.originalFileName, systemID: game.systemID, uploadedAt: fixedDate)
        let installed = try await ingestion.installDownloadedContent(gameID: game.id, stagedURL: staged, descriptor: descriptor)
        XCTAssertEqual(installed.originalFileName, original.originalFileName)
        XCTAssertNotEqual(installed.location, original.location)
        XCTAssertEqual(try Data(contentsOf: location.url(for: installed.location)), Data([UInt8](1...200)))
        XCTAssertEqual(try Data(contentsOf: originalURL), Data([UInt8](1...200)))
        let files = try await store.games.files(for: game.id)
        XCTAssertEqual(files, [installed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testRemoveDeletesRowsAndContent() async throws {
        let game = try await ingestion.ingestLocalFile(at: source).game
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.directory(forGame: game.id).path))
        try await ingestion.remove(gameID: game.id)
        let gone = try await store.games.game(id: game.id)
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory(forGame: game.id).path))
    }
}

/// Makes the filesystem rename fail after a real successful hash, without
/// changing or mocking the existing managed content.
private struct VanishingStagedFileHasher: ContentHasher {
    func hash(fileAt url: URL) async throws -> HashedContent {
        let hashed = try await SHA256ContentHasher().hash(fileAt: url)
        try FileManager.default.removeItem(at: url)
        return hashed
    }

    func hash(data: Data) throws -> HashedContent { try SHA256ContentHasher().hash(data: data) }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayLibrary

/// A disc's identity is its tracks' contents and layout, never its file
/// rules a cue sheet must pass before any file is opened.
final class DiscPackageTests: XCTestCase {
    private var staging: URL!

    override func setUpWithError() throws {
        staging = FileManager.default.temporaryDirectory
            .appending(path: "RelayDisc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: staging) }

    // MARK: Fixtures

    private func write(_ name: String, _ bytes: [UInt8], in directory: URL? = nil) throws -> URL {
        let url = (directory ?? staging).appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    private func writeSheet(_ text: String, named name: String = "game.cue", in directory: URL? = nil) throws -> URL {
        let url = (directory ?? staging).appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func twoTrackSheet(data: String = "Game (Europe).bin", audio: String = "Game (Europe) (Track 02).bin") -> String {
        """
        REM Ripped with some tool
        FILE "\(data)" BINARY
          TRACK 01 MODE2/2352
            INDEX 01 00:00:00
        FILE "\(audio)" BINARY
          TRACK 02 AUDIO
            INDEX 00 00:00:00
            INDEX 01 00:02:00
        """
    }

    private func build(_ cue: URL, in directory: URL? = nil) async throws -> DiscPackage {
        try await DiscPackageBuilder().build(cueURL: cue, stagingDirectory: directory ?? staging)
    }

    // MARK: Identity

    func testSameGameRenamedHasTheSameIdentity() async throws {
        _ = try write("Game (Europe).bin", [1, 2, 3, 4])
        _ = try write("Game (Europe) (Track 02).bin", [9, 9, 9])
        let original = try await build(try writeSheet(twoTrackSheet()))

        let renamed = staging.appending(path: "renamed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        _ = try write("a.bin", [1, 2, 3, 4], in: renamed)
        _ = try write("b.bin", [9, 9, 9], in: renamed)
        let copy = try await build(try writeSheet(twoTrackSheet(data: "a.bin", audio: "b.bin"),
                                                  named: "whatever.cue", in: renamed), in: renamed)

        XCTAssertEqual(original.fingerprint, copy.fingerprint,
                       "file names are not identity")
        XCTAssertEqual(original.members.map(\.hashed), copy.members.map(\.hashed))
    }

    func testDifferentPathLayoutHasTheSameIdentity() async throws {
        _ = try write("t1.bin", [1, 2, 3, 4])
        _ = try write("t2.bin", [9, 9, 9])
        let flat = try await build(try writeSheet(twoTrackSheet(data: "t1.bin", audio: "t2.bin")))

        // The same disc staged one directory deeper, sheet and tracks together.
        let nested = staging.appending(path: "Discs/Game/", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try write("t1.bin", [1, 2, 3, 4], in: nested)
        _ = try write("t2.bin", [9, 9, 9], in: nested)
        let deep = try await build(try writeSheet(twoTrackSheet(data: "t1.bin", audio: "t2.bin"), in: nested), in: nested)

        XCTAssertEqual(flat.fingerprint, deep.fingerprint)
    }

    func testChangedContentWithTheSameFileNamesIsADifferentGame() async throws {
        _ = try write("t1.bin", [1, 2, 3, 4])
        _ = try write("t2.bin", [9, 9, 9])
        let sheet = try writeSheet(twoTrackSheet(data: "t1.bin", audio: "t2.bin"))
        let first = try await build(sheet)

        _ = try write("t2.bin", [9, 9, 8])   // one byte of one track
        let second = try await build(sheet)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    /// The cue sheet's own bytes are not the identity: comments, spacing and
    /// the order of descriptive lines change nothing.
    func testSheetCosmeticsDoNotChangeIdentity() async throws {
        _ = try write("t1.bin", [1, 2, 3, 4])
        _ = try write("t2.bin", [9, 9, 9])
        let plain = try await build(try writeSheet(twoTrackSheet(data: "t1.bin", audio: "t2.bin")))
        let decorated = try await build(try writeSheet("""
            REM GENRE Racing
            TITLE "A Game"
            PERFORMER "Someone"
            file  "t1.bin"   binary
            track 01 mode2/2352
            index 01 00:00:00
            FILE "t2.bin" BINARY
            TRACK 02 AUDIO
            INDEX 00 00:00:00
            INDEX 01 00:02:00
            """, named: "other.cue"))
        XCTAssertEqual(plain.fingerprint, decorated.fingerprint)
    }

    func testTrackLayoutIsPartOfIdentity() async throws {
        _ = try write("t1.bin", [1, 2, 3, 4])
        _ = try write("t2.bin", [9, 9, 9])
        let sheet = twoTrackSheet(data: "t1.bin", audio: "t2.bin")
        let a = try await build(try writeSheet(sheet))
        let b = try await build(try writeSheet(sheet.replacingOccurrences(of: "INDEX 01 00:02:00", with: "INDEX 01 00:03:00"),
                                               named: "b.cue"))
        XCTAssertNotEqual(a.fingerprint, b.fingerprint, "a different pregap is a different disc")
    }

    func testCanonicalManifestContainsNoFileNames() async throws {
        _ = try write("Secret Name.bin", [1, 2, 3, 4])
        _ = try write("Other Secret.bin", [9, 9, 9])
        let package = try await build(try writeSheet(twoTrackSheet(data: "Secret Name.bin", audio: "Other Secret.bin")))
        let manifest = DiscPackage.canonicalManifest(sheet: package.sheet, members: package.members)
        XCTAssertFalse(manifest.contains("Secret"))
        XCTAssertTrue(manifest.hasPrefix("relay-disc/1\n"))
        XCTAssertTrue(manifest.contains("track 1 MODE2/2352"))
        XCTAssertTrue(manifest.contains("track 2 AUDIO"))
        XCTAssertTrue(manifest.contains("sha256:"))
    }

    // MARK: Failure and safety

    func testMissingMemberIsRefused() async throws {
        _ = try write("t1.bin", [1, 2, 3, 4])
        let sheet = try writeSheet(twoTrackSheet(data: "t1.bin", audio: "t2.bin"))
        do {
            _ = try await build(sheet)
            XCTFail("a disc missing a track must not get an identity")
        } catch let error as DiscPackageError {
            XCTAssertEqual(error, .missingMember("t2.bin"))
        }
    }

    func testDuplicateTrackIsRefused() async throws {
        _ = try write("t1.bin", [1, 2, 3, 4])
        let sheet = try writeSheet("""
            FILE "t1.bin" BINARY
              TRACK 01 MODE2/2352
                INDEX 01 00:00:00
              TRACK 01 AUDIO
                INDEX 01 00:02:00
            """)
        do {
            _ = try await build(sheet)
            XCTFail("duplicate tracks must be refused")
        } catch let error as DiscPackageError {
            XCTAssertEqual(error, .sheet(.duplicateTrack(1)))
        }
    }

    func testMaliciousReferencesNeverLeaveStaging() async throws {
        // Something real outside staging that a hostile sheet might aim at.
        let outside = staging.deletingLastPathComponent().appending(path: "relay-outside-\(UUID().uuidString).bin")
        try Data([7, 7, 7]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        _ = try write("t1.bin", [1, 2, 3, 4])

        let attempts = [
            "../\(outside.lastPathComponent)",
            "/etc/hosts",
            "..\\..\\windows\\system32\\drivers\\etc\\hosts",
            "C:\\game.bin",
            "sub/dir/t1.bin",
            "..",
            "t1.bin\u{0}",
        ]
        for reference in attempts {
            let sheet = try writeSheet("""
                FILE "\(reference)" BINARY
                  TRACK 01 MODE2/2352
                    INDEX 01 00:00:00
                """, named: "evil.cue")
            do {
                _ = try await build(sheet)
                XCTFail("'\(reference)' must be refused")
            } catch let error as DiscPackageError {
                guard case .sheet(.unsafeReference) = error else {
                    return XCTFail("'\(reference)' refused for the wrong reason: \(error)")
                }
            }
        }
    }

    /// A symlink inside staging pointing outside must not be followed either.
    func testSymlinkedMemberOutsideStagingIsRefused() async throws {
        let outside = staging.deletingLastPathComponent().appending(path: "relay-target-\(UUID().uuidString).bin")
        try Data([7, 7, 7]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: staging.appending(path: "link.bin"), withDestinationURL: outside)
        let sheet = try writeSheet("""
            FILE "link.bin" BINARY
              TRACK 01 MODE2/2352
                INDEX 01 00:00:00
            """)
        do {
            _ = try await build(sheet)
            XCTFail("a symlink out of staging must be refused")
        } catch let error as DiscPackageError {
            XCTAssertEqual(error, .memberOutsideStaging("link.bin"))
        }
    }

    func testMalformedSheetsAreRefusedCleanly() throws {
        XCTAssertThrowsError(try CueSheetParser.parse(Data("TRACK 01 AUDIO\n".utf8)))
        XCTAssertThrowsError(try CueSheetParser.parse(Data("FILE \"a.bin\" BINARY\n".utf8))) {
            XCTAssertEqual($0 as? CueSheetError, .fileWithoutTracks("a.bin"))
        }
        XCTAssertThrowsError(try CueSheetParser.parse(Data("FILE \"a.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 0:0:0\n".utf8)))
        XCTAssertThrowsError(try CueSheetParser.parse(Data("EXEC rm -rf /\n".utf8)))
        XCTAssertThrowsError(try CueSheetParser.parse(Data(repeating: 0x41, count: CueSheetParser.maxSize + 1))) {
            XCTAssertEqual($0 as? CueSheetError, .tooLarge(CueSheetParser.maxSize + 1))
        }
        XCTAssertThrowsError(try CueSheetParser.parse(Data([0xFF, 0xFE, 0x00, 0x01])))
    }

    func testParserKeepsTracksAndIndexesInOrder() throws {
        let sheet = try CueSheetParser.parse(Data(twoTrackSheet().utf8))
        XCTAssertEqual(sheet.files.count, 2)
        XCTAssertEqual(sheet.files[0].type, "BINARY")
        XCTAssertEqual(sheet.files[0].tracks.map(\.number), [1])
        XCTAssertEqual(sheet.files[1].tracks.map(\.number), [2])
        XCTAssertEqual(sheet.files[1].tracks[0].indexes.map(\.position), ["00:00:00", "00:02:00"])
        XCTAssertEqual(sheet.referencedNames, ["Game (Europe).bin", "Game (Europe) (Track 02).bin"])
    }
}

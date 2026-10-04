// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CoverDownloadsTests.swift
//  RelayUITests — catalog covers through the library model: the option exists
//  only with a cover source, an imported catalog game gets its cover in the
//  background, the preference persists, and removal clears what was downloaded.

import XCTest
import ImageIO
import UniformTypeIdentifiers
import RelayDomain
import RelayLibrary
import RelayEmulation
@testable import RelayUI

private struct FixedCoverSource: CoverArtSource {
    let data: Data
    func cover(forKey key: String) async -> CoverFetch { .image(data) }
}

@MainActor
final class CoverDownloadsTests: XCTestCase {
    var root: URL!
    var factory: FakeFactory!
    var defaults: UserDefaults!
    let coverKey = "gba/" + String(repeating: "5", count: 64)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "RelayUICovers-\(UUID().uuidString)", directoryHint: .isDirectory)
        factory = FakeFactory()
        defaults = UserDefaults(suiteName: "RelayUICovers-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private static func heic() -> Data {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func makeModel(coverSource: (any CoverArtSource)?) throws -> LibraryModel {
        let storage = EmulationStorage(batterySavesDirectory: root.appending(path: "saves"),
                                       saveStatesDirectory: root.appending(path: "states"),
                                       firmwareDirectory: root.appending(path: "firmware"))
        let fixture = try ContentFingerprint(parsing: "sha256:47844f7140738a06f8f3bc09780da3ab095539a250b870f614feed561d9d6f34")
        let provider = StaticMetadataProvider(id: "test", entries: [fixture: MetadataCandidate(title: "240p Test Suite", coverKey: coverKey)])
        let environment = LibraryEnvironment(location: LibraryLocation(rootURL: root.appending(path: "Library")),
                                             session: EmulationSession(factory: factory, storage: storage),
                                             cores: factory.availableCores, deviceKind: .iPhone,
                                             metadataProvider: provider, coverSource: coverSource)
        return LibraryModel(environment: environment, defaults: defaults)
    }

    private func waitForArtwork(_ model: LibraryModel, _ id: GameID, present: Bool) async throws {
        for _ in 0..<250 where (model.metadata[id]?.artworkLocation != nil) != present {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.metadata[id]?.artworkLocation != nil, present)
    }

    func testWithoutACoverSourceThereIsNoOptionAndNoQueue() async throws {
        let model = try makeModel(coverSource: nil)
        await model.load()
        XCTAssertFalse(model.canDownloadCovers)
        XCTAssertNil(model.coverQueue)
        XCTAssertTrue(model.downloadCovers, "on by default")
    }

    func testImportedCatalogGameGetsItsCoverAndTheSettingPersists() async throws {
        guard let fixture = LibraryJourneyTests.fixtureURL else { throw XCTSkip("fixture missing") }
        let model = try makeModel(coverSource: FixedCoverSource(data: Self.heic()))
        await model.load()
        XCTAssertTrue(model.canDownloadCovers)
        await model.importFiles([fixture])
        let game = try XCTUnwrap(model.games.first)
        let placeholderRevision = model.cardModel(for: game).artwork.revision
        try await waitForArtwork(model, game.id, present: true)
        let artwork = try XCTUnwrap(model.metadata[game.id]?.artworkLocation)
        XCTAssertTrue(LibraryLocation.isCatalogCover(artwork))
        XCTAssertNotNil(model.artworkLoader(for: game))
        // A card already on screen reloads only when its artwork revision changes.
        XCTAssertNotEqual(model.cardModel(for: game).artwork.revision, placeholderRevision)

        // The player's cover wins over the downloaded one; Reset returns to it at once.
        let downloadedRevision = model.cardModel(for: game).artwork.revision
        let chosen = await model.chooseCover(Self.heic(), for: game.id)
        XCTAssertTrue(chosen)
        XCTAssertTrue(model.hasCustomCover(game.id))
        let customRevision = try XCTUnwrap(model.cardModel(for: game).artwork.revision)
        XCTAssertTrue(customRevision.hasPrefix("custom:"), customRevision)
        let refused = await model.chooseCover(Data("not an image".utf8), for: game.id)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.cardModel(for: game).artwork.revision, customRevision)
        await model.resetCover(game.id)
        XCTAssertFalse(model.hasCustomCover(game.id))
        XCTAssertEqual(model.cardModel(for: game).artwork.revision, downloadedRevision)

        model.setDownloadCovers(false)
        XCTAssertFalse(try makeModel(coverSource: nil).downloadCovers, "the preference persists")
        await model.removeDownloadedCovers()
        try await waitForArtwork(model, game.id, present: false)
    }
}

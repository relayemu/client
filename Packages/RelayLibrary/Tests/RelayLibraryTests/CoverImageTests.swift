// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RelayDomain
@testable import RelayLibrary

final class CoverImageTests: XCTestCase {
    static func encode(width: Int, height: Int, as type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ArtworkStoreTests.makeImage(width: width, height: height),
                                   [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testAcceptsHEICAndJPEGCovers() {
        XCTAssertEqual(CoverImage.validate(Self.encode(width: 512, height: 360, as: .heic)), .heic)
        XCTAssertEqual(CoverImage.validate(Self.encode(width: 360, height: 512, as: .jpeg)), .jpeg)
        XCTAssertEqual(CoverImage.validate(Self.encode(width: 2048, height: 16, as: .jpeg)), .jpeg)
    }

    func testRefusesOtherFormatsAndGarbage() {
        XCTAssertNil(CoverImage.validate(Self.encode(width: 64, height: 64, as: .png)))
        XCTAssertNil(CoverImage.validate(Data()))
        XCTAssertNil(CoverImage.validate(Data("<html>not a cover</html>".utf8)))
    }

    func testRefusesTruncatedAndMislabelledHEIC() {
        let heic = Self.encode(width: 512, height: 512, as: .heic)
        XCTAssertNil(CoverImage.validate(heic.prefix(heic.count / 3)))
        var mislabelled = heic
        mislabelled.replaceSubrange(8..<12, with: Data("mp42".utf8))
        XCTAssertNil(CoverImage.validate(mislabelled))
    }

    func testRefusesOversizedBytesAndDimensions() {
        var oversized = Self.encode(width: 64, height: 64, as: .jpeg)
        oversized.append(Data(count: CoverImage.maximumBytes + 1 - oversized.count))
        XCTAssertNil(CoverImage.validate(oversized))
        XCTAssertNil(CoverImage.validate(Self.encode(width: 2049, height: 16, as: .jpeg)))
    }
}

final class CatalogCoverStorageTests: XCTestCase {
    var dir: URL!
    var location: LibraryLocation!

    override func setUp() async throws {
        dir = try TestSupport.temporaryDirectory()
        location = LibraryLocation(rootURL: dir)
        try location.createDirectories()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func exists(_ contentLocation: ContentLocation) -> Bool {
        FileManager.default.fileExists(atPath: location.url(for: contentLocation).path)
    }

    func testCatalogCoverLivesBesideProviderArtwork() async throws {
        let store = ArtworkStore(location: location)
        let gameID = GameID()
        let png = CoverImageTests.encode(width: 32, height: 32, as: .png)
        let provider = try store.storeArtwork(ArtworkPayload(data: png, fileExtension: "png"), for: gameID)
        let heic = try store.storeCatalogCover(CoverImageTests.encode(width: 512, height: 512, as: .heic), format: .heic, for: gameID)

        XCTAssertEqual(heic.relativePath, "Artwork/\(gameID)/catalog.heic")
        XCTAssertTrue(exists(provider))
        XCTAssertEqual(store.catalogCover(for: gameID), heic)
        XCTAssertTrue(LibraryLocation.isCatalogCover(heic))
        XCTAssertFalse(LibraryLocation.isCatalogCover(provider))
        let decoded = await store.image(at: heic, maxPixelSize: 128)
        XCTAssertEqual(decoded?.width, 128)

        let jpeg = try store.storeCatalogCover(CoverImageTests.encode(width: 256, height: 256, as: .jpeg), format: .jpeg, for: gameID)
        XCTAssertEqual(jpeg.relativePath, "Artwork/\(gameID)/catalog.jpg")
        XCTAssertFalse(exists(heic))
        XCTAssertEqual(store.catalogCover(for: gameID), jpeg)

        store.removeCatalogCover(for: gameID)
        XCTAssertNil(store.catalogCover(for: gameID))
        XCTAssertTrue(exists(provider))
    }

    func testProviderArtworkAcceptsHEIC() throws {
        let store = ArtworkStore(location: location)
        let stored = try store.storeArtwork(ArtworkPayload(data: CoverImageTests.encode(width: 64, height: 64, as: .heic), fileExtension: "heic"),
                                            for: GameID())
        XCTAssertTrue(stored.relativePath.hasSuffix("/cover.heic"))
    }
}

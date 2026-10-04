// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CoreGraphics
import RelayDomain
@testable import RelayLibrary

final class ArtworkStoreTests: XCTestCase {
    var dir: URL!
    var location: LibraryLocation!

    override func setUp() async throws {
        dir = try TestSupport.temporaryDirectory()
        location = LibraryLocation(rootURL: dir)
        try location.createDirectories()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    static func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testScreenshotRoundTripAndDownsampledDecode() async throws {
        let store = ArtworkStore(location: location)
        let gameID = GameID()
        let image = Self.makeImage(width: 240, height: 160)
        let loc = try store.storeScreenshot(image, for: gameID)
        XCTAssertEqual(loc.relativePath, "Screenshots/\(gameID)/last.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.url(for: loc).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url(for: loc).appendingPathExtension("tmp").path))

        let full = await store.image(at: loc, maxPixelSize: 1000)
        XCTAssertEqual(full?.width, 240)
        let small = await store.image(at: loc, maxPixelSize: 60)
        XCTAssertEqual(small?.width, 60)
        XCTAssertEqual(small?.height, 40)
        // Replacing the screenshot invalidates the cache for that location.
        _ = try store.storeScreenshot(Self.makeImage(width: 120, height: 80), for: gameID)
        let replaced = await store.image(at: loc, maxPixelSize: 1000)
        XCTAssertEqual(replaced?.width, 120)
    }

    func testMissingOrUndecodableArtworkYieldsNil() async throws {
        let store = ArtworkStore(location: location)
        let missing = try ContentLocation(root: .managedLibrary, relativePath: "Artwork/x/cover.png")
        let none = await store.image(at: missing, maxPixelSize: 100)
        XCTAssertNil(none)
        let gameID = GameID()
        let loc = try store.storeArtwork(ArtworkPayload(data: Data("not an image".utf8), fileExtension: "png"), for: gameID)
        let bad = await store.image(at: loc, maxPixelSize: 100)
        XCTAssertNil(bad)
        XCTAssertThrowsError(try store.storeArtwork(ArtworkPayload(data: Data(), fileExtension: "gif"), for: gameID))
    }
}

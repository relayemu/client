// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RelayDomain
@testable import RelayLibrary

final class CustomCoverImageTests: XCTestCase {
    /// A smooth gradient photo-like image, encoded as `type` with the given metadata.
    static func encode(width: Int, height: Int, as type: UTType = .jpeg, properties: [CFString: Any] = [:]) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static let personal: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8566, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 2.3522, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Relay Test Camera", kCGImagePropertyTIFFModel: "RTC-1"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:29 12:00:00"],
    ]

    private func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private func size(_ data: Data) -> (Int, Int) {
        let p = properties(data)
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    func testPhotoBecomesAMetadataFreeHEICOfAtMost1024Pixels() throws {
        let photo = Self.encode(width: 3000, height: 4000, properties: Self.personal)
        XCTAssertNotNil(properties(photo)[kCGImagePropertyGPSDictionary], "the fixture really carries GPS")

        let cover = try CustomCoverImage.normalize(photo)
        XCTAssertEqual(CoverImage.validate(cover), .heic)
        XCTAssertLessThanOrEqual(cover.count, CustomCoverImage.targetBytes)
        let (width, height) = size(cover)
        XCTAssertEqual(max(width, height), 1024)
        XCTAssertEqual(width, 768)
        let kept = properties(cover)
        XCTAssertNil(kept[kCGImagePropertyGPSDictionary])
        XCTAssertNil((kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
        XCTAssertNil((kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertNil((kept[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal])
    }

    func testOrientationIsAppliedAndSmallImagesAreNotEnlarged() throws {
        let rotated = Self.encode(width: 400, height: 300, properties: [kCGImagePropertyOrientation: 6])
        let upright = try CustomCoverImage.normalize(rotated)
        XCTAssertEqual(size(upright).0, 300)
        XCTAssertEqual(size(upright).1, 400)
        XCTAssertEqual(properties(upright)[kCGImagePropertyOrientation] as? Int ?? 1, 1)

        let small = try CustomCoverImage.normalize(Self.encode(width: 200, height: 150, as: .png))
        XCTAssertEqual(size(small).0, 200)
        XCTAssertEqual(size(small).1, 150)
    }

    func testRefusesWhatIsNotAnImage() {
        XCTAssertThrowsError(try CustomCoverImage.normalize(Data())) { XCTAssertEqual($0 as? CustomCoverError, .unusableImage) }
        XCTAssertThrowsError(try CustomCoverImage.normalize(Data("not an image".utf8))) { XCTAssertEqual($0 as? CustomCoverError, .unusableImage) }
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(consumer: CGDataConsumer(data: pdf as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.fill(box); context.endPDFPage(); context.closePDF()
        XCTAssertThrowsError(try CustomCoverImage.normalize(pdf as Data)) { XCTAssertEqual($0 as? CustomCoverError, .unusableImage) }
        XCTAssertThrowsError(try CustomCoverImage.normalize(Data(count: CustomCoverImage.maximumInputBytes + 1))) {
            XCTAssertEqual($0 as? CustomCoverError, .tooLarge)
        }
    }
}

final class CustomCoverEditorTests: XCTestCase {
    var root: URL!
    var store: InMemoryLibraryStore!
    var location: LibraryLocation!
    var artwork: ArtworkStore!
    let clock = TestClock()

    override func setUp() async throws {
        root = try TestSupport.temporaryDirectory()
        store = InMemoryLibraryStore()
        location = LibraryLocation(rootURL: root.appendingPathComponent("Library"))
        try location.createDirectories()
        artwork = ArtworkStore(location: location)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func editor() -> CustomCoverEditor {
        let clock = clock
        return CustomCoverEditor(store: store, artworkStore: artwork, clock: { clock.now })
    }

    private func addGame() async throws -> Game {
        let game = Game(systemID: .gameBoyAdvance, title: "Game", contentFingerprint: try ContentFingerprint(sha256: Array(repeating: 3, count: 32)),
                        addedAt: Date(timeIntervalSince1970: 1))
        try await store.games.insert(game, files: [])
        return game
    }

    private func customFiles(_ game: Game) throws -> [String] {
        let directory = location.artworkDirectory.appending(path: game.id.description)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("custom-") }.sorted()
    }

    func testChooseReplaceAndReset() async throws {
        let game = try await addGame()
        let first = try await editor().choose(CustomCoverImageTests.encode(width: 600, height: 800), for: game.id)
        let fingerprint = try XCTUnwrap(first.fingerprint)
        XCTAssertEqual(try customFiles(game), ["custom-\(fingerprint.hexDigest).heic"])
        let recorded = try await store.games.customCover(for: game.id)
        XCTAssertEqual(recorded, first)
        let stored = try XCTUnwrap(artwork.customCover(first))
        XCTAssertEqual(Int64(try Data(contentsOf: location.url(for: stored)).count), first.sizeInBytes)

        // The same instant on the clock still yields a strictly later value.
        let second = try await editor().choose(CustomCoverImageTests.encode(width: 800, height: 600, as: .png), for: game.id)
        XCTAssertGreaterThan(second.updatedAt, first.updatedAt)
        XCTAssertEqual(try customFiles(game), ["custom-\(try XCTUnwrap(second.fingerprint).hexDigest).heic"])

        try await editor().reset(gameID: game.id)
        let afterReset = try await store.games.customCover(for: game.id)
        let cleared = try XCTUnwrap(afterReset)
        XCTAssertTrue(cleared.isCleared)
        XCTAssertGreaterThan(cleared.updatedAt, second.updatedAt)
        XCTAssertEqual(try customFiles(game), [])
        XCTAssertNil(artwork.customCover(cleared))
    }

    func testRefusedImageAndMissingGameChangeNothing() async throws {
        let game = try await addGame()
        do {
            _ = try await editor().choose(Data("not an image".utf8), for: game.id)
            XCTFail("refused")
        } catch let error as CustomCoverError { XCTAssertEqual(error, .unusableImage) }
        let none = try await store.games.customCover(for: game.id)
        XCTAssertNil(none)

        let missing = GameID()
        do {
            _ = try await editor().choose(CustomCoverImageTests.encode(width: 60, height: 80), for: missing)
            XCTFail("unknown game")
        } catch LibraryError.gameNotFound {}
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: location.artworkDirectory.appending(path: missing.description).path)) ?? []
        XCTAssertEqual(leftovers, [])
    }
}

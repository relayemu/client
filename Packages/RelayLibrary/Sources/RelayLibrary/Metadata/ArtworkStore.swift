// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ArtworkStore.swift
//  RelayLibrary
//
//  Managed storage for cover artwork and gameplay screenshots, plus decoding
//  with downsampling so the UI never holds full-size bitmaps. ImageIO only —
//  no UI framework; decoding runs off the calling actor.

import Foundation
import RelayDomain
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif

public final class ArtworkStore: Sendable {
    public let location: LibraryLocation
    private let cache = ImageCache()

    public init(location: LibraryLocation) {
        self.location = location
    }

    // MARK: Writing

    /// Stores cover artwork for a game and returns its location. Replaces any previous cover.
    public func storeArtwork(_ payload: ArtworkPayload, for gameID: GameID) throws -> ContentLocation {
        let allowed = ["png", "jpg", "jpeg", "heic"]
        guard allowed.contains(payload.fileExtension) else { throw ArtworkError.unsupportedFormat(payload.fileExtension) }
        let contentLocation = try LibraryLocation.artworkLocation(gameID: gameID, fileExtension: payload.fileExtension)
        let url = location.url(for: contentLocation)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Remove stale covers with other extensions.
        for ext in allowed where ext != payload.fileExtension {
            try? FileManager.default.removeItem(at: location.url(for: try LibraryLocation.artworkLocation(gameID: gameID, fileExtension: ext)))
        }
        try payload.data.write(to: url, options: .atomic)
        cache.removeAll()
        return contentLocation
    }

    /// Stores a cover that `CoverImage.validate` accepted, replacing only a
    /// previous catalog cover of the game.
    public func storeCatalogCover(_ data: Data, format: CoverImage.Format, for gameID: GameID) throws -> ContentLocation {
        let contentLocation = try LibraryLocation.catalogCoverLocation(gameID: gameID, format: format)
        let url = location.url(for: contentLocation)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for other in CoverImage.Format.allCases where other != format { removeCatalogCover(for: gameID, format: other) }
        try data.write(to: url, options: .atomic)
        cache.remove(contentLocation)
        return contentLocation
    }

    /// The game's stored catalog cover, if one is on disk.
    public func catalogCover(for gameID: GameID) -> ContentLocation? {
        CoverImage.Format.allCases.lazy
            .compactMap { try? LibraryLocation.catalogCoverLocation(gameID: gameID, format: $0) }
            .first { FileManager.default.fileExists(atPath: self.location.url(for: $0).path) }
    }

    public func removeCatalogCover(for gameID: GameID) {
        for format in CoverImage.Format.allCases { removeCatalogCover(for: gameID, format: format) }
    }

    private func removeCatalogCover(for gameID: GameID, format: CoverImage.Format) {
        guard let contentLocation = try? LibraryLocation.catalogCoverLocation(gameID: gameID, format: format) else { return }
        try? FileManager.default.removeItem(at: location.url(for: contentLocation))
        cache.remove(contentLocation)
    }

    /// Stores a normalised custom cover under its fingerprint. Earlier custom
    /// covers stay until `removeCustomCovers(for:keeping:)`, after the new
    /// value is recorded, so a failed record never loses the current cover.
    public func storeCustomCover(_ data: Data, fingerprint: ContentFingerprint, for gameID: GameID) throws -> ContentLocation {
        let contentLocation = try LibraryLocation.customCoverLocation(gameID: gameID, fingerprint: fingerprint)
        let url = location.url(for: contentLocation)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        cache.remove(contentLocation)
        return contentLocation
    }

    /// The file of a chosen cover when it is on disk; nil for a reset or a missing file.
    public func customCover(_ cover: CustomCover) -> ContentLocation? {
        guard let fingerprint = cover.fingerprint,
              let contentLocation = try? LibraryLocation.customCoverLocation(gameID: cover.gameID, fingerprint: fingerprint),
              FileManager.default.fileExists(atPath: location.url(for: contentLocation).path) else { return nil }
        return contentLocation
    }

    /// Removes a game's custom cover files except the one named by `keeping`.
    public func removeCustomCovers(for gameID: GameID, keeping fingerprint: ContentFingerprint?) {
        let directory = location.artworkDirectory.appending(path: gameID.description)
        let kept = fingerprint.map { "custom-\($0.hexDigest).heic" }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("custom-") && name.hasSuffix(".heic") && name != kept {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
            if let contentLocation = try? ContentLocation(root: .managedLibrary, relativePath: "Artwork/\(gameID)/\(name)") {
                cache.remove(contentLocation)
            }
        }
    }

    /// Removes a game's artwork and screenshot directories (save-state screenshots
    /// live under Saves/ and are removed with the game's saves).
    public func removeAll(for gameID: GameID) {
        let fm = FileManager.default
        try? fm.removeItem(at: location.artworkDirectory.appending(path: gameID.description))
        try? fm.removeItem(at: location.screenshotsDirectory.appending(path: gameID.description))
        cache.removeAll()
    }

    #if canImport(ImageIO)
    /// Longest side of a stored gameplay screenshot. Native GBA frames (240×160) are
    /// kept as is; larger systems are downsampled so thumbnails stay a few tens of KB.
    public static let screenshotMaxPixelSize = 640

    /// Writes the Continue-card screenshot (PNG) for a game and returns its location.
    public func storeScreenshot(_ image: CGImage, for gameID: GameID) throws -> ContentLocation {
        let contentLocation = try LibraryLocation.screenshotLocation(gameID: gameID)
        try writePNG(image, to: contentLocation)
        return contentLocation
    }

    /// Writes a save-state thumbnail (PNG) and returns its location.
    public func storeStateScreenshot(_ image: CGImage, for gameID: GameID, stateID: SaveStateID) throws -> ContentLocation {
        let contentLocation = try LibraryLocation.stateScreenshotLocation(gameID: gameID, stateID: stateID)
        try writePNG(image, to: contentLocation)
        return contentLocation
    }

    /// Writes the frame that accompanies a battery revision (the Two versions chooser
    /// shows it). Named by time because the revision id is minted after the file exists.
    public func storeBatteryScreenshot(_ image: CGImage, for gameID: GameID, stamp: Date) throws -> ContentLocation {
        let millis = Int64((stamp.timeIntervalSince1970 * 1000).rounded())
        let contentLocation = try ContentLocation(root: .managedLibrary, relativePath: "Saves/\(gameID)/battery/revisions/shot-\(millis).png")
        try writePNG(image, to: contentLocation)
        return contentLocation
    }

    /// PNG, downsampled to `screenshotMaxPixelSize`, written to a temporary file and
    /// swapped into place so a crash never leaves a half-written image.
    private func writePNG(_ image: CGImage, to contentLocation: ContentLocation) throws {
        let url = location.url(for: contentLocation)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.appendingPathExtension("tmp")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ArtworkError.encodingFailed
        }
        CGImageDestinationAddImage(destination, Self.downsampled(image, maxPixelSize: Self.screenshotMaxPixelSize), nil)
        guard CGImageDestinationFinalize(destination) else { throw ArtworkError.encodingFailed }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        cache.remove(contentLocation)
    }

    /// Nearest-neighbour downsample (pixel art stays crisp) when the image exceeds `maxPixelSize`.
    static func downsampled(_ image: CGImage, maxPixelSize: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else { return image }
        let scale = Double(maxPixelSize) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: Reading

    /// Decodes `contentLocation` downsampled so its longest side is at most
    /// `maxPixelSize`. Cached per (location, size). Nil when missing or undecodable.
    public func image(at contentLocation: ContentLocation, maxPixelSize: Int) async -> CGImage? {
        let key = ImageCache.Key(location: contentLocation, maxPixelSize: maxPixelSize)
        if let cached = cache.image(for: key) { return cached }
        let url = location.url(for: contentLocation)
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(url, maxPixelSize: maxPixelSize) }.value
        if let decoded { cache.store(decoded, for: key) }
        return decoded
    }

    /// Synchronous downsampled decode (ImageIO thumbnail path, no full-size bitmap in memory).
    public static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }
    #endif
}

public enum ArtworkError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedFormat(String)
    case encodingFailed

    public var description: String {
        switch self {
        case .unsupportedFormat(let ext): return "Unsupported artwork format '.\(ext)'"
        case .encodingFailed: return "Could not encode the image"
        }
    }
}

#if canImport(ImageIO)
/// Small NSCache wrapper keyed by location + size.
final class ImageCache: @unchecked Sendable {
    struct Key: Hashable {
        let location: ContentLocation
        let maxPixelSize: Int
    }

    private let cache = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    private var keys: Set<Key> = []

    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    private func name(_ key: Key) -> NSString { "\(key.location.description)@\(key.maxPixelSize)" as NSString }

    func image(for key: Key) -> CGImage? { cache.object(forKey: name(key)) }

    func store(_ image: CGImage, for key: Key) {
        cache.setObject(image, forKey: name(key), cost: image.bytesPerRow * image.height)
        lock.lock(); keys.insert(key); lock.unlock()
    }

    func remove(_ location: ContentLocation) {
        lock.lock(); let matching = keys.filter { $0.location == location }; keys.subtract(matching); lock.unlock()
        for key in matching { cache.removeObject(forKey: name(key)) }
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock(); keys.removeAll(); lock.unlock()
    }
}
#else
final class ImageCache: @unchecked Sendable {
    func removeAll() {}
    func remove(_ location: ContentLocation) {}
}
#endif

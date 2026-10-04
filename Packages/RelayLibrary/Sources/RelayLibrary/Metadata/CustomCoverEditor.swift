// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CustomCoverEditor.swift
//  RelayLibrary
//
//  A cover the player chooses (cover-art spec §3). The chosen image is
//  untrusted: it is bounded, decoded by ImageIO with its orientation applied,
//  reduced to 1024 px at most and re-encoded as HEIC without any of its
//  metadata (no EXIF, GPS or camera fields), then stored under the
//  fingerprint of those bytes and recorded as the game's custom-cover value.
//  A reset records a cleared value. Values only move forward in time, so a
//  later choice always wins last-writer-wins sync (Plan E).

import Foundation
import RelayDomain
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

public enum CustomCoverError: Error, Equatable, Sendable {
    /// Not an image ImageIO can decode (or not an image at all).
    case unusableImage
    /// Over the input bounds, or still over 1 MiB once normalised.
    case tooLarge
}

public enum CustomCoverImage {
    public static let maximumInputBytes = 64 << 20
    public static let maximumInputPixels = 256_000_000
    public static let maximumPixelSize = 1024
    /// Quality steps down while the cover is larger than this; the hard cap is `CoverImage.maximumBytes`.
    public static let targetBytes = 400_000
    static let qualities = [0.7, 0.55, 0.4]

    /// A HEIC cover of at most 1024 px on the long side that carries no metadata of the source.
    public static func normalize(_ data: Data) throws -> Data {
        guard data.count <= maximumInputBytes else { throw CustomCoverError.tooLarge }
        #if canImport(ImageIO)
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) >= 1,
              let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw CustomCoverError.unusableImage
        }
        // Read from the header, before anything is decoded.
        guard width * height <= maximumInputPixels else { throw CustomCoverError.tooLarge }
        let thumbnail: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceShouldCacheImmediately: true,
                                          kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) else {
            throw CustomCoverError.unusableImage
        }
        var smallest: Data?
        for quality in qualities {
            let encoded = try encodeHEIC(image, quality: quality)
            if encoded.count < smallest?.count ?? .max { smallest = encoded }
            if encoded.count <= targetBytes { break }
        }
        guard let cover = smallest, CoverImage.validate(cover) == .heic else { throw CustomCoverError.tooLarge }
        return cover
        #else
        throw CustomCoverError.unusableImage
        #endif
    }

    #if canImport(ImageIO)
    /// Only the pixels are added to the destination: none of the source's properties travel.
    private static func encodeHEIC(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw CustomCoverError.unusableImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CustomCoverError.unusableImage }
        return data as Data
    }
    #endif
}

public struct CustomCoverEditor: Sendable {
    private let store: any LibraryStore
    private let artworkStore: ArtworkStore
    private let clock: @Sendable () -> Date

    public init(store: any LibraryStore, artworkStore: ArtworkStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.artworkStore = artworkStore
        self.clock = clock
    }

    /// Makes an image the player chose the game's cover.
    public func choose(_ imageData: Data, for gameID: GameID) async throws -> CustomCover {
        let cover = try await Task.detached(priority: .userInitiated) { try CustomCoverImage.normalize(imageData) }.value
        guard try await store.games.game(id: gameID) != nil else { throw LibraryError.gameNotFound(gameID) }
        let fingerprint = try ContentFingerprint(sha256: Array(SHA256.hash(data: cover)))
        let stored = try artworkStore.storeCustomCover(cover, fingerprint: fingerprint, for: gameID)
        let value = CustomCover(gameID: gameID, fingerprint: fingerprint, sizeInBytes: Int64(cover.count),
                                updatedAt: try await nextStamp(for: gameID))
        do {
            try await store.games.setCustomCover(value)
        } catch {
            try? FileManager.default.removeItem(at: artworkStore.location.url(for: stored))
            throw error
        }
        artworkStore.removeCustomCovers(for: gameID, keeping: fingerprint)
        return value
    }

    /// Reads an image file the player chose (Files, an open panel, a drop), bounded before reading.
    public func choose(contentsOf url: URL, for gameID: GameID) async throws -> CustomCover {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= CustomCoverImage.maximumInputBytes else { throw CustomCoverError.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw CustomCoverError.unusableImage }
        return try await choose(data, for: gameID)
    }

    /// Back to the downloaded cover or the placeholder.
    public func reset(gameID: GameID) async throws {
        try await store.games.setCustomCover(CustomCover(gameID: gameID, fingerprint: nil, sizeInBytes: 0,
                                                         updatedAt: try await nextStamp(for: gameID)))
        artworkStore.removeCustomCovers(for: gameID, keeping: nil)
    }

    /// Now, or just after the current value when the clock has not moved past it.
    private func nextStamp(for gameID: GameID) async throws -> Date {
        let now = clock()
        guard let previous = try await store.games.customCover(for: gameID)?.updatedAt, previous >= now else { return now }
        return previous.addingTimeInterval(0.001)
    }
}

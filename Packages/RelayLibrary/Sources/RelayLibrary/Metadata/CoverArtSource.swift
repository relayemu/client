// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CoverArtSource.swift
//  RelayLibrary
//
//  Where catalog covers come from (Relay's EU cover mirror, reached through
//  RelayHostedSync) and what Relay accepts from it. Downloaded bytes are
//  untrusted: they are stored only after `CoverImage.validate` accepts them.

import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// The answer for one cover key.
public enum CoverFetch: Equatable, Sendable {
    /// Unvalidated bytes; the caller validates before storing.
    case image(Data)
    /// The mirror has no cover under this key.
    case notFound
    /// The answer broke the contract (bad redirect, oversized body); treated like a missing cover.
    case invalid
    /// Offline, rate-limited or a server error: try again later.
    case unavailable
}

public protocol CoverArtSource: Sendable {
    /// Fetches the cover named by a `CoverKey`. Never throws: every failure is a `CoverFetch`.
    func cover(forKey key: String) async -> CoverFetch
}

public enum CoverImage {
    /// The mirror stores covers of at most 1 MiB (RelaySync `covers.MaxBytes`).
    public static let maximumBytes = 1 << 20
    public static let maximumPixelSize = 2048

    public enum Format: String, CaseIterable, Sendable {
        case heic, jpeg
        public var fileExtension: String { self == .heic ? "heic" : "jpg" }
    }

    /// The format of an acceptable cover, or nil: size bound, HEIC or JPEG
    /// signature, a complete image that ImageIO decodes, longest side bound.
    public static func validate(_ data: Data) -> Format? {
        guard !data.isEmpty, data.count <= maximumBytes, let format = signature(of: data) else { return nil }
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) >= 1,
              let type = CGImageSourceGetType(source) as String?, acceptedTypes(for: format).contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= maximumPixelSize else { return nil }
        // Decoding a small thumbnail proves the payload decodes, not just its header.
        let thumbnail: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 64]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) != nil else { return nil }
        return format
        #else
        return nil
        #endif
    }

    static func signature(of data: Data) -> Format? {
        let head = [UInt8](data.prefix(12))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return .jpeg }
        guard head.count == 12, head[4..<8].elementsEqual("ftyp".utf8) else { return nil }
        let brand = String(decoding: head[8..<12], as: UTF8.self)
        return ["heic", "heix", "heim", "heis", "mif1", "msf1"].contains(brand) ? .heic : nil
    }

    #if canImport(ImageIO)
    private static func acceptedTypes(for format: Format) -> Set<String> {
        switch format {
        case .heic: return [UTType.heic.identifier, UTType.heif.identifier]
        case .jpeg: return [UTType.jpeg.identifier]
        }
    }
    #endif
}

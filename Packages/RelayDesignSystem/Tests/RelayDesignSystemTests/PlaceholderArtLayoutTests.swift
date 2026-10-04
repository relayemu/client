// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import SwiftUI
import RelayDomain
@testable import RelayDesignSystem

/// A game without artwork shows its system's short name set large. A long name
/// ("SNES", "NGPC", "PCECD") used to run off the trailing edge and read as a
/// different word ("SNE"), while short names sat inside the card.
@MainActor
final class PlaceholderArtLayoutTests: XCTestCase {
    /// Card artwork sizes in points: iPhone shelf, iPad/Mac grid, Apple TV.
    private let sizes = [CGSize(width: 107, height: 143), CGSize(width: 135, height: 180),
                         CGSize(width: 250, height: 360)]

    func testEveryShortNameStaysInsideThePlaceholder() throws {
        for descriptor in SystemCatalog.all {
            for size in sizes {
                let model = ArtworkModel(title: "", systemName: descriptor.name, system: descriptor.id,
                                         hue: SystemAccent.hue(for: descriptor.id))
                let pixels = try Pixels(PlaceholderArt(model: model, showsTitle: false, size: size))
                let ground = pixels.color(x: pixels.width - 2, y: 2)
                // The name is centred vertically; the mark sits in the top-leading corner.
                let band = Int(size.height * 0.3)..<Int(size.height * 0.7)
                for y in band {
                    for x in [4, pixels.width - 2] {
                        XCTAssertTrue(pixels.color(x: x, y: y).isClose(to: ground),
                                      "\(descriptor.shortName) touches the edge at x=\(x), y=\(y) in \(size)")
                    }
                }
            }
        }
    }
}

private struct RGBA: Equatable {
    let r, g, b, a: UInt8
    func isClose(to other: RGBA) -> Bool {
        max(abs(Int(r) - Int(other.r)), abs(Int(g) - Int(other.g)), abs(Int(b) - Int(other.b))) <= 3
    }
}

@MainActor
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init<V: View>(_ view: V) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "SwiftUI must produce a native render")
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        try buffer.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        bytes = buffer
    }

    /// `y` counts from the top, as the view is laid out.
    func color(x: Int, y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
    }
}

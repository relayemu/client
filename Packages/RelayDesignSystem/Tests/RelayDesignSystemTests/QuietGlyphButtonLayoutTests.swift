// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import SwiftUI
@testable import RelayDesignSystem

/// Protect the detail action row's actual SF Symbols and allocated button bounds.
/// Native input tests still establish activation and accessibility hit behavior.
@MainActor
final class QuietGlyphButtonLayoutTests: XCTestCase {
    private let symbols = ["heart", "clock.arrow.circlepath", "ellipsis"]

    func testNativeGlyphButtonsKeepTheirMinimumAreaAndClearInsets() throws {
        for size in [DynamicTypeSize.large, .accessibility5] {
            for symbol in symbols {
                let image = try render(button(symbol).environment(\.dynamicTypeSize, size))
                XCTAssertGreaterThanOrEqual(image.width, Int(EmberButtonStyle.height), symbol)
                XCTAssertGreaterThanOrEqual(image.height, Int(EmberButtonStyle.height), symbol)
                try assertGlyphIsInsideButton(image, symbol: symbol)
            }
        }
    }

    func testOversizedGlyphsStayContainedAndThreeActionsFitOnAnIPhone() throws {
        for symbol in symbols {
            // A 64-point SF Symbol also exercises the regression on macOS,
            // where a UIKit accessibility category does not scale the font.
            let image = try render(button(symbol, explicitSize: 64))
            try assertGlyphIsInsideButton(image, symbol: symbol)
        }
        let row = try render(
            HStack(spacing: RelaySpacing.s) {
                ForEach(symbols, id: \.self) { self.button($0, explicitSize: 64) }
            }
            .fixedSize()
        )
        XCTAssertLessThanOrEqual(row.width, 375 - 2 * Int(RelaySpacing.m),
                                 "Three enlarged actions must fit the iPhone's 343-point content width")
    }

    #if os(iOS)
    func testActualAccessibilityCategoryStillEnlargesTheNativeSymbols() throws {
        for symbol in symbols {
            let regular = try render(button(symbol).environment(\.dynamicTypeSize, .large))
            let accessible = try render(button(symbol).environment(\.dynamicTypeSize, .accessibility5))
            let regularInk = try inkBounds(in: regular)
            let accessibleInk = try inkBounds(in: accessible)
            XCTAssertGreaterThan(accessibleInk.width, regularInk.width, symbol)
            XCTAssertGreaterThan(accessibleInk.height, regularInk.height, symbol)
        }
    }
    #endif

    private func button(_ symbol: String, explicitSize: CGFloat? = nil) -> some View {
        Button {} label: {
            if let explicitSize {
                Image(systemName: symbol).font(.system(size: explicitSize, weight: .semibold))
            } else {
                Image(systemName: symbol)
            }
        }
        .buttonStyle(.quietGlyph)
    }

    private func assertGlyphIsInsideButton(_ image: CGImage, symbol: String,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let ink = try inkBounds(in: image)
        // Allow SF Symbols' optical overhang while requiring visible breathing
        // room on every edge. The former 44-point frame clips these large glyphs.
        XCTAssertGreaterThanOrEqual(ink.minX, 4, symbol, file: file, line: line)
        XCTAssertGreaterThanOrEqual(ink.minY, 4, symbol, file: file, line: line)
        XCTAssertLessThanOrEqual(ink.maxX, CGFloat(image.width - 4), symbol, file: file, line: line)
        XCTAssertLessThanOrEqual(ink.maxY, CGFloat(image.height - 4), symbol, file: file, line: line)
    }

    private func inkBounds(in image: CGImage) throws -> CGRect {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var left = image.width, right = -1, top = image.height, bottom = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                // In the explicit light scheme, only the glyph is dark and
                // opaque; the surface and separator cannot satisfy this mask.
                if pixels[index + 3] >= 128 && pixels[index] < 80
                    && pixels[index + 1] < 80 && pixels[index + 2] < 80 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(right, left, "The native symbol must render visible ink")
        return CGRect(x: left, y: top, width: max(0, right - left + 1), height: max(0, bottom - top + 1))
    }

    private func render<V: View>(_ content: V) throws -> CGImage {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, .light))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "SwiftUI must produce a native render")
    }
}

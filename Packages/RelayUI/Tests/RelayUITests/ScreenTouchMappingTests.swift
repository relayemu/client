// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import CoreGraphics
import RelayEmulation
import RelayDomain
@testable import RelayUI
@testable import RelayVideo

@MainActor
final class ScreenTouchMappingTests: XCTestCase {
    private let ds = FrameDescriptor(width: 256, height: 192, bytesPerRow: 256 * 4,
                                     pixelFormat: .rgbx8, aspectRatio: 4.0 / 3.0)

    func testIntegerPicturesFitSmallAllocatedDSCompanionsWithoutCropping() throws {
        for size in [CGSize(width: 633, height: 375), CGSize(width: 756, height: 354)] {
            let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                controls: SystemCatalog.nintendoDS.inputLayout, screens: SystemCatalog.nintendoDS.screens,
                preferredArrangement: .primarySecondary, scaling: .integer, displayScale: 2)
            let layout = RelayLogicalScreenLayout(size: surface.gameFrame.size,
                screens: SystemCatalog.nintendoDS.screens, preferred: .primarySecondary, gap: 8)
            for frame in layout.frames {
                let options = DisplayOptions(scaling: .integer)
                let rect = MetalFrameView.presentedRect(frame: ds, in: frame.size, options: options, displayScale: 2)
                XCTAssertGreaterThanOrEqual(rect.minX, 0, "\(size): \(frame)")
                XCTAssertGreaterThanOrEqual(rect.minY, 0, "\(size): \(frame)")
                XCTAssertLessThanOrEqual(rect.maxX, frame.width + 0.001)
                XCTAssertLessThanOrEqual(rect.maxY, frame.height + 0.001)
                let center = try XCTUnwrap(MetalFrameView.nativePoint(
                    for: CGPoint(x: rect.midX, y: rect.midY), frame: ds,
                    in: frame.size, options: options, displayScale: 2))
                XCTAssertEqual(center.x, 128)
                XCTAssertEqual(center.y, 96)
                for (x, y) in [(0, 0), (255, 0), (0, 191), (255, 191)] {
                    let point = CGPoint(x: rect.minX + (CGFloat(x) + 0.5) * rect.width / 256,
                                        y: rect.minY + (CGFloat(y) + 0.5) * rect.height / 192)
                    let corner = try XCTUnwrap(MetalFrameView.nativePoint(for: point, frame: ds,
                        in: frame.size, options: options, displayScale: 2))
                    XCTAssertEqual(corner.x, x)
                    XCTAssertEqual(corner.y, y)
                }
            }
        }
    }

    func testIntegerTouchCoordinatesMatchRenderedPixelsAtFractionalPointScales() throws {
        let options = DisplayOptions(scaling: .integer)
        let cases: [(size: CGSize, scale: CGFloat, pixels: CGSize)] = [
            // Five drawable pixels per DS pixel, or 5/3 view points.
            (CGSize(width: 430, height: 330), 3, CGSize(width: 1280, height: 960)),
            // Three drawable pixels per DS pixel, or 1.5 view points.
            (CGSize(width: 390, height: 300), 2, CGSize(width: 768, height: 576)),
            // A compact picture can be smaller than its native size in points.
            (CGSize(width: 180, height: 140), 3, CGSize(width: 512, height: 384)),
            // Expanded A remains unchanged: four drawable pixels, two points.
            (CGSize(width: 834, height: 399), 2, CGSize(width: 1024, height: 768)),
        ]
        let nativeSamples = [(0, 0), (42, 75), (128, 96), (255, 191)]
        for sample in cases {
            let drawable = CGSize(width: sample.size.width * sample.scale,
                                  height: sample.size.height * sample.scale)
            let pixels = MetalFrameView.presentedSize(frame: ds, drawable: drawable, options: options)
            XCTAssertEqual(pixels, sample.pixels)
            // Construct touches at the centers of pixels that the renderer
            // actually displays, independent of the hit-testing rectangle.
            for (x, y) in nativeSamples {
                let point = CGPoint(
                    x: ((drawable.width - pixels.width) / 2 + (CGFloat(x) + 0.5) * pixels.width / 256) / sample.scale,
                    y: ((drawable.height - pixels.height) / 2 + (CGFloat(y) + 0.5) * pixels.height / 192) / sample.scale)
                let mapped = try XCTUnwrap(MetalFrameView.nativePoint(for: point, frame: ds,
                    in: sample.size, options: options, displayScale: sample.scale))
                XCTAssertEqual(mapped.x, x)
                XCTAssertEqual(mapped.y, y)
            }
        }
    }

    func testRetinaIntegerPictureEdgesAndLetterboxingUseTheSameRectangle() throws {
        let size = CGSize(width: 390, height: 300)
        let options = DisplayOptions(scaling: .integer)
        let rect = MetalFrameView.presentedRect(frame: ds, in: size, options: options, displayScale: 2)
        XCTAssertEqual(rect, CGRect(x: 3, y: 6, width: 384, height: 288))
        XCTAssertNil(MetalFrameView.nativePoint(for: CGPoint(x: 2.5, y: 150), frame: ds,
                                                in: size, options: options, displayScale: 2))
        XCTAssertNil(MetalFrameView.nativePoint(for: CGPoint(x: 195, y: 5.5), frame: ds,
                                                in: size, options: options, displayScale: 2))
        let nearEdge = try XCTUnwrap(MetalFrameView.nativePoint(for: CGPoint(x: 3.75, y: 6.75), frame: ds,
                                                in: size, options: options, displayScale: 2))
        XCTAssertEqual(nearEdge.x, 0)
        XCTAssertEqual(nearEdge.y, 0)
    }

    func testFitAndFillMappingDoNotChangeWithDisplayDensity() throws {
        let size = CGSize(width: 390, height: 300)
        let point = CGPoint(x: 50, y: 75)
        for scaling in [DisplayScaling.fit, .fill] {
            let options = DisplayOptions(scaling: scaling)
            let expectedRect = MetalFrameView.presentedRect(frame: ds, in: size, options: options)
            let expectedPoint = try XCTUnwrap(MetalFrameView.nativePoint(for: point, frame: ds,
                                                                       in: size, options: options))
            for scale in [CGFloat(2), 3] {
                let rect = MetalFrameView.presentedRect(frame: ds, in: size, options: options, displayScale: scale)
                XCTAssertEqual(rect.minX, expectedRect.minX, accuracy: 0.0001)
                XCTAssertEqual(rect.minY, expectedRect.minY, accuracy: 0.0001)
                XCTAssertEqual(rect.width, expectedRect.width, accuracy: 0.0001)
                XCTAssertEqual(rect.height, expectedRect.height, accuracy: 0.0001)
                let mapped = try XCTUnwrap(MetalFrameView.nativePoint(for: point, frame: ds,
                    in: size, options: options, displayScale: scale))
                XCTAssertEqual(mapped.x, expectedPoint.x)
                XCTAssertEqual(mapped.y, expectedPoint.y)
            }
        }
    }

    func testDefaultScaleRemainsCompatibleAndInvalidScalesRejectTouches() {
        let size = CGSize(width: 390, height: 300)
        let options = DisplayOptions(scaling: .integer)
        XCTAssertEqual(MetalFrameView.presentedRect(frame: ds, in: size, options: options),
                       CGRect(x: 67, y: 54, width: 256, height: 192))
        for scale in [CGFloat.zero, -1, .infinity, .nan] {
            XCTAssertEqual(MetalFrameView.presentedRect(frame: ds, in: size, options: options, displayScale: scale), .zero)
            XCTAssertNil(MetalFrameView.nativePoint(for: CGPoint(x: 195, y: 150), frame: ds,
                                                   in: size, options: options, displayScale: scale))
        }
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ScreenArrangement.swift
//  RelayVideo
//
//  How a system with two logical screens is laid out (spec §14.4). The
//  presenter draws each screen in its own view; the arrangement is a product
//  choice the player makes once per system and Relay remembers.

import Foundation
import CoreGraphics
import RelayEmulation

public enum ScreenArrangement: String, CaseIterable, Hashable, Codable, Sendable {
    /// Screens one above the other, as the hardware is held.
    case stacked
    /// Screens next to each other, for wide displays.
    case sideBySide
    /// The first screen large, the second small in a corner.
    case primarySecondary
    /// The second screen large, the first small in a corner.
    case secondaryPrimary
}

public extension ScreenArrangement {
    var isAdvanced: Bool { self == .secondaryPrimary }
}

public extension MetalFrameView {
    /// Where the picture lands inside a view of `size` points, for hit-testing
    /// touches against the screen's native pixels. The same geometry as the
    /// presenter's, in points rather than drawable pixels. Integer scaling must
    /// be quantized in drawable pixels before converting back to view points.
    static func presentedRect(frame: FrameDescriptor, in size: CGSize, options: DisplayOptions,
                              displayScale: CGFloat = 1) -> CGRect {
        guard displayScale.isFinite, displayScale > 0 else { return .zero }
        let drawable = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        guard drawable.width.isFinite, drawable.height.isFinite,
              drawable.width > 0, drawable.height > 0 else { return .zero }
        let pixels = presentedSize(frame: frame, drawable: drawable, options: options)
        let presented = CGSize(width: pixels.width / displayScale, height: pixels.height / displayScale)
        guard presented.width > 0, presented.height > 0 else { return .zero }
        return CGRect(x: (size.width - presented.width) / 2, y: (size.height - presented.height) / 2,
                      width: presented.width, height: presented.height)
    }

    /// Maps a point in a view of `size` to native pixels of `frame`, or nil when
    /// the point is outside the picture.
    static func nativePoint(for point: CGPoint, frame: FrameDescriptor, in size: CGSize, options: DisplayOptions,
                            displayScale: CGFloat = 1) -> (x: Int, y: Int)? {
        let rect = presentedRect(frame: frame, in: size, options: options, displayScale: displayScale)
        guard rect.width > 0, rect.contains(point) else { return nil }
        let x = Int((point.x - rect.minX) / rect.width * CGFloat(frame.width))
        let y = Int((point.y - rect.minY) / rect.height * CGFloat(frame.height))
        return (min(max(x, 0), frame.width - 1), min(max(y, 0), frame.height - 1))
    }
}

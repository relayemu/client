// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

public enum RelaySpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 40
    public static let huge: CGFloat = 48
    public static let giant: CGFloat = 64

    /// Platform layout metrics (§5.1).
    public struct Layout: Sendable {
        public let screenMargin: CGFloat
        public let shelfGutter: CGFloat
        public let cardGap: CGFloat
        public let sectionGap: CGFloat
        public let shelfArtworkHeight: CGFloat
        public let gridColumns: Int
    }

    /// Metrics for the current platform (size-class refinements happen in views).
    public static var layout: Layout {
        #if os(tvOS)
        return Layout(screenMargin: 80, shelfGutter: 80, cardGap: 40, sectionGap: 64, shelfArtworkHeight: 320, gridColumns: 5)
        #elseif os(macOS)
        return Layout(screenMargin: 24, shelfGutter: 24, cardGap: 16, sectionGap: 40, shelfArtworkHeight: 180, gridColumns: 6)
        #else
        return Layout(screenMargin: 16, shelfGutter: 16, cardGap: 12, sectionGap: 32, shelfArtworkHeight: 150, gridColumns: 3)
        #endif
    }

    /// iPad regular-width metrics (§5.1).
    public static let padRegularLayout = Layout(screenMargin: 32, shelfGutter: 32, cardGap: 16, sectionGap: 40, shelfArtworkHeight: 200, gridColumns: 6)
}

public enum RelayRadius {
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 28

    /// Card radius for the current platform (§5.2): iPhone m, iPad/macOS l, tvOS xl.
    public static var card: CGFloat {
        #if os(tvOS)
        return xl
        #elseif os(macOS)
        return l
        #else
        return m
        #endif
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RelayColor.swift
//
//  Every colour has explicit Dark and Light values; nothing is derived at
//  runtime. Views outside the package never use literal colours.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum RelayColor {
    // MARK: Neutrals (§4.1)
    public static let canvas = dynamic(light: 0xFBFAF8, dark: 0x0F0E0D)
    public static let canvasGrouped = dynamic(light: 0xF2F0EC, dark: 0x151412)
    public static let surface = dynamic(light: 0xFFFFFF, dark: 0x1F1D1B)
    public static let surfaceElevated = dynamic(light: 0xFFFFFF, dark: 0x272522)
    public static let separator = dynamic(light: 0x1A1816, dark: 0xF5F2EE, lightAlpha: 0.08, darkAlpha: 0.08)
    public static let separatorStrong = dynamic(light: 0x1A1816, dark: 0xF5F2EE, lightAlpha: 0.16, darkAlpha: 0.16)
    public static let ink = Color(hex: 0x1A1816)
    public static let offWhite = Color(hex: 0xF5F2EE)

    // MARK: Text (§4.2)
    public static let textPrimary = dynamic(light: 0x1A1816, dark: 0xF5F2EE)
    public static let textSecondary = dynamic(light: 0x1A1816, dark: 0xF5F2EE, lightAlpha: 0.64, darkAlpha: 0.62)
    /// Increase Contrast variant of `textSecondary` (§10: 78%).
    public static let textSecondaryHighContrast = dynamic(light: 0x1A1816, dark: 0xF5F2EE, lightAlpha: 0.78, darkAlpha: 0.78)
    public static let textTertiary = dynamic(light: 0x1A1816, dark: 0xF5F2EE, lightAlpha: 0.55, darkAlpha: 0.50)
    /// Label on Ember: Ink in Dark Mode, white in Light Mode (§4.3 contrast note).
    public static let textOnEmber = dynamic(light: 0xFFFFFF, dark: 0x1A1816)
    public static let textOnArtwork = offWhite

    // MARK: Ember (§4.3)
    public static let ember = dynamic(light: 0xC93D25, dark: 0xFF6A45)
    public static let emberPressed = dynamic(light: 0xB8361F, dark: 0xFF7A57)
    public static let emberTint = dynamic(light: 0xC93D25, dark: 0xFF6A45, lightAlpha: 0.10, darkAlpha: 0.14)

    // MARK: Semantic status (§4.4) — glyph tints only; text always accompanies them.
    public static let positive = dynamic(light: 0x1E8E3E, dark: 0x34C759)
    public static let caution = dynamic(light: 0xB26A00, dark: 0xFFB340)
    public static let critical = dynamic(light: 0xC62828, dark: 0xFF5B5B)

    /// Artwork scrim colour (Ink); used with opacity by the scrim helpers.
    public static let scrim = ink

    // MARK: Construction

    /// A colour with distinct light/dark values resolved by the platform.
    public static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
        #else
        return Color(hex: light, alpha: lightAlpha)
        #endif
    }
}

public extension Color {
    /// sRGB colour from a 0xRRGGBB literal.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(alpha))
    }
}
#elseif canImport(AppKit)
extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(alpha))
    }
}
#endif

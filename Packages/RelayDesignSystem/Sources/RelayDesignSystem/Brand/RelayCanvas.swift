// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RelayCanvas.swift
//  RelayDesignSystem — Relay's ground.
//
//  The website is paper: warm, with a dot grid you feel rather than read. The app
//  keeps the material and drops the theatre — the same warm neutral with the same
//  26-pt grid, printed far below the ink so it reads as texture on a large screen
//  and disappears on a small one. It is the cheapest way for a screenshot with no
//  content on it to still be Relay.

import SwiftUI

public struct RelayCanvas: View {
    private let grouped: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(grouped: Bool = false) { self.grouped = grouped }

    public var body: some View {
        ZStack {
            (grouped ? RelayColor.canvasGrouped : RelayColor.canvas)
            if !reduceTransparency && contrast != .increased {
                RelayDotGrid(color: scheme == .dark ? RelayColor.offWhite : RelayColor.ink,
                             opacity: scheme == .dark ? 0.045 : 0.055)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The paper grid: 26-pt pitch, 1.4-pt dots, drawn once into a `Canvas`.
public struct RelayDotGrid: View {
    private let color: Color
    private let opacity: Double
    private let pitch: CGFloat = 26
    private let dot: CGFloat = 1.4

    public init(color: Color, opacity: Double) {
        self.color = color
        self.opacity = opacity
    }

    public var body: some View {
        Canvas { context, size in
            let shade = GraphicsContext.Shading.color(color.opacity(opacity))
            var y = pitch / 2
            while y < size.height {
                var x = pitch / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)), with: shade)
                    x += pitch
                }
                y += pitch
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

public extension View {
    /// Relay's screen ground. Use instead of a bare `.background(RelayColor.canvas)`.
    func relayCanvas(grouped: Bool = false) -> some View {
        background(RelayCanvas(grouped: grouped))
    }
}

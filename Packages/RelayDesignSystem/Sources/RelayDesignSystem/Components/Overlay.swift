// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Overlay.swift
//  RelayDesignSystem — §8.7 OverlayCard, §8.8 StatusToast, §8.9 ModePill.
//  In-game surfaces: the pause card, transient confirmations and the
//  persistent mode indicator. Geometry per platform lives here.

import SwiftUI

/// The pause overlay container (§8.7): elevated surface, `radiusXXL`, platform width.
public struct OverlayCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: Self.width)
            .background(RelayColor.surfaceElevated, in: RoundedRectangle(cornerRadius: RelayRadius.xxl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RelayRadius.xxl, style: .continuous).strokeBorder(RelayColor.separator))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 16)
    }

    /// iPhone landscape 420 pt, iPad/macOS 520 pt, tvOS 720 pt (§8.7).
    public static var width: CGFloat {
        #if os(tvOS)
        return 720
        #elseif os(macOS)
        return 520
        #else
        return 420
        #endif
    }
}

/// Transient confirmation (§8.8): thin material capsule, icon + footnote label,
/// optional inline thumbnail. Presentation timing is the caller's (1.8 s).
public struct StatusToast: View {
    private let text: String
    private let symbol: RelaySymbol
    private let thumbnail: CGImage?

    public init(_ text: String, symbol: RelaySymbol, thumbnail: CGImage? = nil) {
        self.text = text
        self.symbol = symbol
        self.thumbnail = thumbnail
    }

    public var body: some View {
        HStack(spacing: RelaySpacing.xs) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: Self.height - 12)
                    .clipShape(RoundedRectangle(cornerRadius: RelayRadius.s, style: .continuous))
            }
            symbol.image
                .font(.relayStatusEmphasis)
                .foregroundStyle(RelayColor.textPrimary)
                .accessibilityHidden(true)
            Text(text)
                .font(.relayStatusEmphasis)
                .foregroundStyle(RelayColor.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, RelaySpacing.m)
        .frame(minHeight: Self.height)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(RelayColor.separator))
        .accessibilityElement(children: .combine)
    }

    public static var height: CGFloat {
        #if os(tvOS)
        return 56
        #else
        return 36
        #endif
    }
}

/// Persistent indicator while a mode is active (§8.9): rewinding, 2×. Never blinks.
public struct ModePill: View {
    private let text: String
    private let symbol: RelaySymbol

    public init(_ text: String, symbol: RelaySymbol) {
        self.text = text
        self.symbol = symbol
    }

    public var body: some View {
        StatusToast(text, symbol: symbol)
    }
}

/// One-line attention bar at the top of the pause overlay (§17.2 notice bar).
public struct NoticeBar: View {
    private let headline: String
    private let message: String
    private let symbol: RelaySymbol

    public init(headline: String, message: String, symbol: RelaySymbol = .caution) {
        self.headline = headline
        self.message = message
        self.symbol = symbol
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RelaySpacing.xs) {
            symbol.image
                .font(.relayStatusEmphasis)
                .foregroundStyle(RelayColor.caution)
                .accessibilityHidden(true)
            (Text(headline).fontWeight(.semibold) + Text(" ") + Text(message))
                .font(.relayStatus)
                .foregroundStyle(RelayColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RelaySpacing.s)
        .background(RelayColor.canvasGrouped, in: RoundedRectangle(cornerRadius: RelayRadius.m, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

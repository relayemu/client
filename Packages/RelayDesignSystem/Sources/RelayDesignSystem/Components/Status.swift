// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Status.swift
//  RelayDesignSystem — §8.6 StatusLine, §8.10 EmptyState, §8.11 ProblemCard.
//  Status never depends on colour alone: glyph shape + text, always.

import SwiftUI

public enum StatusTone: Sendable {
    case neutral, positive, caution, critical

    var color: Color {
        switch self {
        case .neutral: return RelayColor.textSecondary
        case .positive: return RelayColor.positive
        case .caution: return RelayColor.caution
        case .critical: return RelayColor.critical
        }
    }

    var symbol: RelaySymbol {
        switch self {
        case .neutral: return .info
        case .positive: return .positive
        case .caution: return .caution
        case .critical: return .critical
        }
    }
}

/// Glyph + footnote text (§8.6).
public struct StatusLine: View {
    private let text: String
    private let tone: StatusTone
    private let symbol: RelaySymbol?
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ text: String, tone: StatusTone = .neutral, symbol: RelaySymbol? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RelaySpacing.xs) {
            (symbol ?? tone.symbol).image
                .font(.relayStatus)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(text)
                .font(.relayStatus)
                .foregroundStyle(contrast == .increased ? RelayColor.textSecondaryHighContrast : RelayColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Centred empty state (§8.10). An empty Relay screen is one of the few places the
/// anything are the ones that have to carry the brand on their own, because there is
/// no artwork to carry it for them. Screens with a `PenScene` get the drawing; the
/// smaller, in-context empties get their glyph on a warm plate rather than floating
/// grey on black.
public struct EmptyState: View {
    private let scene: PenScene?
    private let symbol: RelaySymbol?
    private let title: String
    private let message: String
    private let primary: (title: String, action: () -> Void)?
    private let secondary: (title: String, action: () -> Void)?
    // Decorative artwork does not need to grow with accessibility text. Keeping
    // its footprint stable leaves the width and height available for the words.
    private let sceneWidth: CGFloat = 208

    /// The branded form: a drawing in Relay's own hand.
    public init(scene: PenScene, title: String, message: String,
                primary: (title: String, action: () -> Void)? = nil,
                secondary: (title: String, action: () -> Void)? = nil) {
        self.scene = scene
        self.symbol = nil
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
    }

    /// The compact form, for empties inside a screen that already has content.
    public init(symbol: RelaySymbol, title: String, message: String,
                primary: (title: String, action: () -> Void)? = nil,
                secondary: (title: String, action: () -> Void)? = nil) {
        self.scene = nil
        self.symbol = symbol
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
    }

    public var body: some View {
        VStack(spacing: RelaySpacing.m) {
            illustration
                .padding(.bottom, RelaySpacing.xxs)
            Text(title)
                .font(.relaySubheader)
                .foregroundStyle(RelayColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.relayBody)
                .foregroundStyle(RelayColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            AdaptiveActionRow(alignment: .center) {
                if let primary {
                    Button(action: primary.action) { Text(primary.title) }.buttonStyle(.ember).relayScrollToKeyboardFocus()
                }
                if let secondary {
                    Button(action: secondary.action) { Text(secondary.title) }.buttonStyle(.quiet).relayScrollToKeyboardFocus()
                }
            }
            .padding(.top, RelaySpacing.xs)
        }
        .padding(RelaySpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var illustration: some View {
        if let scene {
            PenSceneView(scene, width: sceneWidth)
        } else if let symbol {
            symbol.image
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(RelayColor.ember)
                .frame(width: 76, height: 76)
                .background(RelayColor.emberTint, in: Circle())
                .overlay(Circle().strokeBorder(RelayColor.ember.opacity(0.22)))
                .accessibilityHidden(true)
        }
    }
}

/// Inline, non-modal problem surface (§8.11). Relay's problem shape: a tone-coloured
/// spine down the leading edge, the way a system tile carries its hue. It is the same
/// shape language as the rest of the app, so a warning does not look like a foreign
/// object, and it stays sober — nothing here is ever drawn as a joke.
public struct ProblemCard: View {
    private let tone: StatusTone
    private let headline: String
    private let message: String
    private let primary: (title: String, action: () -> Void)?
    private let dismiss: (() -> Void)?

    public init(tone: StatusTone = .caution, headline: String, message: String,
                primary: (title: String, action: () -> Void)? = nil,
                dismiss: (() -> Void)? = nil) {
        self.tone = tone
        self.headline = headline
        self.message = message
        self.primary = primary
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tone.color).frame(width: 3)
            HStack(alignment: .top, spacing: RelaySpacing.s) {
                tone.symbol.image
                    .font(.relaySubheader)
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                    Text(headline)
                        .font(.relayCardTitle)
                        .foregroundStyle(RelayColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.relayCallout)
                        .foregroundStyle(RelayColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if primary != nil || dismiss != nil {
                        AdaptiveActionRow {
                            if let primary {
                                Button(action: primary.action) { Text(primary.title) }.buttonStyle(.ember).relayScrollToKeyboardFocus()
                            }
                            if let dismiss {
                                Button(action: dismiss) { Text("Not Now", bundle: .module) }.buttonStyle(.quiet).relayScrollToKeyboardFocus()
                            }
                        }
                        .padding(.top, RelaySpacing.xxs)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(RelaySpacing.m)
        }
        .background(RelayColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous).strokeBorder(RelayColor.separator))
        .accessibilityElement(children: .contain)
    }
}

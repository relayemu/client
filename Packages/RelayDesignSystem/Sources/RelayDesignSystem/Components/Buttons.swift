// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Buttons.swift
//  RelayDesignSystem — §8.5 EmberButton and QuietButton styles.

import SwiftUI

public struct EmberButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .relayActionLabel(for: dynamicType)
            .font(.relayCardTitle)
            // Actions keep the selected text size. Their row may stack and the
            // button may grow vertically; the label never shrinks to fit.
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .foregroundStyle(isEnabled ? RelayColor.textOnEmber : RelayColor.textSecondary)
            .padding(.horizontal, RelaySpacing.l)
            .padding(.vertical, RelaySpacing.xs)
            .frame(minHeight: Self.height)
            .background {
                TextActionBackground(fill: isEnabled ? (configuration.isPressed ? RelayColor.emberPressed : RelayColor.ember) : RelayColor.emberTint,
                                     accessibilitySize: dynamicType.isAccessibilitySize)
            }
            .relayActionFocus(accessibilitySize: dynamicType.isAccessibilitySize)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .relayMicro, value: configuration.isPressed)
    }

    public static var height: CGFloat {
        #if os(tvOS)
        return 66
        #elseif os(macOS)
        return 40
        #else
        return 44
        #endif
    }
}

public struct QuietButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .relayActionLabel(for: dynamicType)
            .font(.relayCardTitle)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .foregroundStyle(RelayColor.textPrimary)
            .padding(.horizontal, RelaySpacing.l)
            .padding(.vertical, RelaySpacing.xs)
            .frame(minHeight: EmberButtonStyle.height)
            .background {
                TextActionBackground(fill: RelayColor.surfaceElevated, accessibilitySize: dynamicType.isAccessibilitySize, bordered: true)
            }
            .relayActionFocus(accessibilitySize: dynamicType.isAccessibilitySize)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .relayMicro, value: configuration.isPressed)
    }
}

/// A tall, multiline capsule curves away from the first and last text lines.
/// Accessibility actions use the existing corner radius so every line remains
/// over its fill. Normal text actions keep their established capsule geometry.
struct TextActionBackground: View {
    let fill: Color
    let accessibilitySize: Bool
    var bordered = false

    var body: some View {
        if accessibilitySize {
            RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous)
                .fill(fill)
                .overlay {
                    if bordered {
                        RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous)
                            .strokeBorder(RelayColor.separator)
                    }
                }
        } else {
            Capsule().fill(fill)
                .overlay {
                    if bordered { Capsule().strokeBorder(RelayColor.separator) }
                }
        }
    }
}

extension View {
    @ViewBuilder
    func relayActionLabel(for size: DynamicTypeSize) -> some View {
        if size.isAccessibilitySize {
            // These text-button styles already name the action. Giving its title
            // the full width avoids a redundant large icon splitting a word.
            labelStyle(.titleOnly)
        } else {
            self
        }
    }
}

/// A quiet button carrying one glyph and no words. Its native symbol size grows
/// inside a padded minimum hit area, so accessibility glyphs cannot overlap.
public struct QuietGlyphButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.relayCardTitle)
            .fixedSize()
            .foregroundStyle(RelayColor.textPrimary)
            .padding(RelaySpacing.xs)
            .frame(minWidth: EmberButtonStyle.height, minHeight: EmberButtonStyle.height)
            .contentShape(Rectangle())
            .background(RelayColor.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(RelayColor.separator))
            .relayActionFocus(accessibilitySize: false)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .relayMicro, value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func relayActionFocus(accessibilitySize: Bool) -> some View {
        #if os(tvOS)
        FocusReactingAction(label: self, accessibilitySize: accessibilitySize)
        #else
        self
        #endif
    }
}

#if os(tvOS)
/// Read focus inside the native button label, as Relay's cards do. Custom
/// button styles otherwise leave Siri Remote actions without a visible focus.
private struct FocusReactingAction<Label: View>: View {
    let label: Label
    let accessibilitySize: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .overlay {
                if accessibilitySize {
                    RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous)
                        .strokeBorder(RelayColor.offWhite.opacity(isFocused ? 0.9 : 0), lineWidth: 3)
                } else {
                    Capsule()
                        .strokeBorder(RelayColor.offWhite.opacity(isFocused ? 0.9 : 0), lineWidth: 3)
                }
            }
            .scaleEffect(isFocused && !reduceMotion ? 1.04 : 1)
            .shadow(color: RelayColor.scrim.opacity(isFocused ? 0.45 : 0), radius: isFocused ? 14 : 0, y: isFocused ? 6 : 0)
            .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: isFocused)
    }
}
#endif

/// Keeps action labels at their chosen text size. A row becomes a vertical group
/// when its full labels do not fit, and always stacks at accessibility sizes.
public struct AdaptiveActionRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    private let alignment: HorizontalAlignment
    private let content: Content

    public init(alignment: HorizontalAlignment = .leading, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public var body: some View {
        if dynamicType.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: RelaySpacing.s) { content }
                    .fixedSize(horizontal: true, vertical: false)
                stacked
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: alignment, spacing: RelaySpacing.s) { content }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

public extension ButtonStyle where Self == QuietGlyphButtonStyle {
    static var quietGlyph: QuietGlyphButtonStyle { QuietGlyphButtonStyle() }
}

public extension ButtonStyle where Self == EmberButtonStyle {
    static var ember: EmberButtonStyle { EmberButtonStyle() }
}

public extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

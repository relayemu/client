// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import RelayDomain

/// Relay-owned artwork choices. No geometry, input mapping, image downloads or
/// manufacturer assets belong here. Disabling artwork does not disable controls.
public struct RelaySkinConfiguration: Codable, Equatable, Sendable {
    public enum Finish: String, Codable, CaseIterable, Sendable { case graphite, mist }
    public enum Accent: String, Codable, CaseIterable, Sendable { case system, neutral, teal, violet }
    public var enabled: Bool
    public var finish: Finish
    public var accent: Accent

    public init(enabled: Bool = true, finish: Finish = .graphite, accent: Accent = .system) {
        self.enabled = enabled
        self.finish = finish
        self.accent = accent
    }

    public static let standard = Self()

    public func accentColor(for system: SystemID) -> Color {
        switch accent {
        case .system: return SystemAccent.hue(for: system).accent
        case .neutral: return foreground
        case .teal: return SystemHue.teal.accent
        case .violet: return SystemHue.violet.accent
        }
    }

    public var colorScheme: ColorScheme { finish == .graphite ? .dark : .light }
    public var background: Color { finish == .graphite ? RelayColor.ink : RelayColor.offWhite }
    public var foreground: Color { finish == .graphite ? RelayColor.offWhite : RelayColor.ink }
}

/// A quiet inset deck, clipped OUT of the allocated picture. The same treatment
/// can surround a dual-screen portrait stack without covering its lower screen.
/// In landscape the game owns the full canvas: only the control treatment shows.
public struct RelaySkinDeck: View {
    public let configuration: RelaySkinConfiguration
    public let system: SystemID
    public let excluding: CGRect

    public init(configuration: RelaySkinConfiguration, system: SystemID, excluding: CGRect) {
        self.configuration = configuration
        self.system = system
        self.excluding = excluding
    }

    public var body: some View {
        GeometryReader { proxy in
            if configuration.enabled {
                Canvas { context, size in
                    var outside = Path(CGRect(origin: .zero, size: size))
                    outside.addRect(excluding)
                    context.clip(to: outside, style: FillStyle(eoFill: true))
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(configuration.background))
                    let accent = configuration.accentColor(for: system)
                    let dash = CGRect(x: size.width / 2 - 14, y: size.height - RelaySpacing.m,
                                      width: 28, height: 3)
                    context.fill(Path(roundedRect: dash, cornerRadius: 1.5), with: .color(accent.opacity(0.65)))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .environment(\.colorScheme, configuration.colorScheme)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

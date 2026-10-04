// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SystemIdentity.swift
//
//  The System Spectrum is not decoration and it is not a legend: it is how a
//  library of a dozen consoles reads as one library. Every system carries the same
//  three things everywhere it appears — a hue, a short name, and the dash — so a
//  player learns "the violet ones are Super NES" without being told.
//
//  Relay owns these colours and these short names. No manufacturer palette, no

import SwiftUI
import RelayDomain

public extension SystemID {
    /// Relay's own short name, for badges and placeholders. Never a maker's logotype.
    var abbreviation: String {
        if let known = SystemAbbreviation.table[self] { return known }
        // Unknown systems: the identifier, upper-cased and clipped, is always something.
        return String(rawValue.uppercased().prefix(5))
    }
}

enum SystemAbbreviation {
    /// The catalog's short names, so a badge and Game Detail never disagree.
    static let table: [SystemID: String] = Dictionary(
        uniqueKeysWithValues: SystemCatalog.all.map { ($0.id, $0.shortName) })
}

/// A system's badge: the dash, the short name, on the hue's own tint.
/// Small enough for a card corner, legible enough for Apple TV.
public struct SystemChip: View {
    private let name: String
    private let hue: SystemHue
    private let compact: Bool
    #if os(tvOS)
    private let dashHeight: CGFloat = 6
    #else
    @ScaledMetric(relativeTo: .caption) private var dashHeight: CGFloat = 3.5
    #endif

    public init(_ name: String, hue: SystemHue, compact: Bool = false) {
        self.name = name
        self.hue = hue
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: RelaySpacing.xxs + 2) {
            RelayDash(hue.accent, height: dashHeight)
            Text(name)
                .font(.relayBadge)
                .foregroundStyle(hue.accent)
                .lineLimit(compact ? 1 : nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, compact ? RelaySpacing.xs : RelaySpacing.s)
        .padding(.vertical, compact ? 3 : RelaySpacing.xxs + 1)
        .background(hue.tint, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(hue.accent.opacity(0.22)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
    }
}

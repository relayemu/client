// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RelayMark.swift
//  RelayDesignSystem — the Baton, Relay's canonical mark (BRAND_IDENTITY.md §2).
//
//  One geometry, shared with `Brand/relay-mark.svg`, the app icons and the
//  website. Never redraw it by eye and never rotate it to another angle.

import SwiftUI

/// The two halves of the Baton. They are separate shapes so the lead can take the
/// surface's contrast colour while the trail stays Ember, and so the tvOS icon can
/// put them on different parallax layers.
public enum RelayMarkPart: Sendable {
    case lead, trail
}

/// One capsule of the Baton, drawn in the canonical 100 × 100 box and scaled to fit.
public struct RelayMarkShape: Shape {
    public let part: RelayMarkPart
    public init(_ part: RelayMarkPart) { self.part = part }

    /// Canonical construction (Brand/README.md): the group sits at (50, 52) rotated
    /// −45°; the lead capsule spans x −46…−2 at y −18…−4, the trail x 2…46 at y 4…18,
    /// both 44 × 14 with a 7 radius. Gap along the bar 4, perpendicular offset 22.
    public func path(in rect: CGRect) -> Path {
        let box = CGRect(x: part == .lead ? -46 : 2, y: part == .lead ? -18 : 4, width: 44, height: 14)
        var path = Path(roundedRect: box, cornerRadius: 7, style: .continuous)
        path = path.applying(CGAffineTransform(rotationAngle: -.pi / 4))
        path = path.applying(CGAffineTransform(translationX: 50, y: 52))
        // Fit the canonical box into `rect`, aspect-preserving and centred. The mark's
        // own centre sits 2 units below the box centre: that is the optical shift.
        let unit = min(rect.width, rect.height) / 100
        return path.applying(CGAffineTransform(translationX: rect.midX - 50 * unit, y: rect.midY - 50 * unit)
            .scaledBy(x: unit, y: unit))
    }
}

/// The complete mark. `scale` shrinks the mark inside its frame the way the app
/// icon does (the rotated mark fills 90.5 % of the box at scale 1).
public struct RelayMark: View {
    private let lead: Color
    private let trail: Color
    private let scale: CGFloat

    /// Default colours: the lead capsule takes the surface's contrast colour, the
    /// trail capsule is always Ember.
    public init(lead: Color = RelayColor.textPrimary, trail: Color = RelayColor.ember, scale: CGFloat = 1) {
        self.lead = lead
        self.trail = trail
        self.scale = scale
    }

    /// One-colour form, for tinted contexts and watermarks.
    public init(mono color: Color, scale: CGFloat = 1) {
        self.init(lead: color, trail: color, scale: scale)
    }

    public var body: some View {
        ZStack {
            RelayMarkShape(.lead).fill(lead)
            RelayMarkShape(.trail).fill(trail)
        }
        .scaleEffect(scale)
        .accessibilityHidden(true)
    }
}

/// The Baton reduced to one capsule: Relay's bullet and section marker
public struct RelayDash: View {
    private let color: Color
    private let height: CGFloat

    public init(_ color: Color = RelayColor.ember, height: CGFloat = 4) {
        self.color = color
        self.height = height
    }

    public var body: some View {
        Capsule(style: .continuous)
            .fill(color)
            .frame(width: height * 44 / 14, height: height)
            .accessibilityHidden(true)
    }
}

/// Relay's section marker: a dash, the title, and an optional trailing action.
/// The dash carries the section's meaning — Ember for a Relay concept, the system
/// hue for a system — which is how the System Spectrum reaches every screen.
public struct SectionHeader<Trailing: View>: View {
    private let title: String
    private let accent: Color
    private let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicType
    #if os(tvOS)
    private let dashHeight: CGFloat = 9
    #else
    @ScaledMetric(relativeTo: .title2) private var dashHeight: CGFloat = 5
    #endif

    public init(_ title: String, accent: Color = RelayColor.ember, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.accent = accent
        self.trailing = trailing()
    }

    public var body: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                    heading
                    trailing
                }
            } else {
                HStack(alignment: .center, spacing: RelaySpacing.s) {
                    heading
                    Spacer(minLength: RelaySpacing.xs)
                    trailing.fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var heading: some View {
        HStack(spacing: RelaySpacing.s) {
            RelayDash(accent, height: dashHeight)
            Text(title)
                .font(.relayShelfTitle)
                .foregroundStyle(RelayColor.textPrimary)
                .lineLimit(dynamicType.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

public extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, accent: Color = RelayColor.ember) {
        self.init(title, accent: accent, trailing: { EmptyView() })
    }
}

/// Relay's lockup: the mark and the name, the way the website's header carries
/// of each platform — the iPhone navigation bar, the iPad and Mac sidebar, the
/// Apple TV tab sidebar, the onboarding welcome — so the brand is the identity of
/// the application, not another section of it. Nothing else in the app sets the
/// word "Relay" beside the mark; Settings prints the version under its own copy.
public struct RelayLockup: View {
    /// Where the lockup sits decides its size and weight, not the caller.
    public enum Placement: Sendable {
        /// A navigation bar item (iPhone). Mark 22 pt, `.headline`.
        case bar
        /// The top of a sidebar (iPad, Mac). Mark 28 pt, `.title2` bold.
        case sidebar
        /// Apple TV's tab sidebar header. Mark 56 pt, `.title` bold.
        case television
        /// The onboarding welcome. Mark 72 pt, `.largeTitle` bold.
        case hero
    }

    private let placement: Placement
    private let mono: Color?
    @ScaledMetric(relativeTo: .headline) private var barMarkSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var sidebarMarkSize: CGFloat = 28
    @ScaledMetric(relativeTo: .largeTitle) private var heroMarkSize: CGFloat = 72

    public init(_ placement: Placement = .bar, mono: Color? = nil) {
        self.placement = placement
        self.mono = mono
    }

    private var markSize: CGFloat {
        #if os(tvOS)
        let hero: CGFloat = 104
        #else
        let hero = heroMarkSize
        #endif
        switch placement {
        case .bar: return barMarkSize
        case .sidebar: return sidebarMarkSize
        case .television: return 56
        case .hero: return hero
        }
    }

    private var font: Font {
        switch placement {
        case .bar: return .headline.weight(.semibold)
        case .sidebar: return .relayShelfTitle
        case .television: return .relayDetailTitle
        case .hero: return .relayScreenTitle
        }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: placement == .bar ? RelaySpacing.xs : RelaySpacing.s) {
            Group {
                if let mono { RelayMark(mono: mono) } else { RelayMark() }
            }
            .frame(width: markSize, height: markSize)
            Text(verbatim: "Relay")
                .font(font)
                .tracking(placement == .bar ? -0.2 : -0.5)
                .foregroundStyle(mono ?? RelayColor.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Relay"))
        .accessibilityAddTraits(.isHeader)
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Cards.swift
//  RelayDesignSystem — §8.1 GameCard, §8.2 ContinueCard, §8.3 Shelf, §8.4 SystemTile.
//
//  Cards are single accessibility elements with composed labels. Platform
//  differences (hover, tvOS focus) live here, not at the call site.

import SwiftUI
import RelayDomain

// MARK: - GameCard

public struct GameCardModel: Identifiable, Sendable {
    public enum Badge: Sendable, Equatable { case new, inCloud, downloading(Double) }

    public let id: GameID
    public let title: String
    public let system: SystemID
    public let systemName: String
    public let hue: SystemHue
    /// Optional meta line ("2 h ago"); the system name is always shown.
    public let meta: String?
    public let badge: Badge?
    public let artwork: ArtworkModel

    /// `artworkRevision` identifies the artwork bytes: a card already on screen
    /// reloads its image only when it changes (a cover arriving or replaced).
    public init(id: GameID, title: String, system: SystemID, systemName: String, hue: SystemHue, meta: String? = nil,
                badge: Badge? = nil, artworkLoader: ArtworkLoader? = nil, artworkRevision: String? = nil) {
        self.id = id
        self.title = title
        self.system = system
        self.systemName = systemName
        self.hue = hue
        self.meta = meta
        self.badge = badge
        self.artwork = ArtworkModel(title: title, systemName: systemName, system: system, hue: hue,
                                    loader: artworkLoader, revision: artworkRevision)
    }
}

/// One game in a shelf or grid. `artworkHeight` fixes the shelf height; grids
/// pass nil and get a 3:4 tile.
public struct GameCard: View {
    private let model: GameCardModel
    private let artworkHeight: CGFloat?
    /// `nil` means the card is not a button: it is the label of something else
    /// (a `NavigationLink`) that owns the gesture. A card used that way must stay
    /// hit-testable, so it must not wrap its content in a Button of its own.
    private let action: (() -> Void)?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType

    public init(_ model: GameCardModel, artworkHeight: CGFloat? = nil, action: @escaping () -> Void) {
        self.model = model
        self.artworkHeight = artworkHeight
        self.action = action
    }

    /// Non-interactive form, for use as the label of a `NavigationLink`.
    public init(label model: GameCardModel, artworkHeight: CGFloat? = nil) {
        self.model = model
        self.artworkHeight = artworkHeight
        self.action = nil
    }

    public var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(CardButtonStyle())
                .relayScrollToKeyboardFocus()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: artworkCaptionSpacing) {
            artworkArea
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.relayCardTitle)
                    .foregroundStyle(RelayColor.textPrimary)
                    .lineLimit(dynamicType.isAccessibilitySize ? 3 : 2, reservesSpace: true)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                VStack(alignment: .leading, spacing: RelaySpacing.xxs) {
                    HStack(alignment: .center, spacing: RelaySpacing.xs) {
                        RelayDash(model.hue.accent, height: 3)
                        if dynamicType.isAccessibilitySize {
                            Text(model.systemName)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                Text(model.systemName).fixedSize(horizontal: true, vertical: false)
                                Text(model.system.abbreviation).lineLimit(1)
                            }
                        }
                    }
                    if let meta = model.meta { Text(meta) }
                }
                .font(.relayMeta)
                .foregroundStyle(RelayColor.textSecondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A horizontal shelf proposes an unbounded width. Constrain the entire
        // card, including its caption, to the artwork instead of letting a long
        // filename determine the width of the shelf item.
        .frame(width: artworkHeight.map { $0 * 3 / 4 }, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .help(model.title)
        #endif
    }

    private var artworkCaptionSpacing: CGFloat {
        #if os(tvOS)
        // Leave room for the native artwork lift without covering the title.
        RelaySpacing.xxl
        #else
        RelaySpacing.xs
        #endif
    }

    private var artworkArea: some View {
        ArtworkView(model.artwork, cornerRadius: RelayRadius.card, showsTitleWhenEmpty: false)
            .frame(width: artworkHeight.map { $0 * 3 / 4 }, height: artworkHeight)
            .aspectRatio(artworkHeight == nil ? 3 / 4 : nil, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                switch model.badge {
                case .new?: NewBadge().padding(RelaySpacing.xs)
                case .inCloud?: CloudBadge(progress: nil).padding(RelaySpacing.xs)
                case .downloading(let p)?: CloudBadge(progress: p).padding(RelaySpacing.xs)
                case nil: EmptyView()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: RelayRadius.card, style: .continuous)
                .strokeBorder(hovering ? RelayColor.separatorStrong : RelayColor.separator))
            #if os(tvOS)
            .hoverEffect(.highlight)
            #elseif os(iOS) || os(macOS)
            .onHover { hovering = $0 }
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .animation(reduceMotion ? nil : .relayMicro, value: hovering)
            #endif
    }

    private var accessibilityLabel: Text {
        var parts = [model.title, model.systemName]
        if let meta = model.meta { parts.append(meta) }
        switch model.badge {
        case .new?: parts.append(String(localized: "New", bundle: .module))
        case .inCloud?: parts.append(String(localized: "Available to download", bundle: .module))
        case .downloading(let p)?: parts.append(String(localized: "Downloading · \(Int(p * 100)) %", bundle: .module))
        case nil: break
        }
        return Text(parts.joined(separator: ", "))
    }
}

/// "In iCloud" badge (Layer 0, CONTINUITY_UX §5): the only sync glyph on grid cards;
/// shows an Ember progress ring while downloading. Never colour-only: glyph + ring.
public struct CloudBadge: View {
    private let progress: Double?
    public init(progress: Double?) { self.progress = progress }
    public var body: some View {
        ZStack {
            if let progress {
                Circle().stroke(RelayColor.separatorStrong, lineWidth: 2)
                Circle().trim(from: 0, to: max(0.02, progress)).stroke(RelayColor.ember, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                RelaySymbol.download.image.font(.system(size: 10, weight: .semibold)).foregroundStyle(RelayColor.textPrimary)
            } else {
                RelaySymbol.inCloud.image.font(.system(size: 11, weight: .semibold)).foregroundStyle(RelayColor.textPrimary)
            }
        }
        .frame(width: 24, height: 24)
        .background(RelayColor.surfaceElevated, in: Circle())
        .overlay(Circle().strokeBorder(RelayColor.separator))
        .accessibilityHidden(true)
    }
}

/// "NEW" badge (§8.1): caption semibold on surface, never Ember.
public struct NewBadge: View {
    public init() {}
    public var body: some View {
        Text("NEW", bundle: .module)
            .font(.relayBadge)
            .foregroundStyle(RelayColor.textPrimary)
            .padding(.horizontal, RelaySpacing.xs)
            .padding(.vertical, RelaySpacing.xxs)
            .background(RelayColor.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(RelayColor.separator))
    }
}

/// Cards use the native artwork focus effect on Apple TV and a small press
/// response on touch and pointer platforms.
#if os(tvOS)
public struct CardButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.borderless)
            .buttonBorderShape(.roundedRectangle(radius: RelayRadius.card))
    }
}

public extension PrimitiveButtonStyle where Self == CardButtonStyle {
    static var relayCard: CardButtonStyle { CardButtonStyle() }
}
#else
public struct CardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .relayMicro, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == CardButtonStyle {
    static var relayCard: CardButtonStyle { CardButtonStyle() }
}
#endif

// MARK: - ContinueCard

public struct ContinueCardModel: Identifiable, Sendable {
    /// What the Ember capsule offers (CONTINUITY_UX §4, §6).
    public enum Capsule: Sendable, Equatable {
        case `continue`
        /// "Download & Continue" (wide) / "Download" (compact) — content in iCloud.
        case download
        /// "Review" — two versions.
        case review
        /// "How to Add" — content on another device only.
        case howToAdd
        /// Ember progress ring while downloading.
        case downloading(Double)
    }

    public let id: GameID
    public let title: String
    /// "Played on this iPhone · 2 h ago" — composed by the caller (localised).
    public let statusLine: String
    public let hue: SystemHue
    public let system: SystemID
    public let systemName: String
    /// True when this progress reached the device from another one and the player
    /// has not seen it yet: the card plays the arrival once (CONTINUITY_UX §6).
    public let arrived: Bool
    public let screenshotLoader: ArtworkLoader?
    public let artworkLoader: ArtworkLoader?
    /// Changes when the selected screenshot or fallback artwork is replaced.
    public let artworkRevision: String?
    public let capsule: Capsule
    /// Device glyph shown in the status line when the last session came from another device.
    public let deviceSymbol: RelaySymbol?

    public init(id: GameID, title: String, statusLine: String, hue: SystemHue, system: SystemID, systemName: String,
                screenshotLoader: ArtworkLoader?, artworkLoader: ArtworkLoader?, capsule: Capsule = .continue,
                deviceSymbol: RelaySymbol? = nil, arrived: Bool = false, artworkRevision: String? = nil) {
        self.id = id
        self.title = title
        self.statusLine = statusLine
        self.hue = hue
        self.system = system
        self.systemName = systemName
        self.arrived = arrived
        self.screenshotLoader = screenshotLoader
        self.artworkLoader = artworkLoader
        self.artworkRevision = artworkRevision
        self.capsule = capsule
        self.deviceSymbol = deviceSymbol
    }
}

/// The hero of Home, and the component the whole product is about.
///
/// Composition (BRAND_INTEGRATION_AUDIT, "Continue"): the player's own last frame,
/// framed on Ink inside a warm mat, with the system's spine and chip on it; the
/// title and where it was last played set *below* the picture, not scrimmed over
/// it; and one Ember capsule. It is deliberately not a GameCard variant — nothing
/// else in Relay is shaped like this, which is what makes a screenshot of Home
/// recognisable with the name removed.
public struct ContinueCard: View {
    private let model: ContinueCardModel
    private let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .title3) private var minimumCaptionWidth: CGFloat = 160

    public init(_ model: ContinueCardModel, action: @escaping () -> Void) {
        self.model = model
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: RelaySpacing.s) {
                frame
                caption
            }
            .padding(RelaySpacing.s)
            .background(RelayColor.surface, in: RoundedRectangle(cornerRadius: RelayRadius.xxl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RelayRadius.xxl, style: .continuous)
                .strokeBorder(hovering ? model.hue.accent.opacity(0.5) : RelayColor.separator))
            .shadow(color: RelayColor.scrim.opacity(hovering ? 0.22 : 0.12), radius: hovering ? 18 : 10, y: hovering ? 8 : 4)
            .contentShape(RoundedRectangle(cornerRadius: RelayRadius.xxl, style: .continuous))
        }
        .buttonStyle(CardButtonStyle())
        .relayScrollToKeyboardFocus()
        #if os(iOS) || os(macOS)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .relayStandard, value: hovering)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(format: String(localized: "game.accessibility.summary", bundle: .module),
                                       model.title, model.systemName, model.statusLine)))
        .accessibilityHint(Text(capsuleTitle))
        .accessibilityAddTraits(.isButton)
        #if os(macOS)
        .help(model.title)
        #endif
    }

    /// The last frame, framed. Contain-fit on Ink so a 3:2 handheld picture is never
    /// cropped and never stretched; the spine and the chip say which system it is.
    private var frame: some View {
        ZStack(alignment: .topLeading) {
            RelayColor.ink
            ArtworkView(ArtworkModel(title: model.title, systemName: model.systemName, system: model.system, hue: model.hue,
                                     loader: model.screenshotLoader ?? model.artworkLoader, revision: model.artworkRevision),
                        fit: model.screenshotLoader != nil ? .contain : .cover,
                        cornerRadius: 0, showsTitleWhenEmpty: false)
            Rectangle().fill(model.hue.accent).frame(width: 3)
            SystemChip(model.system.abbreviation, hue: model.hue, compact: true)
                .padding(RelaySpacing.xs)
                .padding(.leading, RelaySpacing.xxs)
        }
        .aspectRatio(frameAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous).strokeBorder(RelayColor.separator))
        .relayArrival(model.arrived, reduceMotion: reduceMotion)
        #if os(tvOS)
        // Keep native focus on the artwork while the screenshot loads, rather
        // than letting borderless discover a changing first image in the label.
        .hoverEffect(.highlight)
        #endif
    }

    /// A television is wider than it is tall and so is the room it sits in: the TV
    /// card is 16:9 so the hero fits above the fold from the sofa.
    private var frameAspect: CGFloat {
        #if os(tvOS)
        return 16 / 9
        #else
        return 16 / 10
        #endif
    }

    private var caption: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                stackedCaption
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: RelaySpacing.s) {
                        captionText.frame(minWidth: minimumCaptionWidth)
                        Spacer(minLength: RelaySpacing.xs)
                        continueCapsule.fixedSize(horizontal: true, vertical: false)
                    }
                    stackedCaption
                }
            }
        }
        .padding(.horizontal, RelaySpacing.xxs)
        .padding(.bottom, RelaySpacing.xxs)
    }

    private var stackedCaption: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            captionText
            continueCapsule
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var captionText: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xxs) {
            Text(model.title)
                .font(.relaySubheader)
                .foregroundStyle(RelayColor.textPrimary)
                .lineLimit(dynamicType.isAccessibilitySize ? 3 : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            HStack(alignment: .firstTextBaseline, spacing: RelaySpacing.xxs + 2) {
                if let symbol = model.deviceSymbol {
                    symbol.image.font(.relayStatus).foregroundStyle(RelayColor.textSecondary).accessibilityHidden(true)
                }
                Text(model.statusLine)
                    .font(.relayStatus)
                    .foregroundStyle(RelayColor.textSecondary)
                    .lineLimit(dynamicType.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capsuleTitle: String {
        switch model.capsule {
        case .continue: return String(localized: "Continue", bundle: .module)
        case .download: return String(localized: "Download & Continue", bundle: .module)
        case .review: return String(localized: "Review", bundle: .module)
        case .howToAdd: return String(localized: "How to Add", bundle: .module)
        case .downloading(let p): return String(localized: "Downloading · \(Int(p * 100)) %", bundle: .module)
        }
    }

    @ViewBuilder
    private var continueCapsule: some View {
        switch model.capsule {
        case .downloading(let progress):
            ZStack {
                Circle().stroke(RelayColor.separatorStrong, lineWidth: 3)
                Circle().trim(from: 0, to: max(0.02, progress)).stroke(RelayColor.ember, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: EmberButtonStyle.height - 8, height: EmberButtonStyle.height - 8)
            .accessibilityHidden(true)
        default:
            Label { Text(capsuleLabel) } icon: { capsuleSymbol.image }
                .relayActionLabel(for: dynamicType)
                .font(.relayCardTitle)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .foregroundStyle(RelayColor.textOnEmber)
                .padding(.horizontal, RelaySpacing.m)
                .padding(.vertical, RelaySpacing.xs)
                .frame(minHeight: EmberButtonStyle.height - 6)
                .background {
                    TextActionBackground(fill: RelayColor.ember, accessibilitySize: dynamicType.isAccessibilitySize)
                }
                .accessibilityHidden(true)
        }
    }

    /// Compact widths (iPhone, tvOS cards) shorten "Download & Continue" to "Download" (CONTINUITY_UX §4).
    private var capsuleLabel: String {
        switch model.capsule {
        case .continue, .downloading: return String(localized: "Continue", bundle: .module)
        case .download:
            #if os(macOS)
            return String(localized: "Download & Continue", bundle: .module)
            #else
            return String(localized: "Download", bundle: .module)
            #endif
        case .review: return String(localized: "Review", bundle: .module)
        case .howToAdd: return String(localized: "How to Add", bundle: .module)
        }
    }

    private var capsuleSymbol: RelaySymbol {
        switch model.capsule {
        case .continue, .downloading: return .play
        case .download: return .inCloud
        case .review: return .conflict
        case .howToAdd: return .importFiles
        }
    }
}

// MARK: - Shelf

/// Horizontal shelf with a header (§8.3). Empty shelves must not be rendered by the caller.
/// The header is a `SectionHeader`, so every shelf on every platform is introduced by
/// the Relay dash in the colour of what the shelf is about.
public struct Shelf<Content: View, Destination: Hashable>: View {
    private let title: String
    private let accent: Color
    private let seeAll: Destination?
    private let content: Content
    private let layout = RelaySpacing.layout

    public init(_ title: String, accent: Color = RelayColor.ember, seeAll: Destination?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.seeAll = seeAll
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            SectionHeader(title, accent: accent) {
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        Text("See All", bundle: .module)
                            .font(.relayMeta)
                            .foregroundStyle(RelayColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .relayScrollToKeyboardFocus()
                }
            }
            .padding(.horizontal, layout.screenMargin)
            #if os(tvOS)
            .focusSection()
            #endif
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: layout.cardGap) { content }
                    .padding(.horizontal, layout.screenMargin)
            }
            .relayKeyboardScrollContainer()
            #if os(tvOS)
            .scrollClipDisabled()
            // The full row guides Down from a trailing header action to even
            // a single card at the leading edge of the shelf.
            .focusSection()
            #endif
        }
    }
}

public extension Shelf where Destination == Never {
    init(_ title: String, accent: Color = RelayColor.ember, @ViewBuilder content: () -> Content) {
        self.init(title, accent: accent, seeAll: nil, content: content)
    }
}

// MARK: - SystemTile

public struct SystemTileModel: Identifiable, Sendable {
    public let id: SystemID
    public let name: String
    public let gameCount: Int
    public let hue: SystemHue
    /// Up to three most recent games for the artwork fan.
    public let recentArtwork: [ArtworkModel]

    public init(id: SystemID, name: String, gameCount: Int, hue: SystemHue, recentArtwork: [ArtworkModel]) {
        self.id = id
        self.name = name
        self.gameCount = gameCount
        self.hue = hue
        self.recentArtwork = Array(recentArtwork.prefix(3))
    }
}

/// A system in the Systems shelf or grid (§8.4): 2-pt spine, name, count, three-artwork fan.
public struct SystemTile: View {
    private let model: SystemTileModel
    /// `nil` when the tile is a `NavigationLink`'s label rather than a button of
    /// its own (see `GameCard`): the link owns the gesture and the tile must
    /// remain hit-testable.
    private let action: (() -> Void)?
    @State private var hovering = false
    @Environment(\.dynamicTypeSize) private var dynamicType

    public init(_ model: SystemTileModel, action: @escaping () -> Void) {
        self.model = model
        self.action = action
    }

    /// Non-interactive form, for use as the label of a `NavigationLink`.
    public init(label model: SystemTileModel) {
        self.model = model
        self.action = nil
    }

    public var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(CardButtonStyle())
                .relayScrollToKeyboardFocus()
                #if os(iOS) || os(macOS)
                .onHover { hovering = $0 }
                #endif
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(model.name), \(model.gameCount) games", bundle: .module))
                .accessibilityAddTraits(.isButton)
        } else {
            content
                #if os(iOS) || os(macOS)
                .onHover { hovering = $0 }
                #endif
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(model.name), \(model.gameCount) games", bundle: .module))
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
                Rectangle().fill(model.hue.accent).frame(width: 2)
                ViewThatFits(in: .horizontal) {
                    if !dynamicType.isAccessibilitySize {
                        HStack(spacing: RelaySpacing.s) {
                            // Only keep decorative artwork when the full name fits.
                            // A fixed-width fan must never compress the name.
                            identity.fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: RelaySpacing.xs)
                            fan
                        }
                    }
                    identity.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(RelaySpacing.s)
            }
            .frame(maxWidth: .infinity, minHeight: tileHeight, alignment: .leading)
            .background(RelayColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous)
                .strokeBorder(hovering ? RelayColor.separatorStrong : RelayColor.separator))
        .contentShape(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xxs) {
            Text(model.name)
                .font(.relayCardTitle)
                .foregroundStyle(RelayColor.textPrimary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Text("\(model.gameCount) games", bundle: .module)
                .font(.relayMeta)
                .foregroundStyle(model.hue.accent)
        }
    }

    /// The three most recent games, stacked like cards in a hand.
    ///
    /// Every game in a system tile shares that system's hue, so the fan cannot rely
    /// on the artwork differing: three identical tints overlapped by a hairline read
    /// as one shape with a seam. Separation therefore comes from the composition —
    /// each card is cut out of the one behind it by a ring of the tile's own surface,
    /// the cards behind sit lower and dimmer, and the most recent game is in front.
    private var fan: some View {
        let cards = Array(model.recentArtwork.prefix(3).enumerated())
        return ZStack(alignment: .bottomTrailing) {
            // Painted back to front so the newest game ends up on top.
            ForEach(cards.reversed(), id: \.offset) { index, art in
                let depth = CGFloat(index)
                ArtworkView(art, cornerRadius: RelayRadius.s, showsTitleWhenEmpty: false)
                    .frame(width: fanWidth, height: fanWidth * 4 / 3)
                    .overlay(RoundedRectangle(cornerRadius: RelayRadius.s, style: .continuous)
                        .strokeBorder(RelayColor.separator))
                    // The cut-out: the tile's surface printed just outside the card,
                    // so a card behind always ends where the card in front begins.
                    .background {
                        RoundedRectangle(cornerRadius: RelayRadius.s + 2, style: .continuous)
                            .fill(RelayColor.surface)
                            .padding(-2.5)
                    }
                    .scaleEffect(1 - depth * 0.07, anchor: .bottom)
                    .opacity(Double(1 - depth * 0.22))
                    .offset(x: -depth * fanWidth * 0.36)
            }
        }
        .frame(width: fanWidth * (1 + CGFloat(max(cards.count - 1, 0)) * 0.36), alignment: .bottomTrailing)
    }

    private var tileHeight: CGFloat {
        #if os(tvOS)
        return 180
        #else
        return 96
        #endif
    }

    private var fanWidth: CGFloat {
        #if os(tvOS)
        return 84
        #else
        return 44
        #endif
    }
}

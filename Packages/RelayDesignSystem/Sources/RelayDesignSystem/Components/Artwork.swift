// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Artwork.swift
//  RelayDesignSystem — artwork treatment (§4.7) and placeholder art.

import SwiftUI
import CoreGraphics
import RelayDomain

/// Asynchronous image provider handed to components; returns a downsampled image
/// whose longest side is at most `maxPixelSize`, or nil when none exists.
public typealias ArtworkLoader = @Sendable (_ maxPixelSize: Int) async -> CGImage?

/// A game's artwork as the design system sees it: either loadable or absent.
public struct ArtworkModel: Sendable {
    public let title: String
    public let systemName: String
    /// Drives the placeholder's short name. Absent only for artwork that has no
    /// system of its own (a save-state thumbnail, a comparison pane).
    public let system: SystemID?
    public let hue: SystemHue
    public let loader: ArtworkLoader?
    /// Stable identity of the authoritative image bytes, including replacements
    /// at the same location. A changed loader closure alone is not an identity.
    public let revision: String?

    public init(title: String, systemName: String, system: SystemID? = nil, hue: SystemHue,
                loader: ArtworkLoader? = nil, revision: String? = nil) {
        self.title = title
        self.systemName = systemName
        self.system = system
        self.hue = hue
        self.loader = loader
        self.revision = revision
    }
}

/// Renders artwork contain-fit on the system tint, or the placeholder (§4.7)
/// when there is none. Never jumps: the frame is owned by the caller.
public struct ArtworkView: View {
    public enum Fit { case contain, cover }

    private let model: ArtworkModel
    private let fit: Fit
    private let cornerRadius: CGFloat
    private let showsTitleWhenEmpty: Bool
    @State private var image: CGImage?
    @State private var loaded = false

    private struct LoadRequest: Equatable {
        let revision: String?
        let maxPixelSize: Int
    }

    public init(_ model: ArtworkModel, fit: Fit = .contain, cornerRadius: CGFloat, showsTitleWhenEmpty: Bool = true) {
        self.model = model
        self.fit = fit
        self.cornerRadius = cornerRadius
        self.showsTitleWhenEmpty = showsTitleWhenEmpty
    }

    public var body: some View {
        GeometryReader { proxy in
            let request = LoadRequest(revision: model.revision,
                                      maxPixelSize: Int(max(proxy.size.width, proxy.size.height) * scale))
            ZStack {
                model.hue.tint
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: fit == .contain ? .fit : .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .transition(.opacity)
                } else if loaded || model.loader == nil {
                    PlaceholderArt(model: model, showsTitle: showsTitleWhenEmpty, size: proxy.size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: request) {
                await load(maxPixelSize: request.maxPixelSize)
            }
        }
        .accessibilityHidden(true)
    }

    private var scale: CGFloat {
        #if os(macOS)
        return 2
        #else
        return 3
        #endif
    }

    private func load(maxPixelSize: Int) async {
        guard maxPixelSize > 0 else { return }
        guard let loader = model.loader else {
            image = nil
            loaded = true
            return
        }
        let result = await loader(max(maxPixelSize, 64))
        // A previous revision may finish decoding after its replacement.
        guard !Task.isCancelled else { return }
        withAnimation(.relayStandard) { image = result }
        loaded = true
    }
}

/// The placeholder a game gets when it has no cover, and most libraries have
/// several. It is not a grey rectangle waiting for a real image: the system's hue,
/// its short name set large enough to read across a room, the Baton, and a spine
/// down the leading edge. A library with no artwork at all still looks composed,
/// and it is colour-coded by system while it does it.
public struct PlaceholderArt: View {
    let model: ArtworkModel
    let showsTitle: Bool
    let size: CGSize

    private var short: String { model.system?.abbreviation ?? "" }
    /// Below this the composition is mush, so the mark carries it alone.
    private var isTiny: Bool { min(size.width, size.height) < 64 }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            model.hue.tint
            if isTiny {
                RelayMark(mono: model.hue.ghost, scale: 0.52)
            } else {
                // The short name, set big: the placeholder's texture, different for
                // every system. Long names shrink to fit, so every name is read whole
                // ("SNES", never "SNE") and sits inside the same side margins.
                Text(short)
                    .font(.system(size: min(size.height * 0.34, size.width * 0.46), weight: .heavy))
                    .foregroundStyle(model.hue.watermark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.horizontal, size.width * 0.07)
                RelayMark(mono: model.hue.ghost, scale: 0.9)
                    .frame(width: size.width * 0.32, height: size.width * 0.32)
                    .padding(size.width * 0.05)
                if showsTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title)
                            .font(.relayCardTitle)
                            .foregroundStyle(RelayColor.textPrimary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(RelaySpacing.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            // The spine: the same 2-pt hue edge the system tiles and the sidebar use.
            Rectangle().fill(model.hue.accent).frame(width: 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}

/// Bottom scrim for text on artwork (§4.7): Ink 0% → 64% over the bottom 45%.
public struct ArtworkScrim: View {
    public init() {}
    public var body: some View {
        // The scrim is the one sanctioned gradient use (text legibility on imagery).
        LinearGradient(stops: [
            .init(color: RelayColor.scrim.opacity(0), location: 0),
            .init(color: RelayColor.scrim.opacity(0), location: 0.55),
            .init(color: RelayColor.scrim.opacity(0.64), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }
}

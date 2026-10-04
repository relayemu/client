// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Previews.swift — one preview per component, both colour schemes.

import SwiftUI
import RelayDomain

#if DEBUG
enum PreviewData {
    static let gba = SystemAccent.hue(for: .gameBoyAdvance)
    static func card(_ title: String, badge: GameCardModel.Badge? = nil) -> GameCardModel {
        GameCardModel(id: GameID(), title: title, system: .gameBoyAdvance, systemName: "Game Boy Advance", hue: gba, meta: "2 h ago", badge: badge)
    }
}

#Preview("GameCard") {
    HStack(spacing: RelaySpacing.s) {
        GameCard(PreviewData.card("A Long Homebrew Title That Wraps", badge: .new), artworkHeight: 150) {}
        GameCard(PreviewData.card("Short"), artworkHeight: 150) {}
    }
    .padding()
    .background(RelayColor.canvas)
}

#Preview("ContinueCard") {
    ContinueCard(ContinueCardModel(id: GameID(), title: "240p Test Suite", statusLine: "Played on this Mac · 2 h ago",
                                   hue: PreviewData.gba, system: .gameBoyAdvance, systemName: "Game Boy Advance", screenshotLoader: nil, artworkLoader: nil)) {}
        .frame(width: 342)
        .padding()
        .background(RelayColor.canvas)
}

#Preview("SystemTile + Empty + Problem") {
    VStack(spacing: RelaySpacing.m) {
        SystemTile(SystemTileModel(id: .gameBoyAdvance, name: "Game Boy Advance", gameCount: 14, hue: PreviewData.gba,
                                   recentArtwork: [PreviewData.card("A").artwork, PreviewData.card("B").artwork])) {}
            .frame(width: 220)
        ProblemCard(headline: "notes.txt isn't a supported format.", message: "Relay couldn't recognise this file.",
                    primary: (title: "Which formats work?", action: {}), dismiss: {})
        EmptyState(scene: .dropIn, title: "No games yet.", message: "Drop some in. Relay finds the covers and keeps your saves with you.",
                   primary: (title: "Import Files", action: {}), secondary: (title: "Which formats work?", action: {}))
    }
    .padding()
    .background(RelayColor.canvas)
}
#endif

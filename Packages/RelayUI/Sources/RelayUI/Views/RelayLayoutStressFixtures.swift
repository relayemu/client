// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import SwiftUI
import RelayDomain
import RelayDesignSystem

/// deliberately hostile, invented content. No ROM, account or library is used.
/// Diagnostic labels stay English; product labels use their normal catalogs.
public struct RelayLayoutStressFixtureView: View {
    @State private var selection = 2
    @State private var actionCount = 0
    private let hue = SystemAccent.hue(for: .gameBoyAdvance)

    public init() {}

    private static let titles = [
        "Orbit",
        "The Clockwork Orchard — A Journey Beyond the Last Lighthouse (Europe)",
        "Les Voyageurs de l’aube — L’énigme du phare oublié, édition complète (Europe) (En,Fr,De,Es,It,Nl,Ja) [Révision 12] [Homebrew 2026]",
        "Orbit_Chronicles_CompleteCollectorsEdition_Europe_EnFrDeEsItNlJa_Revision00000000000000000000000000000000000000000000000000000000000001",
    ]

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RelaySpacing.xl) {
                    Text(verbatim: "DEBUG · Invented layout fixtures · No account or game data")
                        .font(.relayStatus)
                        .foregroundStyle(RelayColor.textSecondary)
                        .accessibilityIdentifier("layout.fixture.marker")
                    Picker(selection: $selection) {
                        Text(verbatim: "Short").tag(0)
                        Text(verbatim: "60+").tag(1)
                        Text(verbatim: "120+").tag(2)
                        Text(verbatim: "Token").tag(3)
                    } label: { Text(verbatim: "Title length") }
                    .pickerStyle(.segmented)
                    .relayScrollToKeyboardFocus()
                    .accessibilityIdentifier("layout.fixture.title")

                    SectionHeader(L("Continue Playing"))
                    ContinueCard(ContinueCardModel(
                        id: GameID(), title: Self.titles[selection],
                        statusLine: Formatting.playedElsewhereStatus(deviceKind: .iPhone, at: Date().addingTimeInterval(-7_200)) + " · " + L("Not synced yet"),
                        hue: hue, system: .gameBoyAdvance, systemName: "Game Boy Advance",
                        screenshotLoader: nil, artworkLoader: nil, capsule: .download,
                        deviceSymbol: .deviceIPhone
                    )) { actionCount += 1 }
                    #if os(macOS)
                    .continueCardWidth(layout: RelaySpacing.layout, accessibilitySize: false)
                    #else
                    .frame(maxWidth: 800)
                    #endif
                    .accessibilityIdentifier("layout.fixture.continue")

                    SectionHeader(L("Recently Added"), accent: RelayColor.textTertiary)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: RelaySpacing.layout.cardGap) {
                            ForEach(Array(Self.titles.enumerated()), id: \.offset) { index, title in
                                GameCard(card(title), artworkHeight: RelaySpacing.layout.shelfArtworkHeight) {
                                    selection = index
                                    actionCount += 1
                                }
                                .accessibilityIdentifier("layout.fixture.card.\(index)")
                            }
                        }
                        .padding(.vertical, RelaySpacing.xs)
                    }
                    .relayKeyboardScrollContainer()
                    #if os(macOS)
                    // Match the narrow content beside the shipping Mac sidebar,
                    // so the fourth card genuinely begins outside this shelf.
                    .frame(maxWidth: 460, alignment: .leading)
                    #endif
                    .accessibilityIdentifier("layout.fixture.shelf")

                    SectionHeader(L("Files"), accent: RelayColor.textTertiary)
                    DetailRow(label: Self.titles[selection] + ".gba", value: "32 MB · iPhone")
                    AdaptiveActionRow {
                        Button { actionCount += 1 } label: {
                            Label { Text("Download & Play", bundle: .module) } icon: { RelaySymbol.play.image }
                        }
                        .buttonStyle(.ember)
                        .relayScrollToKeyboardFocus()
                        .accessibilityIdentifier("layout.fixture.primary")
                        Button { actionCount += 1 } label: { Text("Which formats work?", bundle: .module) }
                            .buttonStyle(.quiet)
                            .relayScrollToKeyboardFocus()
                            .accessibilityIdentifier("layout.fixture.secondary")
                    }
                    Text(verbatim: "Actions reached: \(actionCount)")
                        .font(.relayStatus)
                        .accessibilityIdentifier("layout.fixture.feedback")
                }
                .padding(RelaySpacing.layout.screenMargin)
                .frame(maxWidth: 960, alignment: .leading)
            }
            .relayKeyboardScrollContainer()
            .relayCanvas()
            .navigationTitle(Text(verbatim: "Layout fixtures"))
            .toolbar {
                ToolbarItem(placement: .principal) { RelayLockup(.bar) }
            }
        }
    }

    private func card(_ title: String) -> GameCardModel {
        GameCardModel(id: GameID(), title: title, system: .gameBoyAdvance,
                      systemName: "Game Boy Advance", hue: hue,
                      meta: "En, Fr, De, Es, It, Nl, Ja · Homebrew 2026")
    }
}
#endif

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SearchView.swift

import SwiftUI
import RelayDomain
import RelayLibrary
import RelayDesignSystem

public struct SearchView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @Environment(\.relayBrowsingState) private var browsingState
    @State private var localQuery = ""
    @State private var results: [Game] = []
    private let layout = RelaySpacing.layout

    public init() {}

    private var query: String { queryBinding.wrappedValue }

    private var queryBinding: Binding<String> {
        guard let browsingState else { return $localQuery }
        return Binding(get: { browsingState.wrappedValue.searchQuery }, set: { query in
            browsingState.wrappedValue.searchQuery = query
        })
    }

    private struct SearchRequest: Equatable {
        let query: String
        let gameCount: Int
    }

    public var body: some View {
        let request = SearchRequest(query: query, gameCount: model.games.count)
        ScrollView {
            VStack(alignment: .leading, spacing: layout.sectionGap) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    systemsChips
                } else if results.isEmpty && matchingSystems.isEmpty {
                    noResults
                } else {
                    if !results.isEmpty {
                        VStack(alignment: .leading, spacing: RelaySpacing.s) {
                            Text("Games", bundle: .module).font(.relayShelfTitle).foregroundStyle(RelayColor.textPrimary)
                            ForEach(results) { game in
                                NavigationLink(value: Route.game(game.id)) { SearchRow(game: game) }
                                    .buttonStyle(.relayCard)
                                    .relayScrollToKeyboardFocus()
                                    .gameContextMenu(game)
                            }
                        }
                        .padding(.horizontal, layout.screenMargin)
                    }
                    if !matchingSystems.isEmpty {
                        VStack(alignment: .leading, spacing: RelaySpacing.s) {
                            Text("Systems", bundle: .module).font(.relayShelfTitle).foregroundStyle(RelayColor.textPrimary)
                            ForEach(matchingSystems) { summary in
                                NavigationLink(value: Route.system(summary.id)) { SystemTileLabel(model.tileModel(for: summary)) }
                                    .buttonStyle(.relayCard)
                                    .relayScrollToKeyboardFocus()
                            }
                        }
                        .padding(.horizontal, layout.screenMargin)
                    }
                }
            }
            .padding(.vertical, layout.screenMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .relayKeyboardScrollContainer()
        .relayCanvas()
        .navigationTitle(Text("Search", bundle: .module))
        // A dedicated search page keeps its native field alongside its content.
        // Automatic placement can disappear inside an adaptive iOS tab bar.
        .searchable(text: queryBinding, placement: searchPlacement, prompt: Text("Search", bundle: .module))
        .task(id: request) {
            // A reconstructed shell must load the retained query immediately.
            // The view-owned task also cancels stale work when input changes.
            guard !request.query.trimmingCharacters(in: .whitespaces).isEmpty else {
                results = []
                return
            }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            let found = await model.search(request.query)
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }

    private var matchingSystems: [LibraryModel.SystemSummary] {
        let ids = Set(GameQueryProbe.matchingSystemIDs(query))
        return model.systems.filter { ids.contains($0.id) }
    }

    private var systemsChips: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            if !model.systems.isEmpty {
                Text("Systems", bundle: .module).font(.relayShelfTitle).foregroundStyle(RelayColor.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RelaySpacing.xs) {
                        ForEach(model.systems) { summary in
                            NavigationLink(value: Route.system(summary.id)) {
                                Text(summary.name)
                                    .font(.relayMeta)
                                    .foregroundStyle(RelayColor.textPrimary)
                                    .padding(.horizontal, RelaySpacing.m)
                                    .padding(.vertical, RelaySpacing.xs)
                                    .frame(minHeight: EmberButtonStyle.height)
                                    .background(RelayColor.surfaceElevated, in: Capsule())
                                    .overlay(Capsule().strokeBorder(RelayColor.separator))
                            }
                            .buttonStyle(.relayCard)
                            .relayScrollToKeyboardFocus()
                        }
                    }
                }
                .relayKeyboardScrollContainer()
            } else {
                Text("Search your games by title or system.", bundle: .module)
                    .font(.relayBody)
                    .foregroundStyle(RelayColor.textSecondary)
            }
        }
        .padding(.horizontal, layout.screenMargin)
    }

    private var noResults: some View {
        #if os(tvOS)
        EmptyState(scene: .emptyShelf, title: L("No results for “\(query)”"), message: L("Check the spelling, or add the game from another device."))
        #else
        EmptyState(scene: .emptyShelf, title: L("No results for “\(query)”"),
                   message: L("Check the spelling, or import the game if it isn't in your library yet."),
                   primary: (L("Import Files"), { actions.importFiles() }))
        #endif
    }
}

/// Search result row (72 pt on iPhone): artwork 56, title, system · last played.
struct SearchRow: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicType
    let game: Game

    var body: some View {
        let card = model.cardModel(for: game, meta: true)
        HStack(spacing: RelaySpacing.s) {
            ArtworkView(card.artwork, cornerRadius: RelayRadius.s, showsTitleWhenEmpty: false)
                .frame(width: 42, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.relayCardTitle).foregroundStyle(RelayColor.textPrimary)
                    .lineLimit(dynamicType.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.meta.map { "\(card.systemName) · \($0)" } ?? card.systemName)
                    .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                    .lineLimit(dynamicType.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 72)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        #if os(macOS)
        .help(game.title)
        #endif
    }
}

/// Re-uses the library's system-name matching rule for the Systems group.
enum GameQueryProbe {
    static func matchingSystemIDs(_ text: String) -> [SystemID] { GameQuery(text: text).matchingSystemIDs }
}

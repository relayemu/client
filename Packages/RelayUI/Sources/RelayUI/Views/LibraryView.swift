// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LibraryView.swift

import SwiftUI
import RelayDomain
import RelayDesignSystem

public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case title, recentlyPlayed, recentlyAdded
    public var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return L("Title")
        case .recentlyPlayed: return L("Recently Played")
        case .recentlyAdded: return L("Recently Added")
        }
    }
}

public struct LibraryView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @Environment(\.relayBrowsingState) private var browsingState
    @State private var localState: RelayLibraryViewState
    private let initialFilter: LibraryFilter
    private let layout = RelaySpacing.layout

    typealias Segment = RelayLibraryViewState.Segment

    public init(initialFilter: LibraryFilter = .all) {
        self.initialFilter = initialFilter
        _localState = State(initialValue: RelayLibraryViewState(initialFilter: initialFilter))
    }

    private var stateBinding: Binding<RelayLibraryViewState> {
        guard let browsingState else { return $localState }
        return Binding(get: { browsingState.wrappedValue.libraryState(for: initialFilter) }, set: { state in
            var browsing = browsingState.wrappedValue
            browsing.setLibraryState(state, for: initialFilter)
            browsingState.wrappedValue = browsing
        })
    }

    private var segment: Segment { stateBinding.wrappedValue.segment }
    private var sort: LibrarySort { stateBinding.wrappedValue.sort }
    private var systemFilter: SystemID? { stateBinding.wrappedValue.systemFilter }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: layout.sectionGap) {
                ImportBanner()
                ProblemList()
                #if os(tvOS)
                HStack(alignment: .center, spacing: RelaySpacing.huge) {
                    segmentPicker
                    Spacer(minLength: 0)
                    ImportToolbarButton()
                }
                .padding(.horizontal, layout.screenMargin)
                #else
                segmentPicker
                #endif
                content
            }
            #if os(tvOS)
            .padding(.top, RelaySpacing.xl)
            .padding(.bottom, layout.screenMargin)
            #else
            .padding(.vertical, layout.screenMargin)
            #endif
        }
        .relayKeyboardScrollContainer()
        .relayCanvas()
        #if os(tvOS)
        // The selected tab identifies the library. A second native heading
        // stays over the grid when remote focus scrolls its content.
        .navigationTitle(Text(verbatim: ""))
        #else
        .navigationTitle(Text("Library", bundle: .module))
        #endif
        .toolbar {
            ToolbarItemGroup(placement: toolbarPlacement) {
                #if !os(tvOS)
                Menu {
                    Picker(selection: stateBinding.sort) {
                        ForEach(LibrarySort.allCases) { s in Text(s.label).tag(s) }
                    } label: { Text("Sort By", bundle: .module) }
                    Picker(selection: stateBinding.systemFilter) {
                        Text("All Systems", bundle: .module).tag(SystemID?.none)
                        ForEach(model.systems) { s in Text(s.name).tag(SystemID?.some(s.id)) }
                    } label: { Text("System", bundle: .module) }
                } label: {
                    Label { Text("Sort and Filter", bundle: .module) } icon: { RelaySymbol.sort.image }
                }
                #if !os(macOS)
                // The Mac shell already owns the window's import action.
                ImportToolbarButton()
                #endif
                #endif
            }
        }
    }

    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        return .primaryAction
        #else
        return .automatic
        #endif
    }

    private var segmentPicker: some View {
        Picker(selection: stateBinding.segment) {
            Text("All", bundle: .module).tag(Segment.all)
            Text("Systems", bundle: .module).tag(Segment.systems)
            Text("Favorites", bundle: .module).tag(Segment.favorites)
        } label: { Text("Library", bundle: .module) }
        .pickerStyle(.segmented)
        #if os(macOS)
        .labelsHidden()
        #endif
        .relayScrollToKeyboardFocus()
        #if os(tvOS)
        .frame(maxWidth: 900)
        #else
        .padding(.horizontal, layout.screenMargin)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .all:
            let games = sorted(model.games.filter { systemFilter == nil || $0.systemID == systemFilter })
            if games.isEmpty {
                EmptyState(scene: .dropIn, title: L("No games yet."), message: L("Drop some in. Relay finds the covers and keeps your saves with you."))
            } else {
                GameGrid(games: games, meta: sort == .recentlyPlayed)
            }
        case .systems:
            SystemsGrid()
        case .favorites:
            let favorites = model.favorites
            if favorites.isEmpty {
                EmptyState(scene: .emptyShelf, title: L("No favorites yet."), message: favoritesHint)
            } else {
                GameGrid(games: favorites, meta: false)
            }
        }
    }

    private var favoritesHint: String {
        #if os(tvOS)
        return L("Press and hold a game to add one.")
        #elseif os(macOS)
        return L("Right-click a game to add one.")
        #else
        return L("Touch and hold a game to add one.")
        #endif
    }

    private func sorted(_ games: [Game]) -> [Game] {
        switch sort {
        case .title: return games.sorted(by: LibraryModel.byTitle)
        case .recentlyAdded: return games.sorted { ($0.addedAt, $1.id.description) > ($1.addedAt, $0.id.description) }
        case .recentlyPlayed:
            return games.sorted {
                let a = model.history[$0.id]?.lastPlayedAt ?? .distantPast
                let b = model.history[$1.id]?.lastPlayedAt ?? .distantPast
                return a == b ? LibraryModel.byTitle($0, $1) : a > b
            }
        }
    }
}

/// Adaptive grid of 3:4 GameCards (§5.3 column counts; drops a column at accessibility sizes).
struct GameGrid: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let games: [Game]
    let meta: Bool
    private let layout = RelaySpacing.layout

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: layout.cardGap) {
            ForEach(games) { game in
                NavigationLink(value: Route.game(game.id)) {
                    GameCardLabel(model.cardModel(for: game, meta: meta))
                }
                .buttonStyle(.relayCard)
                .relayScrollToKeyboardFocus()
                .gameContextMenu(game)
            }
        }
        .padding(.horizontal, layout.screenMargin)
        .accessibilityLabel(Text("\(games.count) games", bundle: .module))
    }

    private var columns: [GridItem] {
        #if os(iOS)
        if typeSize.isAccessibilitySize {
            return [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: layout.cardGap, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: 100, maximum: 220), spacing: layout.cardGap, alignment: .top)]
        #elseif os(tvOS)
        return Array(repeating: GridItem(.flexible(), spacing: layout.cardGap, alignment: .top), count: 5)
        #else
        if typeSize.isAccessibilitySize {
            return [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: layout.cardGap, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: layout.cardGap, alignment: .top)]
        #endif
    }
}

struct SystemsGrid: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    private let layout = RelaySpacing.layout

    var body: some View {
        let systems = model.systems
        if systems.isEmpty {
            EmptyState(symbol: .systems, title: L("No games yet."), message: L("Systems appear here once you add games."))
        } else {
            LazyVGrid(columns: columns, spacing: layout.cardGap) {
                ForEach(systems) { summary in
                    NavigationLink(value: Route.system(summary.id)) { SystemTileLabel(model.tileModel(for: summary)) }
                        .buttonStyle(.relayCard)
                        .relayScrollToKeyboardFocus()
                        .accessibilityIdentifier("relay.library.system.\(summary.id.rawValue)")
                }
            }
            .padding(.horizontal, layout.screenMargin)
        }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        // Television text and the artwork fan need a full reading-width card.
        return [GridItem(.adaptive(minimum: 480), spacing: layout.cardGap, alignment: .top)]
        #else
        if typeSize.isAccessibilitySize {
            return [GridItem(.flexible(), alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: 280), spacing: layout.cardGap, alignment: .top)]
        #endif
    }
}

public struct SystemPageView: View {
    @Environment(LibraryModel.self) private var model
    let systemID: SystemID

    public init(systemID: SystemID) { self.systemID = systemID }

    public var body: some View {
        ScrollView {
            let games = model.games(in: systemID)
            if games.isEmpty {
                EmptyState(symbol: .systems, title: L("No games yet."), message: L("Games for this system appear here once you add them."))
            } else {
                GameGrid(games: games, meta: false)
                    .padding(.vertical, RelaySpacing.layout.screenMargin)
            }
        }
        .relayKeyboardScrollContainer()
        .relayCanvas()
        .navigationTitle(Formatting.systemName(systemID))
    }
}

/// The same Add games entry point on every platform.
struct ImportToolbarButton: View {
    @Environment(RelayActions.self) private var actions
    var body: some View {
        Menu {
            #if !os(tvOS)
            Button { actions.importFiles() } label: { Text("Import Files", bundle: .module) }
                .relayKeyboardShortcut("i", modifiers: .command)
            #endif
            Button { actions.fromComputer() } label: { Text("From a computer", bundle: .module) }
        } label: {
            Label { Text("Add games", bundle: .module) } icon: { RelaySymbol.importFiles.image }
        }
        .accessibilityLabel(Text("Add games", bundle: .module))
        .accessibilityIdentifier("relay.transfer.addGames")
    }
}

/// Game context menu (§8): Continue/Play, Favorite, Show in Finder (macOS), Delete.
struct GameContextMenu: ViewModifier {
    @Environment(LibraryModel.self) private var model
    let game: Game
    @State private var confirmDelete = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { Task { await model.play(game.id) } } label: {
                    Label { Text(model.history[game.id] == nil ? "Play" : "Continue", bundle: .module) } icon: { RelaySymbol.play.image }
                }
                Button { Task { await model.toggleFavorite(game.id) } } label: {
                    Label { Text(game.isFavorite ? "Unfavorite" : "Favorite", bundle: .module) } icon: {
                        (game.isFavorite ? RelaySymbol.favoriteFilled : RelaySymbol.favorite).image
                    }
                }
                #if os(macOS)
                Button { revealInFinder() } label: { Label { Text("Show in Finder", bundle: .module) } icon: { RelaySymbol.showInFinder.image } }
                #endif
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label { Text("Delete…", bundle: .module) } icon: { RelaySymbol.delete.image }
                }
            }
            .confirmationDialog(Text("Delete \(game.title)?", bundle: .module), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(role: .destructive) { Task { await model.delete(game.id) } } label: { Text("Delete", bundle: .module) }
                Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            } message: {
                Text("Removes the game and its progress from \(Formatting.thisDevice(model.deviceKind)).", bundle: .module)
            }
    }

    #if os(macOS)
    private func revealInFinder() {
        let url = model.environment.location.directory(forGame: game.id)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif
}

extension View {
    func gameContextMenu(_ game: Game) -> some View { modifier(GameContextMenu(game: game)) }
}

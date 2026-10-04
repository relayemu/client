// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import RelayDomain

/// iOS keeps its selection and paths above one native adaptive TabView. Library
/// areas and Settings remain routes in its persistent Home or Library stack;
/// resizing never needs to translate routes or replace the selected content.
struct RelayShellNavigationState {
    private(set) var selection: Destination = .home
    private var tabRoots: [Destination: Destination] = [:]
    private var paths: [Destination: [Route]] = [:]
    private var browsingStates: [Destination: RelayBrowsingState] = [:]

    var selectedTab: Destination { Self.tab(for: selection) }

    var detailPath: [Route] {
        get { paths[selection, default: []] }
        set { paths[selection] = newValue }
    }

    mutating func select(_ destination: Destination) {
        selection = destination
        tabRoots[Self.tab(for: destination)] = destination
    }

    mutating func selectTab(_ tab: Destination) {
        select(destination(for: tab))
    }

    func destination(for tab: Destination) -> Destination { tabRoots[tab] ?? tab }

    func browsingState(for destination: Destination) -> RelayBrowsingState {
        browsingStates[destination, default: RelayBrowsingState()]
    }

    mutating func setBrowsingState(_ state: RelayBrowsingState, for destination: Destination) {
        browsingStates[destination] = state
    }

    mutating func showHomeRoute(_ route: Route) {
        select(.home)
        detailPath = [route]
    }

    func tabPath(for tab: Destination) -> [Route] {
        let root = tabRoots[tab] ?? tab
        let prefix = Self.route(for: root).map { [$0] } ?? []
        return prefix + paths[root, default: []]
    }

    mutating func setTabPath(_ path: [Route], for tab: Destination) {
        let root = tabRoots[tab] ?? tab
        if let prefix = Self.route(for: root), path.first == prefix {
            paths[root] = Array(path.dropFirst())
        } else {
            // Back out of a sidebar-only area's synthetic root to the real tab.
            // A different tab's stack callback must not steal active selection.
            paths[root] = []
            tabRoots[tab] = tab
            paths[tab] = path
            if selectedTab == tab { selection = tab }
        }
    }

    private static func tab(for destination: Destination) -> Destination {
        switch destination {
        case .home, .settings: .home
        case .allGames, .favorites, .system: .allGames
        case .search: .search
        }
    }

    private static func route(for destination: Destination) -> Route? {
        switch destination {
        case .favorites: .library(.favorites)
        case .system(let id): .system(id)
        case .settings: .settings
        case .home, .allGames, .search: nil
        }
    }
}

/// Browsing choices belong to their shell area. Each library entry retains its
/// own initial filter, independently of tab/sidebar chrome and other tabs.
struct RelayBrowsingState: Equatable {
    var searchQuery = ""
    private var libraries: [LibraryFilter: RelayLibraryViewState] = [:]

    func libraryState(for filter: LibraryFilter) -> RelayLibraryViewState {
        libraries[filter, default: RelayLibraryViewState(initialFilter: filter)]
    }

    mutating func setLibraryState(_ state: RelayLibraryViewState, for filter: LibraryFilter) {
        libraries[filter] = state
    }
}

struct RelayLibraryViewState: Equatable {
    enum Segment: Hashable { case all, systems, favorites }

    var segment: Segment
    var sort: LibrarySort
    var systemFilter: SystemID?

    init(initialFilter: LibraryFilter) {
        switch initialFilter {
        case .all: segment = .all; sort = .title; systemFilter = nil
        case .favorites: segment = .favorites; sort = .title; systemFilter = nil
        case .system(let id): segment = .all; sort = .title; systemFilter = id
        case .recentlyPlayed: segment = .all; sort = .recentlyPlayed; systemFilter = nil
        case .recentlyAdded: segment = .all; sort = .recentlyAdded; systemFilter = nil
        }
    }
}

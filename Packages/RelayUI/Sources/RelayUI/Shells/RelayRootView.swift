// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RelayRootView.swift
//  RelayUI — chooses the platform shell (adaptive tabs/sidebar on iOS, split view
//  on Mac, top tabs on Apple TV), hosts the player over everything, and presents
//  the shared sheets (import picker, formats, settings, launch problems).

import SwiftUI
import UniformTypeIdentifiers
import RelayDomain
import RelayDesignSystem

public struct RelayRootView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openSettings) private var showSettings
    #endif
    #if os(iOS)
    @State private var navigation = RelayShellNavigationState()
    #endif

    public init() {}

    public var body: some View {
        @Bindable var actions = actions
        ZStack {
            // The shell stays mounted so navigation state survives a game, but while
            // the game is running it must be completely out of the way: invisible,
            // untouchable, and unable to take a key press. Transparency alone left
            // the library interactive underneath and let its keyboard shortcuts and
            // list focus eat input meant for the game.
            shell
                .opacity(model.isPlaying ? 0 : 1)
                .allowsHitTesting(!model.isPlaying)
                .disabled(model.isPlaying)
                .accessibilityHidden(model.isPlaying)
                // The player toggle animates its own transition below. The shell must
                // not join that transaction: a shelf that appears while the game runs
                // (Continue Playing on the first exit) was otherwise left mid-move on
                // Home, with the next heading drawn over the card (B2-IPH-003).
                .animation(nil, value: model.isPlaying)
            if model.isPlaying {
                PlayerView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(1)
            }
        }

        #if os(iOS)
        // One persistent iOS shell owns the same navigation stacks as its native
        // tabs adapt to a sidebar; local drafts and presentations keep their hosts.
        .onAppear { if let destination = actions.debugInitialDestination { navigation.select(destination) } }
        .onChange(of: actions.debugInitialDestination) { _, destination in
            if let destination { navigation.select(destination) }
        }
        .onChange(of: actions.debugInitialRoute) { _, route in
            if let route { navigation.showHomeRoute(route) }
        }
        #endif
        .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: model.isPlaying)
        .background(RelayColor.canvas)
        .task {
            if !model.isReady { await model.load() }
            // First run: only once the library is open, so a returning player with a
            // full library is never shown the tour by a slow disk.
            actions.presentOnboardingIfNeeded()
        }
        // The first-run experience covers the whole shell; it is not a sheet the
        // library peeks around. macOS presents it as a window sheet, which is the
        // Mac's own full cover.
        #if os(macOS)
        .sheet(isPresented: $actions.onboardingPresented, onDismiss: { actions.onboardingDidDismiss() }) {
            OnboardingView().environment(model).environment(actions)
        }
        #else
        .fullScreenCover(isPresented: $actions.onboardingPresented, onDismiss: { actions.onboardingDidDismiss() }) {
            OnboardingView().environment(model).environment(actions)
        }
        #endif
        // Relay is aggressive here, not on the launch path (owner policy, 2026-09-03).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.resumeCoverDownloads()
            Task {
                async let commerce: Void = model.environment.relayPro.refresh()
                Task { await model.environment.relayAccount?.refresh() }
                await model.sync.appDidBecomeActive()
                await model.refresh()
                _ = await commerce
            }
        }
        #if !os(tvOS)
        .fileImporter(isPresented: $actions.importPickerPresented, allowedContentTypes: [.data, .zip, .archive], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await importSecurityScoped(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await importSecurityScoped(urls) }
            return true
        }
        #endif
        .sheet(isPresented: $actions.formatsSheetPresented, onDismiss: { actions.presentationDidDismiss(.formats) }) { FormatsView() }
        #if os(tvOS)
        .fullScreenCover(isPresented: $actions.transferPresented, onDismiss: { actions.presentationDidDismiss(.transfer) }) {
            NavigationStack { RelayTransferView().environment(model).environment(actions) }
        }
        #else
        .sheet(isPresented: $actions.transferPresented, onDismiss: { actions.presentationDidDismiss(.transfer) }) {
            NavigationStack { RelayTransferView().environment(model).environment(actions) }
        }
        #endif
        .sheet(isPresented: $actions.diagnosticsPresented, onDismiss: { actions.presentationDidDismiss(.diagnostics) }) { NavigationStack { DiagnosticsView() } }
        #if os(tvOS)
        // tvOS sheets are narrow cards. The two real purchase choices and their
        // required renewal/Free disclosures become unreadable at that width.
        // A full-screen product surface preserves television typography and
        // gives the focus engine stable, visible controller targets.
        .fullScreenCover(isPresented: $actions.relayProPresented, onDismiss: { actions.presentationDidDismiss(.pro) }) {
            NavigationStack { RelayProView(feature: actions.relayProFeature, isPresentedModally: true).relayRoutes() }
        }
        #elseif os(iOS)
        .sheet(isPresented: $actions.relayProPresented, onDismiss: { actions.presentationDidDismiss(.pro) }) {
            NavigationStack { RelayProView(feature: actions.relayProFeature, isPresentedModally: true).relayRoutes() }
                .presentationDetents([.large])
                .presentationSizing(.page)
                // The sheet keeps Relay's ground for its whole presented area, so a
                // scroll view that still carries an earlier (keyboard-inset) size
                // cannot leave the page half warm and half system background
                // (B2-IPAD-001).
                .presentationBackground(RelayColor.canvas)
        }
        #else
        .sheet(isPresented: $actions.relayProPresented, onDismiss: { actions.presentationDidDismiss(.pro) }) {
            NavigationStack { RelayProView(feature: actions.relayProFeature, isPresentedModally: true, dismissPresentation: { actions.relayProPresented = false }).relayRoutes() }
        }
        #endif
        .sheet(item: compareBinding, onDismiss: { actions.presentationDidDismiss(.compare) }) { item in CompareView(gameID: item.id) }
        #if os(macOS)
        .onChange(of: actions.settingsPresented) { _, requested in
            guard requested else { return }
            actions.settingsPresented = false
            actions.presentationDidDismiss(.settings)
            showSettings()
        }
        #endif
        .overlay(alignment: .top) { SyncToast() }
        #if os(iOS)
        .sheet(isPresented: $actions.settingsPresented, onDismiss: { actions.settingsDidDismiss() }) { NavigationStack { SettingsView().relayRoutes() } }
        #endif
        // A single alert presenter owns both routes. Chained item alerts can
        // shadow one another on macOS even when the outer item is nil.
        .alert(item: rootAlertBinding) { item in
            let message = item.message
            if item.origin == .play,
               let primary = message.action.flatMap({ actions.primary(for: $0, model: model) }) {
                return Alert(title: Text(message.headline), message: Text(message.message),
                             primaryButton: .default(Text(primary.title)) {
                                 // Consume this alert before its action reserves the
                                 // next surface; native binding callbacks may follow
                                 // the action and must not reopen the old message.
                                 if model.playMessage?.id == message.id { model.clearPlayMessage() }
                                 primary.action()
                             },
                             secondaryButton: .cancel(Text("Not Now", bundle: .module)))
            }
            return Alert(title: Text(message.headline), message: Text(message.message),
                         dismissButton: .default(Text("Close", bundle: .module)))
        }
    }

    private var rootAlertBinding: Binding<RelayRootAlert?> {
        // Capture this presentation's identity. SwiftUI's dismiss callback must
        // not clear a newer play message or a queued storage error.
        let presented = RelayRootAlert.pending(play: model.playMessage, storage: model.loadError,
                                               dismissedStorageID: actions.acknowledgedStorageErrorID,
                                               presentationOccupied: !actions.canPresentRelaySurface)
        return Binding(get: { presented }, set: { value in
            guard actions.canPresentRelaySurface, value == nil, let presented else { return }
            switch presented.origin {
            case .play:
                if model.playMessage?.id == presented.id { model.clearPlayMessage() }
            case .storage:
                actions.acknowledgeStorageError(presented.id)
            }
        })
    }

    private struct CompareItem: Identifiable { let id: GameID }

    private var compareBinding: Binding<CompareItem?> {
        Binding(get: { actions.compareGameID.map(CompareItem.init) }, set: { if $0 == nil { actions.compareGameID = nil } })
    }

    @ViewBuilder
    private var shell: some View {
        #if os(tvOS)
        TVShell()
        #elseif os(macOS)
        SplitShell()
        #else
        AdaptiveShell(navigation: $navigation)
        #endif
    }

    /// Files from the picker/drop may be security scoped; hold access only while importing.
    private func importSecurityScoped(_ urls: [URL]) async {
        let accessing = urls.map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, ok) in zip(urls, accessing) where ok { url.stopAccessingSecurityScopedResource() } }
        await model.importFiles(urls)
    }
}

/// Product-only routing for the root's single native alert presenter. Storage
/// error dismissal does not discard the model's diagnostic evidence.
struct RelayRootAlert: Identifiable {
    enum Origin { case play, storage }
    let origin: Origin
    let message: ProductMessage
    var id: UUID { message.id }

    static func pending(play: ProductMessage?, storage: ProductMessage?, dismissedStorageID: UUID?,
                        presentationOccupied: Bool = false) -> RelayRootAlert? {
        guard !presentationOccupied else { return nil }
        if let play { return RelayRootAlert(origin: .play, message: play) }
        if let storage, storage.id != dismissedStorageID { return RelayRootAlert(origin: .storage, message: storage) }
        return nil
    }
}

/// "Saves are up to date" and similar one-line confirmations from the sync layer.
struct SyncToast: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        if let text = model.sync.toast, !model.isPlaying {
            StatusToast(text, symbol: .upToDate)
                .padding(.top, RelaySpacing.m)
                .transition(.opacity)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    model.sync.clearToast()
                }
        }
    }
}

#if os(iOS)
/// The same Home, Library and Search stacks survive compact/regular transitions.
/// SwiftUI adapts their navigation chrome without replacing the product hierarchy.
struct AdaptiveShell: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @Binding var navigation: RelayShellNavigationState

    var body: some View {
        TabView(selection: tabSelection) {
            Tab(value: Destination.home) {
                NavigationStack(path: tabPath(.home)) {
                    HomeView()
                        .relayRoutes()
                        .toolbar {
                            // App identity belongs in the navigation title, outside
                            // the glass groups reserved for toolbar actions.
                            if #available(iOS 26.0, *) {
                                ToolbarItem(placement: .principal) {
                                    RelayLockup(.bar).allowsHitTesting(false)
                                }
                                .sharedBackgroundVisibility(.hidden)
                            } else {
                                ToolbarItem(placement: .principal) {
                                    RelayLockup(.bar).allowsHitTesting(false)
                                }
                            }
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                ImportToolbarButton()
                                Button { actions.openSettings() } label: {
                                    Label { Text("Settings", bundle: .module) } icon: { RelaySymbol.settings.image }
                                }
                                .accessibilityLabel(Text("Settings", bundle: .module))
                            }
                        }
                        // Native bars outlive the shell's opacity and otherwise
                        // keep reserving space beside the immersive player.
                        .relayChromeHidden(model.isPlaying)
                }
                .environment(\.relayBrowsingState, tabBrowsing(.home))
            } label: { Label { Text("Home", bundle: .module) } icon: { RelaySymbol.home.image } }
            Tab(value: Destination.allGames) {
                NavigationStack(path: tabPath(.allGames)) {
                    LibraryView().relayRoutes().relayChromeHidden(model.isPlaying)
                }
                    .environment(\.relayBrowsingState, tabBrowsing(.allGames))
            } label: { Label { Text("Library", bundle: .module) } icon: { RelaySymbol.library.image } }
            Tab(value: Destination.search, role: .search) {
                NavigationStack(path: tabPath(.search)) {
                    SearchView().relayRoutes().relayChromeHidden(model.isPlaying)
                }
                    .environment(\.relayBrowsingState, tabBrowsing(.search))
            } label: { Label { Text("Search", bundle: .module) } icon: { RelaySymbol.search.image } }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarHeader {
            RelayLockup(.sidebar)
                .padding(.vertical, RelaySpacing.s)
        }
        .tabViewSidebarFooter { sidebarShortcuts }
        .tint(RelayColor.ember)
    }
    /// Sidebar actions reuse the existing tab stacks. Independent sidebar-only
    /// tabs can disappear on compact layouts and force a different selected tab.
    private var sidebarShortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarShortcut(.favorites) {
                Label { Text("Favorites", bundle: .module) } icon: { RelaySymbol.favorite.image }
            }
            if !model.systems.isEmpty {
                Text("Systems", bundle: .module)
                    .font(.relayStatus)
                    .foregroundStyle(RelayColor.textSecondary)
                    .padding(.top, RelaySpacing.m)
                    .padding(.bottom, RelaySpacing.xs)
                ForEach(model.systems) { summary in
                    sidebarShortcut(.system(summary.id)) {
                        HStack(spacing: RelaySpacing.s) {
                            Capsule(style: .continuous)
                                .fill(SystemAccent.hue(for: summary.id).accent)
                                .frame(width: 3, height: 16)
                            Text(summary.name)
                            Spacer(minLength: RelaySpacing.xs)
                            Text(summary.count.formatted()).monospacedDigit()
                        }
                    }
                }
            }
            sidebarShortcut(.settings) {
                Label { Text("Settings", bundle: .module) } icon: { RelaySymbol.settings.image }
            }
        }
    }

    private func sidebarShortcut<Content: View>(_ destination: Destination,
                                                @ViewBuilder label: () -> Content) -> some View {
        Button { navigation.select(destination) } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, RelaySpacing.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(RelayColor.textPrimary)
        .accessibilityAddTraits(navigation.selection == destination ? .isSelected : [])
    }

    private var tabSelection: Binding<Destination> {
        Binding(get: { navigation.selectedTab }, set: { navigation.selectTab($0) })
    }

    private func tabPath(_ tab: Destination) -> Binding<[Route]> {
        Binding(get: { navigation.tabPath(for: tab) },
                set: { navigation.setTabPath($0, for: tab) })
    }

    private func tabBrowsing(_ tab: Destination) -> Binding<RelayBrowsingState> {
        let destination = navigation.destination(for: tab)
        return Binding(get: { navigation.browsingState(for: destination) },
                       set: { navigation.setBrowsingState($0, for: destination) })
    }
}
#endif

#if os(iOS) || os(macOS)
/// iPad and Mac: sidebar (Home, All Games, Favorites, Systems, Settings on iPad) + detail column.
struct SplitShell: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    #if os(iOS)
    @Binding var navigation: RelayShellNavigationState
    private var section: Destination? { navigation.selection }
    private var sectionBinding: Binding<Destination?> {
        Binding(get: { navigation.selection }, set: { navigation.select($0 ?? .home) })
    }
    private var detailPathBinding: Binding<[Route]> {
        Binding(get: { navigation.detailPath }, set: { navigation.detailPath = $0 })
    }
    private var browsingBinding: Binding<RelayBrowsingState>? {
        let destination = navigation.selection
        return Binding(get: { navigation.browsingState(for: destination) },
                       set: { navigation.setBrowsingState($0, for: destination) })
    }
    #else
    @State private var section: Destination? = .home
    @State private var detailPath: [Route] = []
    private var sectionBinding: Binding<Destination?> { $section }
    private var detailPathBinding: Binding<[Route]> { $detailPath }
    private var browsingBinding: Binding<RelayBrowsingState>? { nil }
    #endif
    @State private var columns: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            NavigationStack(path: detailPathBinding) {
                detail
                    .relayRoutes()
                    .toolbar {
                        #if os(iOS)
                        // iPad in portrait hides the sidebar, and the brand with it;
                        // the lockup then takes the bar's centre, as it does on iPhone,
                        // so Home never loses its identity.
                        if columns == .detailOnly {
                            ToolbarItem(placement: .principal) { RelayLockup(.bar) }
                        }
                        #endif
                        ToolbarItemGroup(placement: .primaryAction) {
                            ImportToolbarButton()
                        }
                    }
                    // Declared here, so hidden here: a visibility set on an ancestor of
                    // the split view never reaches this toolbar, and window chrome is
                    // not affected by the root view's opacity.
                    .relayChromeHidden(model.isPlaying)
            }
            .environment(\.relayBrowsingState, browsingBinding)
        }
        .tint(RelayColor.ember)
        #if os(macOS)
        .onAppear { if let d = actions.debugInitialDestination { section = d } }
        .onChange(of: actions.debugInitialRoute) { _, route in if let route { section = .home; detailPath = [route] } }
        #endif
    }

    private var sidebar: some View {
        List(selection: sectionBinding) {
            // The lockup is the sidebar's header, the way a Mac app's identity sits
            // above its source list; it is not a row and cannot be selected.
            RelayLockup(.sidebar)
                .padding(.vertical, RelaySpacing.xs)
                .listRowInsets(EdgeInsets(top: RelaySpacing.xs, leading: RelaySpacing.m, bottom: RelaySpacing.s, trailing: RelaySpacing.m))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .selectionDisabled()
            row(.home) { Label { Text("Home", bundle: .module) } icon: { RelaySymbol.home.image } }
            row(.allGames) { Label { Text("All Games", bundle: .module) } icon: { RelaySymbol.library.image } }
            row(.favorites) { Label { Text("Favorites", bundle: .module) } icon: { RelaySymbol.favorite.image } }
            if !model.systems.isEmpty {
                Section {
                    ForEach(model.systems) { summary in
                        row(.system(summary.id)) {
                            HStack(spacing: RelaySpacing.s) {
                                // The same hue spine the tiles and placeholders carry, so the
                                // sidebar is part of the Spectrum rather than a plain list.
                                Capsule(style: .continuous).fill(SystemAccent.hue(for: summary.id).accent).frame(width: 3, height: 16)
                                Text(summary.name)
                                Spacer()
                                Text(summary.count.formatted()).monospacedDigit().opacity(0.7)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } header: { Text("Systems", bundle: .module) }
            }
            Section {
                row(.search) { Label { Text("Search", bundle: .module) } icon: { RelaySymbol.search.image } }
                #if os(iOS)
                row(.settings) { Label { Text("Settings", bundle: .module) } icon: { RelaySymbol.settings.image } }
                #endif
            }
        }
        // The window title stays "Relay" on macOS; on iPad the sidebar column shows
        // no bar title because the lockup above the list already is the title.
        .navigationTitle("Relay")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .listStyle(.sidebar)
        .keyboardShortcut("1", modifiers: .command)
    }

    /// A sidebar row whose selection Relay paints itself. AppKit draws the native
    /// highlight from the system accent, which follows whatever the Mac's owner
    /// chose in System Settings (Pink, on the owner's Mac); neither `tint` nor
    /// `accentColor` reaches it on macOS 26. An opaque row background sits above
    /// that highlight, so the selected row is Ember — the same filled capsule the
    /// platform draws, in Relay's colour — while the list keeps its native
    /// selection, keyboard navigation and VoiceOver semantics.
    private func row<Content: View>(_ destination: Destination, @ViewBuilder content: () -> Content) -> some View {
        let selected = section == destination
        return content()
            .foregroundStyle(selected ? RelayColor.textOnEmber : RelayColor.textPrimary)
            .listRowBackground(
                RoundedRectangle(cornerRadius: RelayRadius.s, style: .continuous)
                    .fill(selected ? RelayColor.ember : Color.clear)
                    .padding(.horizontal, RelaySpacing.xs)
            )
            .tag(destination)
    }

    @ViewBuilder
    private var detail: some View {
        switch section ?? .home {
        case .home: HomeView()
        case .allGames: LibraryView(initialFilter: .all)
        case .favorites: LibraryView(initialFilter: .favorites)
        case .system(let id): SystemPageView(systemID: id)
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }
}
#endif

#if os(tvOS)
/// Apple TV: top tab bar Home · Library · Search · Settings; controller/focus-first.
struct TVShell: View {
    @Environment(RelayActions.self) private var actions
    @State private var selection: Destination = .home
    @State private var homePath: [Route] = []

    var body: some View {
        // The brand is a row of its own above the tab bar: the lockup at the
        // top-left, at the 80-pt safe margin, and Home · Library · Search ·
        // Settings directly under it, so the two read as one header block from
        // viewing distance. The row lives outside the TabView, so when the bar
        // hides while content has focus, the lockup stays as the top edge and
        // nothing scrolls under it. (tvOS 18's sidebar tab bar was tried first:
        // its section header is reduced to plain text and drops the mark.)
        VStack(alignment: .leading, spacing: 0) {
            RelayLockup(.television)
                .padding(.leading, 80)
                .padding(.top, 46)
                .padding(.bottom, RelaySpacing.xs)
            TabView(selection: $selection) {
                Tab(value: Destination.home) { NavigationStack(path: $homePath) { HomeView().relayRoutes() } } label: { Text("Home", bundle: .module) }
                Tab(value: Destination.allGames) { NavigationStack { LibraryView().relayRoutes() } } label: { Text("Library", bundle: .module) }
                Tab(value: Destination.search) { NavigationStack { SearchView().relayRoutes() } } label: { Text("Search", bundle: .module) }
                Tab(value: Destination.settings) { NavigationStack { SettingsView().relayRoutes() } } label: { Text("Settings", bundle: .module) }
            }
            .tint(RelayColor.ember)
        }
        .ignoresSafeArea(edges: .top)
        .onAppear { if let d = actions.debugInitialDestination { selection = d } }
        .onChange(of: actions.settingsPresented) { _, requested in
            guard requested else { return }
            selection = .settings
            actions.settingsPresented = false
            actions.presentationDidDismiss(.settings)
        }
        .onChange(of: actions.debugInitialRoute) { _, route in if let route { selection = .home; homePath = [route] } }
    }
}
#endif

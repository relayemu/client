// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  HomeView.swift
//  Continuity (CONTINUITY_UX §5): one ProblemCard at most, a two-second "Updating…" line, nothing else.

import SwiftUI
import RelayDomain
import RelayDesignSystem

public struct HomeView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    private let layout = RelaySpacing.layout

    public init() {}

    public var body: some View {
        ScrollView {
            if model.isEmpty {
                VStack(spacing: RelaySpacing.s) {
                    ImportBanner()
                    ContinuityProblemList()
                    ProblemList()
                    LibraryEmptyState()
                        .frame(minHeight: 420)
                }
                .padding(.top, RelaySpacing.s)
            } else {
                // Home begins with the player's own content. The brand lives in the
                // on iPad and Mac, the tab sidebar on Apple TV. Nothing here says Relay.
                VStack(alignment: .leading, spacing: layout.sectionGap) {
                    UpdatingLine()
                    ImportBanner()
                    ContinuityProblemList()
                    ProblemList()
                    shelves
                }
                .padding(.vertical, layout.screenMargin)
            }
        }
        .relayKeyboardScrollContainer()
        .relayCanvas()
        .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: model.games.count)
        // The chrome carries the lockup, so the bar shows no title of its own: "Home"
        // would compete with "Relay" a few points away.
        .navigationTitle(Text(verbatim: ""))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #elseif os(tvOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    private var shelves: some View {
        let continuing = model.continuePlaying
        if !continuing.isEmpty {
            Shelf(L("Continue Playing"), accent: RelayColor.ember) {
                ForEach(continuing) { game in
                    ContinueCard(model.continueModel(for: game)) { Task { await model.primaryAction(game.id) } }
                        .continueCardWidth(layout: layout, accessibilitySize: typeSize.isAccessibilitySize)
                }
            }
        }
        let recent = model.recentlyPlayed
        if !recent.isEmpty {
            GameShelf(title: L("Recently Played"), games: recent, meta: true, accent: RelayColor.textTertiary, seeAll: .library(.recentlyPlayed))
        }
        let added = model.recentlyAdded
        if !added.isEmpty {
            VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                GameShelf(title: L("Recently Added"), games: added, meta: false, accent: RelayColor.textTertiary, seeAll: .library(.recentlyAdded))
                if let hint = model.firstImportHintGameID, added.contains(where: { $0.id == hint }) {
                    FirstImportHint()
                        .padding(.horizontal, layout.screenMargin)
                }
            }
        }
        let systems = model.systems
        if !systems.isEmpty {
            Shelf(L("Systems"), accent: RelayColor.textTertiary) {
                ForEach(systems) { summary in
                    NavigationLink(value: Route.system(summary.id)) {
                        SystemTileLabel(model.tileModel(for: summary))
                    }
                    .buttonStyle(.relayCard)
                    .relayScrollToKeyboardFocus()
                    .frame(width: systemTileWidth)
                }
            }
        }
        let favorites = model.favorites
        if !favorites.isEmpty {
            GameShelf(title: L("Favorites"), games: favorites, meta: false, accent: RelayColor.ember, seeAll: .library(.favorites))
        }
    }

    private var systemTileWidth: CGFloat {
        #if os(tvOS)
        return 400
        #else
        return 220
        #endif
    }
}

extension LibraryModel {
    /// What tapping a Continue card does: continue, download, review, or explain.
    func primaryAction(_ id: GameID) async {
        guard let game = game(id) else { return }
        switch primaryAction(for: game) {
        case .play, .continue: await play(id)
        case .download:
            if canStartGameplay {
                await downloadAndPlay(id)
            } else {
                await download(id)
            }
        case .review, .howToAdd, .downloading: await play(id)   // play() produces the right message
        }
    }
}

extension View {
    /// Continue card width per platform design: 640 pt on Apple TV (TVOS_UX §3), 420 pt on
    /// macOS, and on iOS relative to the shelf's container — full width minus the margin
    /// and a peek of the next card on iPhone (IPHONE_UX §3), 2-up on regular widths and
    /// 3-up above 1200 pt (IPAD_UX §3) so an iPad never shows iPhone-sized cards. Accessibility text uses a wider
    /// single card, capped so its artwork does not dominate the screen.
    @ViewBuilder
    func continueCardWidth(layout: RelaySpacing.Layout, accessibilitySize: Bool) -> some View {
        #if os(tvOS)
        frame(width: 800)
        #elseif os(macOS)
        containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
            min(420, max(0, width - 2 * layout.screenMargin))
        }
        #else
        containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
            if width < 600 { return max(280, width - layout.screenMargin - 32) }
            if accessibilitySize { return min(600, max(280, width - 2 * layout.screenMargin)) }
            let count: CGFloat = width >= 1200 ? 3 : 2
            return (width - 2 * layout.screenMargin - (count - 1) * layout.cardGap) / count
        }
        #endif
    }
}

/// A shelf of GameCards navigating to Game Detail.
struct GameShelf: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var accessibleArtworkHeight = RelaySpacing.layout.shelfArtworkHeight
    let title: String
    let games: [Game]
    let meta: Bool
    var accent: Color = RelayColor.ember
    let seeAll: Route?

    var body: some View {
        // Keep See All and its game links in the same value-based stack so
        // opening a game preserves the Library destination for Back.
        Shelf(title, accent: accent, seeAll: seeAll) {
            ForEach(games) { game in
                NavigationLink(value: Route.game(game.id)) {
                    GameCardLabel(model.cardModel(for: game, meta: meta),
                                  artworkHeight: typeSize.isAccessibilitySize ? accessibleArtworkHeight : RelaySpacing.layout.shelfArtworkHeight)
                }
                .buttonStyle(.relayCard)
                .relayScrollToKeyboardFocus()
                .gameContextMenu(game)
            }
        }
    }
}

/// GameCard rendered as a label inside a NavigationLink (keeps the card's look and
/// accessibility). It must use the card's non-interactive form: a card that is a
/// Button of its own swallows the link's gesture, and disabling hit testing on it
/// leaves the link with nothing to hit, so the whole card stops responding.
struct GameCardLabel: View {
    let model: GameCardModel
    let artworkHeight: CGFloat?
    init(_ model: GameCardModel, artworkHeight: CGFloat? = nil) { self.model = model; self.artworkHeight = artworkHeight }
    var body: some View { GameCard(label: model, artworkHeight: artworkHeight) }
}

struct SystemTileLabel: View {
    let model: SystemTileModel
    init(_ model: SystemTileModel) { self.model = model }
    var body: some View { SystemTile(label: model) }
}

/// "Updating…" under the Home title while a change from another device is applied (at most two seconds).
struct UpdatingLine: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        if model.sync.isUpdating {
            StatusLine(L("Updating…"), symbol: .syncing)
                .padding(.horizontal, RelaySpacing.layout.screenMargin)
                .transition(.opacity)
        }
    }
}

/// Import progress banner (§9.2): non-modal, under the title.
struct ImportBanner: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        if let progress = model.importProgress {
            HStack(spacing: RelaySpacing.s) {
                switch progress {
                case .running(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .tint(RelayColor.ember)
                        .frame(maxWidth: 160)
                    Text("Adding games… \(done) of \(total)", bundle: .module)
                        .font(.relayStatusEmphasis)
                        .foregroundStyle(RelayColor.textPrimary)
                        .monospacedDigit()
                case .summary(let added, let duplicates, let problems):
                    RelayDash(added > 0 ? RelayColor.ember : RelayColor.textTertiary, height: 4)
                    Text(summaryText(added: added, duplicates: duplicates, problems: problems))
                        .font(.relayStatusEmphasis)
                        .foregroundStyle(RelayColor.textPrimary)
                }
                Spacer()
            }
            .padding(.horizontal, RelaySpacing.layout.screenMargin)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }

    private func summaryText(added: Int, duplicates: Int, problems: Int) -> String {
        var parts = [String(localized: "\(added) games added", bundle: .module)]
        if duplicates > 0 { parts.append(String(localized: "\(duplicates) already in your library", bundle: .module)) }
        if problems > 0 { parts.append(String(localized: "\(problems) need attention", bundle: .module)) }
        return parts.joined(separator: " · ")
    }
}

/// The single continuity ProblemCard (CONTINUITY_UX §5 layer 2): Two versions › iCloud full ›
/// Not synced yet (> 10 min online) › account changed › iCloud off (first time only).
struct ContinuityProblemList: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @State private var conflictMessage: ProductMessage?
    @State private var conflictMessageGameID: GameID?

    var body: some View {
        Group {
            if let problem = model.sync.problem, let message = message(for: problem) {
                ProblemCard(tone: message.isCritical ? .critical : .caution, headline: message.headline, message: message.message,
                            primary: message.action.flatMap { actions.primary(for: $0, model: model) },
                            dismiss: { model.sync.dismiss(problem) })
                    .padding(.horizontal, RelaySpacing.layout.screenMargin)
                    .transition(.opacity)
            }
        }
        .task(id: conflictRefreshKey) {
            conflictMessage = nil
            conflictMessageGameID = nil
            guard case .twoVersions(let id) = model.sync.problem, let game = model.game(id) else { return }
            let message = await model.twoVersionsMessage(for: game)
            guard !Task.isCancelled else { return }
            conflictMessageGameID = id
            conflictMessage = message
        }
    }

    private struct ConflictRefreshKey: Equatable {
        let problem: ContinuityProblem?
        let gameIsLoaded: Bool
        let lastAppliedAt: Date?
    }

    private var conflictRefreshKey: ConflictRefreshKey {
        let problem = model.sync.problem
        let loaded: Bool
        if case .twoVersions(let id) = problem { loaded = model.game(id) != nil }
        else { loaded = false }
        return ConflictRefreshKey(problem: problem, gameIsLoaded: loaded, lastAppliedAt: model.sync.lastAppliedAt)
    }

    private func message(for problem: ContinuityProblem) -> ProductMessage? {
        switch problem {
        case .twoVersions(let id):
            return conflictMessageGameID == id ? conflictMessage : nil
        case .quotaFull: return .quotaFull(deviceKind: model.deviceKind, hosted: model.sync.selectedProvider == .relaySync)
        case .pendingTooLong(let count): return .pendingTooLong(count: count)
        case .accountChanged: return .accountChanged(deviceKind: model.deviceKind, hosted: model.sync.selectedProvider == .relaySync)
        case .cloudOff: return .cloudOff(deviceKind: model.deviceKind)
        }
    }
}

/// Import issues collected as ProblemCards (§9.3).
struct ProblemList: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions

    var body: some View {
        if !model.problems.isEmpty {
            VStack(alignment: .leading, spacing: RelaySpacing.s) {
                Text("Import issues", bundle: .module)
                    .font(.relayShelfTitle)
                    .foregroundStyle(RelayColor.textPrimary)
                ForEach(model.problems) { problem in
                    ProblemCard(tone: problem.isCritical ? .critical : .caution, headline: problem.headline, message: problem.message,
                                primary: problem.action.flatMap { actions.primary(for: $0, model: model) },
                                dismiss: { model.dismissProblem(problem) })
                }
            }
            .padding(.horizontal, RelaySpacing.layout.screenMargin)
        }
    }
}

/// The empty library (§4.2): one EmptyState, platform-specific actions.
struct LibraryEmptyState: View {
    @Environment(RelayActions.self) private var actions

    var body: some View {
        #if os(tvOS)
        EmptyState(scene: .handoff,
                   title: L("Nothing here yet."),
                   message: L("With Relay Pro, choose Add games → From a computer to send games to this Apple TV. You can also sync your library from your iPhone, iPad or Mac."),
                   primary: (L("From a computer"), { actions.fromComputer() }))
        #else
        VStack(spacing: RelaySpacing.s) {
            EmptyState(scene: .dropIn,
                       title: L("No games yet."),
                       message: L("Drop some in. Relay finds the covers and keeps your saves with you."),
                       primary: (L("Import Files"), { actions.importFiles() }),
                       secondary: (L("Which formats work?"), { actions.whichFormats() }))
            #if os(macOS)
            Text("or drop files anywhere in this window", bundle: .module)
                .font(.relayCallout)
                .foregroundStyle(RelayColor.textTertiary)
                .padding(.bottom, RelaySpacing.xl)
            #endif
        }
        #endif
    }
}


/// The one line a player sees after their first game lands. It is a note in the
/// margin, not a banner: the pen mark, the sentence, and nothing to dismiss
struct FirstImportHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: RelaySpacing.s) {
            RelayDash(RelayColor.ember, height: 4)
                .padding(.top, 8)
            Text("Open it. Relay saves as you go.", bundle: .module)
                .font(.relayCallout)
                .foregroundStyle(RelayColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

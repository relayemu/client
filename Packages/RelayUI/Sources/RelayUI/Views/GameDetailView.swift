// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  GameDetailView.swift
//  Play / Continue / Download & Play / Review, Favorite, Saves, More (with
//  Choose Cover… / Reset Cover outside tvOS), the continuity status line,
//  Progress, About, Files (In iCloud / On this device).

import SwiftUI
import UniformTypeIdentifiers
import RelayDomain
import RelayDesignSystem
#if os(iOS)
import PhotosUI
#endif

public struct GameDetailView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @Environment(\.dismiss) private var dismiss
    let gameID: GameID
    @State private var files: [GameFile] = []
    @State private var confirmDelete = false
    @State private var confirmRemoveDownload = false
    @State private var showFiles = false
    @State private var savesPresented = false
    @State private var deferredSaveLaunch = RelayDeferredSaveLaunch()
    @State private var saveCount = 0
    @State private var batterySave: Save?
    // Choose Cover… (cover-art spec §3): iPhone/iPad Photos or Files, Mac open panel or a drop.
    @State private var coverFilePresented = false
    @State private var coverRefused = false
    #if os(iOS)
    @State private var coverPhotosPresented = false
    @State private var coverPhoto: PhotosPickerItem?
    #endif

    public init(gameID: GameID) { self.gameID = gameID }

    public var body: some View {
        if let game = model.game(gameID) {
            content(game)
        } else {
            EmptyState(symbol: .library, title: L("That game isn't in your library any more."), message: L("It may have been deleted."))
                .relayCanvas()
        }
    }

    @ViewBuilder
    private func content(_ game: Game) -> some View {
        let card = model.cardModel(for: game)
        let entry = model.history[game.id]
        ScrollView {
            VStack(alignment: .leading, spacing: RelaySpacing.xl) {
                #if os(tvOS)
                // A long title must wrap beside the artwork. Its ideal text
                // width must not switch a television to the tall phone layout.
                wideLayout(game: game, card: card, entry: entry)
                #else
                ViewThatFits(in: .horizontal) {
                    wideLayout(game: game, card: card, entry: entry)
                    narrowLayout(game: game, card: card, entry: entry)
                }
                #endif
                sections(game: game, entry: entry)
            }
            .padding(RelaySpacing.layout.screenMargin)
        }
        .relayKeyboardScrollContainer()
        .relayCanvas()
        // Stable hook for the UI tests, which verify that a real tap on a game
        // card actually reaches this screen.
        .accessibilityIdentifier("relay.gameDetail")
        #if os(tvOS)
        // The hero is the screen heading; a navigation title repeats it above
        // the artwork and pushes the game's actions farther down the screen.
        .navigationTitle(Text(verbatim: ""))
        #else
        .navigationTitle(game.title)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: game.id) { await reload(game) }
        .onChange(of: model.contentPresence[game.id]) { _, _ in Task { await reload(game) } }
        .onChange(of: model.isPlaying) { _, playing in
            if !playing { Task { await reload(game) } }
        }
        .sheet(isPresented: $savesPresented, onDismiss: {
            actions.presentationDidDismiss(.librarySaves)
            let stateToLoad = deferredSaveLaunch.takeAfterDismissal()
            Task {
                if let stateToLoad { await model.play(game.id, restoring: stateToLoad) }
                let browser = await model.browserStates(for: game.id)
                saveCount = browser.quick.count + browser.manual.count
            }
        }) {
            SavesView(context: .library(game.id), requestLibraryLoad: { deferredSaveLaunch.request($0) })
        }
        .confirmationDialog(Text("Delete \(game.title)?", bundle: .module), isPresented: $confirmDelete, titleVisibility: .visible) {
            if model.isSynced(game.id) {
                if model.hasContent(game.id), model.hasCloudContent(game.id) {
                    Button { Task { await model.removeDownload(game.id) } } label: { Text("Delete from \(Formatting.thisDevice(model.deviceKind))", bundle: .module) }
                }
                Button(role: .destructive) {
                    Task { await model.delete(game.id); dismiss() }
                } label: { Text("Delete Everywhere", bundle: .module) }
            } else {
                Button(role: .destructive) {
                    Task { await model.delete(game.id); dismiss() }
                } label: { Text("Delete", bundle: .module) }
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            if model.isSynced(game.id) {
                Text("Delete Everywhere removes the game and its saves from the selected sync service and devices using it. Other services keep their copies. Saves can't be recovered.", bundle: .module)
            } else {
                Text("Removes the game and its progress from \(Formatting.thisDevice(model.deviceKind)).", bundle: .module)
            }
        }
        .confirmationDialog(Text("Remove the download?", bundle: .module), isPresented: $confirmRemoveDownload, titleVisibility: .visible) {
            Button { Task { await model.removeDownload(game.id) } } label: { Text("Remove Download", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Removing a download keeps the game in your selected sync service. Your saves stay on \(Formatting.thisDevice(model.deviceKind)).", bundle: .module)
        }
        #if !os(tvOS)
        .fileImporter(isPresented: $coverFilePresented, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task { coverRefused = !(await model.chooseCover(contentsOf: url, for: game.id)) }
        }
        .alert(Text("This image can't be used as a cover.", bundle: .module), isPresented: $coverRefused) {
            Button(role: .cancel) {} label: { Text("OK", bundle: .module) }
        } message: {
            Text("Try another photo or image file.", bundle: .module)
        }
        #endif
        #if os(iOS)
        .photosPicker(isPresented: $coverPhotosPresented, selection: $coverPhoto, matching: .images)
        .onChange(of: coverPhoto) { _, item in
            guard let item else { return }
            coverPhoto = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { coverRefused = true; return }
                coverRefused = !(await model.chooseCover(data, for: game.id))
            }
        }
        #endif
    }

    /// The cover; on the Mac an image file dropped on it becomes the game's cover.
    private func coverArtwork(_ card: GameCardModel, game: Game) -> some View {
        ArtworkView(card.artwork, cornerRadius: RelayRadius.xl, showsTitleWhenEmpty: false)
            #if os(macOS)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return false }
                Task { coverRefused = !(await model.chooseCover(contentsOf: url, for: game.id)) }
                return true
            }
            #endif
    }

    private func reload(_ game: Game) async {
        files = await model.files(for: game.id)
        let browser = await model.browserStates(for: game.id)
        saveCount = browser.quick.count + browser.manual.count
        batterySave = await model.batterySave(for: game.id)
    }

    /// iPad/macOS/tvOS: artwork column + content column.
    private func wideLayout(game: Game, card: GameCardModel, entry: PlayHistoryEntry?) -> some View {
        HStack(alignment: .top, spacing: RelaySpacing.xl) {
            coverArtwork(card, game: game)
                .frame(width: artworkWidth, height: artworkWidth * 4 / 3)
            VStack(alignment: .leading, spacing: RelaySpacing.m) {
                header(game: game)
                actionRow(game: game, entry: entry)
                statusLine(game: game, entry: entry)
            }
            .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
        }
    }

    /// iPhone: hero artwork, then title and actions.
    private func narrowLayout(game: Game, card: GameCardModel, entry: PlayHistoryEntry?) -> some View {
        VStack(alignment: .leading, spacing: RelaySpacing.m) {
            coverArtwork(card, game: game)
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
                #if os(tvOS)
                .frame(maxHeight: 460)
                #else
                .frame(maxHeight: 240)
                #endif
            header(game: game)
            actionRow(game: game, entry: entry)
            statusLine(game: game, entry: entry)
        }
    }

    private var artworkWidth: CGFloat {
        #if os(tvOS)
        return 400
        #else
        return 320
        #endif
    }

    private func header(game: Game) -> some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xs) {
            Text(game.title)
                .font(.relayDetailTitle)
                .foregroundStyle(RelayColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: RelaySpacing.xs) {
                SystemChip(Formatting.systemName(game.systemID), hue: SystemAccent.hue(for: game.systemID))
                if let year = model.metadata[game.id]?.releaseYear {
                    Text(year.formatted(.number.grouping(.never)))
                        .font(.relayMeta)
                        .foregroundStyle(RelayColor.textSecondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func actionRow(game: Game, entry: PlayHistoryEntry?) -> some View {
        AdaptiveActionRow {
            primaryButton(game: game)
            secondaryActions(game: game)
        }
    }

    private func secondaryActions(game: Game) -> some View {
        HStack(spacing: RelaySpacing.s) {
            Button { Task { await model.toggleFavorite(game.id) } } label: {
                (game.isFavorite ? RelaySymbol.favoriteFilled : RelaySymbol.favorite).image
            }
            .buttonStyle(.quietGlyph)
            .relayScrollToKeyboardFocus()
            .accessibilityLabel(Text(game.isFavorite ? "Unfavorite" : "Favorite", bundle: .module))
            Button {
                if actions.beginPresentation(.librarySaves) { savesPresented = true }
            } label: {
                RelaySymbol.loadState.image
            }
            .buttonStyle(.quietGlyph)
            .relayScrollToKeyboardFocus()
            .accessibilityLabel(Text("Saves", bundle: .module))
            Menu {
                #if os(iOS)
                Menu {
                    Button { coverPhotosPresented = true } label: { Label { Text("Photos", bundle: .module) } icon: { RelaySymbol.photos.image } }
                    Button { coverFilePresented = true } label: { Label { Text("Files", bundle: .module) } icon: { RelaySymbol.showInFinder.image } }
                } label: {
                    Label { Text("Choose Cover…", bundle: .module) } icon: { RelaySymbol.chooseCover.image }
                }
                #elseif os(macOS)
                Button { coverFilePresented = true } label: { Label { Text("Choose Cover…", bundle: .module) } icon: { RelaySymbol.chooseCover.image } }
                #endif
                #if !os(tvOS)
                if model.hasCustomCover(game.id) {
                    Button { Task { await model.resetCover(game.id) } } label: {
                        Label { Text("Reset Cover", bundle: .module) } icon: { RelaySymbol.resetCover.image }
                    }
                }
                Divider()
                #endif
                if model.hasContent(game.id), model.hasCloudContent(game.id) {
                    Button { confirmRemoveDownload = true } label: { Label { Text("Remove Download", bundle: .module) } icon: { RelaySymbol.removeDownload.image } }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label { Text("Delete…", bundle: .module) } icon: { RelaySymbol.delete.image } }
            } label: {
                RelaySymbol.more.image
            }
            .buttonStyle(.quietGlyph)
            .relayScrollToKeyboardFocus()
            .accessibilityLabel(Text("More", bundle: .module))
        }
    }

    /// Continue / Play / Download & Play · size / Review / How to Add / progress (UX §7, CONTINUITY_UX §4).
    @ViewBuilder
    private func primaryButton(game: Game) -> some View {
        let action = model.primaryAction(for: game)
        Button { Task { await model.primaryAction(game.id) } } label: {
            switch action {
            case .play:
                Label { Text("Play", bundle: .module) } icon: { RelaySymbol.play.image }
            case .continue:
                Label { Text("Continue", bundle: .module) } icon: { RelaySymbol.play.image }
            case .download(let size):
                if model.canStartGameplay {
                    Label { Text(size > 50 * 1024 * 1024 ? "Download & Play · \(Formatting.bytes(size))" : "Download & Play", bundle: .module) } icon: { RelaySymbol.inCloud.image }
                } else {
                    Label { Text(size > 50 * 1024 * 1024 ? "Download · \(Formatting.bytes(size))" : "Download", bundle: .module) } icon: { RelaySymbol.inCloud.image }
                }
            case .review:
                Label { Text("Review", bundle: .module) } icon: { RelaySymbol.conflict.image }
            case .howToAdd:
                Label { Text("How to Add", bundle: .module) } icon: { RelaySymbol.importFiles.image }
            case .downloading(let p):
                Label { Text("Downloading · \(Int(p * 100)) %", bundle: .module) } icon: { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.ember)
        .relayScrollToKeyboardFocus()
        .disabled({ if case .downloading = action { return true } else { return false } }())
        .relayKeyboardShortcut(.return, modifiers: .command)
    }

    @ViewBuilder
    private func statusLine(game: Game, entry: PlayHistoryEntry?) -> some View {
        let text = model.statusLine(for: game)
        if !text.isEmpty {
            StatusLine(text, tone: statusTone(for: game), symbol: model.statusSymbol(for: game))
        } else {
            StatusLine(String(localized: "Not played yet", bundle: .module), symbol: Formatting.deviceSymbol(model.deviceKind))
        }
    }

    private func statusTone(for game: Game) -> StatusTone {
        switch model.sync.gameStatus(game.id) {
        case .conflict: return .critical
        case .failed: return .caution
        case .pending(let since) where Date().timeIntervalSince(since) > 10 * 60: return .caution
        default: return .neutral
        }
    }

    @ViewBuilder
    private func sections(game: Game, entry: PlayHistoryEntry?) -> some View {
        if AchievementSystem.isEligible(game.systemID) {
            NavigationLink(value: Route.achievements(game.id)) {
                HStack(spacing: RelaySpacing.m) {
                    RelaySymbol.achievements.image
                        .font(.relayCardTitle)
                        .foregroundStyle(RelayColor.textSecondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                        Text("Achievements", bundle: .module).font(.relayCardTitle)
                        if let set = model.environment.achievements.games[game.id] {
                            Text("\(set.unlockedCount) of \(set.achievements.count) unlocked", bundle: .module)
                                .font(.relayMeta).monospacedDigit()
                                .foregroundStyle(RelayColor.textSecondary)
                        } else {
                            Text("RetroAchievements · Free", bundle: .module)
                                .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.relayMeta).foregroundStyle(RelayColor.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .playToolsSurface()
                .contentShape(RoundedRectangle(cornerRadius: RelayRadius.l))
            }
            .buttonStyle(.relayCard)
            .relayScrollToKeyboardFocus()
            .accessibilityIdentifier("game.achievements")
        }
        if let entry {
            section(title: L("Progress")) {
                DetailRow(label: L("Play time"), value: Formatting.playDuration(entry.totalPlayDuration))
                DetailRow(label: L("Last played"), value: Formatting.relative(Formatting.lastPlayedDate(session: entry.latestSession)))
                DetailRow(label: L("Sessions"), value: entry.sessionCount.formatted())
                DetailRow(label: L("Saves"), value: String(localized: "\(saveCount) saves", bundle: .module))
                if let batterySave {
                    DetailRow(label: L("In-game save"), value: Formatting.relative(batterySave.updatedAt))
                }
            }
        }
        if let meta = model.metadata[game.id], meta.summary != nil || meta.developer != nil || meta.publisher != nil || meta.genre != nil || meta.region != nil {
            section(title: L("About")) {
                if let summary = meta.summary {
                    Text(summary).font(.relayBody).foregroundStyle(RelayColor.textPrimary).lineLimit(5)
                }
                if let developer = meta.developer { DetailRow(label: L("Developer"), value: developer) }
                if let publisher = meta.publisher { DetailRow(label: L("Publisher"), value: publisher) }
                if let genre = meta.genre { DetailRow(label: L("Genre"), value: genre) }
                if let region = meta.region { DetailRow(label: L("Region"), value: region) }
            }
        }
        section(title: L("Files")) {
            #if os(tvOS)
            filesList(game)
            #else
            DisclosureGroup(isExpanded: $showFiles) {
                filesList(game)
            } label: {
                Text("\(files.count) files", bundle: .module).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
            }
            #endif
        }
    }

    private func filesList(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xs) {
            ForEach(files) { file in
                DetailRow(label: file.originalFileName, value: "\(Formatting.bytes(file.sizeInBytes)) · \(Formatting.thisDevice(model.deviceKind).capitalizedFirst)")
            }
            if files.isEmpty {
                DetailRow(label: L("Game file"), value: model.hasCloudContent(game.id) ? (model.sync.selectedProvider == .relaySync ? L("In Relay Sync") : L("In iCloud")) : L("On another device"))
            } else if model.hasCloudContent(game.id) {
                DetailRow(label: model.sync.selectedProvider == .relaySync ? L("Copy in Relay Sync") : L("Copy in iCloud"), value: L("Yes"))
            }
            Text("Files are managed by Relay.", bundle: .module)
                .font(.relayCallout).foregroundStyle(RelayColor.textTertiary)
        }
    }

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xs) {
            HStack(spacing: RelaySpacing.xs) {
                RelayDash(RelayColor.textTertiary, height: 4)
                Text(title).font(.relaySubheader).foregroundStyle(RelayColor.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: RelaySpacing.xs) { content() }
                .padding(RelaySpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RelayColor.surface, in: RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous).strokeBorder(RelayColor.separator))
        }
    }
}

struct DetailRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let label: String
    let value: String

    init(label: String, value: String) { self.label = label; self.value = value }

    var body: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        labelText.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: RelaySpacing.s)
                        valueText.fixedSize(horizontal: true, vertical: false)
                            .multilineTextAlignment(.trailing)
                    }
                    stacked
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(label).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            .help(label)
            #endif
    }

    private var valueText: some View {
        Text(value).font(.relayMeta).foregroundStyle(RelayColor.textPrimary).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xxs) {
            labelText
            valueText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SavesView.swift
//  and Saved (manual) groups with screenshot cards, Load/Delete, "Save Now" in
//  play, and the human message for incompatible saves. Auto Resume never
//  appears here. Reached from the pause overlay (Load State) and Game Detail.

import SwiftUI
import RelayDomain
import RelayDesignSystem

struct SavesView: View {
    enum Context: Equatable {
        /// Inside the pause overlay: loads apply to the running game; Save Now available.
        case inGame
        /// From Game Detail: loading launches the game and restores the state.
        case library(GameID)
    }

    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    let context: Context
    var requestLibraryLoad: ((SaveState) -> Void)?
    @State private var quick: [SaveState] = []
    @State private var manual: [SaveState] = []
    @State private var previousVersions: [BatteryRevision] = []
    @State private var selected: SaveState?
    @State private var confirmDelete: SaveState?
    @State private var confirmRestore: BatteryRevision?
    @State private var loaded = false

    private var play: PlayModel { model.play }
    private var gameID: GameID? {
        switch context {
        case .inGame: return play.game?.id
        case .library(let id): return id
        }
    }
    private var runningCore: EmulatorCoreDescriptor? {
        switch context {
        case .inGame: return play.core
        case .library(let id): return model.game(id).flatMap { g in model.environment.cores.first { $0.supports(g.systemID) } }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: RelaySpacing.xl) {
                        RelayInlineOperationProblem(source: context == .inGame ? .play : .storage)
                            .id(RelayInlineOperationProblem.scrollID)
                        if context == .inGame, play.canSaveStates {
                            Button { Task { await play.saveNow(); await reload() } } label: {
                                Label { Text("Save Now", bundle: .module) } icon: { RelaySymbol.quickSave.image }
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.ember)
                            .relayScrollToKeyboardFocus()
                        }
                        if context == .inGame && play.hardcoreEnabled {
                            Text("Loading Saves is unavailable in Hardcore. You can still create Saves.", bundle: .module)
                        }
                        if loaded, quick.isEmpty, manual.isEmpty {
                            EmptyState(symbol: .loadState, title: L("No saves yet."), message: L("Quick Save or Save Now while you play. Relay keeps your in-game save on its own."))
                        }
                        if !quick.isEmpty { group(L("Quick"), states: quick) }
                        if !manual.isEmpty { group(L("Manual Saves"), states: manual) }
                        if !previousVersions.isEmpty { previousVersionsGroup }
                    }
                    .padding(RelaySpacing.layout.screenMargin)
                }
                .relayKeyboardScrollContainer()
                .onChange(of: context == .inGame ? play.problem?.id : model.loadError?.id) { _, id in
                    guard id != nil else { return }
                    proxy.scrollTo(RelayInlineOperationProblem.scrollID, anchor: .top)
                }
            }
            .relayCanvas()
            .navigationTitle(Text("Saves", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Done", bundle: .module) }
                }
            }
            .task { await reload() }
            .confirmationDialog(Text("Delete this save?", bundle: .module), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button(role: .destructive) {
                    if let state = confirmDelete { Task { await delete(state) } }
                } label: { Text("Delete", bundle: .module) }
                Button(role: .cancel) { confirmDelete = nil } label: { Text("Cancel", bundle: .module) }
            } message: {
                Text("This can't be undone. Your in-game save isn't affected.", bundle: .module)
            }
            .confirmationDialog(Text("Restore this version?", bundle: .module), isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }), titleVisibility: .visible) {
                Button {
                    if let revision = confirmRestore { Task { await model.restore(revision); confirmRestore = nil; await reload() } }
                } label: { Text("Restore", bundle: .module) }
                Button(role: .cancel) { confirmRestore = nil } label: { Text("Cancel", bundle: .module) }
            } message: {
                Text("Your current in-game save is kept as a version too. Nothing is overwritten.", bundle: .module)
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
    }

    private func group(_ title: String, states: [SaveState]) -> some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            Text(title).font(.relayShelfTitle).foregroundStyle(RelayColor.textPrimary).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: RelaySpacing.m) {
                ForEach(Array(states.enumerated()), id: \.element.id) { index, state in
                    SaveCard(state: state, subtitle: subtitle(for: state, index: index, in: states), hue: hue,
                             compatible: isCompatible(state), selected: selected?.id == state.id,
                             loader: model.stateThumbnailLoader(for: state)) {
                        selected = selected?.id == state.id ? nil : state
                    }
                }
            }
            if let selected, states.contains(where: { $0.id == selected.id }) {
                actions(for: selected)
            }
        }
    }

    private var hue: SystemHue {
        gameID.flatMap { model.game($0) }.map { SystemAccent.hue(for: $0.systemID) } ?? .amber
    }

    private var cardWidth: CGFloat {
        #if os(tvOS)
        return 400
        #else
        return 180
        #endif
    }

    private var columns: [GridItem] {
        if dynamicType.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: RelaySpacing.m)]
        }
        return [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth * 1.4), spacing: RelaySpacing.m)]
    }

    private func subtitle(for state: SaveState, index: Int, in states: [SaveState]) -> String {
        let time = Formatting.relative(state.createdAt)
        if state.kind == .quick, index > 0, state.origin == .local { return L("Previous quick save · \(time)") }
        let device = state.origin == .remote ? Formatting.deviceName(state.deviceKind) : Formatting.deviceName(model.deviceKind)
        return L("\(device) · \(time)")
    }

    /// Previous versions of the in-game save (CONTINUITY_UX §8): the losing side of a
    /// Two versions choice and older progress, restorable without rewriting history.
    private var previousVersionsGroup: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            Text("Previous versions", bundle: .module).font(.relayShelfTitle).foregroundStyle(RelayColor.textPrimary).accessibilityAddTraits(.isHeader)
            Text("Older in-game saves, including versions you didn't keep. Restoring one keeps your current progress as a version too.", bundle: .module)
                .font(.relayCallout).foregroundStyle(RelayColor.textTertiary)
            ForEach(previousVersions.prefix(10)) { revision in
                let device = revision.installationID == model.environment.identity?.installationID ? Formatting.deviceName(model.deviceKind) : Formatting.deviceName(revision.deviceKind)
                AdaptiveActionRow {
                    HStack(alignment: .firstTextBaseline, spacing: RelaySpacing.s) {
                        Formatting.deviceSymbol(revision.installationID == model.environment.identity?.installationID ? model.deviceKind : revision.deviceKind).image
                            .foregroundStyle(RelayColor.textSecondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: RelaySpacing.xxs) {
                            Text(L("\(device) · \(Formatting.relative(revision.createdAt))")).font(.relayMeta).foregroundStyle(RelayColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Formatting.bytes(revision.sizeInBytes)).font(.relayStatus).foregroundStyle(RelayColor.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if context != .inGame {
                        Button { confirmRestore = revision } label: { Text("Restore", bundle: .module) }.buttonStyle(.quiet)
                    }
                }
                .padding(RelaySpacing.s)
                .background(RelayColor.surface, in: RoundedRectangle(cornerRadius: RelayRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: RelayRadius.card, style: .continuous).strokeBorder(RelayColor.separator))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func isCompatible(_ state: SaveState) -> Bool {
        guard let core = runningCore else { return false }
        return state.isRestorable(by: core)
    }

    @ViewBuilder
    private func actions(for state: SaveState) -> some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            if !isCompatible(state) {
                ProblemCard(tone: .caution,
                            headline: L("This save was made with an older version of Relay and can't be loaded safely."),
                            message: L("Your in-game save is still available."))
            }
            AdaptiveActionRow {
                Button { Task { await load(state) } } label: {
                    Label { Text("Load", bundle: .module) } icon: { RelaySymbol.play.image }
                }
                .buttonStyle(.ember)
                .relayScrollToKeyboardFocus()
                .disabled(!isCompatible(state) || (context == .inGame && !play.canLoadStates))
                if state.kind == .manual {
                    Button(role: .destructive) { confirmDelete = state } label: {
                        Label { Text("Delete", bundle: .module) } icon: { RelaySymbol.delete.image }
                            .foregroundStyle(RelayColor.critical)
                    }
                    .buttonStyle(.quiet)
                    .relayScrollToKeyboardFocus()
                }
            }
        }
    }

    private func reload() async {
        switch context {
        case .inGame:
            await play.refreshSaves()
            quick = play.quickStates
            manual = play.manualStates
        case .library(let id):
            let browser = await model.browserStates(for: id)
            quick = browser.quick
            manual = browser.manual
            previousVersions = await model.previousVersions(for: id)
        }
        loaded = true
        if let selected, !(quick + manual).contains(where: { $0.id == selected.id }) { self.selected = nil }
    }

    private func load(_ state: SaveState) async {
        switch context {
        case .inGame:
            guard play.canLoadStates else { return }
            let previousProblemID = play.problem?.id
            await play.load(state)
            if play.problem?.id == previousProblemID { dismiss(); play.resume() }
        case .library:
            guard let requestLibraryLoad else { return }
            requestLibraryLoad(state)
            dismiss()
        }
    }

    private func delete(_ state: SaveState) async {
        switch context {
        case .inGame: await play.delete(state)
        case .library: await model.deleteState(state)
        }
        confirmDelete = nil
        await reload()
    }
}

/// One save (§11): 16:10 screenshot, kind + time, caution badge when incompatible.
struct SaveCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let state: SaveState
    let subtitle: String
    let hue: SystemHue
    let compatible: Bool
    let selected: Bool
    let loader: ArtworkLoader?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                ZStack {
                    RelayColor.ink
                    ArtworkView(ArtworkModel(title: "", systemName: "", hue: hue, loader: loader), fit: .contain, cornerRadius: 0, showsTitleWhenEmpty: false)
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: RelayRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: RelayRadius.card, style: .continuous)
                    .strokeBorder(selected ? RelayColor.ember : RelayColor.separator, lineWidth: selected ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    if !compatible {
                        RelaySymbol.caution.image.foregroundStyle(RelayColor.caution).padding(RelaySpacing.xs).accessibilityHidden(true)
                    }
                }
                Text(kindName).font(.relayCardTitle).foregroundStyle(RelayColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.relayStatus).foregroundStyle(RelayColor.textSecondary)
                    .lineLimit(dynamicType.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(compatible ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.relayCard)
        .relayScrollToKeyboardFocus()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compatible
            ? Text("\(kindName), \(subtitle)", bundle: .module)
            : Text("\(kindName), \(subtitle), can't be loaded", bundle: .module))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var kindName: String {
        if state.label == "relay.preCheatSafety" { return L("Before cheats") }
        switch state.kind {
        case .auto: return L("Auto")
        case .quick: return L("Quick")
        case .manual: return L("Manual")
        }
    }
}

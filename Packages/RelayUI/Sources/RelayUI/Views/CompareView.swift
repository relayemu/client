// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CompareView.swift
//  RelayUI — "Two versions" (CONTINUITY_UX §8): two large cards, device kind,
//  time, play context and the last screenshot of each version; one Ember
//  "Keep This One" under each. Relay never merges saves and never picks
//  silently; the other version stays in Previous versions. Fully operable by
//  focus/controller (tvOS) and VoiceOver; no gesture needs precision.

import SwiftUI
import RelayDomain
import RelayLibrary
import RelayDesignSystem

struct CompareView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    let gameID: GameID
    @State private var conflict: BatteryConflict?
    @State private var loaded = false
    @State private var keeping: BatteryRevisionID?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: RelaySpacing.l) {
                        RelayInlineOperationProblem(source: .storage)
                            .id(RelayInlineOperationProblem.scrollID)
                        if let game = model.game(gameID) {
                            // The drawing states the situation — two versions, a choice to
                            // make — and stops there. Nothing about losing progress is ever
                            // illustrated as a joke (BRAND_IDENTITY.md, "What is not Relay").
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: RelaySpacing.m) {
                                    PenSceneView(.twoVersions, width: 150)
                                    introduction(game).frame(minWidth: 280)
                                }
                                VStack(alignment: .leading, spacing: RelaySpacing.m) {
                                    PenSceneView(.twoVersions, width: 150)
                                    introduction(game)
                                }
                            }
                        }
                        if let conflict {
                            if dynamicType.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: RelaySpacing.m) { cards(conflict) }
                            } else {
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .top, spacing: RelaySpacing.m) { cards(conflict) }
                                    VStack(alignment: .leading, spacing: RelaySpacing.m) { cards(conflict) }
                                }
                            }
                            Text("The other version stays in Previous versions. Nothing is deleted.", bundle: .module)
                                .font(.relayCallout)
                                .foregroundStyle(RelayColor.textTertiary)
                        } else if loaded {
                            EmptyState(symbol: .positive, title: L("Nothing to compare."), message: L("This game has one version again."))
                        }
                    }
                    .padding(RelaySpacing.layout.screenMargin)
                }
                .relayKeyboardScrollContainer()
                .onChange(of: model.loadError?.id) { _, id in
                    guard id != nil else { return }
                    proxy.scrollTo(RelayInlineOperationProblem.scrollID, anchor: .top)
                }
            }
            .relayCanvas()
            .navigationTitle(Text("Two versions", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Not Now", bundle: .module) }
                        .accessibilityIdentifier("sync.conflict.cancel")
                }
            }
            .task { conflict = await model.conflict(for: gameID); loaded = true }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }

    private func introduction(_ game: Game) -> some View {
        Text("You played \(game.title) on two devices while they were out of sync. Choose which progress to keep.", bundle: .module)
            .font(.relayBody)
            .foregroundStyle(RelayColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cards(_ conflict: BatteryConflict) -> some View {
        ForEach(Array(conflict.heads.enumerated()), id: \.element.id) { index, head in
            VersionCard(revision: head, versionNumber: index + 1, hue: hue, session: session(for: head), isLocal: head.installationID == model.environment.identity?.installationID,
                        thisDevice: model.deviceKind, loader: model.revisionScreenshotLoader(for: head), busy: keeping != nil) {
                Task { await keep(head) }
            }
        }
    }

    private var hue: SystemHue {
        model.game(gameID).map { SystemAccent.hue(for: $0.systemID) } ?? .amber
    }

    /// The last session from the version's installation, for play context.
    private func session(for head: BatteryRevision) -> PlaySession? {
        let latest = model.history[gameID]?.latestSession
        return latest?.installationID == head.installationID ? latest : nil
    }

    private func keep(_ head: BatteryRevision) async {
        keeping = head.id
        if await model.resolveConflict(gameID: gameID, keeping: head.id) {
            dismiss()
        } else {
            keeping = nil
        }
    }
}

struct VersionCard: View {
    let revision: BatteryRevision
    let versionNumber: Int
    let hue: SystemHue
    let session: PlaySession?
    let isLocal: Bool
    let thisDevice: DeviceKind
    let loader: ArtworkLoader?
    let busy: Bool
    let keep: () -> Void

    private var deviceKind: DeviceKind { isLocal ? thisDevice : revision.deviceKind }
    private var deviceName: String { isLocal ? Formatting.thisDevice(thisDevice) : Formatting.deviceName(deviceKind) }

    /// Buttons-rotor navigation must identify the choice without relying on the
    /// preceding card's text or on an image. Numbering also distinguishes two
    /// versions from the same kind of device saved at the same time.
    static func keepLabel(version: Int, deviceName: String, savedAt: Date) -> String {
        let saved = savedAt.formatted(date: .abbreviated, time: .standard)
        return L("Keep version \(version): \(deviceName), saved \(saved)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            ZStack {
                RelayColor.ink
                ArtworkView(ArtworkModel(title: "", systemName: "", hue: hue, loader: loader), fit: .contain, cornerRadius: 0, showsTitleWhenEmpty: false)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: RelayRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RelayRadius.card, style: .continuous).strokeBorder(RelayColor.separator))
            .accessibilityHidden(true)
            HStack(spacing: RelaySpacing.xs) {
                Formatting.deviceSymbol(deviceKind).image.foregroundStyle(RelayColor.textSecondary).accessibilityHidden(true)
                Text(isLocal ? Formatting.thisDevice(thisDevice).capitalizedFirst : Formatting.deviceName(deviceKind))
                    .font(.relayCardTitle).foregroundStyle(RelayColor.textPrimary)
            }
            Text(L("Saved \(Formatting.relative(revision.createdAt))"))
                .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
            if let session, let duration = session.duration {
                Text(L("Last session \(Formatting.playDuration(duration))"))
                    .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
            }
            Button(action: keep) {
                Text("Keep This One", bundle: .module).frame(maxWidth: .infinity)
            }
            .buttonStyle(.ember)
            .relayScrollToKeyboardFocus()
            .accessibilityLabel(Text(Self.keepLabel(version: versionNumber, deviceName: deviceName, savedAt: revision.createdAt)))
            .accessibilityHint(Text("The other version stays in Previous versions. Nothing is deleted.", bundle: .module))
            .accessibilityIdentifier("sync.conflict.keep." + revision.id.description)
            .disabled(busy)
        }
        .padding(RelaySpacing.m)
        .frame(minWidth: minimumWidth, maxWidth: .infinity, alignment: .leading)
        .background(RelayColor.surface, in: RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous).strokeBorder(RelayColor.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(isLocal ? Formatting.thisDevice(thisDevice) : Formatting.deviceName(deviceKind)), \(L("Saved \(Formatting.relative(revision.createdAt))"))", bundle: .module))
    }

    private var minimumWidth: CGFloat {
        #if os(tvOS)
        return 400
        #else
        return 240
        #endif
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

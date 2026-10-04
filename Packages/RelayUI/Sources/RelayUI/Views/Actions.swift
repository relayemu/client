// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Actions.swift
//  RelayUI — app-level actions views can trigger (import picker, sheets, settings)
//  without knowing which shell hosts them.

import SwiftUI
import Observation
import RelayDomain
import RelayDesignSystem
import RelayEntitlements

@MainActor
@Observable
public final class RelayActions {
    public enum Presentation: Equatable {
        case onboarding, formats, settings, diagnostics, pro, compare, transfer
        case playSaves, librarySaves, playTool
    }

    /// A reservation lasts until native dismissal completes, including the
    /// interval after SwiftUI has set the presenting binding to false.
    public private(set) var activePresentation: Presentation?
    public private(set) var acknowledgedStorageErrorID: UUID?
    public private(set) var acknowledgedPlayErrorID: UUID?

    public var importPickerPresented = false
    public var transferPresented = false
    public var formatsSheetPresented = false
    public var settingsPresented = false
    public var diagnosticsPresented = false
    /// Product presentation plus a Debug direct-screen seam for visual review.
    public var relayProPresented = false
    public var relayProFeature: RelayProFeature?
    /// The in-game Saves browser (pause overlay ▸ Load State, Game ▸ Load State… on macOS).
    public var playSavesPresented = false
    /// The Two versions chooser for a game (CONTINUITY_UX §8).
    public var compareGameID: GameID?
    /// Debug/verification only: shells select this destination on appear.
    public var debugInitialDestination: Destination?
    /// Debug/verification only: shells push this route once set.
    public var debugInitialRoute: Route?


    /// The onboarding cover is up.
    public var onboardingPresented = false
    /// Verification runs and UI tests drive the product straight to a screen;
    /// they never want the cover. Set by the app's Debug hooks, never by views.
    public var onboardingSuppressed = false
    /// Show the current onboarding on this launch whatever the record says
    /// (Debug `--relay-onboarding`, and the screenshots of every first launch).
    public var onboardingForced = false
    /// Deferred until the cover is gone: a picker cannot open over it.
    private var importAfterOnboarding = false
    private var onboardingAfterSettings = false

    public init() {}

    public var canPresentRelaySurface: Bool {
        activePresentation == nil && !importPickerPresented && !onboardingPresented && !formatsSheetPresented
            && !settingsPresented && !diagnosticsPresented && !relayProPresented
            && !playSavesPresented && !transferPresented && compareGameID == nil
    }

    @discardableResult
    public func beginPresentation(_ presentation: Presentation) -> Bool {
        guard canPresentRelaySurface else { return false }
        activePresentation = presentation
        return true
    }

    public func presentationDidDismiss(_ presentation: Presentation) {
        guard activePresentation == presentation else { return }
        activePresentation = nil
    }

    /// Acknowledging the visible product message retains the model's error and
    /// diagnostic detail. A later failure has a new identity and remains visible.
    func acknowledgeStorageError(_ id: UUID) { acknowledgedStorageErrorID = id }
    func acknowledgePlayError(_ id: UUID) { acknowledgedPlayErrorID = id }

    /// Decides once the library is open whether this launch is a first run.
    public func presentOnboardingIfNeeded(state: OnboardingState = OnboardingState()) {
        if onboardingForced || (!onboardingSuppressed && state.needsOnboarding) {
            guard beginPresentation(.onboarding) else { return }
            onboardingPresented = true
        }
    }

    /// Settings ▸ Help ▸ Getting Started: the same experience, on request.
    public func replayOnboarding() {
        if settingsPresented {
            onboardingAfterSettings = true
            settingsPresented = false
        } else {
            guard beginPresentation(.onboarding) else { return }
            onboardingPresented = true
        }
    }

    /// Wait for the Settings sheet to leave before opening the first-run cover.
    public func settingsDidDismiss() {
        presentationDidDismiss(.settings)
        guard onboardingAfterSettings else { return }
        onboardingAfterSettings = false
        guard beginPresentation(.onboarding) else { return }
        onboardingPresented = true
    }

    /// The player is through (or skipped): record it, close the cover, and if
    /// they chose their games, open the real import once the cover has gone.
    public func completeOnboarding(thenImport: Bool = false, state: OnboardingState = OnboardingState()) {
        state.complete()
        onboardingForced = false
        importAfterOnboarding = thenImport
        onboardingPresented = false
    }

    /// Called by the root when the cover has actually been dismissed.
    public func onboardingDidDismiss() {
        presentationDidDismiss(.onboarding)
        guard importAfterOnboarding else { return }
        importAfterOnboarding = false
        importFiles()
    }

    public func importFiles() {
        guard canPresentRelaySurface else { return }
        importPickerPresented = true
    }
    public func fromComputer() {
        guard beginPresentation(.transfer) else { return }
        transferPresented = true
    }
    public func whichFormats() {
        guard beginPresentation(.formats) else { return }
        formatsSheetPresented = true
    }
    public func openSettings() {
        guard beginPresentation(.settings) else { return }
        settingsPresented = true
    }
    public func openDiagnostics() {
        guard beginPresentation(.diagnostics) else { return }
        diagnosticsPresented = true
    }
    public func openPlaySaves() {
        guard beginPresentation(.playSaves) else { return }
        playSavesPresented = true
    }
    public func openRelayPro(feature: RelayProFeature? = nil) {
        guard beginPresentation(.pro) else { return }
        relayProFeature = feature
        relayProPresented = true
    }
    public func compare(_ gameID: GameID) {
        guard beginPresentation(.compare) else { return }
        compareGameID = gameID
    }

    /// Opens the system iCloud storage settings where the platform allows; elsewhere the settings sheet explains.
    public func manageStorage() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?iCloud") { NSWorkspace.shared.open(url) }
        #else
        openSettings()
        #endif
    }

    /// Opens the system settings (iCloud sign-in) where the platform allows.
    public func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") { NSWorkspace.shared.open(url) }
        #else
        openSettings()
        #endif
    }

    func primary(for action: ProductMessage.Action, model: LibraryModel) -> (title: String, action: () -> Void)? {
        switch action {
        case .importFiles, .tryAgain: return (L("Import Files"), { self.importFiles() })
        case .whichFormats: return (L("Which formats work?"), { self.whichFormats() })
        case .showDiagnostics: return (L("Show Diagnostics"), { self.openDiagnostics() })
        case .close: return nil
        case .downloadAndPlay(let id): return (L("Download & Play"), { Task { await model.downloadAndPlay(id) } })
        case .manageStorage:
            if model.sync.selectedProvider == .relaySync { return (L("Open Sync Settings"), { self.openSettings() }) }
            return (L("Manage iCloud Storage"), { self.manageStorage() })
        case .openSettings: return (L("Open Settings"), { self.openSystemSettings() })
        case .compare(let id): return (L("Compare"), { self.compare(id) })
        case .howToAdd: return (L("How to Add"), { self.whichFormats() })
        case .syncWithThisAccount: return (L("Sync with this account"), { Task { await model.environment.sync.acceptAccountChange() } })
        case .relayPro: return (L("View Relay Pro"), { self.openRelayPro() })
        }
    }
}

/// An operation's active destination shows its failure in place. Ancestor
/// alerts defer while that destination owns the presentation. Only an explicit
/// Close acknowledges the identity; dismissing the destination keeps the fallback
/// alert available if the player has not acknowledged its failure.
struct RelayInlineOperationProblem: View {
    static let scrollID = "relay.inlineOperationProblem"
    enum Source: Equatable { case play, storage }
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    let source: Source
    @State private var message: ProductMessage?

    private var current: ProductMessage? {
        source == .play ? model.play.problem : model.loadError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            if let message {
                ProblemCard(tone: message.isCritical ? .critical : .caution,
                            headline: message.headline, message: message.message)
                Button {
                    acknowledge(message.id)
                    self.message = nil
                } label: { Text("Close", bundle: .module) }
                    .buttonStyle(.quiet)
            }
        }
        .onChange(of: current?.id, initial: true) { _, _ in
            let acknowledged = source == .play ? actions.acknowledgedPlayErrorID : actions.acknowledgedStorageErrorID
            guard let current, current.id != acknowledged else { return }
            message = current
        }
    }

    private func acknowledge(_ id: UUID) {
        if source == .play { actions.acknowledgePlayError(id) }
        else { actions.acknowledgeStorageError(id) }
    }
}

/// Save loading from the library is a transfer out of the Saves sheet. Taking
/// the request happens only in the presenter's native onDismiss callback.
struct RelayDeferredSaveLaunch {
    private var requestedState: SaveState?

    mutating func request(_ state: SaveState) { requestedState = state }

    mutating func takeAfterDismissal() -> SaveState? {
        defer { requestedState = nil }
        return requestedState
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncModel.swift
//  RelayUI
//
//  The observable face of RelaySync for the screens: status, per-game cloud
//  switches, the account-change decision and the on-demand content actions.
//  Views never touch the coordinator, the transport or any CloudKit type.

import Foundation
import Observation
import RelayDomain
import RelayLibrary
import RelaySync

/// What Home's single ProblemCard shows, in priority order (CONTINUITY_UX §5).
public enum ContinuityProblem: Equatable, Sendable {
    case twoVersions(GameID)
    case quotaFull
    case pendingTooLong(count: Int)
    case accountChanged
    case cloudOff
}

@MainActor
@Observable
public final class SyncModel {
    public private(set) var status = SyncStatus()
    public private(set) var gameStatuses: [GameID: GameCloudStatus] = [:]
    /// Content fingerprints known to be in iCloud (Remove Download keeps the game playable elsewhere).
    public private(set) var cloudContent: Set<ContentFingerprint> = []
    /// Two-second "Updating…" line under the Home title while remote changes apply.
    public private(set) var isUpdating = false
    public private(set) var lastAppliedAt: Date?
    /// Toast requests for the shell ("Saves are up to date" after a quota problem cleared).
    public private(set) var toast: String?

    private var coordinator: SyncCoordinator?
    private var subscription: Task<Void, Never>?
    private var updatingTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var providerFactory: (@MainActor (SyncProviderSelection) -> (any SyncTransport)?)?
    public private(set) var availableProviders: [SyncProviderSelection] = [.off]
    public private(set) var isSwitchingProvider = false
    private var providerChanges = 0
    private var cloudCapabilities: SyncCapabilities = .gameFilesSupported
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var dismissedPendingSince: Date?
    private var dismissedQuota = false
    private var dismissedConflicts: Set<GameID> = []
    private var hadQuotaProblem = false
    /// Games whose content is present on this device (fed by the library model).
    private var contentPresence: [GameID: Bool] = [:]

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    public var isAvailable: Bool { coordinator != nil }

    /// Observation is attached before the asynchronous transport startup. A slow
    /// account or network never holds the managed library open.
    func attach(_ coordinator: SyncCoordinator,
                availableProviders: [SyncProviderSelection],
                cloudCapabilities: SyncCapabilities,
                factory: @escaping @MainActor (SyncProviderSelection) -> (any SyncTransport)?) async {
        self.availableProviders = availableProviders
        self.cloudCapabilities = cloudCapabilities
        providerFactory = factory
        self.coordinator = coordinator
        subscription?.cancel()
        let stream = await coordinator.statusStream()
        subscription = Task { [weak self] in
            for await status in stream {
                guard let self else { return }
                await self.receive(status)
            }
        }
        startupTask = Task { [weak self] in
            guard let self else { return }
            let saved = await coordinator.savedProviderSelection()
            // A saved preproduction selection remains Off in builds that cannot
            // offer it. Never silently send that library to another provider.
            let selected = availableProviders.contains(saved) ? saved : .off
            await self.selectProvider(selected)
        }
    }

    /// Deterministic test/support seam; normal library and gameplay paths never await this.
    func waitForStartup() async { await startupTask?.value }

    public var selectedProvider: SyncProviderSelection { status.provider }

    public func selectProvider(_ selection: SyncProviderSelection) async {
        guard availableProviders.contains(selection), let coordinator else { return }
        providerChanges += 1
        isSwitchingProvider = true
        defer { providerChanges -= 1; isSwitchingProvider = providerChanges > 0 }
        await coordinator.selectProvider(selection, transport: providerFactory?(selection),
                                         capabilities: selection == .relaySync ? .hostedGameFilesSupported : cloudCapabilities)
        await refreshStatus()
    }

    /// Called after sign-in/out: reconnect only if Relay Sync is the selected
    /// provider. Signing in is never consent to switch or upload game files.
    public func relayAccountDidChange() async {
        // Keychain restore can finish before persisted provider selection loads.
        // Reconnect after that selection so a restored session cannot be missed.
        await startupTask?.value
        guard selectedProvider == .relaySync else { return }
        await selectProvider(.relaySync)
    }

    private func receive(_ new: SyncStatus) async {
        let previous = status
        status = new
        if new.isApplying, !previous.isApplying { showUpdating() }
        if new.lastPullAt != previous.lastPullAt { lastAppliedAt = new.lastPullAt }
        if previous.problem == .quotaFull { hadQuotaProblem = true }
        if hadQuotaProblem, new.problem == nil, new.pendingCount == 0 {
            hadQuotaProblem = false
            dismissedQuota = false
            toast = L("Saves are up to date")
        }
        if new.problem != .quotaFull { dismissedQuota = false }
        if new.pendingCount == 0 { dismissedPendingSince = nil }
        await refreshGameStatuses()
    }

    private func showUpdating() {
        isUpdating = true
        updatingTask?.cancel()
        updatingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.isUpdating = false
        }
    }

    public func clearToast() { toast = nil }

    // MARK: Per-game status

    /// Called by the library model after every refresh.
    func updateLibrary(games: [Game], contentPresence: [GameID: Bool]) async {
        self.contentPresence = contentPresence
        await refreshGameStatuses(games: games)
    }

    private var knownGames: [Game] = []

    private func refreshGameStatuses(games: [Game]? = nil) async {
        if let games { knownGames = games }
        guard let coordinator else { gameStatuses = [:]; return }
        var statuses: [GameID: GameCloudStatus] = [:]
        for game in knownGames {
            statuses[game.id] = await coordinator.gameStatus(game, hasLocalContent: contentPresence[game.id] ?? true)
        }
        gameStatuses = statuses
        cloudContent = await coordinator.cloudContentFingerprints()
    }

    public func gameStatus(_ id: GameID) -> GameCloudStatus {
        gameStatuses[id] ?? (status.isEnabled && isAvailable ? .upToDate : .localOnly)
    }

    public func isInConflict(_ id: GameID) -> Bool { status.conflictGameIDs.contains(id) }

    public func conflict(for id: GameID) async -> BatteryConflict? {
        await coordinator?.conflict(for: id)
    }

    // MARK: Home problem card

    /// The one problem Home shows, or nil when everything is quiet.
    public var problem: ContinuityProblem? {
        guard isAvailable else { return nil }
        if let conflict = status.conflictGameIDs.first(where: { !dismissedConflicts.contains($0) }) { return .twoVersions(conflict) }
        if status.problem == .quotaFull, !dismissedQuota { return .quotaFull }
        if status.isEnabled, status.pendingCount > 0, status.account == .available, status.problem != .network,
           let since = status.pendingSince, now().timeIntervalSince(since) > 10 * 60, dismissedPendingSince != since {
            return .pendingTooLong(count: status.pendingCount)
        }
        if status.accountChangePending { return .accountChanged }
        if selectedProvider == .iCloud, status.isEnabled, status.account == .noAccount || status.account == .restricted, !defaults.bool(forKey: Self.cloudOffShownKey) { return .cloudOff }
        return nil
    }

    private static let cloudOffShownKey = "relay.sync.cloudOffCardShown"

    public func dismiss(_ problem: ContinuityProblem) {
        switch problem {
        case .twoVersions(let id): dismissedConflicts.insert(id)
        case .quotaFull: dismissedQuota = true
        case .pendingTooLong: dismissedPendingSince = status.pendingSince
        case .accountChanged: Task { await declineAccountChange() }
        case .cloudOff: defaults.set(true, forKey: Self.cloudOffShownKey)
        }
    }

    // MARK: Settings and actions

    public func setEnabled(_ enabled: Bool) async {
        await coordinator?.setEnabled(enabled)
        if enabled { defaults.set(false, forKey: Self.cloudOffShownKey) }
        await refreshStatus()
    }

    public func setGameFilesEnabled(_ enabled: Bool) async {
        await coordinator?.setGameFilesEnabled(enabled)
        await refreshStatus()
    }

    /// Updates a transport/build capability without touching the user's opt-in.
    /// Commerce never participates in iCloud synchronization.
    public func setCapabilities(_ capabilities: SyncCapabilities) async {
        await coordinator?.setCapabilities(capabilities)
        await refreshStatus()
    }

    public func acceptAccountChange() async {
        await coordinator?.acceptAccountChange()
        await refreshStatus()
    }

    public func declineAccountChange() async {
        await coordinator?.declineAccountChange()
        await refreshStatus()
    }

    /// Pulls the coordinator's current status without waiting for the stream (after an action).
    private func refreshStatus() async {
        guard let coordinator else { return }
        await receive(await coordinator.status)
    }

    public func requestSync() async {
        await coordinator?.requestSync(reason: .manual)
    }

    /// The app came to the foreground: this is where Relay synchronizes eagerly.
    public func appDidBecomeActive() async {
        await coordinator?.appDidBecomeActive()
    }

    /// Imperceptible grace used at launch, and only when a fetch is already in
    /// flight. Relay never starts a fetch to launch a game (owner policy).
    func graceForInFlightFetch() async {
        guard status.isFetching else { return }
        await coordinator?.graceForInFlightFetch()
    }

    func gameplay(active gameID: GameID?) async {
        await coordinator?.setGameplayActive(gameID)
    }

    func flushSoon() async {
        await coordinator?.flushSoon()
    }

    func resolve(gameID: GameID, keeping revisionID: BatteryRevisionID) async throws {
        try await coordinator?.resolveConflict(gameID: gameID, keeping: revisionID)
        dismissedConflicts.remove(gameID)
    }

    func refreshConflicts() async {
        await coordinator?.refreshConflicts()
    }

    func download(gameID: GameID, ingestion: GameIngestion) async throws -> GameFile? {
        guard let coordinator else { return nil }
        return try await coordinator.downloadContent(gameID: gameID, ingestion: ingestion)
    }

    func upload(gameID: GameID) async {
        try? await coordinator?.uploadContent(gameID: gameID)
    }

    public func transfer(for gameID: GameID) async -> ContentTransfer? {
        await coordinator?.transfer(for: gameID)
    }

    // MARK: Diagnostics

    public func pendingEntries() async -> [SyncJournalEntry] {
        await coordinator?.pendingEntries() ?? []
    }

    public func deferredCount() async -> Int {
        await coordinator?.deferredCount() ?? 0
    }

    public var installationIdentifier: String? {
        get async { await coordinator?.identity.installationID.description }
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import RelayDomain
import RelayAchievementInterfaces

@MainActor @Observable
public final class AchievementsModel {
    public private(set) var account: AchievementAccountState = .disconnected
    public private(set) var lastError: AchievementServiceError?
    public private(set) var games: [GameID: AchievementGame] = [:]
    public private(set) var gameStates: [GameID: AchievementGameState] = [:]
    public private(set) var pendingUnlockCount = 0
    public private(set) var activeGameID: GameID?
    public private(set) var notification: Achievement?
    public private(set) var activationNotice = false
    public private(set) var deliveryUnavailable = false
    public private(set) var isDisconnecting = false
    public let hardcoreAvailable: Bool
    public private(set) var preferredMode: AchievementMode
    public private(set) var activeMode: AchievementMode = .casual
    public private(set) var challenges: [Achievement] = []
    public private(set) var measuredProgress: Achievement?
    public private(set) var leaderboardResult: AchievementLeaderboardResult?
    public private(set) var resetRequired = false
    @ObservationIgnored private let preferences: UserDefaults
    public var isConnected: Bool { if case .connected = account { return true }; return false }
    public var hasAccount: Bool { credentials != nil }
    public var username: String? { credentials?.username }

    @ObservationIgnored private let vault: AchievementVault
    @ObservationIgnored private let transport: any AchievementHTTPTransport
    @ObservationIgnored private let cache: AchievementSnapshotCache
    @ObservationIgnored private let userAgent: String
    @ObservationIgnored private var credentials: AchievementCredentials?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var cacheGeneration: UUID?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var activeOperation = UUID()
    @ObservationIgnored private var activeRuntime: RcheevosRuntime?
    @ObservationIgnored private var authenticationRuntime: RcheevosRuntime?
    @ObservationIgnored private var activeSlot: AchievementRuntimeSlot?
    @ObservationIgnored private var activeROM: (SystemID, URL)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var queuedNotifications: [Achievement] = []
    @ObservationIgnored private var lastRetry = Date.distantPast
    @ObservationIgnored private var retrying = false

    public init(store: any AchievementSecureStore = AchievementKeychainStore(),
                transport: any AchievementHTTPTransport = AchievementURLSessionTransport(),
                cacheDirectory: URL? = nil, userAgent: String? = nil,
                hardcoreValidated: Bool = AchievementClientValidation.isCurrentVersionApproved,
                preferences: UserDefaults = .standard) {
        self.hardcoreAvailable = hardcoreValidated
        self.preferences = preferences
        self.preferredMode = hardcoreValidated && preferences.bool(forKey: "relay.achievements.hardcore") ? .hardcore : .casual
        self.vault = AchievementVault(store: store)
        self.transport = transport
        let folder = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay/RetroAchievements", isDirectory: true)
        self.cache = AchievementSnapshotCache(directory: folder)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        self.userAgent = userAgent ?? "Relay/\(version) rcheevos/12.4.0"
    }

    /// Call once at app startup, without awaiting it on any gameplay path.
    public func start() {
        guard !started else { return }
        started = true
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
        Task { [weak self] in await self?.restoreAccount() }
    }

    public func restoreAccount() async {
        guard !isDisconnecting else { return }
        let current = operation
        do {
            let saved = try await vault.credentials()
            let generation = await vault.currentGeneration()
            guard current == operation else { return }
            self.generation = generation
            guard let saved else { account = .disconnected; return }
            credentials = saved
            let cached = await cache.open(username: saved.username)
            guard current == operation else { return }
            cacheGeneration = cached.0; games = cached.1
            await authenticate(username: saved.username, token: saved.token, operation: current)
        } catch {
            guard current == operation else { return }
            account = .unavailable; lastError = .storage
        }
    }

    public func connect(username: String, password: String) async {
        guard !isDisconnecting else { return }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            lastError = .invalidCredentials; return
        }
        // A single connection attempt owns the UI. The view clears its secure
        // field before awaiting this call; the password is never persisted.
        operation = UUID()
        let current = operation
        authenticationRuntime?.close()
        activeOperation = UUID()
        activeRuntime?.close(); activeRuntime = nil
        activeSlot?.attach(nil)
        generation = await vault.currentGeneration()
        guard current == operation else { return }
        await authenticate(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, operation: current)
    }

    private func authenticate(username: String, password: String? = nil, token: String? = nil, operation current: UUID) async {
        guard let generation else { return }
        account = token == nil ? .connecting : .reconnecting(username)
        lastError = nil
        let runtime = makeRuntime(generation: generation)
        authenticationRuntime = runtime
        do {
            let connected = try await runtime.login(username: username, password: password, token: token)
            guard current == operation else { runtime.close(); return }
            try await vault.save(connected, generation: generation)
            guard current == operation else { runtime.close(); return }
            if credentials?.username.caseInsensitiveCompare(connected.username) != .orderedSame || cacheGeneration == nil {
                let cached = await cache.open(username: connected.username)
                guard current == operation else { runtime.close(); return }
                cacheGeneration = cached.0; games = cached.1
            }
            credentials = connected
            account = .connected(connected.username)
            lastError = nil
            await runtime.retryPersistedAwards(credentials: connected)
            guard current == operation else { runtime.close(); return }
            pendingUnlockCount = (try? await vault.pending(username: connected.username).count) ?? 0
            if let gameID = activeGameID, let (system, url) = activeROM,
               activeRuntime == nil, let slot = activeSlot {
                beginActiveGame(gameID: gameID, system: system, romURL: url, slot: slot)
            }
        } catch {
            guard current == operation else { runtime.close(); return }
            lastError = error as? AchievementServiceError ?? .unavailable
            account = .unavailable
        }
        runtime.close()
        if authenticationRuntime === runtime { authenticationRuntime = nil }
    }

    public func setPreferredMode(_ mode: AchievementMode) {
        guard mode != .hardcore || hardcoreAvailable else { return }
        preferredMode = mode
        preferences.set(mode == .hardcore, forKey: "relay.achievements.hardcore")
    }

    public func continueInCasual() {
        activeSlot?.disableHardcore()
        activeMode = .casual
    }

    public func disconnect() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true; defer { isDisconnecting = false }
        operation = UUID(); activeOperation = UUID()
        authenticationRuntime?.close(); authenticationRuntime = nil
        activeRuntime?.close(); activeRuntime = nil
        activeSlot?.disableHardcore()
        activeSlot?.attach(nil)
        activeMode = .casual
        credentials = nil
        generation = nil
        notificationTask?.cancel(); notificationTask = nil
        queuedNotifications = []; notification = nil; activationNotice = false
        games = [:]; gameStates = [:]; pendingUnlockCount = 0; deliveryUnavailable = false
        do { try await vault.disconnect(); account = .disconnected; lastError = nil }
        catch { account = .credentialRemovalFailed; lastError = .storage }
        await cache.clear(); cacheGeneration = nil
    }

    public func retry() async {
        guard !retrying, let credentials else { return }
        retrying = true; defer { retrying = false }
        lastRetry = Date()
        if !isConnected {
            await authenticate(username: credentials.username, token: credentials.token, operation: operation)
        } else if let gameID = activeGameID, let (system, url) = activeROM, let slot = activeSlot,
                  gameStates[gameID] == .unavailable {
            activeRuntime?.close(); activeRuntime = nil
            beginActiveGame(gameID: gameID, system: system, romURL: url, slot: slot)
        } else if let generation, pendingUnlockCount > 0 {
            let runtime = activeRuntime ?? makeRuntime(generation: generation)
            await runtime.retryPersistedAwards(credentials: credentials)
            if runtime !== activeRuntime { runtime.close() }
        }
    }

    /// Returns immediately. No login, hash, HTTP call or Keychain access is
    /// awaited by PlayModel, EmulationSession or the core's launch sequence.
    public func prepareForPlay(gameID: GameID, system: SystemID, romURL: URL, mode: AchievementMode? = nil) -> AchievementRuntimeSlot? {
        endPlay()
        guard AchievementSystem.isEligible(system) else { return nil }
        activeGameID = gameID; activeROM = (system, romURL)
        let selected = mode ?? preferredMode
        activeMode = hardcoreAvailable && hasAccount && selected == .hardcore ? .hardcore : .casual
        let slot = AchievementRuntimeSlot(mode: activeMode); activeSlot = slot
        if isConnected { beginActiveGame(gameID: gameID, system: system, romURL: romURL, slot: slot) }
        else { gameStates[gameID] = hasAccount ? .unavailable : .inactive }
        return slot
    }

    private func beginActiveGame(gameID: GameID, system: SystemID, romURL: URL, slot: AchievementRuntimeSlot) {
        guard let credentials, let generation else { return }
        activeOperation = UUID()
        let current = activeOperation
        let runtime = makeRuntime(generation: generation, mode: slot.hardcoreEnabled ? .hardcore : .casual)
        activeRuntime = runtime
        slot.attach(runtime)
        gameStates[gameID] = .loading
        Task { [weak self] in
            do {
                _ = try await runtime.login(username: credentials.username, token: credentials.token)
                await runtime.restorePendingUnlocks(username: credentials.username)
                guard let self, self.activeOperation == current else { runtime.close(); return }
                runtime.load(system: system, romURL: romURL) { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.activeOperation == current else { return }
                        self.receiveGame(result, gameID: gameID, announce: true)
                    }
                }
            } catch {
                guard let self, self.activeOperation == current else { runtime.close(); return }
                self.gameStates[gameID] = .unavailable
                self.activeRuntime = nil
                slot.attach(nil); runtime.close()
            }
        }
    }

    public func endPlay() {
        if let activeGameID, let snapshot = activeRuntime?.snapshot() { games[activeGameID] = snapshot; saveCache() }
        if let activeGameID, gameStates[activeGameID] == .active { gameStates[activeGameID] = .inactive }
        activeOperation = UUID()
        activeSlot?.attach(nil); activeSlot = nil
        activeRuntime?.close(); activeRuntime = nil
        activeGameID = nil; activeROM = nil
        activeMode = .casual; challenges = []; measuredProgress = nil; leaderboardResult = nil; resetRequired = false
        notificationTask?.cancel(); notificationTask = nil
        notification = nil; queuedNotifications = []; activationNotice = false
    }

    private func receiveGame(_ result: Result<AchievementGame, AchievementServiceError>, gameID: GameID, announce: Bool) {
        switch result {
        case .success(let game):
            games[gameID] = game
            gameStates[gameID] = game.achievements.isEmpty && game.leaderboards.isEmpty ? .unidentified : .active
            if announce && (!game.achievements.isEmpty || !game.leaderboards.isEmpty) { activationNotice = true }
            saveCache()
        case .failure(.cancelled): break
        case .failure(.unidentified): gameStates[gameID] = .unidentified
        case .failure(.unsupported): gameStates[gameID] = .unsupported
        case .failure: gameStates[gameID] = .unavailable
        }
    }

    public func dismissActivationNotice() { activationNotice = false }

    /// UI refresh / paused-client idle. The core drives evaluation independently
    /// at its actual frame rate; this timer never evaluates achievements.
    public func poll() async {
        activeRuntime?.idle()
        if let activeGameID, let runtime = activeRuntime {
            if let snapshot = runtime.snapshot() { games[activeGameID] = snapshot }
            let updates = runtime.takeEvents()
            challenges = updates.challenges.values.sorted { $0.id < $1.id }
            measuredProgress = updates.progress
            if let result = updates.leaderboardResult { leaderboardResult = result }
            resetRequired = updates.resetRequired
            deliveryUnavailable = updates.disconnected || updates.serverFailure
            if updates.storageFailure { lastError = .storage }
            if !updates.unlocks.isEmpty {
                queuedNotifications.append(contentsOf: updates.unlocks)
                presentNextNotification(); saveCache()
            }
        }
        if let credentials {
            pendingUnlockCount = (try? await vault.pending(username: credentials.username).count) ?? pendingUnlockCount
            if Date().timeIntervalSince(lastRetry) >= 30, lastError != .invalidCredentials {
                await retry()
            }
        }
    }

    private func presentNextNotification() {
        guard notification == nil, !queuedNotifications.isEmpty else { return }
        notification = queuedNotifications.removeFirst()
        notificationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.notification = nil; self.presentNextNotification()
        }
    }

    private func saveCache() {
        guard let cacheGeneration else { return }
        let snapshot = games
        Task { await cache.save(snapshot, generation: cacheGeneration) }
    }

    private func makeRuntime(generation: UUID, mode: AchievementMode = .casual) -> RcheevosRuntime {
        RcheevosRuntime(transport: transport, vault: vault, generation: generation, userAgent: userAgent, mode: mode)
    }
}

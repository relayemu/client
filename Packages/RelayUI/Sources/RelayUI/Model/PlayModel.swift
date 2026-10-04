// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  PlayModel.swift
//  RelayUI
//
//  The gameplay lifecycle behind PlayerView: launch with per-game save storage,
//  Continue (Auto Resume restore), pause/resume, quick save/load, manual
//  states, rewind, speed, display, controller and touch input, lifecycle
//  autosave, and the safe exit that writes progress before the library
//  reappears. Every action is gated by `EmulationSession` capabilities; nothing
//  here knows which core is running. Save writes go through RelayLibrary's
//  atomic managers off the main actor; the emulation thread is never blocked
//  by disk or database work.

import Foundation
import Observation
import OSLog
import CoreGraphics
import RelayDomain
import RelayLibrary
import RelayEmulation
import RelayVideo
import RelayInput
import RelayDesignSystem
import RelayEntitlements

let playLog = Logger(subsystem: "app.relayemu.relay", category: "emulator")

@MainActor
@Observable
public final class PlayModel {
    public struct Toast: Identifiable, Equatable {
        public let id = UUID()
        public let text: String
        public let symbol: RelaySymbol
        public let thumbnail: CGImage?
        public init(text: String, symbol: RelaySymbol, thumbnail: CGImage? = nil) {
            self.text = text
            self.symbol = symbol
            self.thumbnail = thumbnail
        }
        public static func == (l: Toast, r: Toast) -> Bool { l.id == r.id }
    }

    public enum Notice: Equatable, Sendable {
        case controllerDisconnected
    }

    // MARK: Observable state

    public private(set) var game: Game?
    public private(set) var core: EmulatorCoreDescriptor?
    /// The pause overlay is showing.
    public private(set) var isPaused = false
    public private(set) var isRewinding = false
    public private(set) var speed: EmulationSpeed = .normal
    public private(set) var controllerName: String?
    public private(set) var notice: Notice?
    public private(set) var toast: Toast?
    public private(set) var problem: ProductMessage?
    public private(set) var quickStates: [SaveState] = []
    public private(set) var manualStates: [SaveState] = []
    public private(set) var cheats: [CheatDefinition] = []
    /// Touch controls are hidden while a controller is connected unless the preference says otherwise (§6.2).
    public private(set) var touchControlsHidden = false
    public private(set) var lastAutoSaveFailed = false
    public var display: DisplayOptions = .standard {
        didSet { if let game, !applyingEffectivePreferences { preferences.setDisplayOptions(display, for: game.systemID) } }
    }
    /// Layout of a two-screen system; nil fits both pictures to the available
    /// game area. Explicit choices are remembered per system.
    public var screenArrangement: ScreenArrangement? {
        didSet { if let game, !applyingEffectivePreferences { preferences.setScreenArrangement(screenArrangement, for: game.systemID) } }
    }
    /// The running system's screens, from the catalog; one for most systems.
    public var screens: [LogicalScreen] {
        game.flatMap { SystemCatalog.descriptor(for: $0.systemID)?.screens } ?? []
    }
    public var hasMultipleScreens: Bool { session.screenFrameSources.count > 1 }

    // MARK: Capabilities (what the UI may show)

    public var hardcoreEnabled: Bool { session.hardcoreEnabled }
    public var canLoadStates: Bool { session.supportsStateLoading }
    public var canSaveStates: Bool { session.supportsSaveStates }
    public var canRewind: Bool { session.supportsRewind }
    public var canFastForward: Bool { session.supportsFastForward }
    public var canUseCheats: Bool { session.supportsCheats }
    public var supportedCheatFormats: Set<CheatFormat> { session.supportedCheatFormats }
    public var hasRewindHistory: Bool { (session.rewindStatistics?.entries ?? 0) > 0 }
    public var accessPolicy: RelayAccessPolicy { RelayAccessPolicy(entitlement: entitlement) }
    public var availableSpeeds: [EmulationSpeed] {
        let allowed = accessPolicy.allows(.advancedSpeeds)
            ? session.supportedSpeeds
            : session.supportedSpeeds.intersection([.normal, .double])
        return EmulationSpeed.allCases.filter(allowed.contains)
    }
    public var effectiveRewindDuration: TimeInterval {
        preferences.rewindConfiguration(policy: accessPolicy).duration
    }

    // MARK: Dependencies

    let sharing = GameplaySharing()
    private var sceneIsActive = true
    private var resumeForClipWhenActive = false

    #if DEBUG
    public var sharingDiagnosticState: String { String(describing: sharing.state) }
    #endif

    func startSharingClip() async {
        guard game != nil, isPaused, speed == .normal else { return }
        let started = await sharing.startClip(sources: session.screenFrameSources, screens: screens,
                                             arrangement: screenArrangement,
                                             limits: GameplayClipLimits(policy: accessPolicy))
        guard started, game != nil else { return }
        if sceneIsActive { resume() } else { resumeForClipWhenActive = true }
    }

    public let session: EmulationSession
    public let preferences: PlayPreferences
    private let environment: LibraryEnvironment
    private let now: @Sendable () -> Date
    private var currentLaunch: ResolvedLaunch?
    private var input: GameControllerInputBridge?
    private var batteryTimer: Timer?
    private var batteryCheckpoint: Task<Error?, Never>?
    private var rewindTimer: Timer?
    private var toastTask: Task<Void, Never>?
    /// Start of the open "not playing" interval, if the game is not running now.
    private var inactiveSince: Date?
    private var wasRunningBeforeInactive = false
    /// Time this session spent not playing the game: paused with the overlay in
    /// front, or the app in the background. One open interval is kept at a time,
    /// so a pause that overlaps background/inactive time is counted once and
    /// neither is counted twice (B2-IPH-001). Excluded from play time.
    public private(set) var backgroundDuration: TimeInterval = 0
    private var persisting = false
    private var applyingEffectivePreferences = false
    private var cheatSafetyBackupCreated = false
    private var entitlement: RelayEntitlementState
    /// The app supplies its live presentation policy. Physical command buttons
    /// must not resume or quick-load behind a Relay tool; releases still clean
    /// up held rewind/fast-forward state. Ordinary game input is unchanged.
    @ObservationIgnored public var allowsGameplayCommands: @MainActor () -> Bool = { true }

    public init(environment: LibraryEnvironment, preferences: PlayPreferences = PlayPreferences(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.session = environment.session
        self.preferences = preferences
        self.now = now
        entitlement = environment.relayPro.entitlement
    }

    private var battery: BatterySaveManager? { environment.batterySaves }
    private var states: SaveStateManager? { environment.saveStates }

    // MARK: Launch

    /// Prepares per-game storage, starts the core, attaches input, and restores
    /// the latest Auto Resume state when compatible ("Continue").
    public func start(launch: ResolvedLaunch, achievementMode: AchievementMode? = nil, allowAutoResume: Bool = true) async throws {
        guard game == nil else { throw EmulationError.invalidState("a game is already running") }
        let gameID = launch.game.id
        let romBaseName = launch.contentURL.deletingPathExtension().lastPathComponent
        try await battery?.prepareForLaunch(gameID: gameID, romBaseName: romBaseName)
        let storage = EmulationStorage(batterySavesDirectory: environment.location.batteryWorkingDirectory(forGame: gameID),
                                       saveStatesDirectory: environment.location.saveStatesDirectory(forGame: gameID),
                                       firmwareDirectory: environment.firmwareDirectory)
        session.setRewindConfiguration(preferences.rewindConfiguration(policy: accessPolicy))
        let achievements = environment.achievements.prepareForPlay(gameID: gameID, system: launch.game.systemID,
                                                                  romURL: launch.contentURL, mode: achievementMode)
        do {
            try session.play(romURL: launch.contentURL, coreID: launch.core.id,
                             systemID: launch.game.systemID, storage: storage, achievements: achievements)
        } catch {
            environment.achievements.endPlay()
            throw error
        }
        currentLaunch = launch
        game = launch.game
        core = launch.core
        applyingEffectivePreferences = true
        display = preferences.displayOptions(for: launch.game.systemID, gameID: launch.game.id, policy: accessPolicy)
        screenArrangement = preferences.screenArrangement(for: launch.game.systemID, gameID: launch.game.id, policy: accessPolicy)
        applyingEffectivePreferences = false
        speed = .normal
        isPaused = false
        notice = nil
        problem = nil
        lastAutoSaveFailed = false
        backgroundDuration = 0
        inactiveSince = nil
        cheatSafetyBackupCreated = false
        cheats = preferences.cheats(for: launch.game.id)

        // The system's own control layout decides the controller and keyboard
        // mapping; an unknown system falls back to the Game Boy Advance's shape.
        let system = SystemCatalog.descriptor(for: launch.game.systemID) ?? SystemCatalog.gameBoyAdvance
        let profile = preferences.controllerMapping(for: system, gameID: launch.game.id, policy: accessPolicy)
        let bridge = GameControllerInputBridge(session: session, system: system, profile: profile)
        bridge.delegate = self
        bridge.start()
        input = bridge
        controllerName = bridge.hasController ? (bridge.controllerVendorName ?? L("Controller")) : nil
        touchControlsHidden = bridge.hasController && !preferences.showTouchControlsWithController

        if allowAutoResume && preferences.continueFromLatestSave { await restoreAutoResume() }
        startBatteryCheckpoints()
        await refreshSaves()
        if accessPolicy.allows(.cheats), cheats.contains(where: \.isEnabled) {
            await activatePersistedCheats()
        }
    }

    /// Continue restores the newest Auto Resume that belongs with the current
    /// battery progress (paired with the active head; RELAY_SYNC_CONFLICTS.md §2.1).
    private func restoreAutoResume() async {
        guard let game, let core, let states, canSaveStates else { return }
        let head = try? await environment.store?.saves.activeBatteryRevisionID(for: game.id)
        guard let auto = try? await states.latestAutoResume(for: game.id, activeRevision: head ?? nil) else {
            await noteContinuedFromInGameSave(game)
            return
        }
        do {
            let bytes = try states.load(auto, game: game, for: core)
            // Resume is explicitly Casual, even if the new-game preference is
            // Hardcore. The downgrade precedes the native restore.
            if hardcoreEnabled { continueInCasual() }
            try session.restoreState(bytes)
            playLog.info("auto resume restored for \(game.id, privacy: .public)")
        } catch {
            // Incompatible or damaged Auto Resume: the in-game save carries; say so quietly (CONTINUITY_UX §6.9).
            playLog.notice("auto resume skipped for \(game.id, privacy: .public): \(String(describing: error), privacy: .public)")
            if error as? EmulationError == .stateFirmwareMismatch {
                show(Toast(text: L("Auto Resume skipped — different PlayStation firmware"), symbol: .loadState))
            } else { await noteContinuedFromInGameSave(game) }
        }
    }

    /// "Continued from your in-game save" when progress came from another device without a usable state.
    private func noteContinuedFromInGameSave(_ game: Game) async {
        guard let store = environment.store,
              let headID = try? await store.saves.activeBatteryRevisionID(for: game.id),
              let head = try? await store.saves.batteryRevision(id: headID),
              head.origin == .remote else { return }
        show(Toast(text: L("Continued from your in-game save"), symbol: .loadState))
    }

    public func continueInCasual() {
        environment.achievements.continueInCasual()
        session.continueInCasual()
    }

    public func restartInHardcore() async {
        guard environment.achievements.hardcoreAvailable, environment.achievements.hasAccount,
              let launch = currentLaunch else { return }
        pause(force: true)
        _ = await persistProgress()
        guard !lastAutoSaveFailed else { return }
        _ = await finish(persistingProgress: false)
        do { try await start(launch: launch, achievementMode: .hardcore, allowAutoResume: false) }
        catch { problem = .forStorage(error) }
    }

    // MARK: Pause / resume

    public func pause(force: Bool = false) {
        guard game != nil, !isRewinding else { return }
        if sharing.state == .recording { sharing.stopClip() }
        if session.state == .running { session.pause(force: force) }
        guard session.state == .paused else {
            show(Toast(text: L("Play a little longer before pausing in Hardcore."), symbol: .achievements))
            return
        }
        input?.releaseAll()
        isPaused = true
        // The overlay is in front of a still-running core: this is not play time.
        beginInactive()
    }

    public func resume() {
        guard game != nil, !isRewinding else { return }
        if notice == .controllerDisconnected, requiresController { return }
        endInactive()
        isPaused = false
        notice = nil
        session.resume()
    }

    /// Opens the session's "not playing" interval. Idempotent: a pause that
    /// overlaps an inactive/background interval keeps the first start, so the
    /// wall-clock time is only ever counted once.
    private func beginInactive() {
        guard inactiveSince == nil else { return }
        inactiveSince = now()
    }

    /// Closes the open interval, if any, and adds it to `backgroundDuration`.
    private func endInactive() {
        guard let since = inactiveSince else { return }
        inactiveSince = nil
        backgroundDuration += max(0, now().timeIntervalSince(since))
    }

    public func togglePause() { isPaused ? resume() : pause() }

    /// Apple TV has no touch fallback: a game cannot resume without a controller.
    public var requiresController: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    // MARK: Saves

    public func refreshSaves() async {
        guard let game, let states else { return }
        if let browser = try? await states.browserStates(for: game.id, now: now()) {
            quickStates = browser.quick
            manualStates = browser.manual
        }
    }

    /// Quick Save: 80 ms freeze, state + battery snapshot, "Saved" toast (§17.3).
    public func quickSave() async {
        _ = await createState(kind: .quick)
    }

    /// Save Now in the Saves browser: an immutable manual state.
    public func saveNow() async {
        _ = await createState(kind: .manual)
    }

    @discardableResult
    private func createState(kind: SaveState.Kind, label: String? = nil, showConfirmation: Bool = true) async -> SaveState? {
        guard let game, let core, let states, canSaveStates, !isRewinding else { return nil }
        let wasRunning = session.state == .running
        if wasRunning {
            session.pause()
            guard session.state == .paused else {
                show(Toast(text: L("Play a little longer before pausing in Hardcore."), symbol: .achievements))
                return nil
            }
        }
        defer { if wasRunning, !isPaused { session.resume() } }
        _ = await batteryCheckpoint?.value
        do {
            let payload = try session.captureState()
            let screenshot = session.frameSource.flatMap(FrameCapture.image(from:))
            let batteryBytes = session.batterySaveBytes()
            let batteryManager = battery
            let stamp = now()
            let store = environment.store
            let state = try await Task.detached(priority: .userInitiated) {
                _ = try await batteryManager?.snapshot(gameID: game.id, data: batteryBytes, now: stamp)
                let head = try await store?.saves.activeBatteryRevisionID(for: game.id)
                return try await states.create(kind: kind, game: game, core: core, payload: payload,
                                               screenshot: screenshot, label: label,
                                               batteryRevisionID: head, now: stamp)
            }.value
            if showConfirmation { show(Toast(text: L("Saved"), symbol: .saved, thumbnail: screenshot)) }
            await refreshSaves()
            await environment.sync.flushSoon()
            playLog.info("\(kind.rawValue, privacy: .public) state \(state.id, privacy: .public) written for \(game.id, privacy: .public)")
            return state
        } catch {
            problem = .forSaveFailure(error, title: game.title)
            return nil
        }
    }

    /// Quick Load: restores the latest quick save.
    public func quickLoad() async {
        guard let game, let states, canLoadStates else { return }
        guard let quick = try? await states.latestQuickSave(for: game.id) else { return }
        await load(quick)
    }

    /// Loads any state after validation; refuses incompatible or damaged ones with a human message.
    public func load(_ state: SaveState) async {
        guard let game, let core, let states, canLoadStates, !isRewinding else { return }
        do {
            let bytes = try states.load(state, game: game, for: core)
            let wasRunning = session.state == .running
            if wasRunning { session.pause() }
            try session.restoreState(bytes)
            if wasRunning, !isPaused { session.resume() }
            show(Toast(text: L("Loaded · \(Formatting.relative(state.createdAt, now: now()))"), symbol: .loadState))
            playLog.info("state \(state.id, privacy: .public) restored for \(game.id, privacy: .public)")
        } catch {
            problem = .forStateLoad(error)
        }
    }

    public func delete(_ state: SaveState) async {
        guard let states else { return }
        do {
            try await states.delete(state)
            await refreshSaves()
        } catch {
            problem = .forStorage(error)
        }
    }

    // Cores that expose cards in memory use the same atomic Save/revision
    // manager as lifecycle saves. Two-second checkpoints bound crash loss;
    // unchanged bytes create no file or revision. Manual/lifecycle saves wait
    // for an in-flight checkpoint before selecting their paired battery head.
    private func startBatteryCheckpoints() {
        batteryTimer?.invalidate()
        guard session.requiresBatterySnapshots else { return }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkpointBattery() }
        }
    }
    func checkpointBattery() async {
        guard let game, let battery, session.state == .running, !persisting, batteryCheckpoint == nil,
              let bytes = session.batterySaveBytes() else { return }
        let stamp = now()
        let task = Task.detached(priority: .utility) { () -> Error? in
            do { _ = try await battery.snapshot(gameID: game.id, data: bytes, now: stamp); return nil }
            catch { return error }
        }
        batteryCheckpoint = task
        let failure = await task.value
        batteryCheckpoint = nil
        if let failure {
            lastAutoSaveFailed = true
            playLog.error("battery checkpoint failed: \(String(describing: failure), privacy: .public)")
        }
    }

    public func selectDisc(at index: Int) {
        do { try session.selectDisc(at: index) }
        catch { problem = ProductMessage(headline: L("Couldn't change the disc."),
            message: L("Your current disc is still selected. Try again after checking that the game is fully downloaded."), action: .close) }
    }
    public func setControllerKind(_ kind: EmulationControllerKind) {
        do { try session.setControllerKind(kind) }
        catch { problem = ProductMessage(headline: L("Couldn't change the controller."), message: L("Return to the game, reopen Pause and try again."), action: .close) }
    }
    public func setAnalogModeEnabled(_ enabled: Bool) {
        do { try session.setAnalogModeEnabled(enabled) }
        catch { problem = ProductMessage(headline: L("Couldn't change the controller."), message: L("Return to the game, reopen Pause and try again."), action: .close) }
    }

    // MARK: Lifecycle autosave

    /// Battery snapshot + Auto Resume state + Continue screenshot. Safe at any
    /// point; failures are remembered so Exit can warn (§17.2).
    @discardableResult
    public func persistProgress() async -> ContentLocation? {
        guard let game, let core, !persisting else { return nil }
        persisting = true
        defer { persisting = false }
        _ = await batteryCheckpoint?.value
        let payload = canSaveStates ? try? session.captureState() : nil
        let screenshot = session.frameSource.flatMap(FrameCapture.image(from:))
        let batteryBytes = session.batterySaveBytes()
        let batteryManager = battery
        let stateManager = states
        let artworkStore = environment.artworkStore
        let stamp = now()
        let store = environment.store
        let result: (ContentLocation?, Error?) = await Task.detached(priority: .userInitiated) {
            var failure: Error?
            let location = screenshot.flatMap { try? artworkStore.storeScreenshot($0, for: game.id) }
            // The revision keeps a copy of the frame for the Two versions chooser.
            let revisionShot = screenshot.flatMap { try? artworkStore.storeBatteryScreenshot($0, for: game.id, stamp: stamp) }
            do { _ = try await batteryManager?.snapshot(gameID: game.id, data: batteryBytes, screenshotLocation: revisionShot, now: stamp) } catch { failure = error }
            if let payload, let stateManager {
                let head = try? await store?.saves.activeBatteryRevisionID(for: game.id)
                do { _ = try await stateManager.create(kind: .auto, game: game, core: core, payload: payload, screenshot: screenshot, batteryRevisionID: head ?? nil, now: stamp) } catch { failure = failure ?? error }
            }
            return (location, failure)
        }.value
        if let error = result.1 {
            lastAutoSaveFailed = true
            playLog.error("autosave failed for \(game.id, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            lastAutoSaveFailed = false
        }
        await environment.sync.flushSoon()
        return result.0
    }

    /// Scene went inactive (lock, app switcher, call): pause without persisting.
    public func sceneDidBecomeInactive() {
        sceneIsActive = false
        guard game != nil else { return }
        wasRunningBeforeInactive = session.state == .running && !isPaused
        if isRewinding { endRewind() }
        pause(force: true)
    }

    /// Scene went to the background: pause and write everything (§13).
    public func sceneDidEnterBackground() async {
        sceneIsActive = false
        resumeForClipWhenActive = false
        sharing.stopClip()
        guard game != nil else { return }
        if isRewinding { endRewind() }
        pause(force: true)
        // Already paused: `pause` opened the interval. Otherwise the guard above
        // means there is no game to account for.
        beginInactive()
        await persistProgress()
    }

    /// Scene is active again: account the background time; stay paused with the overlay.
    public func sceneDidBecomeActive() {
        sceneIsActive = true
        if resumeForClipWhenActive, sharing.state == .recording {
            resumeForClipWhenActive = false
            resume()
        }
        // The game stays paused with the overlay after returning, so the
        // "not playing" interval stays open until the player resumes: closing it
        // here would start a second interval that double-counts the same time.
    }

    // MARK: Exit

    /// Writes progress, stops the core and input, and returns the Continue
    /// screenshot location. The library records the session afterwards.
    public func finish(persistingProgress: Bool = true) async -> ContentLocation? {
        resumeForClipWhenActive = false
        await sharing.endSession()
        guard game != nil else { return nil }
        batteryTimer?.invalidate(); batteryTimer = nil
        if isRewinding { endRewind() }
        if session.state == .running { session.pause(force: true) }
        // Exiting while paused closes the interval here: the session record is
        // written with the time that was actually played (B2-IPH-001).
        endInactive()
        input?.releaseAll()
        let screenshot = persistingProgress ? await persistProgress() : nil
        input?.stop()
        input = nil
        session.stop()
        environment.achievements.endPlay()
        game = nil
        core = nil
        isPaused = false
        isRewinding = false
        notice = nil
        toast = nil
        quickStates = []
        manualStates = []
        cheats = []
        controllerName = nil
        return screenshot
    }

    // MARK: Rewind

    public func beginRewind() {
        sharing.stopClip()
        guard canRewind, !isRewinding, game != nil else { return }
        guard session.beginRewind() else { return }
        isRewinding = true
        isPaused = false
        let interval = preferences.rewindConfiguration(policy: accessPolicy).captureInterval
        rewindTimer?.invalidate()
        rewindTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.session.rewindStep() }
        }
        _ = session.rewindStep()
    }

    public func endRewind() {
        rewindTimer?.invalidate()
        rewindTimer = nil
        guard isRewinding else { return }
        isRewinding = false
        session.endRewind()
    }

    // MARK: Speed

    public func setSpeed(_ newSpeed: EmulationSpeed) {
        guard availableSpeeds.contains(newSpeed) else { return }
        if newSpeed != .normal { sharing.stopClip() }
        session.setSpeed(newSpeed)
        speed = session.speed
    }

    /// Hold-to-fast-forward from keyboard/controller.
    public func setFastForwardHeld(_ held: Bool) {
        setSpeed(held ? preferences.effectiveFastForwardSpeed(policy: accessPolicy, supported: session.supportedSpeeds) : .normal)
    }

    // MARK: Pro policy and persistent configuration

    public func entitlementDidChange(_ state: RelayEntitlementState) {
        entitlement = state
        sharing.accessDidChange(limits: GameplayClipLimits(policy: accessPolicy))
        session.setRewindConfiguration(preferences.rewindConfiguration(policy: accessPolicy))
        if !availableSpeeds.contains(speed) { setSpeed(.normal) }
        applyEffectiveDisplayPreferences()
        updateControllerProfile()
        if !accessPolicy.allows(.cheats) {
            try? session.applyCheats([])
        } else if game != nil, cheats.contains(where: \.isEnabled) {
            Task { [weak self] in await self?.activatePersistedCheats() }
        }
    }

    public func allows(_ feature: RelayProFeature) -> Bool { accessPolicy.allows(feature) }

    public func setRewindDuration(_ duration: TimeInterval) {
        let requested = max(0, duration)
        guard requested <= 10 || accessPolicy.allows(.extendedRewind) else { return }
        preferences.rewindDuration = min(requested, 60)
        session.setRewindConfiguration(preferences.rewindConfiguration(policy: accessPolicy))
    }

    public func saveAdvancedDisplay(_ options: DisplayOptions, arrangement: ScreenArrangement?, perGame: Bool) {
        guard accessPolicy.allows(.advancedDisplay), let game else { return }
        if perGame {
            preferences.setDisplayOptions(options, for: game.id)
            preferences.setScreenArrangement(arrangement, for: game.id)
        } else {
            preferences.setDisplayOptions(options, for: game.systemID)
            preferences.setScreenArrangement(arrangement, for: game.systemID)
            preferences.clearDisplayOptions(for: game.id)
            preferences.clearScreenArrangement(for: game.id)
        }
        applyEffectiveDisplayPreferences()
    }

    public func saveControllerMapping(_ profile: ControllerMappingProfile, perGame: Bool) {
        guard accessPolicy.allows(.advancedControllerMapping),
              let game, let system = SystemCatalog.descriptor(for: game.systemID) else { return }
        if perGame {
            preferences.setControllerMapping(profile, for: game.id, system: system)
        } else {
            preferences.setControllerMapping(profile, for: system)
            preferences.clearControllerMapping(for: game.id)
        }
        updateControllerProfile()
    }

    public func resetControllerMapping(perGame: Bool) {
        guard let game else { return }
        if perGame { preferences.clearControllerMapping(for: game.id) }
        else { preferences.resetControllerMapping(for: game.systemID) }
        updateControllerProfile()
    }

    public var hasPerGameControllerMapping: Bool {
        game.map { preferences.hasControllerMapping(for: $0.id) } ?? false
    }

    public func controllerMapping(perGame: Bool? = nil) -> ControllerMappingProfile {
        guard let game, let system = SystemCatalog.descriptor(for: game.systemID) else { return .init() }
        let gameID = perGame == false ? nil : game.id
        return preferences.controllerMapping(for: system, gameID: gameID, policy: accessPolicy)
    }

    private func updateControllerProfile() {
        guard let game, let system = SystemCatalog.descriptor(for: game.systemID) else { return }
        input?.updateProfile(preferences.controllerMapping(for: system, gameID: game.id, policy: accessPolicy))
    }

    private func applyEffectiveDisplayPreferences() {
        guard let game else { return }
        applyingEffectivePreferences = true
        display = preferences.displayOptions(for: game.systemID, gameID: game.id, policy: accessPolicy)
        screenArrangement = preferences.screenArrangement(for: game.systemID, gameID: game.id, policy: accessPolicy)
        applyingEffectivePreferences = false
    }

    #if os(iOS)
    public func touchLayout(portrait: Bool, scale: CGFloat, fitting size: CGSize? = nil) -> TouchLayout {
        let system = SystemCatalog.descriptor(for: game?.systemID ?? .gameBoyAdvance) ?? SystemCatalog.gameBoyAdvance
        return preferences.touchLayout(for: system, portrait: portrait, scale: scale, policy: accessPolicy, fitting: size)
    }

    public var effectiveTouchOpacity: Double { preferences.effectiveTouchOpacity(policy: accessPolicy) }

    public func saveTouchLayout(_ layout: TouchLayout, portrait: Bool, scale: CGFloat, opacity: Double) {
        guard accessPolicy.allows(.touchLayoutEditing), let game,
              let system = SystemCatalog.descriptor(for: game.systemID) else { return }
        preferences.setTouchLayout(layout, for: system, portrait: portrait, scale: scale)
        preferences.touchOpacity = opacity
    }

    public func resetTouchLayout(portrait: Bool) {
        guard let game else { return }
        preferences.resetTouchLayout(for: game.systemID, portrait: portrait)
    }
    #endif

    // Artwork has no effect on saved touch geometry. Revision makes local
    // UserDefaults changes observable without rewriting effective preferences.
    private var skinRevision = 0
    public var skin: RelaySkinConfiguration {
        _ = skinRevision
        return preferences.skin(for: game?.systemID ?? .gameBoyAdvance, policy: accessPolicy)
    }

    public func setSkinEnabled(_ enabled: Bool) {
        guard let game else { return }
        preferences.setSkinEnabled(enabled, for: game.systemID)
        skinRevision += 1
    }

    public func setSkin(_ configuration: RelaySkinConfiguration) {
        guard let game else { return }
        preferences.setSkin(configuration, for: game.systemID, policy: accessPolicy)
        skinRevision += 1
    }

    // MARK: Cheats

    public func validateCheat(_ cheat: CheatDefinition) -> CheatValidationError? {
        session.validateCheat(cheat)
    }

    public func addCheat(_ cheat: CheatDefinition) -> CheatValidationError? {
        guard accessPolicy.allows(.cheats), let game else { return .unsupportedFormat }
        if let error = validateCheat(cheat) { return error }
        cheats.append(cheat)
        preferences.setCheats(cheats, for: game.id)
        return nil
    }

    public func removeCheat(_ id: UUID) {
        guard accessPolicy.allows(.cheats), let game else { return }
        cheats.removeAll { $0.id == id }
        preferences.setCheats(cheats, for: game.id)
        try? session.applyCheats(cheats)
    }

    public func setCheatEnabled(_ id: UUID, enabled: Bool) async {
        guard accessPolicy.allows(.cheats), let game,
              let index = cheats.firstIndex(where: { $0.id == id }) else { return }
        var updated = cheats
        updated[index].isEnabled = enabled
        if enabled, !cheatSafetyBackupCreated {
            guard await createPreCheatSafetyBackup() else { return }
        }
        do {
            try session.applyCheats(updated)
            cheats = updated
            preferences.setCheats(updated, for: game.id)
        } catch {
            problem = .forStorage(error)
        }
    }

    private func activatePersistedCheats() async {
        guard canUseCheats, accessPolicy.allows(.cheats), cheats.contains(where: \.isEnabled) else { return }
        if !cheatSafetyBackupCreated, !(await createPreCheatSafetyBackup()) { return }
        do { try session.applyCheats(cheats) } catch { problem = .forStorage(error) }
    }

    private func createPreCheatSafetyBackup() async -> Bool {
        guard let state = await createState(kind: .manual, label: "relay.preCheatSafety", showConfirmation: false) else { return false }
        cheatSafetyBackupCreated = true
        _ = state
        show(Toast(text: L("Safety save created before cheats"), symbol: .saved))
        return true
    }

    public func captureScreenshot() {
        guard let game, let image = session.frameSource.flatMap(FrameCapture.image(from:)) else { return }
        do {
            _ = try environment.artworkStore.storeScreenshot(image, for: game.id)
            show(Toast(text: L("Screenshot saved"), symbol: .saved, thumbnail: image))
        } catch {
            problem = .forStorage(error)
        }
    }

    // MARK: Touch input

    // MARK: Touch screen (any platform with a pointer or a finger)

    /// A touch on one of the system's screens (native pixels of that screen).
    public func touchScreen(index: Int, x: Int, y: Int) {
        guard !isPaused else { return }
        session.touch(screenIndex: index, x: x, y: y)
    }

    public func releaseTouchScreen() {
        session.releaseTouch()
    }

    #if os(iOS)
    /// Every touch control that is currently held. Published so a UI test can
    /// observe that a real finger reached the control layer: the layer was
    /// unverified by any test until a hit-testing regression made it inert on
    public private(set) var touchedControls: Set<TouchControl> = []
    /// The last control a finger pressed, kept after release so a UI test can
    /// observe a tap that has already ended.
    public private(set) var lastTouchedControl: TouchControl?

    public func touch(_ control: TouchControl, pressed: Bool) {
        if pressed {
            touchedControls.insert(control)
            lastTouchedControl = control
        } else {
            touchedControls.remove(control)
        }
        guard let input = Self.input(for: control) else { return }
        if pressed { session.press(input) } else { session.release(input) }
    }

    public func touchStick(_ control: TouchControl, position: CGPoint) {
        guard control == .leftStick || control == .rightStick else { return }
        let left = control == .leftStick
        session.move(left ? .leftStickX : .rightStickX, to: Float(position.x))
        // Controller axes use positive-up; touch coordinates use positive-down.
        session.move(left ? .leftStickY : .rightStickY, to: -Float(position.y))
    }

    static func input(for control: TouchControl) -> EmulationInput? {
        switch control {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .a: return .a
        case .b: return .b
        case .l: return .l
        case .r: return .r
        case .l2: return .l2
        case .r2: return .r2
        case .l3: return .l3
        case .r3: return .r3
        case .leftStick, .rightStick: return nil
        case .start: return .start
        case .select: return .select
        case .x: return .x
        case .y: return .y
        case .cUp: return .cUp
        case .cDown: return .cDown
        case .cLeft: return .cLeft
        case .cRight: return .cRight
        }
    }

    public func toggleTouchControls() {
        guard preferences.twoFingerTapTogglesControls else { return }
        touchControlsHidden.toggle()
    }
    #endif

    // MARK: Toasts

    private func show(_ item: Toast) {
        toast = item
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            if self?.toast?.id == item.id { self?.toast = nil }
        }
    }

    public func clearProblem() { problem = nil }
}

// MARK: - Controller

extension PlayModel: GameControllerInputBridgeDelegate {
    public func inputBridge(_ bridge: GameControllerInputBridge, controllerDidConnect name: String?) {
        let displayName = name ?? L("Controller")
        controllerName = displayName
        touchControlsHidden = !preferences.showTouchControlsWithController
        if notice == .controllerDisconnected { notice = nil }
        show(Toast(text: L("\(displayName) connected"), symbol: .controller))
    }

    public func inputBridgeControllerDidDisconnect(_ bridge: GameControllerInputBridge) {
        controllerName = nil
        touchControlsHidden = false
        guard game != nil else { return }
        if isRewinding { endRewind() }
        pause(force: true)
        notice = .controllerDisconnected
    }

    public func inputBridge(_ bridge: GameControllerInputBridge, command: InputCommand, pressed: Bool) {
        guard !pressed || allowsGameplayCommands() else { return }
        switch command {
        case .pause:
            if pressed { togglePause() }
        case .quickSave:
            if pressed { Task { await quickSave() } }
        case .quickLoad:
            if pressed { Task { await quickLoad() } }
        case .rewind:
            if pressed { beginRewind() } else { endRewind() }
        case .fastForward:
            setFastForwardHeld(pressed)
        case .screenshot:
            if pressed { captureScreenshot() }
        }
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  EmulationSession.swift
//  RelayEmulation
//
//  The Relay-facing facade the shells talk to. Owns one driver at a time and
//  exposes observable state. Keeps no knowledge of Provenance or mGBA.
//
//  (`.saveStates`), fast-forward (`.fastForward`) and rewind (`.rewind`, built
//  on the state serializer). The real-time path (driver thread, presenter) is
//  untouched; everything here runs on the main actor except the rewind
//  capture loop, which uses the driver's thread-safe serializer.

import Foundation
import Observation
import RelayDomain

@MainActor
@Observable
public final class EmulationSession {
    public private(set) var state: EmulationState = .idle
    public private(set) var diagnostics = EmulationDiagnostics()
    public private(set) var core: EmulatorCoreDescriptor?
    public private(set) var romURL: URL?
    public private(set) var speed: EmulationSpeed = .normal
    public private(set) var isRewinding = false
    public var hardcoreEnabled: Bool { achievementRuntime?.hardcoreEnabled ?? false }

    /// Frame source for presenters; nil until a game is loaded.
    public var frameSource: VideoFrameSource? { driver?.frameSource }
    /// One source per logical screen of the running system (`SystemDescriptor.screens` order).
    public var screenFrameSources: [VideoFrameSource] { driver?.screenFrameSources ?? [] }
    /// The running core's state serializer, for callers that keep their own
    /// capture schedule (the rewind engine does). Like `frameSource`, what it
    /// vends stays safe to call after the game stops: it reports failure rather
    /// than touching a core that is gone.
    public var stateSerializer: (any EmulationStateSerializer)? { driver?.stateSerializer }
    /// Presenters bump this once per presented frame.
    public let presentationCounter = PresentationCounter()

    private let factory: any EmulationDriverFactory
    private let storage: EmulationStorage
    private var driver: (any EmulationDriver)?
    private var achievementRuntime: AchievementRuntimeSlot?
    private var diagnosticsTimer: Timer?
    private var audioEnabled = true
    private var rewind: RewindEngine?
    private var rewindConfiguration: RewindConfiguration
    private var memoryPressure: DispatchSourceMemoryPressure?

    public init(factory: any EmulationDriverFactory, storage: EmulationStorage,
                rewindConfiguration: RewindConfiguration = .standard) {
        self.factory = factory
        self.storage = storage
        self.rewindConfiguration = rewindConfiguration
    }

    public var availableCores: [EmulatorCoreDescriptor] { factory.availableCores }

    // MARK: Capabilities (what the UI may offer for the running core)

    public var capabilities: CoreCapabilities { core?.capabilities ?? [] }
    public var supportsSaveStates: Bool { capabilities.contains(.saveStates) && driver?.stateSerializer != nil }
    public var supportsStateLoading: Bool { supportsSaveStates && !hardcoreEnabled }
    public var supportsFastForward: Bool { capabilities.contains(.fastForward) }
    public var supportsRewind: Bool { !hardcoreEnabled && capabilities.contains(.rewind) && supportsSaveStates && rewindConfiguration.duration > 0 }
    public var supportedSpeeds: Set<EmulationSpeed> {
        guard let driver else { return [.normal] }
        return hardcoreEnabled ? Set(driver.supportedSpeeds.filter { $0.nominalMultiplier >= 1 }) : driver.supportedSpeeds
    }
    public var supportsCheats: Bool {
        !hardcoreEnabled && capabilities.contains(.cheats) && !(driver?.supportedCheatFormats.isEmpty ?? true)
    }
    public var supportedCheatFormats: Set<CheatFormat> { driver?.supportedCheatFormats ?? [] }

    public var requiresBatterySnapshots: Bool { driver?.requiresBatterySnapshots ?? false }
    public private(set) var discStatus: EmulationDiscStatus?
    public private(set) var controllerKind: EmulationControllerKind = .digital
    public private(set) var analogModeEnabled = false
    public var supportedControllers: Set<EmulationControllerKind> { driver?.supportedControllers ?? [] }
    public var usesEmulatedFirmware: Bool { driver?.usesEmulatedFirmware ?? false }

    public func selectDisc(at index: Int) throws {
        guard let driver, state == .paused, capabilities.contains(.diskSwap) else { throw EmulationError.invalidState("pause before changing discs") }
        try driver.selectDisc(at: index)
        refreshDiscAndController()
    }
    public func setControllerKind(_ kind: EmulationControllerKind) throws {
        guard let driver, state == .paused else { throw EmulationError.invalidState("pause before changing controller") }
        try driver.setControllerKind(kind)
        refreshDiscAndController()
    }
    public func setAnalogModeEnabled(_ enabled: Bool) throws {
        guard let driver, state == .paused else { throw EmulationError.invalidState("pause before changing analog mode") }
        try driver.setAnalogModeEnabled(enabled)
        refreshDiscAndController()
    }
    private func refreshDiscAndController() {
        discStatus = driver?.discStatus
        controllerKind = driver?.controllerKind ?? .digital
        analogModeEnabled = driver?.analogModeEnabled ?? false
    }

    // MARK: Lifecycle

    /// Loads `romURL` with `coreID` and starts emulation (video + audio).
    public func play(romURL: URL, coreID: CoreID, systemID: SystemID,
                     audio: Bool = true, storage: EmulationStorage? = nil,
                     achievements: AchievementRuntimeSlot? = nil) throws {
        guard state == .idle || state == .stopped || isFailed else {
            throw EmulationError.invalidState("play() called while \(state)")
        }
        guard FileManager.default.fileExists(atPath: romURL.path) else {
            let error = EmulationError.romNotFound(romURL.lastPathComponent)
            state = .failed(error)
            throw error
        }
        state = .loading
        do {
            let driver = try factory.makeDriver(coreID: coreID, systemID: systemID)
            try driver.load(romURL: romURL, storage: storage ?? self.storage)
            driver.setAchievementRuntime(achievements)
            achievementRuntime = achievements
            try driver.start()
            self.driver = driver
            self.core = driver.descriptor
            refreshDiscAndController()
            self.romURL = romURL
            audioEnabled = audio
            speed = .normal
            if audio {
                do { try driver.startAudio() } catch {
                    // Audio failure must not block play; surface it in diagnostics.
                    diagnostics.audioRunning = false
                }
            }
            state = .running
            startRewindIfSupported()
            startDiagnostics()
            observeMemoryPressure()
        } catch let error as EmulationError {
            state = .failed(error)
            throw error
        } catch {
            let wrapped = EmulationError.loadFailed(String(describing: error))
            state = .failed(wrapped)
            throw wrapped
        }
    }

    public func pause(force: Bool = false) {
        guard state == .running, let driver else { return }
        guard force || achievementRuntime?.canPause() != false else { return }
        driver.setPaused(true)
        driver.stopAudio()
        rewind?.stopCapturing()
        state = .paused
    }

    public func resume() {
        guard state == .paused, let driver, !isRewinding else { return }
        driver.setPaused(false)
        if audioEnabled, speed == .normal { try? driver.startAudio() }
        rewind?.startCapturing()
        state = .running
    }

    public func stop() {
        guard let driver else { return }
        rewind?.stopCapturing()
        rewind = nil
        isRewinding = false
        driver.stopAudio()
        driver.setAchievementRuntime(nil)
        achievementRuntime = nil
        driver.stop()
        self.driver = nil
        refreshDiscAndController()
        stopDiagnostics()
        memoryPressure?.cancel()
        memoryPressure = nil
        speed = .normal
        state = .stopped
    }

    /// Return to Casual immediately. Re-entering Hardcore requires play() on a
    /// newly created core; no public method can upgrade a live session.
    public func continueInCasual() {
        achievementRuntime?.disableHardcore()
        startRewindIfSupported()
    }

    // MARK: Input

    public func press(_ input: EmulationInput) { driver?.press(input) }
    public func release(_ input: EmulationInput) { driver?.release(input) }
    /// A touch on one of the system's screens, in that screen's native pixels.
    /// Ignored when the core lacks `.touchInput`.
    public func touch(screenIndex: Int, x: Int, y: Int) {
        guard capabilities.contains(.touchInput) else { return }
        driver?.touch(screenIndex: screenIndex, x: x, y: y)
    }
    public func releaseTouch() {
        guard capabilities.contains(.touchInput) else { return }
        driver?.releaseTouch()
    }

    /// Sends a continuous control's value. Clamped here so no adapter has to
    /// defend itself against a stick reading outside its range.
    public func move(_ axis: EmulationAxis, to value: Float) {
        driver?.move(axis, to: axis.clamp(value))
    }

    // MARK: Battery save

    /// The game's battery save bytes as the core holds them now (nil when none).
    /// Safe while running; the save layer snapshots these atomically.
    public func batterySaveBytes() -> Data? {
        guard let driver, state == .running || state == .paused else { return nil }
        return driver.batterySaveData()
    }

    // MARK: Speed (capability: fastForward)

    /// Audio is muted while the speed is not normal (sped-up sound would only
    /// queue seconds of latency in the core's ring buffer) and resumes cleanly
    /// — buffer flushed — when normal speed returns.
    public func setSpeed(_ newSpeed: EmulationSpeed) {
        guard let driver, state == .running || state == .paused else { return }
        guard supportedSpeeds.contains(newSpeed) else { return }
        guard newSpeed != speed else { return }
        driver.setSpeed(newSpeed)
        if state == .running, audioEnabled {
            if newSpeed == .normal {
                driver.flushAudio()
                try? driver.startAudio()
            } else {
                driver.stopAudio()
                driver.flushAudio()
            }
        }
        speed = newSpeed
        diagnostics.speed = newSpeed
    }

    // MARK: Cheats (capability: cheats)

    public func validateCheat(_ cheat: CheatDefinition) -> CheatValidationError? {
        guard supportsCheats, let driver else { return .unsupportedFormat }
        return driver.validateCheat(cheat)
    }

    public func applyCheats(_ cheats: [CheatDefinition]) throws {
        guard let driver, supportsCheats else {
            if cheats.isEmpty { return }
            throw EmulationError.unsupported("cheats")
        }
        if let invalid = cheats.compactMap({ driver.validateCheat($0) }).first {
            throw EmulationError.unsupported("invalid cheat: \(invalid)")
        }
        try driver.applyCheats(cheats.filter(\.isEnabled))
    }

    // MARK: Save states (capability: saveStates)

    /// The core's complete machine state, as opaque bytes for the save layer.
    /// Safe while running (the driver serialises against its frame loop).
    public func captureState() throws -> Data {
        guard let serializer = driver?.stateSerializer, supportsSaveStates else {
            throw EmulationError.unsupported("save states")
        }
        let started = DispatchTime.now()
        let data: Data
        do { data = try serializer.serializeState() } catch { throw EmulationError.stateFailed(String(describing: error)) }
        diagnostics.lastStateCaptureMillis = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        return data
    }

    /// Restores bytes produced by `captureState` on the same core version. The
    /// caller is responsible for compatibility checks (Relay's save layer does
    /// them); the driver only guarantees it will not crash on refusal. Queued
    /// audio is dropped so nothing stale plays; when paused, one frame is run
    /// so the frozen picture shows the restored state. Rewind history restarts
    /// from here (a load is a new timeline).
    public func restoreState(_ data: Data) throws {
        guard let driver, let serializer = driver.stateSerializer, supportsStateLoading else {
            throw EmulationError.unsupported("save states")
        }
        guard !isRewinding else { throw EmulationError.invalidState("restoreState() while rewinding") }
        let started = DispatchTime.now()
        do { try serializer.restoreState(data) }
        catch let error as EmulationError { throw error }
        catch { throw EmulationError.stateFailed(String(describing: error)) }
        diagnostics.lastStateRestoreMillis = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        driver.flushAudio()
        refreshDiscAndController()
        rewind?.reset()
        if state == .paused { serializer.runSingleFrame() }
    }

    // MARK: Rewind (capability: rewind)

    public var rewindStatistics: RewindBuffer.Statistics? { rewind?.statistics }

    /// Enters rewind mode: the game pauses, audio stops, and each `rewindStep()`
    /// moves one capture back. Returns false when rewind is unsupported or
    /// there is no history yet.
    @discardableResult
    public func beginRewind() -> Bool {
        guard let driver, let rewind, supportsRewind, state == .running || state == .paused, !isRewinding else { return false }
        guard rewind.statistics.entries > 0 else { return false }
        if state == .running {
            driver.setPaused(true)
            driver.stopAudio()
            state = .paused
        }
        rewind.beginRewind()
        achievementRuntime?.setPreviewing(true)
        isRewinding = true
        return true
    }

    /// One step back in time. Returns false when history is exhausted.
    @discardableResult
    public func rewindStep() -> Bool {
        guard isRewinding, let rewind else { return false }
        return rewind.stepBack()
    }

    /// Leaves rewind mode and resumes play from the restored point.
    public func endRewind() {
        guard isRewinding, let driver, let rewind else { return }
        isRewinding = false
        driver.flushAudio()
        rewind.endRewind(resumeCapturing: true)
        achievementRuntime?.setPreviewing(false)
        driver.setPaused(false)
        if audioEnabled, speed == .normal { try? driver.startAudio() }
        state = .running
    }

    /// Applies a new rewind configuration. A running ring is resized in place;
    /// this is how entitlement changes return a session to the Free cap.
    public func setRewindConfiguration(_ configuration: RewindConfiguration) {
        rewindConfiguration = configuration
        if let rewind {
            rewind.reconfigure(configuration)
        } else if state == .running || state == .paused {
            startRewindIfSupported()
            if state == .paused { rewind?.stopCapturing() }
        }
    }

    private func startRewindIfSupported() {
        guard let serializer = driver?.stateSerializer, capabilities.contains(.rewind), rewindConfiguration.duration > 0 else {
            rewind = nil
            return
        }
        let engine = RewindEngine(serializer: serializer, configuration: rewindConfiguration)
        engine.startCapturing()
        rewind = engine
    }

    /// Memory pressure: shrink the rewind ring first (spec §40), never the emulator.
    private func observeMemoryPressure() {
        memoryPressure?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.rewind?.shrink() }
        }
        source.resume()
        memoryPressure = source
    }

    // MARK: Diagnostics

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func startDiagnostics() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let driver = self.driver else { return }
                var d = driver.sampleDiagnostics()
                d.controllerName = self.diagnostics.controllerName
                d.presentedFramesPerSecond = Double(self.presentationCounter.take())
                d.speed = self.speed
                d.lastStateCaptureMillis = self.diagnostics.lastStateCaptureMillis
                d.lastStateRestoreMillis = self.diagnostics.lastStateRestoreMillis
                if let stats = self.rewind?.statistics {
                    d.rewindEntries = stats.entries
                    d.rewindBytes = stats.bytes
                    d.rewindRetainedSeconds = stats.retainedSeconds
                }
                if let source = driver.frameSource { d.frameChecksum = source.sampledChecksum() }
                self.diagnostics = d
                self.refreshDiscAndController()
            }
        }
    }

    private func stopDiagnostics() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    /// Lets the input layer report the active controller for the diagnostics line.
    public func setControllerName(_ name: String?) {
        diagnostics.controllerName = name
    }
}

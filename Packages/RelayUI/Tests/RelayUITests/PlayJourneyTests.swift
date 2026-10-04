// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  PlayJourneyTests.swift
//  with a fake driver that supports states, rewind and speed:
//  play → background → resume → stop (background time excluded);
//  play → quick save → continue (Auto Resume restores);
//  play → load state; incompatible state refused with a human message;
//  lifecycle autosave; Saves browser hides Auto Resume; capabilities gate the UI.

import XCTest
import RelayDomain
import RelayLibrary
import RelayEmulation
import RelayVideo
import RelayInput
import RelayDesignSystem
import RelayEntitlements
import RelayAchievements
@testable import RelayUI

/// Mutable test clock usable from the model's Sendable `now` closure.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class CountingSerializer: EmulationStateSerializer, @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt32 = 1
    func serializeState() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        var d = Data(repeating: 0xAB, count: 8192)
        withUnsafeBytes(of: counter.littleEndian) { d.replaceSubrange(0..<4, with: $0) }
        return d
    }
    func restoreState(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        counter = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
    func runSingleFrame() {}
    var value: UInt32 { lock.lock(); defer { lock.unlock() }; return counter }
}

@MainActor
final class PlayDriver: EmulationDriver {
    let descriptor = EmulatorCoreDescriptor(id: "fake", name: "Fake", version: "1", license: "MIT",
                                            supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates, .rewind, .fastForward, .cheats])
    var frameSource: VideoFrameSource? = nil
    var stateSerializer: (any EmulationStateSerializer)? = nil
    let serializer = CountingSerializer()
    var battery = Data([1, 2, 3, 4])
    var log: [String] = []
    var storage: EmulationStorage?
    func load(romURL: URL, storage: EmulationStorage) throws { log.append("load"); self.storage = storage; stateSerializer = serializer }
    func start() throws { log.append("start") }
    func setPaused(_ paused: Bool) { log.append(paused ? "pause" : "resume") }
    func stop() { log.append("stop"); stateSerializer = nil }
    func press(_ input: EmulationInput) { log.append("press:\(input.rawValue)") }
    func release(_ input: EmulationInput) { log.append("release:\(input.rawValue)") }
    func startAudio() throws {}
    func stopAudio() {}
    func flushAudio() { log.append("flush") }
    func setSpeed(_ speed: EmulationSpeed) { log.append("speed:\(speed.rawValue)") }
    var supportedSpeeds: Set<EmulationSpeed> { Set(EmulationSpeed.allCases) }
    var supportedCheatFormats: Set<CheatFormat> { [.gameShark] }
    func validateCheat(_ cheat: CheatDefinition) -> CheatValidationError? {
        if cheat.label.isEmpty { return .emptyLabel }
        if cheat.code.isEmpty { return .emptyCode }
        return cheat.format == .gameShark ? nil : .unsupportedFormat
    }
    func applyCheats(_ cheats: [CheatDefinition]) throws { log.append("cheats:\(cheats.filter(\.isEnabled).count)") }
    func batterySaveData() -> Data? { battery }
    func sampleDiagnostics() -> EmulationDiagnostics { EmulationDiagnostics() }
}

@MainActor
final class PlayFactory: EmulationDriverFactory {
    let driver = PlayDriver()
    var availableCores: [EmulatorCoreDescriptor] { [driver.descriptor] }
    func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver { driver }
}

@MainActor
final class PlayJourneyTests: XCTestCase {
    var root: URL!
    var factory: PlayFactory!
    let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
    lazy var defaults: UserDefaults = UserDefaults(suiteName: "RelayUITests-play-\(UUID().uuidString)")!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "RelayPlayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        factory = PlayFactory()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func makeModel(entitlementProvider: (any RelayEntitlementProviding)? = nil, achievements: AchievementsModel? = nil) -> LibraryModel {
        let storage = EmulationStorage(batterySavesDirectory: root.appending(path: "saves"),
                                       saveStatesDirectory: root.appending(path: "states"),
                                       firmwareDirectory: root.appending(path: "firmware"))
        let session = EmulationSession(factory: factory, storage: storage,
                                       rewindConfiguration: RewindConfiguration(duration: 5, captureInterval: 0.02, memoryBudgetBytes: 4 * 1024 * 1024))
        let environment = LibraryEnvironment(location: LibraryLocation(rootURL: root.appending(path: "Library")),
                                             session: session, cores: factory.availableCores, deviceKind: .iPhone,
                                             entitlementProvider: entitlementProvider, achievements: achievements)
        let clock = self.clock
        return LibraryModel(environment: environment, now: { clock.now }, defaults: defaults)
    }

    private func importGame(into model: LibraryModel) async throws -> Game {
        let url = root.appending(path: "game.gba")
        try Data(GBABytes.make(payload: 0x11)).write(to: url)
        await model.importFiles([url])
        return try XCTUnwrap(model.games.first)
    }

    func testHardcoreRestartAutoResumeAndShortcutsUseSessionGuards() async throws {
        let achievements = AchievementsModel(store: AchievementJourneyStore(), transport: AchievementJourneyTransport(),
                                             cacheDirectory: root.appending(path: "achievements"),
                                             hardcoreValidated: true, preferences: defaults)
        await achievements.connect(username: "RelayFixture", password: "fixture-password")
        XCTAssertTrue(achievements.isConnected)
        achievements.setPreferredMode(.hardcore)
        let model = makeModel(achievements: achievements)
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play
        XCTAssertTrue(play.hardcoreEnabled)
        XCTAssertFalse(play.canLoadStates)
        XCTAssertFalse(play.canRewind)
        XCTAssertFalse(play.canUseCheats)
        XCTAssertTrue(play.canSaveStates)
        XCTAssertFalse(play.availableSpeeds.contains(.quarter))
        XCTAssertFalse(play.availableSpeeds.contains(.half))
        await play.quickSave()
        let saved = try XCTUnwrap(play.quickStates.first)
        let before = factory.driver.serializer.value
        await play.quickLoad(); await play.load(saved)
        XCTAssertEqual(factory.driver.serializer.value, before, "Shortcuts and direct model calls cannot load in Hardcore")
        play.beginRewind(); XCTAssertFalse(play.isRewinding)
        play.setSpeed(.half); XCTAssertEqual(play.speed, .normal)
        await model.stop()
        await model.play(game.id)
        XCTAssertFalse(play.hardcoreEnabled, "Auto Resume must explicitly downgrade before restoring")
        XCTAssertEqual(achievements.activeMode, .casual)
        XCTAssertTrue(play.canLoadStates)
        let starts = factory.driver.log.filter { $0 == "load" }.count
        await play.restartInHardcore()
        XCTAssertTrue(play.hardcoreEnabled)
        XCTAssertEqual(factory.driver.log.filter { $0 == "load" }.count, starts + 1, "Hardcore entry must reload the core")
        XCTAssertEqual(achievements.activeMode, .hardcore)
        play.continueInCasual()
        XCTAssertFalse(play.hardcoreEnabled)
        await play.load(saved)
        XCTAssertNil(play.problem)
        await model.stop()
        await achievements.disconnect()
    }

    func testPlayBackgroundResumeStopExcludesBackgroundTimeAndWritesProgress() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        XCTAssertTrue(model.isPlaying)
        let play = model.play
        XCTAssertTrue(play.canSaveStates); XCTAssertTrue(play.canRewind); XCTAssertTrue(play.canFastForward)
        XCTAssertEqual(factory.driver.storage?.batterySavesDirectory, model.environment.location.batteryWorkingDirectory(forGame: game.id), "per-game save storage")
        XCTAssertFalse(play.isPaused)

        clock.advance(30)
        await play.sceneDidEnterBackground()
        XCTAssertTrue(play.isPaused)
        XCTAssertEqual(model.session.state, .paused)
        // Background autosave: battery snapshot + Auto Resume + Continue screenshot (none: no frames in the fake).
        let battery = await model.batterySave(for: game.id)
        XCTAssertEqual(battery?.sizeInBytes, 4)
        let states = try await model.environment.saveStates!.states(for: game.id)
        XCTAssertEqual(states.map(\.kind), [.auto])
        XCTAssertFalse(play.lastAutoSaveFailed)

        clock.advance(120)
        play.sceneDidBecomeActive()
        XCTAssertTrue(play.isPaused, "stays paused with the overlay after returning")
        play.resume()
        XCTAssertFalse(play.isPaused)
        XCTAssertEqual(model.session.state, .running)
        clock.advance(10)
        await model.stop()
        XCTAssertFalse(model.isPlaying)
        let entry = try XCTUnwrap(model.history[game.id])
        XCTAssertEqual(entry.latestSession.pausedDuration, 120)
        XCTAssertEqual(entry.totalPlayDuration, 40, "30 s before + 10 s after; the 120 s in the background do not count")
        XCTAssertEqual(factory.driver.log.last, "stop")
        // Exit wrote another Auto Resume (history keeps up to 3).
        let after = try await model.environment.saveStates!.states(for: game.id)
        XCTAssertEqual(after.filter { $0.kind == .auto }.count, 2)
        XCTAssertNil(play.game)
    }

    /// B2-IPH-001: a long foreground Pause used to be recorded as play time.
    func testForegroundPauseIsExcludedFromPlayTime() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play

        clock.advance(120)                  // two minutes of real play
        play.pause()                        // Pause overlay, app stays in front
        XCTAssertTrue(play.isPaused)
        clock.advance(5_280)                // ~1 h 28 m left on the Pause screen
        await model.stop()                  // Exit Game from the overlay

        XCTAssertFalse(model.isPlaying)
        let entry = try XCTUnwrap(model.history[game.id])
        XCTAssertEqual(entry.latestSession.pausedDuration, 5_280, accuracy: 0.001)
        XCTAssertEqual(entry.totalPlayDuration, 120, accuracy: 0.001, "paused time is not play time")
        XCTAssertEqual(play.backgroundDuration, 5_280, accuracy: 0.001)
    }

    /// A pause that overlaps background/inactive time is counted once.
    func testPauseOverlappingBackgroundTimeIsCountedOnce() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play

        clock.advance(30)
        play.pause()                        // paused in the foreground
        clock.advance(10)
        await play.sceneDidEnterBackground() // still paused; same interval continues
        clock.advance(100)
        play.sceneDidBecomeActive()          // returns, still paused with the overlay
        clock.advance(20)
        play.resume()
        clock.advance(10)
        await model.stop()

        let entry = try XCTUnwrap(model.history[game.id])
        XCTAssertEqual(entry.latestSession.pausedDuration, 130, accuracy: 0.001, "10 s + 100 s + 20 s, counted once")
        XCTAssertEqual(entry.totalPlayDuration, 40, accuracy: 0.001)
    }

    /// Repeated lifecycle callbacks must not open a second interval.
    func testRepeatedLifecycleCallbacksDoNotDoubleCountPausedTime() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play

        clock.advance(10)
        await play.sceneDidEnterBackground()
        play.sceneDidBecomeActive()
        await play.sceneDidEnterBackground()
        play.sceneDidBecomeActive()
        await play.sceneDidEnterBackground()   // repeated callbacks while already paused
        clock.advance(50)
        play.resume()
        clock.advance(10)
        await model.stop()

        let entry = try XCTUnwrap(model.history[game.id])
        XCTAssertEqual(entry.latestSession.pausedDuration, 50, accuracy: 0.001, "one interval, from the first pause to the resume")
        XCTAssertEqual(entry.totalPlayDuration, 20, accuracy: 0.001)
    }

    /// An ordinary session without any pause keeps its full wall-clock duration.
    func testUnpausedSessionKeepsItsFullDuration() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        clock.advance(90)
        await model.stop()

        let entry = try XCTUnwrap(model.history[game.id])
        XCTAssertEqual(entry.latestSession.pausedDuration, 0, accuracy: 0.001)
        XCTAssertEqual(entry.totalPlayDuration, 90, accuracy: 0.001)
    }

    func testQuickSaveThenContinueRestoresAutoResumeAndBrowserHidesIt() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play
        let valueAtSave = factory.driver.serializer.value
        await play.quickSave()
        XCTAssertEqual(play.toast?.text, String(localized: "Saved", bundle: .module))
        XCTAssertEqual(play.quickStates.count, 1)
        XCTAssertNil(play.problem)
        _ = try factory.driver.serializer.serializeState()   // the machine moves on
        _ = try factory.driver.serializer.serializeState()
        let valueAtExit = factory.driver.serializer.value
        XCTAssertGreaterThan(valueAtExit, valueAtSave)
        await model.stop()

        // Continue: the Auto Resume state written at exit is restored on launch.
        await model.play(game.id)
        XCTAssertEqual(factory.driver.serializer.value, valueAtExit + 1, "restored the state captured at exit (capture increments once)")
        XCTAssertTrue(factory.driver.log.contains("flush"), "audio flushed on restore")
        let browser = await model.browserStates(for: game.id)
        XCTAssertEqual(browser.quick.count, 1)
        XCTAssertTrue(browser.manual.isEmpty)
        let all = try await model.environment.saveStates!.states(for: game.id)
        XCTAssertTrue(all.contains { $0.kind == .auto }, "Auto Resume exists but is not in the browser")

        // Quick Load restores the quick save.
        await play.quickLoad()
        XCTAssertEqual(factory.driver.serializer.value, valueAtSave + 1)
        XCTAssertTrue(play.toast?.text.hasPrefix(String(localized: "Loaded · \("")", bundle: .module).prefix(4)) ?? false)
        await model.stop()
    }

    func testControllerCommandsCannotBypassAnOpenRelayTool() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play
        let actions = RelayActions()
        play.allowsGameplayCommands = { actions.canPresentRelaySurface }
        let bridge = GameControllerInputBridge(session: model.session, system: SystemCatalog.gameBoyAdvance)
        play.pause()
        XCTAssertTrue(actions.beginPresentation(.playTool))
        let before = factory.driver.log
        for command: InputCommand in [.pause, .quickSave, .quickLoad, .rewind, .fastForward, .screenshot] {
            play.inputBridge(bridge, command: command, pressed: true)
        }
        XCTAssertTrue(play.isPaused, "the modal's pause host must remain mounted")
        XCTAssertEqual(model.session.state, .paused)
        XCTAssertEqual(factory.driver.log, before, "blocked commands never reach the game or capture a state")
        XCTAssertEqual(play.speed, .normal)
        XCTAssertFalse(play.isRewinding)

        actions.presentationDidDismiss(.playTool)
        play.inputBridge(bridge, command: .pause, pressed: true)
        XCTAssertFalse(play.isPaused, "the same physical command works again after native dismissal")
        await model.stop()
    }

    func testHeldControllerCommandCanReleaseWhileARelayToolOwnsPresentation() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play
        let actions = RelayActions()
        play.allowsGameplayCommands = { actions.canPresentRelaySurface }
        let bridge = GameControllerInputBridge(session: model.session, system: SystemCatalog.gameBoyAdvance)
        play.inputBridge(bridge, command: .fastForward, pressed: true)
        XCTAssertEqual(play.speed, .double)
        XCTAssertTrue(actions.beginPresentation(.playTool))
        play.inputBridge(bridge, command: .fastForward, pressed: false)
        XCTAssertEqual(play.speed, .normal, "opening a tool must not strand a held speed command")
        actions.presentationDidDismiss(.playTool)
        await model.stop()
    }

    func testIncompatibleAndCorruptStatesAreRefusedWithHumanMessages() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play
        await play.saveNow()
        let manual = try XCTUnwrap(play.manualStates.first)
        // Simulate a state from another core version.
        let older = SaveState(id: manual.id, gameID: manual.gameID, coreID: manual.coreID, coreVersion: "0", kind: .manual,
                              createdAt: manual.createdAt, location: manual.location, screenshotLocation: manual.screenshotLocation)
        let before = factory.driver.serializer.value
        await play.load(older)
        XCTAssertEqual(play.problem?.headline, String(localized: "This save was made with an older version of Relay and can't be loaded safely.", bundle: .module))
        XCTAssertEqual(factory.driver.serializer.value, before, "nothing reached the core")
        play.clearProblem()
        // Corrupt the file.
        let url = model.environment.location.url(for: manual.location)
        try Data("junk".utf8).write(to: url)
        await play.load(manual)
        XCTAssertEqual(play.problem?.headline, String(localized: "This save is damaged and can't be loaded.", bundle: .module))
        XCTAssertEqual(factory.driver.serializer.value, before)
        play.clearProblem()
        await play.delete(manual)
        XCTAssertTrue(play.manualStates.isEmpty)
        await model.stop()
    }

    func testRewindAndSpeedThroughThePlayModel() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play
        for _ in 0..<100 where !play.hasRewindHistory {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(play.hasRewindHistory)
        let before = factory.driver.serializer.value
        play.beginRewind()
        XCTAssertTrue(play.isRewinding)
        try await Task.sleep(for: .milliseconds(120))
        play.endRewind()
        XCTAssertFalse(play.isRewinding)
        XCTAssertLessThan(factory.driver.serializer.value, before)
        XCTAssertEqual(model.session.state, .running)

        play.setFastForwardHeld(true)
        XCTAssertEqual(play.speed, .double)
        XCTAssertTrue(factory.driver.log.contains("speed:double"))
        play.setFastForwardHeld(false)
        XCTAssertEqual(play.speed, .normal)
        play.setSpeed(.maximum)
        XCTAssertEqual(play.speed, .normal, "Max is a Pro preset")
        await model.stop()
        XCTAssertEqual(model.session.speed, .normal)
    }

    func testControllerDisconnectPausesWithNoticeAndTouchReturns() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        let play = model.play
        let bridge = GameControllerInputBridge(session: model.session, system: SystemCatalog.gameBoyAdvance)
        play.inputBridge(bridge, controllerDidConnect: "DualSense")
        XCTAssertEqual(play.controllerName, "DualSense")
        XCTAssertTrue(play.touchControlsHidden)
        XCTAssertEqual(play.toast?.text, String(localized: "\("DualSense") connected", bundle: .module))
        play.inputBridgeControllerDidDisconnect(bridge)
        XCTAssertTrue(play.isPaused)
        XCTAssertEqual(play.notice, .controllerDisconnected)
        XCTAssertFalse(play.touchControlsHidden)
        XCTAssertNil(play.controllerName)
        play.resume()   // iPhone: touch is a valid fallback, resume allowed
        XCTAssertFalse(play.isPaused)
        XCTAssertNil(play.notice)
        play.inputBridge(bridge, command: .pause, pressed: true)
        XCTAssertTrue(play.isPaused)
        await model.stop()
    }

    func testDisplayPreferenceIsRememberedPerSystem() async throws {
        let model = makeModel()
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        XCTAssertEqual(model.play.display, .standard)
        model.play.display = DisplayOptions(scaling: .fit, filter: .sharp)
        await model.stop()
        await model.play(game.id)
        XCTAssertEqual(model.play.display, DisplayOptions(scaling: .fit, filter: .sharp))
        await model.stop()
    }

    func testProSpeedsAndRewindReactToEntitlementWithoutRestart() async throws {
        let provider = PlayEntitlementProvider(state: .free)
        let model = makeModel(entitlementProvider: provider)
        await model.load()
        let game = try await importGame(into: model)
        model.play.preferences.rewindDuration = 60
        await model.play(game.id)

        XCTAssertEqual(model.play.effectiveRewindDuration, 10)
        XCTAssertEqual(model.play.availableSpeeds, [.normal, .double])
        provider.send(RelayEntitlementState(activeProductIDs: [.proMonthly]))
        for _ in 0..<50 where !model.play.allows(.advancedSpeeds) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.play.effectiveRewindDuration, 60)
        XCTAssertTrue(model.play.availableSpeeds.contains(.quarter))
        model.play.setSpeed(.quadruple)
        XCTAssertEqual(model.play.speed, .quadruple)

        provider.send(.free)
        for _ in 0..<50 where model.play.allows(.advancedSpeeds) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.play.speed, .normal)
        XCTAssertEqual(model.play.effectiveRewindDuration, 10)
        XCTAssertEqual(model.play.preferences.rewindDuration, 60, "the Pro preference survives")
        await model.stop()
    }

    func testCheatCreatesSafetyStateAndDefinitionsSurviveEntitlementLoss() async throws {
        let provider = PlayEntitlementProvider(state: RelayEntitlementState(activeProductIDs: [.proOnce]))
        let model = makeModel(entitlementProvider: provider)
        await model.load()
        let game = try await importGame(into: model)
        await model.play(game.id)
        XCTAssertEqual(model.play.addCheat(CheatDefinition(label: "", code: "01234567", format: .gameShark)), .emptyLabel)
        XCTAssertEqual(model.play.addCheat(CheatDefinition(label: "Wrong format", code: "01234567", format: .codeBreaker)), .unsupportedFormat)
        let cheat = CheatDefinition(label: "Test", code: "01234567", format: .gameShark)
        XCTAssertNil(model.play.addCheat(cheat))

        await model.play.setCheatEnabled(cheat.id, enabled: true)
        await model.play.setCheatEnabled(cheat.id, enabled: false)
        await model.play.setCheatEnabled(cheat.id, enabled: true)
        let saved = try await model.environment.saveStates!.states(for: game.id)
        XCTAssertEqual(saved.filter { $0.label == "relay.preCheatSafety" }.count, 1,
                       "one immutable safety point covers the play session")
        XCTAssertTrue(factory.driver.log.contains("cheats:1"))

        provider.send(.free)
        for _ in 0..<50 where model.play.allows(.cheats) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.play.cheats.first?.isEnabled == true, "definition remains stored")
        XCTAssertTrue(factory.driver.log.contains("cheats:0"), "runtime cheats are removed")
        await model.stop()
    }

    func testAdvancedConfigurationFallsBackFreeWithoutBeingDeleted() {
        let preferences = PlayPreferences(defaults: defaults)
        let free = RelayAccessPolicy(entitlement: .free)
        let pro = RelayAccessPolicy(entitlement: RelayEntitlementState(activeProductIDs: [.proOnce]))
        let display = DisplayOptions(scaling: .fill, filter: .crtSoft)
        preferences.setDisplayOptions(display, for: .gameBoyAdvance)
        XCTAssertEqual(preferences.displayOptions(for: .gameBoyAdvance, gameID: nil, policy: free),
                       DisplayOptions(scaling: .fit, filter: .original))
        XCTAssertEqual(preferences.displayOptions(for: .gameBoyAdvance, gameID: nil, policy: pro), display)

        let gameID = GameID()
        let perGameDisplay = DisplayOptions(scaling: .integer, filter: .smooth)
        preferences.setDisplayOptions(perGameDisplay, for: gameID)
        preferences.setScreenArrangement(.sideBySide, for: .nintendoDS)
        preferences.setScreenArrangement(.secondaryPrimary, for: gameID)
        XCTAssertEqual(preferences.displayOptions(for: .gameBoyAdvance, gameID: gameID, policy: pro), perGameDisplay)
        XCTAssertEqual(preferences.displayOptions(for: .gameBoyAdvance, gameID: gameID, policy: free),
                       DisplayOptions(scaling: .fit, filter: .original),
                       "Free falls back without erasing the per-game choice")
        XCTAssertEqual(preferences.screenArrangement(for: .nintendoDS, gameID: gameID, policy: pro), .secondaryPrimary)
        XCTAssertEqual(preferences.screenArrangement(for: .nintendoDS, gameID: gameID, policy: free), .sideBySide)

        let mapping = ControllerMappingProfile(bindings: [.buttonA: .command(.quickSave)])
        preferences.setControllerMapping(mapping, for: SystemCatalog.gameBoyAdvance)
        XCTAssertTrue(preferences.controllerMapping(for: SystemCatalog.gameBoyAdvance, gameID: nil, policy: free).bindings.isEmpty)
        XCTAssertEqual(preferences.controllerMapping(for: SystemCatalog.gameBoyAdvance, gameID: nil, policy: pro), mapping)

        let perGame = ControllerMappingProfile(bindings: [.buttonB: .command(.screenshot)])
        preferences.setControllerMapping(perGame, for: gameID, system: SystemCatalog.gameBoyAdvance)
        XCTAssertTrue(preferences.hasControllerMapping(for: gameID))
        XCTAssertEqual(preferences.controllerMapping(for: SystemCatalog.gameBoyAdvance, gameID: gameID, policy: pro), perGame)
        XCTAssertTrue(preferences.controllerMapping(for: SystemCatalog.gameBoyAdvance, gameID: gameID, policy: free).bindings.isEmpty)
        preferences.clearControllerMapping(for: gameID)
        XCTAssertFalse(preferences.hasControllerMapping(for: gameID))
        XCTAssertEqual(preferences.controllerMapping(for: SystemCatalog.gameBoyAdvance, gameID: gameID, policy: pro), mapping)

        let fallbackTouch = TouchLayout.layout(for: SystemCatalog.gameBoyAdvance.inputLayout, portrait: true, scale: 1)
        let movedA = fallbackTouch.elements.first { $0.control == .a }!.moved(to: CGPoint(x: 0.5, y: 0.5))
        let customTouch = fallbackTouch.replacing(movedA)
        preferences.setTouchLayout(customTouch, for: SystemCatalog.gameBoyAdvance, portrait: true, scale: 1)
        XCTAssertEqual(preferences.touchLayout(for: SystemCatalog.gameBoyAdvance, portrait: true, scale: 1, policy: free), fallbackTouch)
        XCTAssertEqual(preferences.touchLayout(for: SystemCatalog.gameBoyAdvance, portrait: true, scale: 1, policy: pro), customTouch)
        preferences.resetTouchLayout(for: .gameBoyAdvance, portrait: true)
        XCTAssertEqual(preferences.touchLayout(for: SystemCatalog.gameBoyAdvance, portrait: true, scale: 1, policy: pro), fallbackTouch)
    }
}

@MainActor
private final class PlayEntitlementProvider: RelayEntitlementProviding {
    private(set) var state: RelayEntitlementState
    private var continuation: AsyncStream<RelayEntitlementState>.Continuation?

    init(state: RelayEntitlementState) { self.state = state }

    func stateUpdates() -> AsyncStream<RelayEntitlementState> {
        let state = self.state
        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(state)
        }
    }

    func loadProducts() async throws -> [RelayStoreProduct] { [] }
    func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome { .userCancelled }
    func restorePurchases() async throws -> RelayEntitlementState { state }
    func refresh() async -> RelayEntitlementState { state }
    func send(_ state: RelayEntitlementState) { self.state = state; continuation?.yield(state) }
}

private final class AchievementJourneyStore: AchievementSecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
    func remove(_ key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private struct AchievementJourneyTransport: AchievementHTTPTransport {
    func send(_ request: URLRequest) async -> AchievementHTTPResponse {
        if String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("r=login2") {
            return .init(status: 200, body: Data("{\"Success\":true,\"User\":\"RelayFixture\",\"Token\":\"fixture-session\",\"Score\":0,\"SoftcoreScore\":0,\"Messages\":0}".utf8))
        }
        return .unavailable
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  EmulationDriver.swift
//  RelayEmulation
//
//  The adapter contract. One driver instance = one loaded game in one core.

import Foundation
import RelayDomain
@_exported import RelayAchievementInterfaces

public enum EmulationControllerKind: String, CaseIterable, Codable, Sendable {
    case digital, dualShock
}

public struct EmulationDiscStatus: Equatable, Sendable {
    public let count: Int
    public let selectedIndex: Int
    public init(count: Int, selectedIndex: Int) { self.count = count; self.selectedIndex = selectedIndex }
}

/// Directories a driver may write to for a given game.
public struct EmulationStorage: Sendable {
    /// Where the core writes battery saves (SRAM/flash) for this game.
    public let batterySavesDirectory: URL
    public let saveStatesDirectory: URL
    /// Where firmware/BIOS files are looked up (unused by mGBA which has HLE BIOS).
    public let firmwareDirectory: URL

    public init(batterySavesDirectory: URL, saveStatesDirectory: URL, firmwareDirectory: URL) {
        self.batterySavesDirectory = batterySavesDirectory
        self.saveStatesDirectory = saveStatesDirectory
        self.firmwareDirectory = firmwareDirectory
    }
}

/// Thread-safe access to the core's whole machine state, vended by drivers whose
/// core has `CoreCapabilities.saveStates`. Implementations serialise against the
/// core's own frame lock so callers may use them from any thread (the rewind
/// engine captures off the main actor).
public protocol EmulationStateSerializer: AnyObject, Sendable {
    /// The complete machine state as opaque, core-defined bytes.
    func serializeState() throws -> Data
    /// Restores a state previously produced by `serializeState` on the same core version.
    func restoreState(_ data: Data) throws
    /// Runs exactly one emulated frame. Only meaningful while the core is paused;
    /// used to refresh the picture after a restore without resuming play.
    func runSingleFrame()
}

/// All methods are called on the main actor by `EmulationSession`; drivers own
/// their real-time threads internally and must never hop actors in the frame path.
@MainActor
public protocol EmulationDriver: AnyObject {
    var descriptor: EmulatorCoreDescriptor { get }
    /// Available after `load` succeeds. The system's first (or only) screen.
    var frameSource: VideoFrameSource? { get }
    /// One source per logical screen, in `SystemDescriptor.screens` order;
    /// `[frameSource]` for a single-screen system.
    var screenFrameSources: [VideoFrameSource] { get }
    /// Available after `load` succeeds when the core supports save states; nil otherwise.
    var stateSerializer: (any EmulationStateSerializer)? { get }
    /// Installs a synchronous, per-emulated-frame observer after load and before
    /// start. Memory stays under the driver's machine lock. Nil detaches it.
    func setAchievementRuntime(_ runtime: AchievementRuntimeSlot?)

    func load(romURL: URL, storage: EmulationStorage) throws
    func start() throws
    func setPaused(_ paused: Bool)
    func stop()

    func press(_ input: EmulationInput)
    func release(_ input: EmulationInput)
    /// Sets a continuous control to `value`, already clamped to the axis's
    /// legal range. A no-op for cores without `.analogInput`.
    func move(_ axis: EmulationAxis, to value: Float)
    /// A touch on the screen at `screenIndex` (into `screenFrameSources`), in
    /// that screen's native pixels. A no-op for cores without `.touchInput`.
    func touch(screenIndex: Int, x: Int, y: Int)
    func releaseTouch()

    func startAudio() throws
    func stopAudio()
    /// Drops audio queued by the core that has not been played yet (after a
    /// state restore or a rewind, so stale sound never plays).
    func flushAudio()

    /// Changes the emulation speed; a no-op for cores without `.fastForward`.
    func setSpeed(_ speed: EmulationSpeed)
    /// Exact presets this adapter can execute safely and truthfully.
    var supportedSpeeds: Set<EmulationSpeed> { get }

    /// Formats accepted by this adapter. Empty when cheats are unavailable.
    var supportedCheatFormats: Set<CheatFormat> { get }
    func validateCheat(_ cheat: CheatDefinition) -> CheatValidationError?
    /// Replaces the active runtime cheat set atomically from Relay's point of view.
    func applyCheats(_ cheats: [CheatDefinition]) throws

    /// The game's current battery save (its own persistent memory) as the core
    /// holds it right now, in the game's native format. Nil when the game has
    /// written nothing yet or the core cannot expose it. Never a save state.
    func batterySaveData() -> Data?

    /// True when Relay must regularly snapshot persistent RAM because the core never writes a live file.
    var requiresBatterySnapshots: Bool { get }
    var discStatus: EmulationDiscStatus? { get }
    func selectDisc(at index: Int) throws
    var supportedControllers: Set<EmulationControllerKind> { get }
    var controllerKind: EmulationControllerKind { get }
    func setControllerKind(_ kind: EmulationControllerKind) throws
    var analogModeEnabled: Bool { get }
    func setAnalogModeEnabled(_ enabled: Bool) throws
    var usesEmulatedFirmware: Bool { get }

    /// Snapshot of driver-side diagnostics (frame rate etc.).
    func sampleDiagnostics() -> EmulationDiagnostics
}

public extension EmulationDriver {
    var requiresBatterySnapshots: Bool { false }
    var discStatus: EmulationDiscStatus? { nil }
    func selectDisc(at index: Int) throws { throw EmulationError.unsupported("disc switching") }
    var supportedControllers: Set<EmulationControllerKind> { [] }
    var controllerKind: EmulationControllerKind { .digital }
    func setControllerKind(_ kind: EmulationControllerKind) throws { throw EmulationError.unsupported("controller type") }
    var analogModeEnabled: Bool { false }
    func setAnalogModeEnabled(_ enabled: Bool) throws { throw EmulationError.unsupported("analog mode") }
    var usesEmulatedFirmware: Bool { false }
    func setAchievementRuntime(_ runtime: AchievementRuntimeSlot?) {}
    var stateSerializer: (any EmulationStateSerializer)? { nil }
    var screenFrameSources: [VideoFrameSource] { frameSource.map { [$0] } ?? [] }
    func move(_ axis: EmulationAxis, to value: Float) {}
    func touch(screenIndex: Int, x: Int, y: Int) {}
    func releaseTouch() {}
    func flushAudio() {}
    func setSpeed(_ speed: EmulationSpeed) {}
    var supportedSpeeds: Set<EmulationSpeed> {
        // The conservative protocol default preserves the baseline feature.
        // Every advanced preset must be opted into by an adapter that has
        // actually qualified it.
        descriptor.capabilities.contains(.fastForward) ? [.normal, .double] : [.normal]
    }
    var supportedCheatFormats: Set<CheatFormat> { [] }
    func validateCheat(_ cheat: CheatDefinition) -> CheatValidationError? { .unsupportedFormat }
    func applyCheats(_ cheats: [CheatDefinition]) throws {
        guard cheats.isEmpty else { throw EmulationError.unsupported("cheats") }
    }
    func batterySaveData() -> Data? { nil }
}

/// Creates drivers. Lets the shells stay ignorant of concrete adapters.
@MainActor
public protocol EmulationDriverFactory: AnyObject {
    var availableCores: [EmulatorCoreDescriptor] { get }
    /// - Parameter systemID: which of the core's systems is being played. A
    ///   core that runs several systems (mGBA runs Game Boy, Game Boy Color and
    ///   Game Boy Advance) needs to know before it loads anything.
    func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver
}

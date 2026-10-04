// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MGBADriver.swift
//  RelayProvenanceAdapter
//
//  EmulationDriver backed by Provenance's PVmGBACore (PVEmulatorCore subclass
//  over the ObjC++ PVmGBAGameCoreBridge and the vendored libmGBA sources).
//
//  Lifecycle mirrors upstream PVEmulatorViewController.initCore/createEmulator:
//    set paths → initialize() → loadFile(atPath:) → setupAudioGraph → startEmulation().
//  The core runs its own real-time thread (PVCoreObjCBridge.emulationLoopThread);
//  nothing here touches the frame path.

import Foundation
import RelayDomain
import RelayEmulation
import PVEmulatorCore
import PVCoreBridge
import PVCoreAudio
import PVAudio
import PVLogging
import PVmGBACore
import PVmGBABridge
import ObjectiveC

@MainActor
final class MGBADriver: EmulationDriver {
    /// Version reported by the vendored core package's Core.plist.
    static let upstreamVersion = "0.10.3"

    let descriptor = ProvenanceDriverFactory.mgbaDescriptor

    private(set) var frameSource: VideoFrameSource?
    private(set) var stateSerializer: (any EmulationStateSerializer)?

    private let core: PVmGBACore
    private var audio: AVAudioEngineGameAudioEngine?
    private var audioGraphReady = false
    private var audioRunning = false
    private var loaded = false
    private var started = false

    /// The Relay system this driver was created for. mGBA runs three, and the
    /// system decides which mGBA core the vendored bridge builds.
    private let systemID: SystemID

    init(systemID: SystemID) {
        self.systemID = systemID
        core = PVmGBACore()
        // Set before `initialize()`: the bridge reads it to decide whether to
        // create the Game Boy core or the Game Boy Advance one.
        core.systemIdentifier = ProvenanceDriverFactory.provenanceSystemIdentifier(for: systemID)
        core.coreIdentifier = "com.provenance.core.mGBA"
    }

    // MARK: EmulationDriver

    func load(romURL: URL, storage: EmulationStorage) throws {
        guard !loaded else { throw EmulationError.invalidState("driver already loaded") }
        let fm = FileManager.default
        for dir in [storage.batterySavesDirectory, storage.saveStatesDirectory, storage.firmwareDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        core.batterySavesPath = storage.batterySavesDirectory.path
        core.saveStatesPath = storage.saveStatesDirectory.path
        core.BIOSPath = storage.firmwareDirectory.path
        core.romName = romURL.deletingPathExtension().lastPathComponent

        // Creates the mGBA core instance and its video/audio buffers.
        core.initialize()
        do {
            // `PVEmulatorCore.loadFile` is a stub that throws; the real loader lives on the
            // ObjC bridge. Upstream's PVEmulatorViewController uses the same dispatch.
            if let bridge = core.bridge as? EmulatorCoreIOInterface {
                try bridge.loadFile(atPath: romURL.path)
            } else {
                try core.loadFile(atPath: romURL.path)
            }
        } catch {
            throw EmulationError.loadFailed(error.localizedDescription)
        }
        // Choose the bounded single-producer/single-consumer implementation
        // before either the emulation thread or the audio node starts. The
        // upstream default can overwrite unread samples when a write crosses
        // its remaining capacity, then report more queued bytes than it owns.
        guard let buffer = Self.makeAudioBuffer(length: Int(core.audioBufferSize(forBuffer: 0)) * 32) else {
            throw EmulationError.audioFailed("could not allocate the audio ring buffer")
        }
        core.ringBuffers = [buffer]
        loaded = true
        frameSource = ProvenanceFrameSource(core: core)
        if let bridge = core.bridge as? PVmGBAGameCoreBridge {
            stateSerializer = MGBAStateSerializer(bridge: bridge)
        }
    }

    func start() throws {
        guard loaded else { throw EmulationError.invalidState("start() before load()") }
        guard !started else { return }
        core.startEmulation()
        guard core.isRunning else { throw EmulationError.startFailed("core did not enter the running state") }
        started = true
    }

    func setAchievementRuntime(_ runtime: AchievementRuntimeSlot?) {
        guard let bridge = core.bridge as? PVmGBAGameCoreBridge else { return }
        objc_sync_enter(bridge); defer { objc_sync_exit(bridge) }
        (stateSerializer as? MGBAStateSerializer)?.invalidate()
        if let runtime {
            bridge.relayFrameHandler = { [weak bridge] in
                guard let bridge else { return }
                runtime.evaluateFrame { region, offset, buffer in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Int(bridge.relayReadMemoryRegion(region.rawValue, offset: offset, buffer: base, count: UInt(buffer.count)))
                }
            }
            bridge.relayResetHandler = { runtime.resetProgress() }
        } else {
            bridge.relayFrameHandler = nil; bridge.relayResetHandler = nil
        }
        stateSerializer = MGBAStateSerializer(bridge: bridge, achievements: runtime)
    }

    func setPaused(_ paused: Bool) {
        guard started else { return }
        core.setPauseEmulation(paused)
    }

    func stop() {
        stopAudio()
        setAchievementRuntime(nil)
        if started {
            core.stopEmulation()
            started = false
        }
        frameSource = nil
        stateSerializer = nil
        loaded = false
    }

    func flushAudio() {
        core.ringBuffer(atIndex: 0)?.clear()
    }

    func batterySaveData() -> Data? {
        guard loaded, let bridge = core.bridge as? PVmGBAGameCoreBridge else { return nil }
        objc_sync_enter(bridge); defer { objc_sync_exit(bridge) }
        return bridge.relay_cloneBatterySave()
    }

    func setSpeed(_ speed: EmulationSpeed) {
        // This bridge exposes 0.5×, 1×, 2× and 5×. Relay does not pretend it
        // can run the 0.25×/3×/4× presets supported by the other adapters.
        switch speed {
        case .half: core.gameSpeed = .slow
        case .normal: core.gameSpeed = .normal
        case .double: core.gameSpeed = .fast
        case .maximum: core.gameSpeed = .veryFast
        case .quarter, .triple, .quadruple: return
        }
    }

    var supportedSpeeds: Set<EmulationSpeed> { [.half, .normal, .double, .maximum] }

    var supportedCheatFormats: Set<CheatFormat> { [.gameShark, .codeBreaker, .proActionReplay] }

    func validateCheat(_ cheat: CheatDefinition) -> CheatValidationError? {
        guard !cheat.label.isEmpty else { return .emptyLabel }
        guard !cheat.code.isEmpty else { return .emptyCode }
        guard supportedCheatFormats.contains(cheat.format) else { return .unsupportedFormat }
        let lines = cheat.code
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: { $0 == "+" || $0 == "\n" })
        guard !lines.isEmpty else { return .malformedCode }
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-:"))
        let hexadecimalDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        for line in lines {
            let compact = String(line).components(separatedBy: separators).joined()
            guard (8...16).contains(compact.count), compact.count.isMultiple(of: 2),
                  compact.unicodeScalars.allSatisfy(hexadecimalDigits.contains) else {
                return .malformedCode
            }
        }
        return nil
    }

    func applyCheats(_ cheats: [CheatDefinition]) throws {
        guard loaded, let bridge = core.bridge as? PVmGBAGameCoreBridge else {
            throw EmulationError.invalidState("cheats applied before load")
        }
        objc_sync_enter(bridge); defer { objc_sync_exit(bridge) }
        bridge.resetCheatCodes()
        for cheat in cheats where cheat.isEnabled {
            guard validateCheat(cheat) == nil else {
                throw EmulationError.unsupported("invalid cheat")
            }
            let applied = bridge.setCheat(
                cheat.code.replacingOccurrences(of: "\n", with: "+"),
                setType: cheat.id.uuidString,
                setEnabled: true
            )
            guard applied else {
                bridge.resetCheatCodes()
                throw EmulationError.unsupported("cheat was rejected by the core")
            }
        }
    }

    func press(_ input: EmulationInput) {
        guard let button = Self.button(for: input) else { return }
        core.didPush(button, forPlayer: 0)
    }

    func release(_ input: EmulationInput) {
        guard let button = Self.button(for: input) else { return }
        core.didRelease(button, forPlayer: 0)
    }

    func startAudio() throws {
        guard loaded else { throw EmulationError.audioFailed("no game loaded") }
        if audio == nil { audio = AVAudioEngineGameAudioEngine() }
        guard let audio else { return }
        if !audioGraphReady {
            do {
                try audio.setupAudioGraph(for: core)
                audioGraphReady = true
            } catch {
                throw EmulationError.audioFailed(error.localizedDescription)
            }
        }
        audio.startAudio()
        audioRunning = true
    }

    func stopAudio() {
        guard audioRunning, let audio else { return }
        audio.stopAudio()
        audioRunning = false
    }

    func sampleDiagnostics() -> EmulationDiagnostics {
        var d = EmulationDiagnostics()
        d.emulationFramesPerSecond = core.emulationFPS
        d.audioSampleRate = core.audioSampleRate
        d.audioRunning = audioRunning
        d.audioBufferedBytes = core.ringBuffer(atIndex: 0)?.availableBytesForReading ?? 0
        return d
    }

    // MARK: Mapping

    static func makeAudioBuffer(length: Int) -> (any RingBufferProtocol)? {
        RingBufferType.openEMU.make(withLength: length)
    }

    /// Relay buttons the mGBA core has. The Game Boy has no shoulder buttons,
    /// but nothing needs to special-case that here: `SystemInputLayout` stops
    /// the input layer from ever producing `.l`/`.r` for a Game Boy, and the
    /// core's own key bits for the eight shared buttons are identical between
    /// its Game Boy and Game Boy Advance cores. Buttons no mGBA system has are
    /// dropped rather than mapped to something the player did not press.
    private static func button(for input: EmulationInput) -> PVGBAButton? {
        switch input {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .a: return .a
        case .b: return .b
        case .l: return .l
        case .r: return .r
        case .start: return .start
        case .select: return .select
        case .x, .y, .l2, .r2, .l3, .r3, .z, .mode, .cUp, .cDown, .cLeft, .cRight: return nil
        }
    }
}

/// Whole-machine state through the mGBA bridge's in-memory serializer. Every call
/// holds the bridge's monitor — the same `@synchronized(self)` the emulation loop
/// takes around `executeFrame` — so serialisation never observes a half-run frame
/// and callers may use it from any thread (the rewind capture task does).
final class MGBAStateSerializer: EmulationStateSerializer, @unchecked Sendable {
    private let bridge: PVmGBAGameCoreBridge
    private let achievements: AchievementRuntimeSlot?
    private var valid = true

    init(bridge: PVmGBAGameCoreBridge, achievements: AchievementRuntimeSlot? = nil) {
        self.bridge = bridge
        self.achievements = achievements
    }

    func serializeState() throws -> Data {
        objc_sync_enter(bridge); defer { objc_sync_exit(bridge) }
        guard valid else { throw EmulationError.stateFailed("mGBA session has ended") }
        return AchievementStateEnvelope.append(to: try bridge.serializeState(), progress: achievements?.captureProgress())
    }

    func restoreState(_ data: Data) throws {
        guard achievements?.hardcoreEnabled != true else { throw EmulationError.unsupported("state loading in Hardcore") }
        objc_sync_enter(bridge); defer { objc_sync_exit(bridge) }
        guard valid else { throw EmulationError.stateFailed("mGBA session has ended") }
        let state = try AchievementStateEnvelope.split(data)
        try bridge.deserializeState(state.core)
        achievements?.restoreProgress(state.progress)
    }

    func runSingleFrame() {
        guard achievements?.hardcoreEnabled != true else { return }
        objc_sync_enter(bridge); defer { objc_sync_exit(bridge) }
        guard valid else { return }
        achievements?.setPreviewing(true)
        defer { achievements?.setPreviewing(false) }
        bridge.executeFrame()
    }

    func invalidate() {
        objc_sync_enter(bridge); defer { objc_sync_exit(bridge) }
        valid = false
    }
}

/// Exposes the core's software framebuffer (RGBX8, 240×160 for GBA) to presenters.
/// The core writes the buffer from its emulation thread; presenters sample it
/// at display rate, exactly as upstream PVMetalViewController does for
/// non-double-buffered cores.
final class ProvenanceFrameSource: VideoFrameSource, @unchecked Sendable {
    private let core: PVEmulatorCore

    init(core: PVEmulatorCore) {
        self.core = core
    }

    var frameDescriptor: FrameDescriptor {
        let size = core.bufferSize
        let rect = core.screenRect
        let width = Int(rect.width > 0 ? rect.width : size.width)
        let height = Int(rect.height > 0 ? rect.height : size.height)
        let aspect = core.aspectSize
        let aspectRatio = aspect.height > 0 ? Double(aspect.width / aspect.height) : Double(width) / Double(max(height, 1))
        return FrameDescriptor(width: width,
                               height: height,
                               bytesPerRow: Int(size.width) * 4,
                               pixelFormat: .rgbx8,
                               aspectRatio: aspectRatio)
    }

    func withCurrentFrame(_ body: (UnsafeRawPointer, FrameDescriptor) -> Void) {
        guard let buffer = core.videoBuffer else { return }
        let descriptor = frameDescriptor
        guard descriptor.width > 0, descriptor.height > 0 else { return }
        body(buffer, descriptor)
    }
}

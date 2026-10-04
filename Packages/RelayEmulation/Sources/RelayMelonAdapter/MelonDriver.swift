// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MelonDriver.swift
//  RelayMelonAdapter
//
//  EmulationDriver over the melonDS core through Relay's C bridge
//  (Vendor/melonDS/RelayBridge). The bridge runs the DS on its own thread;
//  this driver loads, pauses, feeds buttons and touches, drains audio into
//  Relay's output and exchanges battery saves and states. Two screens: the
//  top one is `frameSource`, both are `screenFrameSources`.

import Foundation
import RelayDomain
import RelayEmulation
import RelayAudioOutput
import MelonRelay

@MainActor
final class MelonDriver: EmulationDriver {
    let descriptor = MelonDriverFactory.descriptor

    private(set) var frameSource: VideoFrameSource?
    private(set) var screenFrameSources: [VideoFrameSource] = []
    private(set) var stateSerializer: (any EmulationStateSerializer)?

    private let systemID: SystemID
    private var handle: MelonHandle?
    private var audio: CoreAudioOutput?
    private var started = false
    private var achievementObserver: CoreAchievementObserver?

    init(systemID: SystemID) {
        self.systemID = systemID
    }

    // MARK: EmulationDriver

    func load(romURL: URL, storage: EmulationStorage) throws {
        guard handle == nil else { throw EmulationError.invalidState("driver already loaded") }
        let fm = FileManager.default
        let local = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "Relay/melonDS", directoryHint: .isDirectory)
        for dir in [local, storage.batterySavesDirectory, storage.saveStatesDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let raw = melon_relay_create(local.path, storage.batterySavesDirectory.path) else {
            throw EmulationError.loadFailed("the melonDS core could not be created")
        }
        let handle = MelonHandle(raw)
        guard melon_relay_load_rom(raw, romURL.path) == 1 else {
            melon_relay_destroy(raw)
            throw EmulationError.loadFailed("melonDS refused \(romURL.lastPathComponent)")
        }
        self.handle = handle
        let screens = SystemCatalog.descriptor(for: systemID)?.screens ?? []
        let top = MelonFrameSource(handle: handle, screen: 0, aspectRatio: screens.first?.aspectRatio ?? 4.0 / 3.0)
        let bottom = MelonFrameSource(handle: handle, screen: 1, aspectRatio: screens.dropFirst().first?.aspectRatio ?? 4.0 / 3.0)
        frameSource = top
        screenFrameSources = [top, bottom]
        stateSerializer = MelonStateSerializer(handle: handle)
    }

    func start() throws {
        guard let handle else { throw EmulationError.invalidState("start() before load()") }
        guard !started else { return }
        handle.use { melon_relay_set_paused($0, 0) }
        started = true
    }

    func setAchievementRuntime(_ runtime: AchievementRuntimeSlot?) {
        guard let handle else { return }
        handle.use { raw in
            if let runtime {
                let observer = CoreAchievementObserver(runtime: runtime) { region, offset, buffer in
                    guard let base = buffer.baseAddress else { return 0 }
                    return melon_relay_read_memory(raw, region.rawValue, offset, base.assumingMemoryBound(to: UInt8.self), buffer.count)
                }
                melon_relay_set_observer(raw, CoreAchievementObserver.callback, observer.context)
                achievementObserver = observer
            } else {
                melon_relay_set_observer(raw, nil, nil)
                achievementObserver = nil
            }
        }
        stateSerializer = MelonStateSerializer(handle: handle, achievements: runtime)
    }

    func setPaused(_ paused: Bool) {
        guard let handle, started else { return }
        handle.use { melon_relay_set_paused($0, paused ? 1 : 0) }
    }

    func stop() {
        stopAudio()
        setAchievementRuntime(nil)
        guard let handle else { return }
        handle.invalidate { raw in
            melon_relay_stop(raw)
            melon_relay_destroy(raw)
        }
        self.handle = nil
        frameSource = nil
        screenFrameSources = []
        stateSerializer = nil
        started = false
    }

    func press(_ input: EmulationInput) { setButton(input, pressed: true) }
    func release(_ input: EmulationInput) { setButton(input, pressed: false) }

    private func setButton(_ input: EmulationInput, pressed: Bool) {
        guard let handle, let button = Self.button(for: input) else { return }
        handle.use { melon_relay_set_button($0, button, pressed ? 1 : 0) }
    }

    func touch(screenIndex: Int, x: Int, y: Int) {
        // Only the bottom screen has a digitiser.
        guard let handle, screenIndex == 1 else { return }
        handle.use { melon_relay_touch($0, UInt16(clamping: x), UInt16(clamping: y)) }
    }

    func releaseTouch() {
        guard let handle else { return }
        handle.use { melon_relay_release_touch($0) }
    }

    func startAudio() throws {
        guard let handle else { throw EmulationError.audioFailed("no game loaded") }
        if audio == nil {
            let rate = Double(handle.use(default: 0) { melon_relay_audio_sample_rate($0) })
            audio = CoreAudioOutput(sampleRate: rate > 0 ? rate : 48_000) { buffer, frames in
                handle.use(default: 0) { melon_relay_read_audio($0, buffer, frames) }
            }
        }
        do { try audio?.start() } catch { throw EmulationError.audioFailed(error.localizedDescription) }
    }

    func stopAudio() {
        audio?.stop()
    }

    func flushAudio() {
        guard let handle else { return }
        handle.use { melon_relay_flush_audio($0) }
    }

    func setSpeed(_ speed: EmulationSpeed) {
        guard let handle else { return }
        switch speed {
        case .quarter: handle.use { melon_relay_set_speed_percent($0, 25) }
        case .half: handle.use { melon_relay_set_speed_percent($0, 50) }
        case .normal: handle.use { melon_relay_set_speed_percent($0, 100) }
        case .double: handle.use { melon_relay_set_speed_percent($0, 200) }
        case .triple: handle.use { melon_relay_set_speed_percent($0, 300) }
        case .quadruple: handle.use { melon_relay_set_speed_percent($0, 400) }
        case .maximum: handle.use { melon_relay_set_speed_percent($0, 500) }
        }
    }

    var supportedSpeeds: Set<EmulationSpeed> {
#if os(tvOS)
        return Set(EmulationSpeed.allCases).subtracting([.quadruple])
#else
        return Set(EmulationSpeed.allCases)
#endif
    }

    func batterySaveData() -> Data? {
        guard let handle else { return nil }
        var size = 0
        guard let bytes = handle.use(default: nil, { melon_relay_copy_battery($0, &size) }), size > 0 else { return nil }
        defer { melon_relay_free(bytes) }
        return Data(bytes: bytes, count: size)
    }

    func sampleDiagnostics() -> EmulationDiagnostics {
        var d = EmulationDiagnostics()
        guard let handle else { return d }
        d.emulationFramesPerSecond = handle.use(default: 0) { melon_relay_fps($0) }
        d.audioSampleRate = Double(handle.use(default: 0) { melon_relay_audio_sample_rate($0) })
        d.audioRunning = audio?.isRunning ?? false
        d.audioBufferedBytes = handle.use(default: 0) { melon_relay_audio_buffered_frames($0) } * 4
        return d
    }

    // MARK: Mapping

    /// melonDS's KEYINPUT bit order. Buttons the DS lacks are dropped.
    static func button(for input: EmulationInput) -> MelonRelayButton? {
        switch input {
        case .a: return MelonRelayButtonA
        case .b: return MelonRelayButtonB
        case .select: return MelonRelayButtonSelect
        case .start: return MelonRelayButtonStart
        case .right: return MelonRelayButtonRight
        case .left: return MelonRelayButtonLeft
        case .up: return MelonRelayButtonUp
        case .down: return MelonRelayButtonDown
        case .r: return MelonRelayButtonR
        case .l: return MelonRelayButtonL
        case .x: return MelonRelayButtonX
        case .y: return MelonRelayButtonY
        default: return nil
        }
    }
}

/// The bridge handle: shared with the presenter, the audio render thread and
/// the rewind capture task, and the only thing that may destroy the instance
/// (`CoreHandle`).
typealias MelonHandle = CoreHandle

/// Whole-machine state through the bridge, which stops the DS at a frame
/// boundary itself, so the rewind engine may call this from its capture task.
final class MelonStateSerializer: EmulationStateSerializer, @unchecked Sendable {
    private let handle: MelonHandle
    private let achievements: AchievementRuntimeSlot?

    init(handle: MelonHandle, achievements: AchievementRuntimeSlot? = nil) {
        self.handle = handle; self.achievements = achievements
    }

    private func withMachine<T>(_ body: @escaping (OpaquePointer) -> T) -> T? {
        let value: T?? = handle.use { raw -> T? in
            var result: T?
            let operation = CoreSynchronousOperation { result = body(raw) }
            operation.withContext { melon_relay_with_machine(raw, CoreSynchronousOperation.callback, $0) }
            return result
        }
        return value ?? nil
    }

    func serializeState() throws -> Data {
        let result: Data?? = withMachine { [achievements] raw -> Data? in
            var size = 0
            guard let bytes = melon_relay_serialize_state(raw, &size), size > 0 else { return nil }
            defer { melon_relay_free(bytes) }
            let state = Data(bytes: bytes, count: size)
            return AchievementStateEnvelope.append(to: state, progress: achievements?.captureProgress())
        }
        guard let wrapped = result, let data = wrapped else { throw EmulationError.stateFailed("Melon produced no state") }
        return data
    }

    func restoreState(_ data: Data) throws {
        guard achievements?.hardcoreEnabled != true else { throw EmulationError.unsupported("state loading in Hardcore") }
        let state = try AchievementStateEnvelope.split(data)
        let ok = withMachine { [achievements] pointer -> Bool in
            let loaded = state.core.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return melon_relay_deserialize_state(pointer, base.assumingMemoryBound(to: UInt8.self), buffer.count)
            }
            if loaded == 1 { achievements?.restoreProgress(state.progress) }
            return loaded == 1
        }
        guard ok == true else { throw EmulationError.stateFailed("Melon refused the state") }
    }

    func runSingleFrame() {
        guard achievements?.hardcoreEnabled != true else { return }
        achievements?.setPreviewing(true)
        defer { achievements?.setPreviewing(false) }
        handle.use { melon_relay_run_single_frame($0) }
    }
}

/// One DS screen (0 top, 1 bottom), 256×192 RGBX8, read under the bridge's lock.
final class MelonFrameSource: VideoFrameSource, @unchecked Sendable {
    private let handle: MelonHandle
    private let screen: Int32
    private let aspectRatio: Double

    init(handle: MelonHandle, screen: Int32, aspectRatio: Double) {
        self.handle = handle
        self.screen = screen
        self.aspectRatio = aspectRatio
    }

    var frameDescriptor: FrameDescriptor {
        FrameDescriptor(width: 256, height: 192, bytesPerRow: 256 * 4, pixelFormat: .rgbx8, aspectRatio: aspectRatio)
    }

    func withCurrentFrame(_ body: (UnsafeRawPointer, FrameDescriptor) -> Void) {
        handle.use { pointer in
            var pixels: UnsafePointer<UInt8>? = nil
            var info = MelonRelayFrameInfo()
            guard melon_relay_lock_frame(pointer, screen, &pixels, &info) == 1, let pixels else { return }
            defer { melon_relay_unlock_frame(pointer) }
            body(UnsafeRawPointer(pixels), frameDescriptor)
        }
    }
}

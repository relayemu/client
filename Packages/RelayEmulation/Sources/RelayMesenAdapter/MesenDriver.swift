// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MesenDriver.swift
//  RelayMesenAdapter
//
//  EmulationDriver over the Mesen 2 core through Relay's C bridge
//  (Vendor/Mesen2/RelayBridge). Mesen runs the machine on its own thread with
//  its own frame limiter; this driver only loads, pauses, feeds input, drains
//  audio into Relay's output and exchanges battery saves and states.

import Foundation
import RelayDomain
import RelayEmulation
import RelayAudioOutput
import MesenRelay

@MainActor
final class MesenDriver: EmulationDriver {
    let descriptor = MesenDriverFactory.descriptor

    private(set) var frameSource: VideoFrameSource?
    private(set) var stateSerializer: (any EmulationStateSerializer)?

    private let systemID: SystemID
    private var handle: MesenHandle?
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
        let home = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "Relay/Mesen", directoryHint: .isDirectory)
        for dir in [home, storage.batterySavesDirectory, storage.saveStatesDirectory, storage.firmwareDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let raw = mesen_relay_create(home.path, storage.batterySavesDirectory.path,
                                           storage.saveStatesDirectory.path, storage.firmwareDirectory.path) else {
            throw EmulationError.loadFailed("the Mesen core could not be created")
        }
        let handle = MesenHandle(raw)
        // Mesen decides Game Gear against Master System, and WonderSwan Color
        // against WonderSwan, by file extension. Relay decided from the header,
        // so the game is loaded through a link named for the system it is.
        let loadURL = Self.loadURL(for: romURL, system: systemID, in: home)
        guard mesen_relay_load_rom(raw, loadURL.path) == 1 else {
            mesen_relay_destroy(raw)
            throw EmulationError.loadFailed("Mesen refused \(romURL.lastPathComponent)")
        }
        let console = mesen_relay_console(raw)
        guard let expected = Self.console(for: systemID), console == expected else {
            mesen_relay_stop(raw)
            mesen_relay_destroy(raw)
            throw EmulationError.loadFailed("\(romURL.lastPathComponent) is not a \(systemID) game")
        }
        self.handle = handle
        let screen = SystemCatalog.descriptor(for: systemID)?.screens.first
        frameSource = MesenFrameSource(handle: handle,
                                       fallbackWidth: screen?.width ?? 256,
                                       fallbackHeight: screen?.height ?? 240,
                                       aspectRatio: screen?.aspectRatio ?? 4.0 / 3.0)
        stateSerializer = MesenStateSerializer(handle: handle)
    }

    func start() throws {
        guard let handle else { throw EmulationError.invalidState("start() before load()") }
        guard !started else { return }
        handle.use { mesen_relay_set_paused($0, 0) }
        started = true
    }

    func setAchievementRuntime(_ runtime: AchievementRuntimeSlot?) {
        guard let handle else { return }
        handle.use { raw in
            if let runtime {
                let observer = CoreAchievementObserver(runtime: runtime) { region, offset, buffer in
                    guard let base = buffer.baseAddress else { return 0 }
                    return mesen_relay_read_memory(raw, region.rawValue, offset, base.assumingMemoryBound(to: UInt8.self), buffer.count)
                }
                mesen_relay_set_observer(raw, CoreAchievementObserver.callback, observer.context)
                achievementObserver = observer
            } else {
                mesen_relay_set_observer(raw, nil, nil)
                achievementObserver = nil
            }
        }
        stateSerializer = MesenStateSerializer(handle: handle, achievements: runtime)
    }

    func setPaused(_ paused: Bool) {
        guard let handle, started else { return }
        handle.use { mesen_relay_set_paused($0, paused ? 1 : 0) }
    }

    func stop() {
        stopAudio()
        setAchievementRuntime(nil)
        guard let handle else { return }
        handle.invalidate { raw in
            mesen_relay_stop(raw)
            mesen_relay_destroy(raw)
        }
        self.handle = nil
        frameSource = nil
        stateSerializer = nil
        started = false
    }

    func press(_ input: EmulationInput) { setButton(input, pressed: true) }
    func release(_ input: EmulationInput) { setButton(input, pressed: false) }

    private func setButton(_ input: EmulationInput, pressed: Bool) {
        guard let handle else { return }
        let upright = systemID == .wonderSwan || systemID == .wonderSwanColor
            ? handle.use(default: 0, { mesen_relay_ws_vertical($0) }) == 1 : false
        guard let bit = Self.button(for: input, system: systemID, upright: upright) else { return }
        handle.use { mesen_relay_set_button($0, 0, bit, pressed ? 1 : 0) }
    }

    /// The path Mesen loads: the game file itself when its extension already
    /// names the system, otherwise a link with the system's canonical extension
    /// (same base name, so Mesen's battery file name matches Relay's).
    static func loadURL(for romURL: URL, system: SystemID, in folder: URL) -> URL {
        guard let canonical = SystemCatalog.descriptor(for: system)?.fileExtensions.first,
              romURL.pathExtension.lowercased() != canonical else { return romURL }
        let link = folder.appending(path: "links", directoryHint: .isDirectory)
            .appending(path: romURL.deletingPathExtension().lastPathComponent + "." + canonical)
        let fm = FileManager.default
        try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        do { try fm.createSymbolicLink(at: link, withDestinationURL: romURL) } catch { return romURL }
        return link
    }

    func startAudio() throws {
        guard let handle else { throw EmulationError.audioFailed("no game loaded") }
        if audio == nil {
            let rate = Double(handle.use(default: 0) { mesen_relay_audio_sample_rate($0) })
            audio = CoreAudioOutput(sampleRate: rate > 0 ? rate : 48_000) { buffer, frames in
                handle.use(default: 0) { mesen_relay_read_audio($0, buffer, frames) }
            }
        }
        do { try audio?.start() } catch { throw EmulationError.audioFailed(error.localizedDescription) }
    }

    func stopAudio() {
        audio?.stop()
    }

    func flushAudio() {
        guard let handle else { return }
        handle.use { mesen_relay_flush_audio($0) }
    }

    func setSpeed(_ speed: EmulationSpeed) {
        guard let handle else { return }
        switch speed {
        case .quarter: handle.use { mesen_relay_set_speed_percent($0, 25) }
        case .half: handle.use { mesen_relay_set_speed_percent($0, 50) }
        case .normal: handle.use { mesen_relay_set_speed_percent($0, 100) }
        case .double: handle.use { mesen_relay_set_speed_percent($0, 200) }
        case .triple: handle.use { mesen_relay_set_speed_percent($0, 300) }
        case .quadruple: handle.use { mesen_relay_set_speed_percent($0, 400) }
        case .maximum: handle.use { mesen_relay_set_speed_percent($0, 500) }
        }
    }

    var supportedSpeeds: Set<EmulationSpeed> { Set(EmulationSpeed.allCases) }

    func batterySaveData() -> Data? {
        guard let handle else { return nil }
        var size = 0
        guard let bytes = handle.use(default: nil, { mesen_relay_copy_battery($0, &size) }), size > 0 else { return nil }
        defer { mesen_relay_free(bytes) }
        return Data(bytes: bytes, count: size)
    }

    func sampleDiagnostics() -> EmulationDiagnostics {
        var d = EmulationDiagnostics()
        guard let handle else { return d }
        d.emulationFramesPerSecond = handle.use(default: 0) { mesen_relay_fps($0) }
        d.audioSampleRate = Double(handle.use(default: 0) { mesen_relay_audio_sample_rate($0) })
        d.audioRunning = audio?.isRunning ?? false
        d.audioBufferedBytes = handle.use(default: 0) { mesen_relay_audio_buffered_frames($0) } * 4
        return d
    }

    // MARK: Mapping

    static func console(for system: SystemID) -> MesenRelayConsole? {
        switch system {
        case .nes: return MesenRelayConsoleNes
        case .snes: return MesenRelayConsoleSnes
        case .masterSystem, .gameGear: return MesenRelayConsoleSms
        case .pcEngine: return MesenRelayConsolePcEngine
        case .wonderSwan, .wonderSwanColor: return MesenRelayConsoleWs
        default: return nil
        }
    }

    /// Mesen's button index for the standard controller of each console
    /// (`NesController::Buttons`, `SnesController::Buttons`, `SmsController`,
    /// `PceController`, `WsController`). A button the system lacks is dropped,
    /// never mapped to something else. `upright` is the WonderSwan held
    /// vertically: the Y cluster becomes the pad and the X cluster the second
    /// cluster, both turned a quarter turn, as Mesen's own vertical preset does.
    static func button(for input: EmulationInput, system: SystemID, upright: Bool = false) -> UInt8? {
        switch system {
        case .masterSystem, .gameGear:
            // Up 0, Down 1, Left 2, Right 3, B ("1") 4, A ("2") 5, Pause 6.
            switch input {
            case .up: return 0
            case .down: return 1
            case .left: return 2
            case .right: return 3
            case .b: return 4
            case .a: return 5
            case .start: return 6
            default: return nil
            }
        case .pcEngine:
            // Up 0, Down 1, Left 2, Right 3, Select 4, Run 5, I 6, II 7.
            switch input {
            case .up: return 0
            case .down: return 1
            case .left: return 2
            case .right: return 3
            case .select: return 4
            case .start: return 5
            case .a: return 6
            case .b: return 7
            default: return nil
            }
        case .wonderSwan, .wonderSwanColor:
            // X cluster Up 0, Down 1, Left 2, Right 3; Y cluster Up2 4, Down2 5,
            // Left2 6, Right2 7; Sound 8, Start 9, B 10, A 11.
            switch input {
            case .a: return 11
            case .b: return 10
            case .start: return 9
            case .up: return upright ? 7 : 0
            case .down: return upright ? 6 : 1
            case .left: return upright ? 4 : 2
            case .right: return upright ? 5 : 3
            case .cUp: return upright ? 3 : 4
            case .cDown: return upright ? 2 : 5
            case .cLeft: return upright ? 0 : 6
            case .cRight: return upright ? 1 : 7
            default: return nil
            }
        case .nes:
            switch input {
            case .up: return 0
            case .down: return 1
            case .left: return 2
            case .right: return 3
            case .start: return 4
            case .select: return 5
            case .b: return 6
            case .a: return 7
            default: return nil
            }
        case .snes:
            switch input {
            case .a: return 0
            case .b: return 1
            case .x: return 2
            case .y: return 3
            case .l: return 4
            case .r: return 5
            case .select: return 6
            case .start: return 7
            case .up: return 8
            case .down: return 9
            case .left: return 10
            case .right: return 11
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// The bridge handle: shared with the presenter, the audio render thread and
/// the rewind capture task, and the only thing that may destroy the instance
/// (`CoreHandle`).
typealias MesenHandle = CoreHandle

/// Whole-machine state through the bridge, which takes Mesen's own emulator
/// lock, so the rewind engine may call this from its capture task.
final class MesenStateSerializer: EmulationStateSerializer, @unchecked Sendable {
    private let handle: MesenHandle
    private let achievements: AchievementRuntimeSlot?

    init(handle: MesenHandle, achievements: AchievementRuntimeSlot? = nil) {
        self.handle = handle; self.achievements = achievements
    }

    private func withMachine<T>(_ body: @escaping (OpaquePointer) -> T) -> T? {
        let value: T?? = handle.use { raw -> T? in
            var result: T?
            let operation = CoreSynchronousOperation { result = body(raw) }
            operation.withContext { mesen_relay_with_machine(raw, CoreSynchronousOperation.callback, $0) }
            return result
        }
        return value ?? nil
    }

    func serializeState() throws -> Data {
        let result: Data?? = withMachine { [achievements] raw -> Data? in
            var size = 0
            guard let bytes = mesen_relay_serialize_state(raw, &size), size > 0 else { return nil }
            defer { mesen_relay_free(bytes) }
            let state = Data(bytes: bytes, count: size)
            return AchievementStateEnvelope.append(to: state, progress: achievements?.captureProgress())
        }
        guard let wrapped = result, let data = wrapped else { throw EmulationError.stateFailed("Mesen produced no state") }
        return data
    }

    func restoreState(_ data: Data) throws {
        guard achievements?.hardcoreEnabled != true else { throw EmulationError.unsupported("state loading in Hardcore") }
        let state = try AchievementStateEnvelope.split(data)
        let ok = withMachine { [achievements] pointer -> Bool in
            let loaded = state.core.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return mesen_relay_deserialize_state(pointer, base.assumingMemoryBound(to: UInt8.self), buffer.count)
            }
            if loaded == 1 { achievements?.restoreProgress(state.progress) }
            return loaded == 1
        }
        guard ok == true else { throw EmulationError.stateFailed("Mesen refused the state") }
    }

    func runSingleFrame() {
        guard achievements?.hardcoreEnabled != true else { return }
        achievements?.setPreviewing(true)
        defer { achievements?.setPreviewing(false) }
        handle.use { mesen_relay_run_single_frame($0) }
    }
}

/// The last frame Mesen decoded, RGBX8, held by the bridge and read under its lock.
final class MesenFrameSource: VideoFrameSource, @unchecked Sendable {
    private let handle: MesenHandle
    private let fallbackWidth: Int
    private let fallbackHeight: Int
    private let aspectRatio: Double

    init(handle: MesenHandle, fallbackWidth: Int, fallbackHeight: Int, aspectRatio: Double) {
        self.handle = handle
        self.fallbackWidth = fallbackWidth
        self.fallbackHeight = fallbackHeight
        self.aspectRatio = aspectRatio
    }

    var frameDescriptor: FrameDescriptor {
        var pixels: UnsafePointer<UInt8>? = nil
        var info = MesenRelayFrameInfo()
        let live = handle.use(default: false) { pointer -> Bool in
            guard mesen_relay_lock_frame(pointer, &pixels, &info) == 1 else { return false }
            mesen_relay_unlock_frame(pointer)
            return true
        }
        if live { return descriptor(width: Int(info.width), height: Int(info.height)) }
        return descriptor(width: fallbackWidth, height: fallbackHeight)
    }

    /// The catalog states the display shape of the native picture; a frame of
    /// another size (a hi-res Super NES mode, a WonderSwan held upright) keeps
    /// the same pixel shape, so its aspect follows its dimensions.
    private func descriptor(width: Int, height: Int) -> FrameDescriptor {
        let nativeShape = Double(fallbackWidth) / Double(max(fallbackHeight, 1))
        let pixelAspect = aspectRatio / nativeShape
        let aspect = (Double(width) / Double(max(height, 1))) * pixelAspect
        return FrameDescriptor(width: width, height: height, bytesPerRow: width * 4,
                               pixelFormat: .rgbx8, aspectRatio: aspect)
    }

    func withCurrentFrame(_ body: (UnsafeRawPointer, FrameDescriptor) -> Void) {
        handle.use { pointer in
            var pixels: UnsafePointer<UInt8>? = nil
            var info = MesenRelayFrameInfo()
            guard mesen_relay_lock_frame(pointer, &pixels, &info) == 1, let pixels else { return }
            defer { mesen_relay_unlock_frame(pointer) }
            guard info.width > 0, info.height > 0 else { return }
            body(UnsafeRawPointer(pixels), descriptor(width: Int(info.width), height: Int(info.height)))
        }
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain
import RelayLibrary
import RelayEmulation
import RelayAudioOutput
import PCSXRelay

@MainActor
final class PCSXDriver: EmulationDriver {
    let descriptor = PCSXDriverFactory.descriptor
    private(set) var frameSource: VideoFrameSource?
    private(set) var stateSerializer: (any EmulationStateSerializer)?
    private var handle: CoreHandle?
    private var audio: CoreAudioOutput?
    private var started = false

    func load(romURL: URL, storage: EmulationStorage) throws {
        guard handle == nil else { throw EmulationError.invalidState("driver already loaded") }
        // The library resolver provides only the validated managed CUE/M3U.
        guard ["cue", "m3u"].contains(romURL.pathExtension.lowercased()) else {
            throw EmulationError.loadFailed("PlayStation content must be imported into the library")
        }
        for directory in [storage.batterySavesDirectory, storage.firmwareDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let firmware: URL
        do { firmware = try PlayStationFirmwareStore(firmwareDirectory: storage.firmwareDirectory).verifiedDirectory() }
        catch { throw EmulationError.firmwareInvalid }
        guard let raw = pcsx_relay_create(firmware.path, storage.batterySavesDirectory.path) else {
            throw EmulationError.loadFailed("the PlayStation core is already in use")
        }
        guard pcsx_relay_load(raw, romURL.path) == 1 else {
            pcsx_relay_destroy(raw)
            throw EmulationError.loadFailed("the PlayStation core refused this disc")
        }
        let battery = storage.batterySavesDirectory.appending(path: romURL.deletingPathExtension().lastPathComponent + ".sav")
        if FileManager.default.fileExists(atPath: battery.path) {
            do {
                let data = try Data(contentsOf: battery)
                let ok = data.withUnsafeBytes { b in
                    pcsx_relay_load_cards(raw, b.bindMemory(to: UInt8.self).baseAddress, b.count)
                }
                guard ok == 1 else { throw EmulationError.loadFailed("the PlayStation memory-card snapshot is damaged") }
            } catch { pcsx_relay_destroy(raw); throw error }
        }
        let handle = CoreHandle(raw)
        self.handle = handle
        frameSource = PCSXFrameSource(handle: handle, fallbackWidth: 320, fallbackHeight: 240, aspectRatio: 4.0 / 3.0)
        stateSerializer = PCSXStateSerializer(handle: handle)
    }

    func start() throws {
        guard let handle else { throw EmulationError.invalidState("start before load") }
        guard !started else { return }
        handle.use { pcsx_relay_set_paused($0, 0) }; started = true
    }
    func setPaused(_ paused: Bool) {
        handle?.use {
            if !paused { pcsx_relay_flush_audio($0) }
            pcsx_relay_set_paused($0, paused ? 1 : 0)
            if paused { pcsx_relay_flush_audio($0) }
        }
    }
    func stop() {
        stopAudio(); audio = nil
        handle?.invalidate { pcsx_relay_destroy($0) }
        handle = nil; frameSource = nil; stateSerializer = nil; started = false
    }
    func press(_ input: EmulationInput) { button(input, true) }
    func release(_ input: EmulationInput) { button(input, false) }
    private func button(_ input: EmulationInput, _ pressed: Bool) {
        guard let bit = Self.buttonBit(input) else { return }
        handle?.use { pcsx_relay_set_button($0, bit, pressed ? 1 : 0) }
    }
    // Relay face positions: south B=Cross, east A=Circle, north X=Triangle,
    // west Y=Square. Physical-controller remapping stays in RelayInput.
    static func buttonBit(_ input: EmulationInput) -> UInt32? {
        switch input {
        case .b: return 0
        case .y: return 1
        case .select: return 2
        case .start: return 3
        case .up: return 4
        case .down: return 5
        case .left: return 6
        case .right: return 7
        case .a: return 8
        case .x: return 9
        case .l: return 10
        case .r: return 11
        case .l2: return 12
        case .r2: return 13
        case .l3: return 14
        case .r3: return 15
        default: return nil
        }
    }
    func move(_ axis: EmulationAxis, to value: Float) {
        guard value.isFinite else { return }
        if axis == .triggerL || axis == .triggerR {
            button(axis == .triggerL ? .l2 : .r2, value > 0.5); return
        }
        let index: UInt32
        switch axis {
        case .leftStickX: index = 0
        case .leftStickY: index = 1
        case .rightStickX: index = 2
        case .rightStickY: index = 3
        default: return
        }
        // Relay/GameController Y is positive upwards; PS1 is positive downwards.
        let directed = (index == 1 || index == 3) ? -axis.clamp(value) : axis.clamp(value)
        handle?.use { pcsx_relay_set_axis($0, index, Int16(directed * 32767)) }
    }
    func startAudio() throws {
        guard let handle else { throw EmulationError.audioFailed("no game loaded") }
        if audio == nil {
            audio = CoreAudioOutput(sampleRate: 44_100) { buffer, frames in
                handle.use(default: 0) { pcsx_relay_read_audio($0, buffer, frames) }
            }
        }
        do { try audio?.start() } catch { throw EmulationError.audioFailed(error.localizedDescription) }
    }
    func stopAudio() { audio?.stop() }
    func flushAudio() { handle?.use { pcsx_relay_flush_audio($0) } }
    var supportedSpeeds: Set<EmulationSpeed> { [.normal, .double] }
    func setSpeed(_ speed: EmulationSpeed) { handle?.use { pcsx_relay_set_speed($0, speed == .double ? 200 : 100) } }
    func batterySaveData() -> Data? {
        guard let handle else { return nil }
        var data = Data(count: pcsx_relay_card_size())
        let ok = data.withUnsafeMutableBytes { b in
            handle.use(default: 0) { pcsx_relay_copy_cards($0, b.bindMemory(to: UInt8.self).baseAddress, b.count) }
        }
        return ok == 1 ? data : nil
    }
    var requiresBatterySnapshots: Bool { true }
    var discStatus: EmulationDiscStatus? {
        handle?.use { EmulationDiscStatus(count: Int(pcsx_relay_disc_count($0)), selectedIndex: Int(pcsx_relay_disc_index($0))) }
    }
    func selectDisc(at index: Int) throws {
        guard index >= 0, index < 8, handle?.use({ pcsx_relay_switch_disc($0, UInt32(index)) }) == 1 else {
            throw EmulationError.loadFailed("the disc could not be changed")
        }
        flushAudio()
    }
    var supportedControllers: Set<EmulationControllerKind> { [.digital, .dualShock] }
    var controllerKind: EmulationControllerKind { handle?.use { pcsx_relay_controller($0) } == 1 ? .dualShock : .digital }
    func setControllerKind(_ kind: EmulationControllerKind) throws {
        guard handle?.use({ pcsx_relay_set_controller($0, kind == .dualShock ? 1 : 0) }) == 1 else {
            throw EmulationError.invalidState("controller unavailable")
        }
    }
    var analogModeEnabled: Bool { handle?.use { pcsx_relay_analog_mode($0) } == 1 }
    func setAnalogModeEnabled(_ enabled: Bool) throws {
        guard handle?.use({ pcsx_relay_set_analog_mode($0, enabled ? 1 : 0) }) == 1 else {
            throw EmulationError.invalidState("analog mode unavailable")
        }
    }
    var usesEmulatedFirmware: Bool { handle?.use { pcsx_relay_uses_hle($0) } == 1 }
    func sampleDiagnostics() -> EmulationDiagnostics {
        var native = PCSXRelayDiagnostics()
        handle?.use { pcsx_relay_diagnostics($0, &native) }
        var result = EmulationDiagnostics()
        result.emulationFramesPerSecond = native.framesPerSecond
        result.audioSampleRate = 44_100
        result.audioRunning = audio?.isRunning ?? false
        result.audioBufferedBytes = Int(native.audioBufferedFrames) * 4
        result.audioFramesProduced = native.audioFramesProduced
        result.audioFramesRequested = native.audioFramesRequested
        result.audioFramesMissing = native.audioFramesMissing
        result.audioFramesDiscarded = native.audioFramesDiscarded
        result.targetFramesPerSecond = native.targetFramesPerSecond
        result.longestFrameMilliseconds = native.longestFrameMilliseconds
        return result
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayEmulation
import RelayLibrary
import PCSXRelay

/// Whole-machine state through the bridge, which takes PCSX's own emulator
/// lock, so the rewind engine may call this from its capture task.
final class PCSXStateSerializer: EmulationStateSerializer, @unchecked Sendable {
    private let handle: CoreHandle

    init(handle: CoreHandle) { self.handle = handle }

    func serializeState() throws -> Data {
        var size = 0
        guard let bytes = handle.use(default: nil, { pcsx_relay_save_state($0, &size) }), size > 0 else {
            throw EmulationError.stateFailed("PCSX produced no state")
        }
        defer { pcsx_relay_free(bytes) }
        return Data(bytes: bytes, count: size)
    }

    func restoreState(_ data: Data) throws {
        let ok = handle.use(default: 0) { pointer in
            data.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return pcsx_relay_load_state(pointer, base.assumingMemoryBound(to: UInt8.self), buffer.count)
            }
        }
        if ok == -2 { throw EmulationError.stateFirmwareMismatch }
        guard ok == 1 else { throw EmulationError.stateFailed("PCSX refused the state") }
    }

    func runSingleFrame() {
        handle.use { pcsx_relay_run_frame($0) }
    }
}

/// The last frame PCSX decoded, RGBX8, held by the bridge and read under its lock.
final class PCSXFrameSource: VideoFrameSource, @unchecked Sendable {
    private let handle: CoreHandle
    private let fallbackWidth: Int
    private let fallbackHeight: Int
    private let aspectRatio: Double

    init(handle: CoreHandle, fallbackWidth: Int, fallbackHeight: Int, aspectRatio: Double) {
        self.handle = handle
        self.fallbackWidth = fallbackWidth
        self.fallbackHeight = fallbackHeight
        self.aspectRatio = aspectRatio
    }

    var frameDescriptor: FrameDescriptor {
        var pixels: UnsafePointer<UInt8>? = nil
        var info = PCSXRelayFrameInfo()
        let live = handle.use(default: false) { pointer -> Bool in
            guard pcsx_relay_lock_frame(pointer, &pixels, &info) == 1 else { return false }
            pcsx_relay_unlock_frame(pointer)
            return true
        }
        if live { return descriptor(width: Int(info.width), height: Int(info.height)) }
        return descriptor(width: fallbackWidth, height: fallbackHeight)
    }

    /// PS1 output stays 4:3 across its low-resolution and interlaced modes.
    private func descriptor(width: Int, height: Int) -> FrameDescriptor {
        return FrameDescriptor(width: width, height: height, bytesPerRow: width * 4,
                               pixelFormat: .rgbx8, aspectRatio: 4.0 / 3.0)
    }

    func withCurrentFrame(_ body: (UnsafeRawPointer, FrameDescriptor) -> Void) {
        handle.use { pointer in
            var pixels: UnsafePointer<UInt8>? = nil
            var info = PCSXRelayFrameInfo()
            guard pcsx_relay_lock_frame(pointer, &pixels, &info) == 1, let pixels else { return }
            defer { pcsx_relay_unlock_frame(pointer) }
            guard info.width > 0, info.height > 0 else { return }
            body(UnsafeRawPointer(pixels), descriptor(width: Int(info.width), height: Int(info.height)))
        }
    }
}

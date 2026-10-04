// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Core-native memory regions. Offsets are physical, unbanked byte offsets,
/// except addressSpace, which is a side-effect-free peek of the native bus.
/// Service-specific address translation lives in RelayAchievements.
public enum AchievementMemoryRegion: UInt32, Sendable {
    case addressSpace = 0
    case workRAM = 1
    case internalRAM = 2
    case saveRAM = 3
    case auxiliaryRAM = 4
}

/// Valid only during the synchronous frame callback, under the machine lock.
/// A short read means unavailable memory, never a fabricated zero-filled bank.
public typealias AchievementMemoryReader = (AchievementMemoryRegion, UInt32, UnsafeMutableRawBufferPointer) -> Int

/// The only achievement contract cores see. No HTTP, account or rcheevos types.
/// Every method must be thread-safe. Network work must always be asynchronous.
public protocol EmulationAchievementRuntime: AnyObject, Sendable {
    /// Called once after EVERY emulated frame, including undisplayed frames.
    /// The reader must not escape this call. Never call during a rewind preview.
    func evaluateFrame(readMemory: AchievementMemoryReader)
    /// Called under the SAME machine lock as the paired core state operation.
    func captureProgress() -> Data?
    func restoreProgress(_ data: Data?)
    func resetProgress()
    func disableHardcore()
    func canPause() -> Bool
}

/// A session can enter Hardcore only by creating a fresh core and slot.
/// Downgrading is permitted; there is deliberately no mid-session enable API.
public enum AchievementMode: String, Codable, Sendable { case casual, hardcore }

public extension EmulationAchievementRuntime {
    func disableHardcore() {}
    func canPause() -> Bool { true }
}

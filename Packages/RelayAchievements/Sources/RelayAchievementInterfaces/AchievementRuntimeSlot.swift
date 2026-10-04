// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A stable core attachment while login/identification finish asynchronously.
/// State restores arriving before RA is ready are retained and applied once.
public final class AchievementRuntimeSlot: EmulationAchievementRuntime, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var runtime: (any EmulationAchievementRuntime)?
    private var restored: Data?
    private var hasRestore = false
    private var previewing = false

    private var mode: AchievementMode
    public init(mode: AchievementMode = .casual) { self.mode = mode }
    public var hardcoreEnabled: Bool { locked { mode == .hardcore } }
    public func canPause() -> Bool { locked { mode != .hardcore || (runtime?.canPause() ?? true) } }
    public func disableHardcore() {
        locked { mode = .casual; runtime?.disableHardcore() }
    }
    public func attach(_ runtime: (any EmulationAchievementRuntime)?) {
        locked {
            self.runtime = runtime
            if mode == .casual { runtime?.disableHardcore() }
            if hasRestore, let runtime {
                runtime.restoreProgress(restored)
                restored = nil; hasRestore = false
            }
        }
    }
    public func setPreviewing(_ value: Bool) { locked { previewing = value } }
    public func evaluateFrame(readMemory: AchievementMemoryReader) {
        locked { if !previewing { runtime?.evaluateFrame(readMemory: readMemory) } }
    }
    public func captureProgress() -> Data? {
        locked { runtime?.captureProgress() ?? (hasRestore ? restored : nil) }
    }
    public func restoreProgress(_ data: Data?) {
        locked {
            guard mode != .hardcore else { return }
            if let runtime { runtime.restoreProgress(data) }
            else { restored = data; hasRestore = true }
        }
    }
    public func resetProgress() {
        locked { restored = nil; hasRestore = false; runtime?.resetProgress() }
    }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
}

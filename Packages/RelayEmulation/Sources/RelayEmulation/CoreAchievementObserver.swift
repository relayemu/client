// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Retained by a driver until its native observer has been detached under the
/// machine lock. Native pointers are used only during that locked callback.
public final class CoreAchievementObserver {
    private let runtime: AchievementRuntimeSlot
    private let reader: AchievementMemoryReader
    public init(runtime: AchievementRuntimeSlot, reader: @escaping AchievementMemoryReader) {
        self.runtime = runtime; self.reader = reader
    }
    public var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    public static let callback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { pointer, event in
        guard let pointer else { return }
        let observer = Unmanaged<CoreAchievementObserver>.fromOpaque(pointer).takeUnretainedValue()
        if event == 0 { observer.runtime.evaluateFrame(readMemory: observer.reader) }
        else if event == 1 { observer.runtime.resetProgress() }
    }
}

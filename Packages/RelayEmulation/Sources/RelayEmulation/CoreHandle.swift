// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CoreHandle.swift
//  RelayEmulation
//
//  Shared, invalidatable ownership of one C emulator instance.
//
//  A driver is not the only owner of its core: the Metal presenter keeps the
//  `VideoFrameSource` and draws from it at display rate, the audio engine reads
//  samples on its render thread, and the rewind engine serialises state from a
//  background task. Stopping a game destroys the C instance, so every one of
//  those must be unable to touch it afterwards — and must not be inside a call
//  while it is destroyed. Both are the handle's job: `use` runs a call under a
//  lock and does nothing once the instance is gone; `invalidate` takes the same
//  lock, so it waits for a call in flight and no later call can start.
//
//  Without this the app aborts on stop with "mutex lock failed: Invalid

import Foundation
import os

public final class CoreHandle: @unchecked Sendable {
    /// `os_unfair_lock` rather than `NSLock`: the audio render thread takes it,
    /// and this is the primitive that donates priority instead of inverting it.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var pointer: OpaquePointer?

    public init(_ pointer: OpaquePointer) {
        self.pointer = pointer
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// True until the instance has been destroyed.
    public var isValid: Bool {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return pointer != nil
    }

    /// Runs `body` with the live instance, or returns nil when it is gone.
    @discardableResult
    public func use<T>(_ body: (OpaquePointer) -> T) -> T? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        guard let pointer else { return nil }
        return body(pointer)
    }

    /// As above, with a value to report when the instance is gone.
    public func use<T>(default fallback: T, _ body: (OpaquePointer) -> T) -> T {
        use(body) ?? fallback
    }

    /// Stops and destroys the instance. Runs `teardown` once, under the lock,
    /// so it never overlaps a call in flight; every later `use` is a no-op.
    public func invalidate(_ teardown: (OpaquePointer) -> Void) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        guard let pointer else { return }
        self.pointer = nil
        teardown(pointer)
    }
}

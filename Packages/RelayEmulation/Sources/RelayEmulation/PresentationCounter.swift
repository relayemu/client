// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  PresentationCounter.swift
//  RelayEmulation
//
//  Thread-safe counter presenters bump once per presented frame; the session
//  samples it for diagnostics. Foundation-only so any presenter can use it.

import Foundation

public final class PresentationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    public init() {}

    public func increment() {
        lock.lock(); count &+= 1; lock.unlock()
    }

    /// Returns the count accumulated since the previous call and resets it.
    public func take() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = count; count = 0; return n
    }
}

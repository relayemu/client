// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  VideoFrameSource.swift
//  RelayEmulation

import Foundation

/// A source of software framebuffers that a presenter can sample at display
/// rate. Implementations are provided by adapters; presenters must not retain
/// the pointer beyond the closure.
public protocol VideoFrameSource: AnyObject, Sendable {
    /// Current frame geometry; may change after the core reports a new video mode.
    var frameDescriptor: FrameDescriptor { get }
    /// Calls `body` with a pointer to the most recent complete frame, or does
    /// nothing when no frame is available yet. Safe to call from any thread;
    /// the adapter provides whatever synchronisation the core requires.
    func withCurrentFrame(_ body: (UnsafeRawPointer, FrameDescriptor) -> Void)
}

public extension VideoFrameSource {
    /// Samples every 61st pixel of the current frame into a 32-bit checksum.
    /// Cheap enough to run once per second for diagnostics.
    func sampledChecksum() -> UInt32 {
        var checksum: UInt32 = 0
        withCurrentFrame { pointer, descriptor in
            let pixels = pointer.assumingMemoryBound(to: UInt32.self)
            let count = descriptor.bytesPerRow / 4 * descriptor.height
            var i = 0
            while i < count {
                checksum = (checksum &* 31) &+ pixels[i]
                i += 61
            }
        }
        return checksum
    }
}

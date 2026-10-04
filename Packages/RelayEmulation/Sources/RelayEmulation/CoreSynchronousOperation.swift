// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Stack-scoped Swift work executed synchronously under a C core's machine
/// lock. The C bridge MUST NOT store the callback/context beyond the call.
public final class CoreSynchronousOperation {
    private let body: () -> Void
    public init(_ body: @escaping () -> Void) { self.body = body }
    public func withContext(_ invoke: (UnsafeMutableRawPointer) -> Void) {
        withExtendedLifetime(self) { invoke(Unmanaged.passUnretained(self).toOpaque()) }
    }
    public static let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
        guard let pointer else { return }
        Unmanaged<CoreSynchronousOperation>.fromOpaque(pointer).takeUnretainedValue().body()
    }
}

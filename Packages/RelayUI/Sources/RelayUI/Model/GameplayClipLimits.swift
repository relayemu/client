// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import RelayEntitlements

/// Snapshot the central access policy at the start of a recording. Expiry can
/// stop an active Pro recording, but never deletes the completed media.
struct GameplayClipLimits: Equatable, Sendable {
    let duration: TimeInterval?
    let maximumBytes: Int?

    static let free = Self(duration: 15, maximumBytes: 16 * 1024 * 1024)
    static let pro = Self(duration: nil, maximumBytes: nil)

    init(policy: RelayAccessPolicy) {
        self = policy.allows(.extendedRecording) ? .pro : .free
    }

    private init(duration: TimeInterval?, maximumBytes: Int?) {
        self.duration = duration
        self.maximumBytes = maximumBytes
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

public extension Animation {
    static let relayMicro = Animation.easeOut(duration: 0.12)
    static let relayStandard = Animation.smooth(duration: 0.24)
    static let relayOverlayIn = Animation.snappy(duration: 0.32, extraBounce: 0)
    static let relayOverlayOut = Animation.easeIn(duration: 0.2)
    static let relayArrival = Animation.smooth(duration: 0.42)
}

public enum RelayMotion {
    /// The animation to use given the Reduce Motion setting (§9.5: same duration, crossfade).
    public static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.24) : .relayStandard
    }
}

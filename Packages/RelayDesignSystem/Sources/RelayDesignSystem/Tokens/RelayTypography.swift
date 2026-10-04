// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RelayTypography.swift
//  Dynamic Type, tvOS scaling and macOS sizing come for free.

import SwiftUI

public extension Font {
    static let relayScreenTitle = Font.largeTitle.weight(.bold)
    static let relayShelfTitle = Font.title2.weight(.bold)
    static let relayDetailTitle = Font.title.weight(.bold)
    static let relaySubheader = Font.title3.weight(.semibold)
    static let relayCardTitle = Font.headline.weight(.semibold)
    static let relayBody = Font.body
    static let relayCallout = Font.callout
    static let relayMeta = Font.subheadline
    static let relayStatus = Font.footnote
    static let relayStatusEmphasis = Font.footnote.weight(.medium)
    static let relayBadge = Font.caption.weight(.semibold)
    static let relayOverlayLabel = Font.caption2.weight(.semibold)
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CustomCover.swift
//  RelayDomain
//
//  The cover a player chose for a game (cover-art spec §3). It is a
//  preference, like the title or favourite: one value per game whose later
//  `updatedAt` wins, never "Two versions". A reset is a value too (no
//  fingerprint), so it can travel to other devices and win over an older
//  choice. The image itself is Relay-normalised HEIC named by its fingerprint.

import Foundation

public struct CustomCover: Hashable, Codable, Sendable {
    public let gameID: GameID
    /// SHA-256 of the normalised image; nil when the player reset the cover.
    public var fingerprint: ContentFingerprint?
    public var sizeInBytes: Int64
    public var updatedAt: Date

    public init(gameID: GameID, fingerprint: ContentFingerprint?, sizeInBytes: Int64, updatedAt: Date) {
        self.gameID = gameID
        self.fingerprint = fingerprint
        self.sizeInBytes = sizeInBytes
        self.updatedAt = updatedAt
    }

    public var isCleared: Bool { fingerprint == nil }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Cross-device membership identity. Generations advance only after durable
/// retirement; timestamps and the local GameID never allocate a generation.
public struct GameMembership: Hashable, Codable, Sendable {
    public static let maximumGeneration: Int64 = 2_147_483_647
    public let fingerprint: ContentFingerprint
    public let generation: Int64

    public init(fingerprint: ContentFingerprint, generation: Int64 = 0) {
        self.fingerprint = fingerprint
        self.generation = generation
    }

    public var hasValidGeneration: Bool { (0...Self.maximumGeneration).contains(generation) }
}

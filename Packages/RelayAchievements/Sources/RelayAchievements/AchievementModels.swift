// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain
@_exported import RelayAchievementInterfaces

public struct Achievement: Identifiable, Codable, Equatable, Sendable {
    public let id: UInt32
    public let title: String
    public let description: String
    public let points: UInt32
    public var isUnlocked: Bool
    public var isHardcore = false
    public let isSupported: Bool
    public let isChallengeActive: Bool
    public let progress: String
    public let percent: Double
    public let badgeURL: URL?
}

public struct AchievementGame: Codable, Equatable, Sendable {
    public let id: UInt32
    public let hash: String
    public let title: String
    public var achievements: [Achievement]
    public var updatedAt: Date
    public var mode: AchievementMode = .casual
    public var leaderboards: [AchievementLeaderboard] = []
    public var richPresence = ""
    public var unlockedCount: Int { achievements.filter(\.isUnlocked).count }
    public var earnedPoints: UInt32 { achievements.filter(\.isUnlocked).reduce(0) { $0 + $1.points } }
    public var totalPoints: UInt32 { achievements.reduce(0) { $0 + $1.points } }
}

public enum AchievementServiceError: Error, Equatable, Sendable {
    case invalidCredentials, unavailable, storage, unidentified, unsupported, cancelled, invalidResponse
}

/// An official emulator-session token, NEVER a Web API key or Relay identity.
/// Deliberately has no CustomStringConvertible/diagnostic representation.
public struct AchievementCredentials: Codable, Equatable, Sendable {
    public let username: String
    public let token: String
    public init(username: String, token: String) { self.username = username; self.token = token }
}

/// Only an unlock emitted by rc_client can enter the durable outbox. The
/// official request builder reconstructs its signed retry after a restart.
struct PendingAchievementAward: Codable, Equatable, Sendable {
    let username: String
    let achievementID: UInt32
    let gameHash: String
    let earnedAt: Date
    var hardcore: Bool? = nil
    var isHardcore: Bool { hardcore == true }
    var key: String { "\(username.lowercased()):\(gameHash):\(achievementID):\(isHardcore ? 1 : 0)" }
}

public enum AchievementAccountState: Equatable, Sendable {
    case disconnected, connecting, connected(String), reconnecting(String), unavailable, credentialRemovalFailed
}

public enum AchievementGameState: Equatable, Sendable {
    case inactive, loading, active, unavailable, unidentified, unsupported
}

public struct AchievementLeaderboard: Identifiable, Codable, Equatable, Sendable {
    public let id: UInt32
    public let title: String
    public let description: String
    public let value: String
    public let isTracking: Bool
    public let isSupported: Bool
}

public struct AchievementLeaderboardResult: Equatable, Sendable {
    public let id: UInt32
    public let score: String
    public let rank: UInt32
    public let entries: UInt32
}

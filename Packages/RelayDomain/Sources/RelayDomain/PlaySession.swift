// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  PlaySession.swift
//  RelayDomain
//
//  Play history — the truth the sync layer transports for "Continue Playing".
//  One `PlaySession` per launch of a game, on whichever device it happened;
//  sessions received from other installations carry their origin so the UI
//  can say "Played on iPad · 2 h ago".

import Foundation

public struct PlaySession: Hashable, Codable, Sendable, Identifiable {
    public let id: PlaySessionID
    public let gameID: GameID
    public let generation: Int64
    public let coreID: CoreID
    public let startedAt: Date
    /// Nil while the session is in progress (or if the app died before ending it).
    public var endedAt: Date?
    /// The last frame captured when the session ended, in managed storage
    public var screenshotLocation: ContentLocation?
    /// Time the app spent in the background (or otherwise not playing) during
    /// the session; excluded from `duration` so play time stays honest.
    public var pausedDuration: TimeInterval
    public var installationID: InstallationID?
    public var deviceKind: DeviceKind
    public var origin: SyncOrigin

    public init(id: PlaySessionID = PlaySessionID(), gameID: GameID, coreID: CoreID, startedAt: Date,
                endedAt: Date? = nil, screenshotLocation: ContentLocation? = nil, pausedDuration: TimeInterval = 0,
                installationID: InstallationID? = nil, deviceKind: DeviceKind = .unknown, origin: SyncOrigin = .local, generation: Int64 = 0) {
        self.id = id
        self.gameID = gameID
        self.generation = generation
        self.coreID = coreID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.screenshotLocation = screenshotLocation
        self.pausedDuration = max(0, pausedDuration)
        self.installationID = installationID
        self.deviceKind = deviceKind
        self.origin = origin
    }

    /// Play duration (wall clock minus `pausedDuration`); nil until the session has ended. Never negative.
    public var duration: TimeInterval? {
        endedAt.map { max(0, $0.timeIntervalSince(startedAt) - pausedDuration) }
    }

    /// Returns a copy marked as ended at `date` (clamped to `startedAt` at the earliest).
    public func ended(at date: Date) -> PlaySession {
        var copy = self
        copy.endedAt = max(date, startedAt)
        return copy
    }
}

/// Per-game summary derived from play sessions; what "Continue Playing" needs locally.
public struct PlayHistoryEntry: Hashable, Codable, Sendable, Identifiable {
    public var id: GameID { gameID }
    public let gameID: GameID
    /// Start of the most recent session.
    public let lastPlayedAt: Date
    /// Sum of the durations of ended sessions.
    public let totalPlayDuration: TimeInterval
    public let sessionCount: Int
    public let latestSession: PlaySession

    public init(gameID: GameID, lastPlayedAt: Date, totalPlayDuration: TimeInterval, sessionCount: Int, latestSession: PlaySession) {
        self.gameID = gameID
        self.lastPlayedAt = lastPlayedAt
        self.totalPlayDuration = totalPlayDuration
        self.sessionCount = sessionCount
        self.latestSession = latestSession
    }
}

// Legacy records always identify initial generation.
extension PlaySession {
    private enum CodingKeys: String, CodingKey {
        case id, gameID, coreID, startedAt, endedAt, screenshotLocation, pausedDuration, installationID, deviceKind, origin, generation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(PlaySessionID.self, forKey: .id),
            gameID: try values.decode(GameID.self, forKey: .gameID),
            coreID: try values.decode(CoreID.self, forKey: .coreID),
            startedAt: try values.decode(Date.self, forKey: .startedAt),
            endedAt: try values.decodeIfPresent(Date.self, forKey: .endedAt),
            screenshotLocation: try values.decodeIfPresent(ContentLocation.self, forKey: .screenshotLocation),
            pausedDuration: try values.decodeIfPresent(TimeInterval.self, forKey: .pausedDuration) ?? 0,
            installationID: try values.decodeIfPresent(InstallationID.self, forKey: .installationID),
            deviceKind: try values.decodeIfPresent(DeviceKind.self, forKey: .deviceKind) ?? .unknown,
            origin: try values.decodeIfPresent(SyncOrigin.self, forKey: .origin) ?? .local,
            generation: try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0
        )
    }
}

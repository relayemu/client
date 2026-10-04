// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SQLitePlayHistoryRepository.swift
//  RelayPersistence

import Foundation
import GRDB
import RelayDomain
import RelayLibrary

struct SQLitePlayHistoryRepository: PlayHistoryRepository {
    let writer: any DatabaseWriter
    let journaling: Bool
    let now: @Sendable () -> Date

    func record(_ session: PlaySession) async throws {
        let journaling = journaling
        try await writer.relayWrite { db in
            _ = try GenerationRules.activeGame(session.gameID, generation: session.generation, in: db)
            if let existing = try PlaySessionRecord.fetchOne(db, key: session.id.description) {
                guard existing.gameId == session.gameID.description, existing.generation == session.generation,
                      existing.installationId == (session.installationID?.description ?? existing.installationId) else {
                    throw LibraryError.invalidRelationship("session UUID belongs to another membership or source installation")
                }
            }
            var row = session
            if row.origin == .local, row.installationID == nil, let identity = try? SyncMeta.identity(in: db) {
                row.installationID = identity.installationID
                if row.deviceKind == .unknown { row.deviceKind = identity.deviceKind }
            }
            try PlaySessionRecord(row).save(db)
            if journaling, row.origin == .local { try JournalWriter.record(.playSession(row.id), in: db) }
        }
    }

    func sessions(for gameID: GameID, limit: Int) async throws -> [PlaySession] {
        try await writer.relayRead { db in
            try PlaySessionRecord
                .filter(Column("game_id") == gameID.description)
                .order(Column("started_at").desc, Column("id"))
                .limit(limit)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func session(id: PlaySessionID) async throws -> PlaySession? {
        try await writer.relayRead { db in
            try PlaySessionRecord.fetchOne(db, key: id.description)?.toDomain()
        }
    }

    func recentlyPlayed(limit: Int) async throws -> [PlayHistoryEntry] {
        try await writer.relayRead { db in
            try Self.recentlyPlayed(db, limit: limit)
        }
    }

    func lastPlayed() async throws -> PlayHistoryEntry? {
        try await writer.relayRead { db in
            try Self.recentlyPlayed(db, limit: 1).first
        }
    }

    private struct Summary: Codable, FetchableRecord {
        var gameId: String
        var lastPlayedAt: Int64
        var sessionCount: Int
        var totalDurationMillis: Int64

        enum CodingKeys: String, CodingKey {
            case gameId = "game_id"
            case lastPlayedAt = "last_played_at"
            case sessionCount = "session_count"
            case totalDurationMillis = "total_duration_millis"
        }
    }

    private static func recentlyPlayed(_ db: Database, limit: Int) throws -> [PlayHistoryEntry] {
        let summaries = try Summary.fetchAll(db, sql: """
            SELECT game_id,
                   MAX(started_at) AS last_played_at,
                   COUNT(*) AS session_count,
                   COALESCE(SUM(CASE WHEN ended_at IS NULL THEN 0 ELSE MAX(0, ended_at - started_at - paused_ms) END), 0) AS total_duration_millis
            FROM play_session
            GROUP BY game_id
            ORDER BY last_played_at DESC, game_id
            LIMIT ?
            """, arguments: [limit])
        return try summaries.map { summary in
            guard let gameID = GameID(summary.gameId) else { throw LibraryError.storage("invalid game id '\(summary.gameId)'") }
            guard let latest = try PlaySessionRecord
                .filter(Column("game_id") == summary.gameId)
                .order(Column("started_at").desc, Column("id"))
                .fetchOne(db) else {
                throw LibraryError.storage("play history summary without sessions for \(summary.gameId)")
            }
            return PlayHistoryEntry(gameID: gameID,
                                    lastPlayedAt: Timestamps.date(summary.lastPlayedAt),
                                    totalPlayDuration: Double(summary.totalDurationMillis) / 1000,
                                    sessionCount: summary.sessionCount,
                                    latestSession: try latest.toDomain())
        }
    }
}

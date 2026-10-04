// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SQLiteGameRepository.swift
//  RelayPersistence

import Foundation
import GRDB
import RelayDomain
import RelayLibrary

struct SQLiteGameRepository: GameRepository {
    let writer: any DatabaseWriter
    let journaling: Bool
    let now: @Sendable () -> Date

    func insert(_ game: Game, files: [GameFile]) async throws {
        // Validate the relationship before touching the database so the error is a Relay error.
        let primaries = files.filter { $0.role == .primary }.count
        guard primaries <= 1, files.isEmpty || primaries == 1 else {
            throw LibraryError.invalidRelationship("a game with files needs exactly one primary file (got \(primaries))")
        }
        guard files.allSatisfy({ $0.gameID == game.id }) else {
            throw LibraryError.invalidRelationship("all files must belong to game \(game.id)")
        }
        let journaling = journaling
        try await writer.relayWrite { db in
            if let existing = try GameRecord
                .filter(Column("content_fingerprint") == game.contentFingerprint.canonicalString)
                .fetchOne(db) {
                guard let existingID = GameID(existing.id) else { throw LibraryError.storage("invalid game id '\(existing.id)'") }
                throw LibraryError.duplicateContent(existing: existingID, fingerprint: game.contentFingerprint)
            }
            try GenerationRules.requireSuccessor(game.contentFingerprint, generation: game.generation, in: db)
            try GameRecord(game).insert(db)
            for file in files {
                try GameFileRecord(file).insert(db)
            }
            if journaling { try JournalWriter.record(.gameEntry(game.contentFingerprint, generation: game.generation), in: db) }
        }
    }

    func nextGeneration(for fingerprint: ContentFingerprint) async throws -> Int64 {
        try await writer.relayRead { db in try GenerationRules.next(fingerprint, in: db) }
    }

    func insertFile(_ file: GameFile) async throws {
        try await writer.relayWrite { db in
            _ = try GenerationRules.activeGame(file.gameID, in: db)
            if file.role == .primary,
               try GameFileRecord.filter(Column("game_id") == file.gameID.description && Column("role") == "primary").fetchCount(db) > 0 {
                throw LibraryError.invalidRelationship("game \(file.gameID) already has a primary file")
            }
            try GameFileRecord(file).insert(db)
        }
    }

    func game(id: GameID) async throws -> Game? {
        try await writer.relayRead { db in
            try GameRecord.fetchOne(db, key: id.description)?.toDomain()
        }
    }

    func game(fingerprint: ContentFingerprint) async throws -> Game? {
        try await writer.relayRead { db in
            try GameRecord.filter(Column("content_fingerprint") == fingerprint.canonicalString).fetchOne(db)?.toDomain()
        }
    }

    func allGames() async throws -> [Game] {
        try await writer.relayRead { db in
            try GameRecord
                .order(Column("title").collating(.nocase), Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func files(for gameID: GameID) async throws -> [GameFile] {
        try await writer.relayRead { db in
            try GameFileRecord
                .filter(Column("game_id") == gameID.description)
                .order(sql: "CASE role WHEN 'primary' THEN 0 ELSE 1 END, original_file_name, id")
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func update(_ game: Game) async throws {
        let journaling = journaling
        try await writer.relayWrite { db in
            guard var record = try GameRecord.fetchOne(db, key: game.id.description) else {
                throw LibraryError.gameNotFound(game.id)
            }
            _ = try GenerationRules.activeGame(game.id, generation: game.generation, in: db)
            guard record.contentFingerprint == game.contentFingerprint.canonicalString,
                  record.systemId == game.systemID.rawValue else {
                throw LibraryError.invalidRelationship("canonical game classification and identity are immutable")
            }
            // Only display metadata participates in last-write-wins.
            record.title = game.title
            record.isFavorite = game.isFavorite
            record.updatedAt = Timestamps.millis(game.updatedAt)
            try record.update(db)
            if journaling { try JournalWriter.record(.gameEntry(game.contentFingerprint, generation: game.generation), in: db) }
        }
    }

    /// Delete from Library: cascades to every row of the game and records the
    /// deletion tombstone with its intent (stale devices must not resurrect it).
    func deleteGame(id: GameID) async throws {
        let journaling = journaling
        let deletedAt = now()
        try await writer.relayWrite { db in
            guard let record = try GameRecord.fetchOne(db, key: id.description) else { return }
            let fingerprint = try ContentFingerprint(parsing: record.contentFingerprint)
            let identity = try SyncMeta.identity(in: db)
            let tombstone = DeletionTombstone(target: .game(fingerprint), deletedAt: deletedAt,
                                              installationID: identity.installationID, generation: record.generation)
            try SyncTombstoneRecord.upsert(tombstone, in: db)
            _ = try GameRecord.deleteOne(db, key: id.description)
            let removedContent = try GameContentRecord.filter(Column("fingerprint") == fingerprint.canonicalString)
                .filter(Column("generation") <= record.generation).deleteAll(db)
            guard journaling else { return }
            let entry = SyncIntent.gameEntry(fingerprint, generation: record.generation)
            try db.execute(sql: "DELETE FROM sync_journal WHERE kind = ? AND key = ?", arguments: [entry.kind.rawValue, entry.key])
            try JournalWriter.record(.tombstone(tombstone.target, generation: tombstone.generation), in: db)
            if removedContent > 0 {
                try JournalWriter.record(.contentIndex(fingerprint, operation: .delete, generation: record.generation), in: db)
                try JournalWriter.record(.gameContent(fingerprint, operation: .delete, generation: record.generation), in: db)
            }
        }
    }

    func removeLocalContent(gameID: GameID) async throws {
        try await writer.relayWrite { db in
            _ = try GameFileRecord.filter(Column("game_id") == gameID.description).deleteAll(db)
        }
    }
}


extension SQLiteGameRepository {
    func games(matching query: GameQuery) async throws -> [Game] {
        try await writer.relayRead { db in
            var request = GameRecord.all()
            if let system = query.systemID { request = request.filter(Column("system_id") == system.rawValue) }
            if query.favoritesOnly { request = request.filter(Column("is_favorite") == true) }
            if let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let pattern = "%" + Self.escapeLike(text) + "%"
                let systemIDs = query.matchingSystemIDs.map(\.rawValue)
                // Title, a matching system name, or metadata (developer, publisher, alternate titles JSON).
                let sql = """
                    (game.title LIKE ? ESCAPE '\\'
                     OR game.system_id IN (SELECT value FROM json_each(?))
                     OR EXISTS (SELECT 1 FROM game_metadata m WHERE m.game_id = game.id
                                AND (m.developer LIKE ? ESCAPE '\\' OR m.publisher LIKE ? ESCAPE '\\'
                                     OR m.alternate_titles LIKE ? ESCAPE '\\')))
                    """
                request = request.filter(sql: sql, arguments: [pattern, Self.jsonArray(systemIDs), pattern, pattern, pattern])
            }
            switch query.sort {
            case .title: request = request.order(Column("title").collating(.nocase), Column("id"))
            case .recentlyAdded: request = request.order(Column("added_at").desc, Column("id"))
            }
            if let limit = query.limit { request = request.limit(limit) }
            return try request.fetchAll(db).map { try $0.toDomain() }
        }
    }

    func recentlyAdded(limit: Int) async throws -> [Game] {
        try await games(matching: GameQuery(sort: .recentlyAdded, limit: limit))
    }

    func gameCountsBySystem() async throws -> [SystemID: Int] {
        try await writer.relayRead { db in
            let rows = try Row.fetchAll(db, sql: "SELECT system_id, COUNT(*) AS n FROM game GROUP BY system_id")
            var counts: [SystemID: Int] = [:]
            for row in rows { counts[SystemID(rawValue: row["system_id"])] = row["n"] }
            return counts
        }
    }

    func metadata(for gameID: GameID) async throws -> GameMetadata? {
        try await writer.relayRead { db in
            try GameMetadataRecord.fetchOne(db, key: gameID.description)?.toDomain()
        }
    }

    func upsertMetadata(_ metadata: GameMetadata) async throws {
        try await writer.relayWrite { db in
            guard try gameExists(metadata.gameID, in: db) else { throw LibraryError.gameNotFound(metadata.gameID) }
            try GameMetadataRecord(metadata).save(db)
        }
    }

    func deleteMetadata(for gameID: GameID) async throws {
        try await writer.relayWrite { db in
            _ = try GameMetadataRecord.deleteOne(db, key: gameID.description)
        }
    }

    func lookupDigests(for fingerprint: ContentFingerprint) async throws -> LookupDigests? {
        try await writer.relayRead { db in try ContentLookupRecord.fetchOne(db, key: fingerprint.description)?.digests }
    }

    func setLookupDigests(_ digests: LookupDigests, for fingerprint: ContentFingerprint) async throws {
        try await writer.relayWrite { db in try ContentLookupRecord(digests, fingerprint: fingerprint).save(db) }
    }

    func setArtworkLocation(_ location: ContentLocation?, for gameID: GameID) async throws {
        try await writer.relayWrite { db in
            try db.execute(sql: "UPDATE game_metadata SET artwork_root = ?, artwork_path = ? WHERE game_id = ?",
                           arguments: [location?.root.rawValue, location?.relativePath, gameID.description])
        }
    }

    func coverMissedAt(key: String) async throws -> Date? {
        try await writer.relayRead { db in
            try Int64.fetchOne(db, sql: "SELECT missed_at FROM cover_miss WHERE cover_key = ?", arguments: [key]).map(Timestamps.date)
        }
    }

    func customCover(for gameID: GameID) async throws -> CustomCover? {
        try await writer.relayRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM custom_cover WHERE game_id = ?", arguments: [gameID.description]).map(Self.customCover)
        }
    }

    func customCovers() async throws -> [CustomCover] {
        try await writer.relayRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM custom_cover ORDER BY game_id").map(Self.customCover)
        }
    }

    func setCustomCover(_ cover: CustomCover) async throws {
        let journaling = journaling
        try await writer.relayWrite { db in
            guard let membership = try Row.fetchOne(db, sql: "SELECT content_fingerprint, generation FROM game WHERE id = ?",
                                                    arguments: [cover.gameID.description]) else {
                throw LibraryError.gameNotFound(cover.gameID)
            }
            try db.execute(sql: "INSERT OR REPLACE INTO custom_cover (game_id, fingerprint, size_in_bytes, updated_at) VALUES (?, ?, ?, ?)",
                           arguments: [cover.gameID.description, cover.fingerprint?.canonicalString, cover.sizeInBytes,
                                       Timestamps.millis(cover.updatedAt)])
            // The player's choice and its sync intent are one transaction.
            if journaling {
                let fingerprint = try ContentFingerprint(parsing: membership["content_fingerprint"])
                try JournalWriter.record(.artwork(fingerprint, generation: membership["generation"]), in: db)
            }
        }
    }

    private static func customCover(_ row: Row) throws -> CustomCover {
        let raw: String = row["game_id"]
        guard let gameID = GameID(raw) else { throw LibraryError.storage("invalid game id '\(raw)'") }
        let fingerprint = try (row["fingerprint"] as String?).map { try ContentFingerprint(parsing: $0) }
        return CustomCover(gameID: gameID, fingerprint: fingerprint, sizeInBytes: row["size_in_bytes"],
                           updatedAt: Timestamps.date(row["updated_at"]))
    }

    func recordCoverMiss(key: String, at date: Date) async throws {
        try await writer.relayWrite { db in
            try db.execute(sql: "INSERT OR REPLACE INTO cover_miss (cover_key, missed_at) VALUES (?, ?)",
                           arguments: [key, Timestamps.millis(date)])
        }
    }

    /// Escapes `%`, `_` and `\` for a LIKE pattern using `\` as the escape character.
    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func jsonArray(_ strings: [String]) -> String {
        String(data: (try? JSONEncoder().encode(strings)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }
}

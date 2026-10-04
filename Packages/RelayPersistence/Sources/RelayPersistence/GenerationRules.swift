// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import GRDB
import RelayDomain
import RelayLibrary

/// Membership checks shared by canonical writers and the remote transaction.
/// Every caller holds the same database transaction as its eventual mutation.
enum GenerationRules {
    static func validate(_ generation: Int64) throws {
        guard (0...GameMembership.maximumGeneration).contains(generation) else {
            throw LibraryError.invalidRelationship("generation is out of range")
        }
    }

    static func retired(_ fingerprint: ContentFingerprint, in db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT retired_through FROM sync_game_retirement WHERE fingerprint = ?",
                          arguments: [fingerprint.canonicalString])
    }

    static func next(_ fingerprint: ContentFingerprint, in db: Database) throws -> Int64 {
        guard let retired = try retired(fingerprint, in: db) else { return 0 }
        guard retired < GameMembership.maximumGeneration else {
            throw LibraryError.invalidRelationship("library generation exhausted")
        }
        return retired + 1
    }

    static func retire(_ fingerprint: ContentFingerprint, through generation: Int64, in db: Database) throws {
        try validate(generation)
        try db.execute(sql: """
            INSERT INTO sync_game_retirement (fingerprint, retired_through) VALUES (?, ?)
            ON CONFLICT(fingerprint) DO UPDATE SET retired_through = MAX(retired_through, excluded.retired_through)
            """, arguments: [fingerprint.canonicalString, generation])
    }

    static func isRetired(_ fingerprint: ContentFingerprint, generation: Int64, in db: Database) throws -> Bool {
        try validate(generation)
        return try retired(fingerprint, in: db).map { generation <= $0 } ?? false
    }

    static func requireSuccessor(_ fingerprint: ContentFingerprint, generation: Int64, in db: Database) throws {
        try validate(generation)
        guard generation == (try next(fingerprint, in: db)) else {
            throw LibraryError.membershipChanged
        }
    }

    static func activeGame(_ id: GameID, generation: Int64? = nil, in db: Database) throws -> GameRecord {
        guard let game = try GameRecord.fetchOne(db, key: id.description) else { throw LibraryError.gameNotFound(id) }
        if let generation {
            try validate(generation)
            guard generation == game.generation else { throw LibraryError.membershipChanged }
        }
        let fingerprint = try ContentFingerprint(parsing: game.contentFingerprint)
        try requireSuccessor(fingerprint, generation: game.generation, in: db)
        return game
    }

    static func requireParent(_ parent: BatteryRevisionRecord, gameID: GameID, generation: Int64) throws {
        guard parent.gameId == gameID.description, parent.generation == generation else {
            throw LibraryError.invalidRelationship("battery parent belongs to another membership")
        }
    }

    static func validateDescriptor(_ descriptor: GameContentDescriptor, in db: Database) throws {
        try requireSuccessor(descriptor.fingerprint, generation: descriptor.generation, in: db)
        if let game = try GameRecord.filter(Column("content_fingerprint") == descriptor.fingerprint.canonicalString).fetchOne(db) {
            guard game.generation == descriptor.generation, game.systemId == descriptor.systemID.rawValue else {
                throw LibraryError.invalidRelationship("content classification or generation conflicts with canonical membership")
            }
        }
    }
}

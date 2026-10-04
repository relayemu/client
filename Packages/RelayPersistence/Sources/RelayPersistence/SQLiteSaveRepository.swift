// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SQLiteSaveRepository.swift
//  RelayPersistence
//
//  Battery saves, battery revisions/heads and save states. Every local
//  mutation of synchronized state records its intent in the same transaction
//  (`JournalWriter`); remote applies bypass this repository.

import Foundation
import GRDB
import RelayDomain
import RelayLibrary

struct SQLiteSaveRepository: SaveRepository {
    let writer: any DatabaseWriter
    let journaling: Bool
    let now: @Sendable () -> Date

    func upsert(_ save: Save) async throws {
        try await writer.relayWrite { db in
            _ = try GenerationRules.activeGame(save.gameID, in: db)
            try SaveRecord(save).save(db)
        }
    }

    func saves(for gameID: GameID) async throws -> [Save] {
        try await writer.relayRead { db in
            try SaveRecord
                .filter(Column("game_id") == gameID.description)
                .order(Column("updated_at").desc, Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func deleteSave(id: SaveID) async throws {
        try await writer.relayWrite { db in
            _ = try SaveRecord.deleteOne(db, key: id.description)
        }
    }

    // MARK: Battery revisions

    func commitBatterySnapshot(_ save: Save, revision: BatteryRevision) async throws {
        let journaling = journaling
        try await writer.relayWrite { db in
            guard revision.gameID == save.gameID else { throw LibraryError.invalidRelationship("revision belongs to another game") }
            _ = try GenerationRules.activeGame(save.gameID, generation: revision.generation, in: db)
            try Self.validateParents(revision, in: db)
            try SaveRecord(save).save(db)
            try BatteryRevisionRecord(revision).insert(db)
            try BatteryHeadRecord(gameId: save.gameID.description, revisionId: revision.id.description).save(db)
            if journaling, revision.origin == .local { try JournalWriter.record(.batteryRevision(revision.id), in: db) }
        }
    }

    func insertBatteryRevision(_ revision: BatteryRevision) async throws {
        let journaling = journaling
        try await writer.relayWrite { db in
            _ = try GenerationRules.activeGame(revision.gameID, generation: revision.generation, in: db)
            try Self.validateParents(revision, in: db)
            try BatteryRevisionRecord(revision).insert(db)
            if journaling, revision.origin == .local { try JournalWriter.record(.batteryRevision(revision.id), in: db) }
        }
    }

    func batteryRevisions(for gameID: GameID) async throws -> [BatteryRevision] {
        try await writer.relayRead { db in
            try BatteryRevisionRecord
                .filter(Column("game_id") == gameID.description)
                .order(Column("created_at").desc, Column("id").desc)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func batteryRevision(id: BatteryRevisionID) async throws -> BatteryRevision? {
        try await writer.relayRead { db in
            try BatteryRevisionRecord.fetchOne(db, key: id.description)?.toDomain()
        }
    }

    func activeBatteryRevisionID(for gameID: GameID) async throws -> BatteryRevisionID? {
        try await writer.relayRead { db in
            try BatteryHeadRecord.fetchOne(db, key: gameID.description).flatMap { BatteryRevisionID($0.revisionId) }
        }
    }

    func adoptBatteryRevision(_ id: BatteryRevisionID, save: Save) async throws {
        try await writer.relayWrite { db in
            guard let revision = try BatteryRevisionRecord.fetchOne(db, key: id.description) else { throw LibraryError.revisionNotFound(id) }
            guard revision.gameId == save.gameID.description else { throw LibraryError.invalidRelationship("revision \(id) belongs to another game") }
            _ = try GenerationRules.activeGame(save.gameID, generation: revision.generation, in: db)
            try SaveRecord(save).save(db)
            try BatteryHeadRecord(gameId: save.gameID.description, revisionId: id.description).save(db)
        }
    }

    // MARK: Save states

    func insert(_ state: SaveState) async throws {
        let journaling = journaling
        try await writer.relayWrite { db in
            _ = try GenerationRules.activeGame(state.gameID, generation: state.generation, in: db)
            guard try SyncTombstoneRecord.fetch(.saveState(state.id), in: db) == nil else {
                throw LibraryError.invalidRelationship("state UUID is permanently deleted")
            }
            if let parentID = state.batteryRevisionID {
                guard let parent = try BatteryRevisionRecord.fetchOne(db, key: parentID.description) else { throw LibraryError.revisionNotFound(parentID) }
                try GenerationRules.requireParent(parent, gameID: state.gameID, generation: state.generation)
            }
            try SaveStateRecord(state).insert(db)
            if journaling, state.origin == .local { try JournalWriter.record(.saveState(state.id), in: db) }
        }
    }

    func saveStates(for gameID: GameID) async throws -> [SaveState] {
        try await writer.relayRead { db in
            try SaveStateRecord
                .filter(Column("game_id") == gameID.description)
                .order(Column("created_at").desc, Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func saveState(id: SaveStateID) async throws -> SaveState? {
        try await writer.relayRead { db in
            try SaveStateRecord.fetchOne(db, key: id.description)?.toDomain()
        }
    }

    /// Every deletion creates permanent state-UUID suppression, including
    /// automatic/quick retention and explicitly deleted received states.
    func deleteSaveState(id: SaveStateID) async throws {
        let journaling = journaling
        let deletedAt = now()
        try await writer.relayWrite { db in
            guard let row = try SaveStateRecord.fetchOne(db, key: id.description) else { return }
            let state = try row.toDomain()
            let game = try GameRecord.fetchOne(db, key: row.gameId)
            let identity = try SyncMeta.identity(in: db)
            let tombstone = DeletionTombstone(target: .saveState(state.id), deletedAt: deletedAt,
                installationID: identity.installationID, generation: state.generation,
                gameFingerprint: try game.map { try ContentFingerprint(parsing: $0.contentFingerprint) })
            try SyncTombstoneRecord.upsert(tombstone, in: db)
            _ = try SaveStateRecord.deleteOne(db, key: id.description)
            guard journaling else { return }
            try db.execute(sql: "DELETE FROM sync_journal WHERE kind = 'saveState' AND key = ?", arguments: [id.description])
            try JournalWriter.record(.tombstone(tombstone.target, generation: tombstone.generation), in: db)
        }
    }

    private static func validateParents(_ revision: BatteryRevision, in db: Database) throws {
        for parentID in revision.parentIDs {
            guard parentID != revision.id,
                  let parent = try BatteryRevisionRecord.fetchOne(db, key: parentID.description) else {
                throw LibraryError.invalidRelationship("battery parent is missing or self-referential")
            }
            try GenerationRules.requireParent(parent, gameID: revision.gameID, generation: revision.generation)
        }
    }
}

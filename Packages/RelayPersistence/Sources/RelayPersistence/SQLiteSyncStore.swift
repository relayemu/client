// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SQLiteSyncStore.swift
//  RelayPersistence
//
//  The persistence side of synchronization: the journal (outbox), the
//  installation identity and small meta values, tombstones, deferred remote
//  records, cloud content descriptors, and `applyRemote` — one transaction per
//  inbound batch that never records intents (echo suppression) and applies
//  belong to rows: game entries merge (LWW on updated_at, earliest added_at),
//  sessions keep the finalised version, immutable objects are idempotent,
//  tombstones win over older entries and delete rows.

import Foundation
import GRDB
import RelayDomain
import RelayLibrary

struct SQLiteSyncJournal: SyncJournal {
    let writer: any DatabaseWriter

    func pending(limit: Int, excluding: Set<SyncIntent.Kind>) async throws -> [SyncJournalEntry] {
        let excluded = excluding.map(\.rawValue)
        return try await writer.relayRead { db in
            try SyncJournalRecord.filter(!excluded.contains(Column("kind")))
                .order(Column("sequence")).limit(limit).fetchAll(db).map { try $0.toEntry() }
        }
    }

    func pending(afterSequence: Int64, throughSequence: Int64?, limit: Int, excluding: Set<SyncIntent.Kind>) async throws -> SyncJournalPage {
        guard afterSequence >= 0, (1...1_000).contains(limit),
              throughSequence.map({ $0 >= afterSequence }) ?? true else {
            throw LibraryError.invalidRelationship("invalid journal pagination bounds")
        }
        let excluded = excluding.map(\.rawValue)
        return try await writer.relayRead { db in
            let ceiling: Int64
            if let throughSequence {
                ceiling = throughSequence
            } else {
                let tail = try Int64.fetchOne(db, sql: "SELECT MAX(sequence) FROM sync_journal") ?? 0
                ceiling = max(afterSequence, tail)
            }
            let rows = try SyncJournalRecord
                .filter(Column("sequence") > afterSequence && Column("sequence") <= ceiling)
                .filter(!excluded.contains(Column("kind")))
                .order(Column("sequence")).limit(limit + 1).fetchAll(db)
            return SyncJournalPage(entries: try rows.prefix(limit).map { try $0.toEntry() },
                                   throughSequence: ceiling, hasMore: rows.count > limit)
        }
    }

    func pendingCount() async throws -> Int {
        try await writer.relayRead { db in
            try SyncJournalRecord.filter(Column("kind") != SyncIntent.Kind.artwork.rawValue).fetchCount(db)
        }
    }

    func pendingIDs(in ids: [Int64]) async throws -> Set<Int64> {
        // Bound caller work and each statement's bind variables. All chunks
        // share one read snapshot so membership cannot mix database versions.
        guard ids.count <= 100_000 else {
            throw LibraryError.invalidRelationship("too many journal receipts to confirm")
        }
        guard !ids.isEmpty else { return [] }
        return try await writer.relayRead { db in
            var found: Set<Int64> = []
            for offset in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[offset..<min(offset + 500, ids.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                found.formUnion(try Int64.fetchAll(db,
                    sql: "SELECT sequence FROM sync_journal WHERE sequence IN (\(placeholders))",
                    arguments: StatementArguments(chunk)))
            }
            return found
        }
    }

    func enqueue(_ intents: [SyncIntent]) async throws {
        try await writer.relayWrite { db in try JournalWriter.record(intents, in: db) }
    }

    func complete(_ ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await writer.relayWrite { db in
            _ = try SyncJournalRecord.filter(ids.contains(Column("sequence"))).deleteAll(db)
        }
    }

    func fail(_ ids: [Int64], reason: String) async throws {
        guard !ids.isEmpty else { return }
        try await writer.relayWrite { db in
            try db.execute(sql: "UPDATE sync_journal SET attempts = attempts + 1, last_error = ? WHERE sequence IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                           arguments: StatementArguments([reason] + ids.map { String($0) }))
        }
    }

    func clear() async throws {
        try await writer.relayWrite { db in _ = try SyncJournalRecord.deleteAll(db) }
    }
}

struct SQLiteSyncStore: SyncStore {
    let writer: any DatabaseWriter

    var journal: any SyncJournal { SQLiteSyncJournal(writer: writer) }

    func identity() async throws -> SyncIdentity {
        try await writer.relayRead { db in try SyncMeta.identity(in: db) }
    }

    func metaValue(forKey key: String) async throws -> String? {
        try await writer.relayRead { db in try SyncMeta.value(key, in: db) }
    }

    func setMetaValue(_ value: String?, forKey key: String) async throws {
        try await writer.relayWrite { db in try SyncMeta.set(value, key: key, in: db) }
    }

    // MARK: Apply remote

    func applyRemote(_ batch: RemoteApplyBatch) async throws -> RemoteApplyOutcome {
        try await writer.relayWrite { db in
            var outcome = RemoteApplyOutcome()
            let identity = try SyncMeta.identity(in: db)
            var deletedMemberships: [GameID: Int64] = [:]
            var batchRetirements: [ContentFingerprint: Int64] = [:]
            var batchStateDeletions = Set(batch.deletedStateIDs)

            // A barrier and the resulting cascade commit atomically. Old
            // tombstones cannot remove a newer active incarnation.
            for tombstone in batch.tombstones {
                try SyncTombstoneRecord.upsert(tombstone, in: db)
                switch tombstone.target {
                case .game(let fingerprint):
                    batchRetirements[fingerprint] = max(batchRetirements[fingerprint] ?? -1, tombstone.generation)
                    if let row = try GameRecord.filter(Column("content_fingerprint") == fingerprint.canonicalString).fetchOne(db),
                       row.generation <= tombstone.generation, let id = GameID(row.id) {
                        deletedMemberships[id] = row.generation
                        _ = try GameRecord.deleteOne(db, key: row.id)
                        outcome.deletedGameIDs.append(id)
                    }
                    _ = try GameContentRecord.filter(Column("fingerprint") == fingerprint.canonicalString)
                        .filter(Column("generation") <= tombstone.generation).deleteAll(db)
                case .saveState(let id):
                    batchStateDeletions.insert(id)
                    if let row = try SaveStateRecord.fetchOne(db, key: id.description) {
                        _ = try SaveStateRecord.deleteOne(db, key: id.description)
                        outcome.deletedStates.append(try row.toDomain())
                    }
                }
            }
            // Compatibility with old CloudKit record deletion callbacks: the
            // observer records permanent suppression, even if the row is absent.
            for id in batch.deletedStateIDs {
                let state = try SaveStateRecord.fetchOne(db, key: id.description)
                let game = try state.flatMap { try GameRecord.fetchOne(db, key: $0.gameId) }
                let tombstone = DeletionTombstone(target: .saveState(id), deletedAt: Date(),
                    installationID: identity.installationID, generation: state?.generation ?? 0,
                    gameFingerprint: try game.map { try ContentFingerprint(parsing: $0.contentFingerprint) })
                try SyncTombstoneRecord.upsert(tombstone, in: db)
                if let state {
                    _ = try SaveStateRecord.deleteOne(db, key: id.description)
                    outcome.deletedStates.append(try state.toDomain())
                }
            }

            for entry in batch.gameEntries {
                try GenerationRules.validate(entry.generation)
                if let retired = batchRetirements[entry.fingerprint], entry.generation <= retired {
                    outcome.skippedRetired += 1; continue
                }
                try GenerationRules.requireSuccessor(entry.fingerprint, generation: entry.generation, in: db)
                if var row = try GameRecord.filter(Column("content_fingerprint") == entry.fingerprint.canonicalString).fetchOne(db) {
                    guard row.generation == entry.generation else { throw LibraryError.membershipChanged }
                    guard row.systemId == entry.systemID.rawValue else {
                        throw LibraryError.invalidRelationship("canonical game classification is immutable")
                    }
                    let incoming = Timestamps.millis(entry.updatedAt)
                    let incomingWins = incoming > row.updatedAt
                        || (incoming == row.updatedAt && (entry.title, entry.isFavorite ? 1 : 0) > (row.title, row.isFavorite ? 1 : 0))
                    if incomingWins { row.title = entry.title; row.isFavorite = entry.isFavorite; row.updatedAt = incoming }
                    row.addedAt = min(row.addedAt, Timestamps.millis(entry.addedAt))
                    try row.update(db)
                } else {
                    let game = Game(id: entry.proposedID, systemID: entry.systemID, title: entry.title,
                        contentFingerprint: entry.fingerprint, addedAt: entry.addedAt, isFavorite: entry.isFavorite,
                        updatedAt: entry.updatedAt, generation: entry.generation)
                    try GameRecord(game).insert(db)
                    outcome.createdGameIDs.append(game.id)
                }
            }

            for descriptor in batch.contentDescriptors {
                if let retired = batchRetirements[descriptor.fingerprint], descriptor.generation <= retired {
                    outcome.skippedRetired += 1; continue
                }
                try GenerationRules.validateDescriptor(descriptor, in: db)
                try GameContentRecord(descriptor, remoteScope: batch.remoteScope).save(db)
            }
            let deletedContent = batch.deletedContentMemberships + batch.deletedContentFingerprints.map { GameMembership(fingerprint: $0) }
            for membership in deletedContent {
                try GenerationRules.validate(membership.generation)
                _ = try GameContentRecord.filter(Column("remote_scope") == batch.remoteScope)
                    .filter(Column("fingerprint") == membership.fingerprint.canonicalString)
                    .filter(Column("generation") == membership.generation).deleteAll(db)
            }

            func requireActive(_ id: GameID, generation: Int64) throws -> Bool {
                if let retired = deletedMemberships[id], generation <= retired { return false }
                guard try gameExists(id, in: db) else { throw LibraryError.membershipChanged }
                _ = try GenerationRules.activeGame(id, generation: generation, in: db)
                return true
            }

            for session in batch.sessions {
                guard try requireActive(session.gameID, generation: session.generation) else { outcome.skippedRetired += 1; continue }
                if let existing = try PlaySessionRecord.fetchOne(db, key: session.id.description) {
                    guard existing.gameId == session.gameID.description, existing.generation == session.generation,
                          existing.installationId == session.installationID?.description else {
                        throw LibraryError.invalidRelationship("session UUID belongs to another membership or source installation")
                    }
                    if existing.installationId == identity.installationID.description { continue }
                    if session.endedAt.map(Timestamps.millis) ?? 0 < existing.endedAt ?? 0 { continue }
                }
                var remote = session; remote.origin = .remote
                try PlaySessionRecord(remote).save(db)
            }

            // Custom covers: last writer wins by (updated_at, fingerprint or ''), never journalled.
            for remote in batch.customCovers {
                guard try requireActive(remote.cover.gameID, generation: remote.generation) else { outcome.skippedRetired += 1; continue }
                try db.execute(sql: """
                    INSERT INTO custom_cover (game_id, fingerprint, size_in_bytes, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(game_id) DO UPDATE SET fingerprint = excluded.fingerprint, size_in_bytes = excluded.size_in_bytes,
                        updated_at = excluded.updated_at
                    WHERE (excluded.updated_at, coalesce(excluded.fingerprint, '')) > (custom_cover.updated_at, coalesce(custom_cover.fingerprint, ''))
                    """, arguments: [remote.cover.gameID.description, remote.cover.fingerprint?.canonicalString, remote.cover.sizeInBytes,
                                    Timestamps.millis(remote.cover.updatedAt)])
            }

            var incomingRevisions: [BatteryRevisionID: BatteryRevision] = [:]
            for revision in batch.revisions {
                if let other = incomingRevisions[revision.id],
                   (other.gameID != revision.gameID || other.generation != revision.generation || other.dataFingerprint != revision.dataFingerprint
                    || other.installationID != revision.installationID || other.parentIDs != revision.parentIDs) {
                    throw LibraryError.invalidRelationship("battery revision UUID has conflicting immutable identity")
                }
                incomingRevisions[revision.id] = revision
            }
            func requireParent(_ id: BatteryRevisionID, gameID: GameID, generation: Int64) throws {
                if let parent = try BatteryRevisionRecord.fetchOne(db, key: id.description) {
                    try GenerationRules.requireParent(parent, gameID: gameID, generation: generation)
                } else if let parent = incomingRevisions[id] {
                    guard parent.gameID == gameID, parent.generation == generation else {
                        throw LibraryError.invalidRelationship("battery reference belongs to another membership")
                    }
                } else { throw LibraryError.invalidRelationship("battery reference is missing") }
            }
            var touchedGames: Set<GameID> = []
            for revision in batch.revisions {
                guard try requireActive(revision.gameID, generation: revision.generation) else { outcome.skippedRetired += 1; continue }
                for parent in revision.parentIDs {
                    guard parent != revision.id else { throw LibraryError.invalidRelationship("battery revision references itself") }
                    try requireParent(parent, gameID: revision.gameID, generation: revision.generation)
                }
                if let existing = try BatteryRevisionRecord.fetchOne(db, key: revision.id.description) {
                    guard existing.gameId == revision.gameID.description, existing.generation == revision.generation,
                          existing.installationId == revision.installationID.description,
                          existing.dataFingerprint == revision.dataFingerprint.canonicalString,
                          (try existing.toDomain()).parentIDs == revision.parentIDs else {
                        throw LibraryError.invalidRelationship("battery revision UUID has conflicting immutable identity")
                    }
                    outcome.skippedExisting += 1; continue
                }
                let remote = BatteryRevision(id: revision.id, gameID: revision.gameID, parentIDs: revision.parentIDs,
                    createdAt: revision.createdAt, dataFingerprint: revision.dataFingerprint, sizeInBytes: revision.sizeInBytes,
                    installationID: revision.installationID, deviceKind: revision.deviceKind, location: revision.location,
                    screenshotLocation: revision.screenshotLocation, origin: .remote, generation: revision.generation)
                try BatteryRevisionRecord(remote).insert(db)
                touchedGames.insert(revision.gameID)
            }
            outcome.gamesNeedingReconciliation = Array(touchedGames)

            for state in batch.states {
                if batchStateDeletions.contains(state.id) { outcome.skippedRetired += 1; continue }
                guard try requireActive(state.gameID, generation: state.generation) else { outcome.skippedRetired += 1; continue }
                // A tombstone installed after preparation invalidates the whole
                // batch, including its cursor, so staged files can be removed.
                guard try SyncTombstoneRecord.fetch(.saveState(state.id), in: db) == nil else { throw LibraryError.membershipChanged }
                if let parent = state.batteryRevisionID { try requireParent(parent, gameID: state.gameID, generation: state.generation) }
                if let existing = try SaveStateRecord.fetchOne(db, key: state.id.description) {
                    guard existing.gameId == state.gameID.description, existing.generation == state.generation,
                          existing.installationId == state.installationID?.description else {
                        throw LibraryError.invalidRelationship("state UUID belongs to another membership or source installation")
                    }
                    outcome.skippedExisting += 1; continue
                }
                var remote = state; remote.origin = .remote
                try SaveStateRecord(remote).insert(db)
            }

            for key in batch.resolvedDeferredKeys {
                _ = try SyncDeferredRecord.filter(Column("remote_scope") == batch.remoteScope).filter(Column("key") == key).deleteAll(db)
            }
            for deferred in batch.deferred { try SyncDeferredRecord(deferred, remoteScope: batch.remoteScope).save(db) }
            if let checkpoint = batch.checkpoint {
                guard checkpoint.sequence >= 0 else { throw LibraryError.invalidRelationship("negative sync checkpoint") }
                let previous = try SyncMeta.value(checkpoint.key, in: db).flatMap(Int64.init) ?? 0
                guard checkpoint.sequence >= previous else { throw LibraryError.invalidRelationship("sync checkpoint regressed") }
                try SyncMeta.set(String(checkpoint.sequence), key: checkpoint.key, in: db)
            }
            return outcome
        }
    }

    // MARK: Deferred

    func deferredRecords() async throws -> [DeferredRemoteRecord] {
        return try await deferredRecords(remoteScope: "cloudkit")
    }

    func deferredRecords(remoteScope: String) async throws -> [DeferredRemoteRecord] {
        try await writer.relayRead { db in
            try SyncDeferredRecord.filter(Column("remote_scope") == remoteScope).order(Column("received_at"), Column("key")).fetchAll(db).map { $0.toDomain() }
        }
    }

    func removeDeferredRecords(keys: [String]) async throws {
        try await removeDeferredRecords(keys: keys, remoteScope: "cloudkit")
    }

    func removeDeferredRecords(keys: [String], remoteScope: String) async throws {
        guard !keys.isEmpty else { return }
        try await writer.relayWrite { db in
            _ = try SyncDeferredRecord.filter(Column("remote_scope") == remoteScope).filter(keys.contains(Column("key"))).deleteAll(db)
        }
    }

    // MARK: Tombstones

    func tombstones() async throws -> [DeletionTombstone] {
        try await writer.relayRead { db in
            try SyncTombstoneRecord.order(Column("deleted_at")).fetchAll(db).map { try $0.toDomain() }
        }
    }

    func tombstone(for target: DeletionTombstone.Target) async throws -> DeletionTombstone? {
        try await tombstone(for: target, generation: 0)
    }

    func tombstone(for target: DeletionTombstone.Target, generation: Int64) async throws -> DeletionTombstone? {
        try GenerationRules.validate(generation)
        return try await writer.relayRead { db in try SyncTombstoneRecord.fetch(target, generation: generation, in: db) }
    }

    func retiredGeneration(for fingerprint: ContentFingerprint) async throws -> Int64? {
        try await writer.relayRead { db in try GenerationRules.retired(fingerprint, in: db) }
    }

    func recordTombstone(_ tombstone: DeletionTombstone) async throws {
        try await writer.relayWrite { db in
            try SyncTombstoneRecord.upsert(tombstone, in: db)
            try JournalWriter.record(.tombstone(tombstone.target, generation: tombstone.generation), in: db)
        }
    }

    // MARK: Content descriptors

    func contentDescriptors() async throws -> [GameContentDescriptor] {
        return try await contentDescriptors(remoteScope: "cloudkit")
    }

    func contentDescriptors(remoteScope: String) async throws -> [GameContentDescriptor] {
        try await writer.relayRead { db in
            try GameContentRecord.filter(Column("remote_scope") == remoteScope).order(Column("fingerprint")).fetchAll(db).map { try $0.toDomain() }
        }
    }

    func contentDescriptor(for fingerprint: ContentFingerprint) async throws -> GameContentDescriptor? {
        return try await contentDescriptor(for: fingerprint, remoteScope: "cloudkit")
    }

    func contentDescriptor(for fingerprint: ContentFingerprint, remoteScope: String) async throws -> GameContentDescriptor? {
        try await writer.relayRead { db in
            try GameContentRecord.filter(Column("remote_scope") == remoteScope).filter(Column("fingerprint") == fingerprint.canonicalString).fetchOne(db)?.toDomain()
        }
    }

    func recordContentDescriptor(_ descriptor: GameContentDescriptor) async throws {
        try await recordContentDescriptor(descriptor, remoteScope: "cloudkit")
    }

    func recordContentDescriptor(_ descriptor: GameContentDescriptor, remoteScope: String) async throws {
        try await writer.relayWrite { db in
            try GenerationRules.validateDescriptor(descriptor, in: db)
            try GameContentRecord(descriptor, remoteScope: remoteScope).save(db)
            try JournalWriter.record(.contentIndex(descriptor.fingerprint, generation: descriptor.generation), in: db)
        }
    }

    func removeContentDescriptor(for fingerprint: ContentFingerprint, recordIntent: Bool) async throws {
        try await removeContentDescriptor(for: fingerprint, generation: 0, recordIntent: recordIntent, remoteScope: "cloudkit")
    }

    func removeContentDescriptor(for fingerprint: ContentFingerprint, recordIntent: Bool, remoteScope: String) async throws {
        try await removeContentDescriptor(for: fingerprint, generation: 0, recordIntent: recordIntent, remoteScope: remoteScope)
    }

    func removeContentDescriptor(for fingerprint: ContentFingerprint, generation: Int64, recordIntent: Bool) async throws {
        try await removeContentDescriptor(for: fingerprint, generation: generation, recordIntent: recordIntent, remoteScope: "cloudkit")
    }

    func removeContentDescriptor(for fingerprint: ContentFingerprint, generation: Int64, recordIntent: Bool, remoteScope: String) async throws {
        try GenerationRules.validate(generation)
        try await writer.relayWrite { db in
            _ = try GameContentRecord.filter(Column("remote_scope") == remoteScope)
                .filter(Column("fingerprint") == fingerprint.canonicalString).filter(Column("generation") == generation).deleteAll(db)
            if recordIntent {
                try JournalWriter.record(.contentIndex(fingerprint, operation: .delete, generation: generation), in: db)
                try JournalWriter.record(.gameContent(fingerprint, operation: .delete, generation: generation), in: db)
            }
        }
    }

    // MARK: Reconciliation

    /// Journals every local synchronized object: game entries, local-origin
    /// revisions, states and sessions, tombstones and content descriptors this
    /// device uploaded. The explicit bridge variant includes received history
    /// without changing its original installation or provenance.
    func enqueueEverything() async throws {
        try await enqueueEverything(remoteScope: "cloudkit")
    }

    func enqueueEverything(remoteScope: String) async throws {
        try await enqueueEverything(remoteScope: remoteScope, includeRemoteHistory: false)
    }

    func enqueueEverything(remoteScope: String, includeRemoteHistory: Bool) async throws {
        try await writer.relayWrite { db in
            let now = Date()
            for game in try GameRecord.fetchAll(db) {
                try JournalWriter.record(.gameEntry(try ContentFingerprint(parsing: game.contentFingerprint), generation: game.generation), in: db, now: now)
            }
            for revision in try BatteryRevisionRecord.filter(includeRemoteHistory || Column("origin") == SyncOrigin.local.rawValue).fetchAll(db) {
                if let id = BatteryRevisionID(revision.id) { try JournalWriter.record(.batteryRevision(id), in: db, now: now) }
            }
            for state in try SaveStateRecord.filter(includeRemoteHistory || Column("origin") == SyncOrigin.local.rawValue).fetchAll(db) {
                if let id = SaveStateID(state.id) { try JournalWriter.record(.saveState(id), in: db, now: now) }
            }
            for session in try PlaySessionRecord.filter(includeRemoteHistory || Column("origin") == SyncOrigin.local.rawValue).fetchAll(db) {
                if let id = PlaySessionID(session.id) { try JournalWriter.record(.playSession(id), in: db, now: now) }
            }
            for tombstone in try SyncTombstoneRecord.fetchAll(db) {
                try JournalWriter.record(.tombstone(try tombstone.toDomain().target, generation: tombstone.generation), in: db, now: now)
            }
            for content in try GameContentRecord.filter(Column("remote_scope") == remoteScope).fetchAll(db) {
                try JournalWriter.record(.contentIndex(try ContentFingerprint(parsing: content.fingerprint), generation: content.generation), in: db, now: now)
            }
        }
    }
}

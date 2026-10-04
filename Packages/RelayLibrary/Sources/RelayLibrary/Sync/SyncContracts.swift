// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncContracts.swift
//  RelayLibrary
//
//  types, no database types: intents, a durable journal and the transactional
//  operations the semantic sync layer (Packages/RelaySync) needs.
//
//  Contract rules every implementation must honour:
//    - a repository mutation of synchronized state records its `SyncIntent`
//      inside the same transaction as the canonical change (crash-safe);
//    - `applyRemote` is one transaction per batch; nothing half-applied is
//      ever visible; it never records intents (echo suppression);
//    - the journal survives restarts and tolerates replay (deterministic keys);
//    - identity is minted once per store and never derived from hardware.

import Foundation
import RelayDomain

/// Which installation and device kind this store belongs to.
public struct SyncIdentity: Hashable, Sendable {
    public let installationID: InstallationID
    public let deviceKind: DeviceKind

    public init(installationID: InstallationID, deviceKind: DeviceKind) {
        self.installationID = installationID
        self.deviceKind = deviceKind
    }
}

/// The durable intent to upload (or delete) one logical object. The payload
/// is built from canonical rows at send time, so mutable objects coalesce to
/// one pending intent per key.
public struct SyncIntent: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case gameEntry, playSession, batteryRevision, saveState, tombstone, contentIndex, gameContent
        /// A game's custom-cover value (cover-art Plan E). Cosmetic: never counted as pending
        /// progress, and sent only by a transport that can carry it.
        case artwork
    }

    public enum Operation: String, Codable, Sendable {
        case upsert, delete
    }

    public let kind: Kind
    /// Logical key: a content fingerprint (`sha256:…`) or an entity UUID string,
    /// or `<kind>:<key>` for tombstones.
    public let key: String
    public let operation: Operation

    public init(kind: Kind, key: String, operation: Operation = .upsert) {
        self.kind = kind
        self.key = key
        self.operation = operation
    }

    public static func gameEntry(_ fingerprint: ContentFingerprint, generation: Int64 = 0) -> SyncIntent { SyncIntent(kind: .gameEntry, key: contentKey(fingerprint, generation: generation)) }
    public static func playSession(_ id: PlaySessionID) -> SyncIntent { SyncIntent(kind: .playSession, key: id.description) }
    public static func batteryRevision(_ id: BatteryRevisionID) -> SyncIntent { SyncIntent(kind: .batteryRevision, key: id.description) }
    public static func saveState(_ id: SaveStateID, operation: Operation = .upsert) -> SyncIntent { SyncIntent(kind: .saveState, key: id.description, operation: operation) }
    public static func tombstone(_ target: DeletionTombstone.Target, generation: Int64 = 0) -> SyncIntent {
        let key: String
        if case .game(let fingerprint) = target { key = contentKey(fingerprint, generation: generation) }
        else { key = target.keyString }
        return SyncIntent(kind: .tombstone, key: "\(target.kindName):\(key)")
    }
    public static func contentIndex(_ fingerprint: ContentFingerprint, operation: Operation = .upsert, generation: Int64 = 0) -> SyncIntent { SyncIntent(kind: .contentIndex, key: contentKey(fingerprint, generation: generation), operation: operation) }
    public static func gameContent(_ fingerprint: ContentFingerprint, operation: Operation = .upsert, generation: Int64 = 0) -> SyncIntent { SyncIntent(kind: .gameContent, key: contentKey(fingerprint, generation: generation), operation: operation) }
    /// One pending intent per game membership: a reset is another value of the same register.
    public static func artwork(_ fingerprint: ContentFingerprint, generation: Int64 = 0) -> SyncIntent { SyncIntent(kind: .artwork, key: contentKey(fingerprint, generation: generation)) }

    private static func contentKey(_ fingerprint: ContentFingerprint, generation: Int64) -> String {
        generation == 0 ? fingerprint.canonicalString : "\(fingerprint.canonicalString)@\(generation)"
    }

    /// Initial journal keys remain byte-for-byte compatible with the old outbox.
    public static func contentMembership(parsing key: String) throws -> GameMembership {
        let parts = key.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let generation = parts.count == 2 ? Int64(parts[1]) : 0,
              (0...GameMembership.maximumGeneration).contains(generation) else {
            throw LibraryError.invalidRelationship("invalid journal membership")
        }
        return GameMembership(fingerprint: try ContentFingerprint(parsing: String(parts[0])), generation: generation)
    }

}

public struct SyncJournalEntry: Hashable, Sendable, Identifiable {
    /// Monotonic sequence number (the send order).
    public let id: Int64
    public let intent: SyncIntent
    public let createdAt: Date
    public let attempts: Int
    public let lastError: String?

    public init(id: Int64, intent: SyncIntent, createdAt: Date, attempts: Int = 0, lastError: String? = nil) {
        self.id = id
        self.intent = intent
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
    }
}

/// One bounded journal scan. The ceiling remains fixed for an entire sweep;
/// newly enqueued/coalesced intents are visited during the next sweep.
public struct SyncJournalPage: Sendable {
    public let entries: [SyncJournalEntry]
    public let throughSequence: Int64
    public let hasMore: Bool

    public init(entries: [SyncJournalEntry], throughSequence: Int64, hasMore: Bool) {
        self.entries = entries
        self.throughSequence = throughSequence
        self.hasMore = hasMore
    }
}

/// The outbox. Entries are added by repository transactions (and by
/// `enqueue` for explicit reconciliation) and removed once the server
/// acknowledged them.
public protocol SyncJournal: Sendable {
    /// Oldest pending entries first, leaving out `excluding` kinds (which stay pending
    /// and never hold back later entries).
    func pending(limit: Int, excluding: Set<SyncIntent.Kind>) async throws -> [SyncJournalEntry]
    /// Scans `(afterSequence, throughSequence]` in sequence order. A nil ceiling
    /// captures the current tail in the same read snapshot, floored at the
    /// supplied cursor for an exhausted/restored journal. Limit is 1...1000.
    /// This is scheduling progress, never acknowledgement of journal entries.
    func pending(afterSequence: Int64, throughSequence: Int64?, limit: Int, excluding: Set<SyncIntent.Kind>) async throws -> SyncJournalPage
    /// Pending progress: every entry except cosmetic `artwork`.
    func pendingCount() async throws -> Int
    /// Confirms which exact journal receipts still exist. Failures must throw:
    /// an empty result permits a transport to discard acknowledged receipts.
    func pendingIDs(in ids: [Int64]) async throws -> Set<Int64>
    /// Adds intents (coalescing with existing pending ones by kind/key/operation).
    func enqueue(_ intents: [SyncIntent]) async throws
    /// Removes acknowledged entries.
    func complete(_ ids: [Int64]) async throws
    /// Keeps entries pending, counting the attempt and recording the reason.
    func fail(_ ids: [Int64], reason: String) async throws
    /// Drops every pending entry (account change: never upload old intents into a new account).
    func clear() async throws
}

public extension SyncJournal {
    func pending(limit: Int) async throws -> [SyncJournalEntry] {
        try await pending(limit: limit, excluding: [])
    }

    func pending(afterSequence: Int64, throughSequence: Int64?, limit: Int) async throws -> SyncJournalPage {
        try await pending(afterSequence: afterSequence, throughSequence: throughSequence, limit: limit, excluding: [])
    }

    func pending(afterSequence: Int64, throughSequence: Int64?, limit: Int, excluding: Set<SyncIntent.Kind>) async throws -> SyncJournalPage {
        throw LibraryError.invalidRelationship("journal pagination unavailable")
    }

    func pendingIDs(in ids: [Int64]) async throws -> Set<Int64> {
        throw LibraryError.invalidRelationship("sync journal does not support receipt confirmation")
    }
}

/// A remote record that could not be applied yet (its game entry or a
/// battery parent has not arrived). Stored verbatim and retried after every
/// successful apply. `payload` is the portable record encoded by the sync layer.
public struct DeferredRemoteRecord: Hashable, Sendable, Identifiable {
    /// `<kind>:<key>`.
    public var id: String { key }
    public let key: String
    public let kind: String
    public let payload: Data
    public let reason: String
    public let receivedAt: Date

    public init(key: String, kind: String, payload: Data, reason: String, receivedAt: Date) {
        self.key = key
        self.kind = kind
        self.payload = payload
        self.reason = reason
        self.receivedAt = receivedAt
    }
}

/// A remote game entry to merge into the local library (last-write-wins on
/// `updatedAt`; `addedAt` keeps the earliest value seen).
public struct RemoteGameEntry: Hashable, Sendable {
    public let fingerprint: ContentFingerprint
    public let generation: Int64
    public let systemID: SystemID
    public let title: String
    public let isFavorite: Bool
    public let addedAt: Date
    public let updatedAt: Date
    public let contentSize: Int64?
    /// The `GameID` to use when the fingerprint is not in the library yet (minted by the applier).
    public let proposedID: GameID

    public init(fingerprint: ContentFingerprint, systemID: SystemID, title: String, isFavorite: Bool, addedAt: Date, updatedAt: Date,
                contentSize: Int64?, proposedID: GameID = GameID(), generation: Int64 = 0) {
        self.fingerprint = fingerprint
        self.generation = generation
        self.systemID = systemID
        self.title = title
        self.isFavorite = isFavorite
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.contentSize = contentSize
        self.proposedID = proposedID
    }
}

/// Everything one remote batch changes locally, applied in one transaction.
/// Files referenced by rows (revision files, state containers, screenshots)
/// are installed by the sync layer *before* the batch is applied; the store
/// reports what it deleted so files can be removed *after* the commit.
public struct SyncCheckpoint: Sendable {
    public let key: String
    public let sequence: Int64

    public init(key: String, sequence: Int64) {
        self.key = key
        self.sequence = sequence
    }
}

/// A custom-cover value from another device and the membership generation it belongs to.
public struct RemoteCustomCover: Hashable, Sendable {
    public let cover: CustomCover
    public let generation: Int64

    public init(cover: CustomCover, generation: Int64) {
        self.cover = cover
        self.generation = generation
    }
}

public struct RemoteApplyBatch: Sendable {
    /// Provider/account namespace for remote descriptors and deferred envelopes.
    public var remoteScope: String = "cloudkit"
    /// A transport cursor advances in the same transaction as its records and
    /// durable deferred envelopes. A failed apply must never acknowledge a page.
    public var checkpoint: SyncCheckpoint?
    public var gameEntries: [RemoteGameEntry] = []
    public var sessions: [PlaySession] = []
    public var revisions: [BatteryRevision] = []
    public var states: [SaveState] = []
    public var tombstones: [DeletionTombstone] = []
    public var contentDescriptors: [GameContentDescriptor] = []
    /// Record deletions received (retention of auto/quick states by their owner).
    public var deletedStateIDs: [SaveStateID] = []
    /// Legacy deletions identify initial generation only.
    public var deletedContentFingerprints: [ContentFingerprint] = []
    public var deletedContentMemberships: [GameMembership] = []
    /// Custom-cover values from other devices; each replaces the local value only
    /// when it orders later (checked again inside the transaction). Never journalled.
    public var customCovers: [RemoteCustomCover] = []
    public var deferred: [DeferredRemoteRecord] = []
    /// Keys (`<kind>:<key>`) of deferred records that this batch resolves.
    public var resolvedDeferredKeys: [String] = []

    public init() {}

    public var isEmpty: Bool {
        gameEntries.isEmpty && sessions.isEmpty && revisions.isEmpty && states.isEmpty && tombstones.isEmpty
            && contentDescriptors.isEmpty && deletedStateIDs.isEmpty && deletedContentFingerprints.isEmpty
            && deletedContentMemberships.isEmpty && customCovers.isEmpty && deferred.isEmpty && resolvedDeferredKeys.isEmpty
            && checkpoint == nil
    }
}

public struct RemoteApplyOutcome: Sendable, Equatable {
    /// Games created by this batch (no files; cloud-only or on another device).
    public var createdGameIDs: [GameID] = []
    /// Games deleted by tombstones (rows are gone; the caller removes files).
    public var deletedGameIDs: [GameID] = []
    /// States deleted by tombstones or record deletions (rows gone; caller removes files).
    public var deletedStates: [SaveState] = []
    /// Revisions and states skipped because they already existed (idempotent delivery).
    public var skippedExisting: Int = 0
    /// Valid historical records suppressed by a durable retirement barrier.
    public var skippedRetired: Int = 0
    /// Games whose battery graph changed (revisions added) and need head reconciliation.
    public var gamesNeedingReconciliation: [GameID] = []

    public init() {}
}

/// The persistence side of synchronization.
public protocol SyncStore: Sendable {
    var journal: any SyncJournal { get }
    /// This installation's identity (minted on first access, stable afterwards).
    func identity() async throws -> SyncIdentity
    /// Small durable key/value state of the sync layer (account identity hash, enablement, timestamps).
    func metaValue(forKey key: String) async throws -> String?
    func setMetaValue(_ value: String?, forKey key: String) async throws
    /// Applies a remote batch atomically. Throws `LibraryError.duplicateContent` when a
    /// proposed new game's fingerprint appeared concurrently (the caller retries).
    func applyRemote(_ batch: RemoteApplyBatch) async throws -> RemoteApplyOutcome
    func deferredRecords() async throws -> [DeferredRemoteRecord]
    func removeDeferredRecords(keys: [String]) async throws
    func tombstones() async throws -> [DeletionTombstone]
    func tombstone(for target: DeletionTombstone.Target) async throws -> DeletionTombstone?
    func tombstone(for target: DeletionTombstone.Target, generation: Int64) async throws -> DeletionTombstone?
    /// Highest permanently retired generation; nil means no retirement is known.
    func retiredGeneration(for fingerprint: ContentFingerprint) async throws -> Int64?
    /// Records a local deletion tombstone and its intent (used when a game or state is deleted locally).
    func recordTombstone(_ tombstone: DeletionTombstone) async throws
    func contentDescriptors() async throws -> [GameContentDescriptor]
    func contentDescriptor(for fingerprint: ContentFingerprint) async throws -> GameContentDescriptor?
    /// Records that this device uploaded content (index) and its intent.
    func recordContentDescriptor(_ descriptor: GameContentDescriptor) async throws
    func removeContentDescriptor(for fingerprint: ContentFingerprint, recordIntent: Bool) async throws
    func removeContentDescriptor(for fingerprint: ContentFingerprint, generation: Int64, recordIntent: Bool) async throws
    func removeContentDescriptor(for fingerprint: ContentFingerprint, generation: Int64, recordIntent: Bool, remoteScope: String) async throws
    /// Scoped variants isolate provider/account remote state. Production stores must
    /// persist these namespaces atomically with remote batches.
    func deferredRecords(remoteScope: String) async throws -> [DeferredRemoteRecord]
    func removeDeferredRecords(keys: [String], remoteScope: String) async throws
    func contentDescriptors(remoteScope: String) async throws -> [GameContentDescriptor]
    func contentDescriptor(for fingerprint: ContentFingerprint, remoteScope: String) async throws -> GameContentDescriptor?
    func recordContentDescriptor(_ descriptor: GameContentDescriptor, remoteScope: String) async throws
    func removeContentDescriptor(for fingerprint: ContentFingerprint, recordIntent: Bool, remoteScope: String) async throws
    func enqueueEverything(remoteScope: String) async throws
    /// Includes received canonical history when bridging the library into another remote.
    func enqueueEverything(remoteScope: String, includeRemoteHistory: Bool) async throws
    /// Journals every local synchronized object (first enablement, account change accepted, zone re-created).
    func enqueueEverything() async throws
}

// Existing single-remote implementations remain compatible with CloudKit.
// Other namespaces require explicit support to prevent accidental account leakage.
public extension SyncStore {
    func retiredGeneration(for fingerprint: ContentFingerprint) async throws -> Int64? { nil }

    func tombstone(for target: DeletionTombstone.Target, generation: Int64) async throws -> DeletionTombstone? {
        guard generation == 0 else { throw LibraryError.invalidRelationship("generation-aware tombstones unavailable") }
        return try await tombstone(for: target)
    }

    func removeContentDescriptor(for fingerprint: ContentFingerprint, generation: Int64, recordIntent: Bool) async throws {
        guard generation == 0 else { throw LibraryError.invalidRelationship("generation-aware content unavailable") }
        try await removeContentDescriptor(for: fingerprint, recordIntent: recordIntent)
    }

    func removeContentDescriptor(for fingerprint: ContentFingerprint, generation: Int64, recordIntent: Bool, remoteScope: String) async throws {
        guard generation == 0 else { throw LibraryError.invalidRelationship("generation-aware content unavailable") }
        try await removeContentDescriptor(for: fingerprint, recordIntent: recordIntent, remoteScope: remoteScope)
    }

    private func requireLegacyScope(_ remoteScope: String) throws {
        guard remoteScope == "cloudkit" else {
            throw LibraryError.invalidRelationship("sync store does not support remote namespaces")
        }
    }

    func deferredRecords(remoteScope: String) async throws -> [DeferredRemoteRecord] {
        try requireLegacyScope(remoteScope)
        return try await deferredRecords()
    }
    func removeDeferredRecords(keys: [String], remoteScope: String) async throws {
        try requireLegacyScope(remoteScope)
        try await removeDeferredRecords(keys: keys)
    }
    func contentDescriptors(remoteScope: String) async throws -> [GameContentDescriptor] {
        try requireLegacyScope(remoteScope)
        return try await contentDescriptors()
    }
    func contentDescriptor(for fingerprint: ContentFingerprint, remoteScope: String) async throws -> GameContentDescriptor? {
        try requireLegacyScope(remoteScope)
        return try await contentDescriptor(for: fingerprint)
    }
    func recordContentDescriptor(_ descriptor: GameContentDescriptor, remoteScope: String) async throws {
        try requireLegacyScope(remoteScope)
        try await recordContentDescriptor(descriptor)
    }
    func removeContentDescriptor(for fingerprint: ContentFingerprint, recordIntent: Bool, remoteScope: String) async throws {
        try requireLegacyScope(remoteScope)
        try await removeContentDescriptor(for: fingerprint, recordIntent: recordIntent)
    }
    func enqueueEverything(remoteScope: String, includeRemoteHistory: Bool) async throws {
        guard !includeRemoteHistory else {
            throw LibraryError.invalidRelationship("sync store does not support remote history reconciliation")
        }
        try await enqueueEverything(remoteScope: remoteScope)
    }
    func enqueueEverything(remoteScope: String) async throws {
        try requireLegacyScope(remoteScope)
        try await enqueueEverything()
    }
}

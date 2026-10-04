// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import RelayDomain
import RelayLibrary

/// Canonical games/saves/tombstones are shared. Remote availability and deferred pages are not.
struct ScopedSyncStore: SyncStore {
    let base: any SyncStore
    let scope: String

    var journal: any SyncJournal { base.journal }
    func identity() async throws -> SyncIdentity { try await base.identity() }
    func metaValue(forKey key: String) async throws -> String? { try await base.metaValue(forKey: key) }
    func setMetaValue(_ value: String?, forKey key: String) async throws { try await base.setMetaValue(value, forKey: key) }
    func applyRemote(_ batch: RemoteApplyBatch) async throws -> RemoteApplyOutcome {
        var batch = batch
        batch.remoteScope = scope
        return try await base.applyRemote(batch)
    }
    func deferredRecords() async throws -> [DeferredRemoteRecord] { try await base.deferredRecords(remoteScope: scope) }
    func removeDeferredRecords(keys: [String]) async throws { try await base.removeDeferredRecords(keys: keys, remoteScope: scope) }
    func tombstones() async throws -> [DeletionTombstone] { try await base.tombstones() }
    func tombstone(for target: DeletionTombstone.Target) async throws -> DeletionTombstone? { try await base.tombstone(for: target) }
    func retiredGeneration(for fingerprint: ContentFingerprint) async throws -> Int64? { try await base.retiredGeneration(for: fingerprint) }
    func tombstone(for target: DeletionTombstone.Target, generation: Int64) async throws -> DeletionTombstone? { try await base.tombstone(for: target, generation: generation) }
    func recordTombstone(_ tombstone: DeletionTombstone) async throws { try await base.recordTombstone(tombstone) }
    func contentDescriptors() async throws -> [GameContentDescriptor] { try await base.contentDescriptors(remoteScope: scope) }
    func contentDescriptor(for fingerprint: ContentFingerprint) async throws -> GameContentDescriptor? {
        try await base.contentDescriptor(for: fingerprint, remoteScope: scope)
    }
    func recordContentDescriptor(_ descriptor: GameContentDescriptor) async throws { try await base.recordContentDescriptor(descriptor, remoteScope: scope) }
    func removeContentDescriptor(for fingerprint: ContentFingerprint, recordIntent: Bool) async throws {
        try await base.removeContentDescriptor(for: fingerprint, recordIntent: recordIntent, remoteScope: scope)
    }
    func removeContentDescriptor(for fingerprint: ContentFingerprint, generation: Int64, recordIntent: Bool) async throws {
        try await base.removeContentDescriptor(for: fingerprint, generation: generation, recordIntent: recordIntent, remoteScope: scope)
    }
    func enqueueEverything() async throws { try await base.enqueueEverything(remoteScope: scope, includeRemoteHistory: true) }
}

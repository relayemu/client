// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  OutboundBuilder.swift
//  RelaySync
//
//  Turns pending journal intents into outbound changes built from the
//  canonical rows at send time. An intent whose object no longer exists
//  (deleted meanwhile) completes silently; nothing is ever sent from memory.

import Foundation
import RelayDomain
import RelayLibrary

struct OutboundBuilder: Sendable {
    let store: any LibraryStore
    let syncStore: any SyncStore
    let location: LibraryLocation
    let identity: SyncIdentity

    struct Built {
        var changes: [OutboundChange] = []
        /// Intents that have nothing to send any more (object gone).
        var completed: [Int64] = []
        /// Which game each change concerns (for per-game pending status).
        var gameByKey: [RecordKey: ContentFingerprint] = [:]
    }

    func build(from entries: [SyncJournalEntry]) async -> Built {
        var built = Built()
        for entry in entries {
            do {
                if let change = try await change(for: entry) {
                    built.changes.append(change)
                    if case .save(let record, _) = change.payload, let fp = record.gameFingerprint { built.gameByKey[change.key] = fp }
                } else {
                    built.completed.append(entry.id)
                }
            } catch {
                // A row that cannot be read is reported as failed; the journal keeps it.
                syncLog.error("outbound build failed for \(entry.intent.kind.rawValue, privacy: .public) \(entry.intent.key, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return built
    }

    private func change(for entry: SyncJournalEntry) async throws -> OutboundChange? {
        let intent = entry.intent
        switch (intent.kind, intent.operation) {
        case (.gameEntry, .upsert):
            let membership = try SyncIntent.contentMembership(parsing: intent.key)
            let fingerprint = membership.fingerprint
            guard let game = try await store.games.game(fingerprint: fingerprint), game.generation == membership.generation else { return nil }
            let files = try await store.games.files(for: game.id)
            let record = SyncGameEntry(fingerprint: fingerprint, systemID: game.systemID.rawValue, title: game.title, isFavorite: game.isFavorite,
                                       addedAt: SyncTime.millis(game.addedAt), updatedAt: SyncTime.millis(game.updatedAt),
                                       contentSize: files.first(where: { $0.role == .primary })?.sizeInBytes, generation: game.generation)
            return OutboundChange(journalIDs: [entry.id], key: .game(fingerprint, generation: game.generation), payload: .save(.game(record), assets: [:]))

        case (.playSession, .upsert):
            guard let id = PlaySessionID(intent.key), let session = try await store.playHistory.session(id: id),
                  let game = try await store.games.game(id: session.gameID), game.generation == session.generation else { return nil }
            var assets: [SyncAssetName: URL] = [:]
            if let shot = session.screenshotLocation, FileManager.default.fileExists(atPath: location.url(for: shot).path) {
                assets[.screenshot] = location.url(for: shot)
            }
            let record = SyncSession(sessionID: session.id, fingerprint: game.contentFingerprint,
                                     installationID: session.installationID ?? identity.installationID,
                                     deviceKind: (session.deviceKind == .unknown ? identity.deviceKind : session.deviceKind).rawValue,
                                     coreID: session.coreID.rawValue, startedAt: SyncTime.millis(session.startedAt),
                                     endedAt: session.endedAt.map(SyncTime.millis), pausedMs: Int64((session.pausedDuration * 1000).rounded()),
                                     hasScreenshot: assets[.screenshot] != nil, generation: game.generation)
            return OutboundChange(journalIDs: [entry.id], key: .session(id, generation: game.generation), payload: .save(.session(record), assets: assets))

        case (.batteryRevision, .upsert):
            guard let id = BatteryRevisionID(intent.key), let revision = try await store.saves.batteryRevision(id: id),
                  let game = try await store.games.game(id: revision.gameID), game.generation == revision.generation else { return nil }
            let dataURL = location.url(for: revision.location)
            guard FileManager.default.fileExists(atPath: dataURL.path) else { return nil }
            var assets: [SyncAssetName: URL] = [.data: dataURL]
            if let shot = revision.screenshotLocation, FileManager.default.fileExists(atPath: location.url(for: shot).path) {
                assets[.screenshot] = location.url(for: shot)
            }
            let record = SyncBatteryRevision(revisionID: revision.id, fingerprint: game.contentFingerprint, parentIDs: revision.parentIDs,
                                             createdAt: SyncTime.millis(revision.createdAt), dataFingerprint: revision.dataFingerprint,
                                             dataSize: revision.sizeInBytes, installationID: revision.installationID,
                                             deviceKind: revision.deviceKind.rawValue, hasScreenshot: assets[.screenshot] != nil, generation: game.generation)
            return OutboundChange(journalIDs: [entry.id], key: .batteryRevision(id, generation: game.generation), payload: .save(.batteryRevision(record), assets: assets))

        case (.saveState, .upsert):
            guard let id = SaveStateID(intent.key), let state = try await store.saves.saveState(id: id),
                  let game = try await store.games.game(id: state.gameID), game.generation == state.generation else { return nil }
            let containerURL = location.url(for: state.location)
            guard FileManager.default.fileExists(atPath: containerURL.path) else { return nil }
            let header = try SaveStateContainer.readHeader(at: containerURL)
            var assets: [SyncAssetName: URL] = [.payload: containerURL]
            if let shot = state.screenshotLocation, FileManager.default.fileExists(atPath: location.url(for: shot).path) {
                assets[.screenshot] = location.url(for: shot)
            }
            let record = SyncSaveState(stateID: state.id, fingerprint: game.contentFingerprint, kind: state.kind.rawValue,
                                       coreID: state.coreID.rawValue, coreVersion: state.coreVersion,
                                       stateCompatibilityVersion: state.stateCompatibilityVersion, formatVersion: state.formatVersion,
                                       createdAt: SyncTime.millis(state.createdAt), payloadFingerprint: header.payloadFingerprint,
                                       payloadSize: Int64(header.payloadLength), batteryRevisionID: state.batteryRevisionID,
                                       installationID: state.installationID ?? identity.installationID,
                                       deviceKind: (state.deviceKind == .unknown ? identity.deviceKind : state.deviceKind).rawValue,
                                       label: state.label, hasScreenshot: assets[.screenshot] != nil, generation: game.generation)
            return OutboundChange(journalIDs: [entry.id], key: .state(id, generation: game.generation), payload: .save(.state(record), assets: assets))

        case (.saveState, .delete):
            guard let id = SaveStateID(intent.key) else { return nil }
            return OutboundChange(journalIDs: [entry.id], key: .state(id), payload: .delete)

        case (.tombstone, .upsert):
            guard let target = Self.tombstoneTarget(intent.key), let tombstone = try await syncStore.tombstone(for: target, generation: Self.tombstoneGeneration(intent.key)) else { return nil }
            return OutboundChange(journalIDs: [entry.id], key: .tombstone(target, generation: tombstone.generation), payload: .save(.tombstone(SyncTombstone(tombstone)), assets: [:]))

        case (.contentIndex, .upsert):
            let membership = try SyncIntent.contentMembership(parsing: intent.key)
            let fingerprint = membership.fingerprint
            guard let descriptor = try await syncStore.contentDescriptor(for: fingerprint), descriptor.generation == membership.generation else { return nil }
            let record = SyncContentIndex(fingerprint: fingerprint, size: descriptor.sizeInBytes, fileName: descriptor.fileName,
                                          systemID: descriptor.systemID.rawValue, partCount: descriptor.parts.count,
                                          uploadedAt: SyncTime.millis(descriptor.uploadedAt), installationID: identity.installationID, generation: descriptor.generation)
            return OutboundChange(journalIDs: [entry.id], key: .contentIndex(fingerprint, generation: membership.generation), payload: .save(.contentIndex(record), assets: [:]))

        case (.contentIndex, .delete):
            let membership = try SyncIntent.contentMembership(parsing: intent.key)
            let fingerprint = membership.fingerprint
            return OutboundChange(journalIDs: [entry.id], key: .contentIndex(fingerprint, generation: membership.generation), payload: .delete)

        case (.gameContent, .delete):
            let membership = try SyncIntent.contentMembership(parsing: intent.key)
            let fingerprint = membership.fingerprint
            return OutboundChange(journalIDs: [entry.id], key: .gameContent(fingerprint, part: 0, generation: membership.generation), payload: .delete)

        case (.artwork, .upsert):
            // The register's current value, read at send time; a reset carries no asset.
            let membership = try SyncIntent.contentMembership(parsing: intent.key)
            guard let game = try await store.games.game(fingerprint: membership.fingerprint), game.generation == membership.generation,
                  let cover = try await store.games.customCover(for: game.id) else { return nil }
            var assets: [SyncAssetName: URL] = [:]
            if let chosen = cover.fingerprint {
                let file = location.url(for: try LibraryLocation.customCoverLocation(gameID: game.id, fingerprint: chosen))
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                assets[.data] = file
            }
            let record = SyncArtwork(fingerprint: game.contentFingerprint, artworkFingerprint: cover.fingerprint,
                                     artworkSize: cover.fingerprint == nil ? nil : cover.sizeInBytes, updatedAt: SyncTime.millis(cover.updatedAt),
                                     installationID: identity.installationID, generation: game.generation)
            return OutboundChange(journalIDs: [entry.id], key: .artwork(game.contentFingerprint, generation: game.generation),
                                  payload: .save(.artwork(record), assets: assets))

        case (.gameContent, .upsert), (.gameEntry, .delete), (.playSession, .delete), (.batteryRevision, .delete), (.tombstone, .delete),
             (.artwork, .delete):
            // Content uploads go through ContentManager directly; the others never happen.
            return nil
        }
    }

    private static func tombstoneGeneration(_ key: String) -> Int64 {
        guard key.hasPrefix("game:"), let membership = try? SyncIntent.contentMembership(parsing: String(key.dropFirst(5))) else { return 0 }
        return membership.generation
    }

    static func tombstoneTarget(_ key: String) -> DeletionTombstone.Target? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let kind = String(key[..<colon])
        let value = String(key[key.index(after: colon)...])
        switch kind {
        case "game": return (try? SyncIntent.contentMembership(parsing: value)).map { .game($0.fingerprint) }
        case "state": return SaveStateID(value).map { .saveState($0) }
        default: return nil
        }
    }
}

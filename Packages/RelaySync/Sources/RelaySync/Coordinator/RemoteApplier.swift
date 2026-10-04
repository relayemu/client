// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RemoteApplier.swift
//  RelaySync
//
//  Validates inbound records, stages and verifies their assets in
//  Relay-owned storage, installs files under immutable Relay paths, and
//  builds the one transactional batch the store applies. Records whose
//  prerequisites are missing are deferred (with their staged assets) and
//  retried later. Nothing here trusts a remote value that was not checked.

import Foundation
import RelayDomain
import RelayLibrary

/// A deferred record and where its staged assets live (relative to the sync inbox).
struct DeferredEnvelope: Codable, Sendable {
    var record: SyncRecord
    var assets: [SyncAssetName: String]
}

struct RemoteApplier: Sendable {
    let store: any LibraryStore
    let syncStore: any SyncStore
    let location: LibraryLocation
    let saveStates: SaveStateManager
    let identity: SyncIdentity
    let validator = SyncRecordValidator()
    let hasher = SHA256ContentHasher()

    struct Prepared {
        var batch = RemoteApplyBatch()
        /// Files installed for this batch (removed if the commit fails).
        var installedFiles: [URL] = []
        /// Diagnostics: how many inbound records were rejected and why.
        var rejected: [(RecordKey, String)] = []
        var deferredCount = 0
        /// Games (by fingerprint) touched by this batch, for status refresh.
        var touched: Set<ContentFingerprint> = []
        /// Games whose custom cover may have changed: superseded files are removed after the commit.
        var coverGames: Set<GameID> = []
    }

    /// Stages and validates every change; returns what to apply.
    func prepare(changes: [InboundChange], deletions: [RecordKey], now: Date, retryingDeferred: Bool = false) async throws -> Prepared {
        var prepared = Prepared()
        var validated: [(InboundChange, SyncRecord)] = []
        for change in changes {
            do {
                let record = try validator.validate(change.record)
                guard change.key == record.key else { throw SyncValidationError.invalidField("record key") }
                validated.append((change, record))
            } catch {
                prepared.rejected.append((change.key, String(describing: error)))
            }
        }

        // Retirement is a permanent high-water mark. Collect the whole page first,
        // so tombstone ordering cannot expose assets from a retired membership.
        var barriers: [ContentFingerprint: Int64] = [:]
        for (_, record) in validated {
            if let fp = record.gameFingerprint, barriers[fp] == nil {
                barriers[fp] = try await syncStore.retiredGeneration(for: fp) ?? -1
            }
        }
        var deletedStates = Set<SaveStateID>()
        for (_, record) in validated {
            guard case .tombstone(let t) = record, let target = t.target else { continue }
            prepared.batch.tombstones.append(DeletionTombstone(target: target, deletedAt: SyncTime.date(t.deletedAt), installationID: t.installationID, generation: t.generation, gameFingerprint: t.gameFingerprint))
            if case .game(let fp) = target {
                barriers[fp] = max(barriers[fp] ?? -1, t.generation)
                prepared.touched.insert(fp)
            } else if case .saveState(let id) = target { deletedStates.insert(id) }
        }
        let declaredRevisions = validated.compactMap { if case .batteryRevision(let revision) = $0.1 { revision } else { nil } }
        var eligible: [(InboundChange, SyncRecord)] = []
        for (change, record) in validated {
            if case .tombstone = record { continue }
            if let fp = record.gameFingerprint {
                let retired = barriers[fp] ?? -1
                if record.generation <= retired { continue }
                if record.generation != retired + 1 {
                    try deferRecord(change, record, reason: "future generation", into: &prepared, now: now, reuseAssets: retryingDeferred)
                    continue
                }
            }
            eligible.append((change, record))
        }
        validated = eligible

        var games: [ContentFingerprint: Game] = [:]
        var classificationConflicts = Set<ContentFingerprint>()
        func resolveGame(_ fingerprint: ContentFingerprint, generation: Int64) async throws -> Game? {
            if classificationConflicts.contains(fingerprint) { return nil }
            if let g = games[fingerprint], g.generation == generation { return g }
            if let g = try await store.games.game(fingerprint: fingerprint), g.generation == generation {
                games[fingerprint] = g
                return g
            }
            return nil
        }

        // Membership entries precede history regardless of server page ordering.
        for (change, record) in validated {
            guard case .game(let entry) = record else { continue }
            let existing = try await resolveGame(entry.fingerprint, generation: entry.generation)
            if let existing, existing.systemID.rawValue != entry.systemID {
                prepared.rejected.append((change.key, "established systemID differs"))
                classificationConflicts.insert(entry.fingerprint)
                continue
            }
            let proposed = existing?.id ?? GameID()
            if existing == nil {
                games[entry.fingerprint] = Game(id: proposed, systemID: SystemID(rawValue: entry.systemID), title: entry.title,
                                                contentFingerprint: entry.fingerprint, addedAt: SyncTime.date(entry.addedAt),
                                                isFavorite: entry.isFavorite, updatedAt: SyncTime.date(entry.updatedAt), generation: entry.generation)
            }
            prepared.batch.gameEntries.append(RemoteGameEntry(fingerprint: entry.fingerprint, systemID: SystemID(rawValue: entry.systemID),
                                                              title: entry.title, isFavorite: entry.isFavorite,
                                                              addedAt: SyncTime.date(entry.addedAt), updatedAt: SyncTime.date(entry.updatedAt),
                                                              contentSize: entry.contentSize, proposedID: proposed, generation: entry.generation))
            prepared.touched.insert(entry.fingerprint)
        }
        for (change, record) in validated {
            guard case .contentIndex(let index) = record else { continue }
            guard let game = try await resolveGame(index.fingerprint, generation: index.generation) else {
                try deferRecord(change, record, reason: "unknown game generation", into: &prepared, now: now, reuseAssets: retryingDeferred)
                continue
            }
            guard game.systemID.rawValue == index.systemID else {
                prepared.rejected.append((change.key, "established systemID differs")); continue
            }
            let parts = [GameContentDescriptor.Part(index: 0, fingerprint: index.fingerprint, sizeInBytes: index.size)]
            prepared.batch.contentDescriptors.append(GameContentDescriptor(fingerprint: index.fingerprint, sizeInBytes: index.size, fileName: index.fileName,
                                                                           systemID: SystemID(rawValue: index.systemID), parts: parts,
                                                                           uploadedAt: SyncTime.date(index.uploadedAt), generation: index.generation))
            prepared.touched.insert(index.fingerprint)
        }

        // 2. Objects that need a game and, for revisions, their parents.
        let incomingRevisions = Dictionary(grouping: validated.compactMap { if case .batteryRevision(let revision) = $0.1 { revision } else { nil } }, by: \.revisionID)
        let declaredByID = Dictionary(grouping: declaredRevisions, by: \.revisionID)
        func revisionMembership(_ id: BatteryRevisionID, game: Game) async throws -> Bool? {
            if let candidates = incomingRevisions[id] {
                return candidates.allSatisfy { $0.fingerprint == game.contentFingerprint && $0.generation == game.generation }
            }
            if let revision = try await store.saves.batteryRevision(id: id) {
                return revision.gameID == game.id && revision.generation == game.generation
            }
            // A retired legacy copy must not shadow an eligible migrated copy.
            // Without a current copy, a declared cross-generation edge is invalid.
            if let candidates = declaredByID[id] {
                return candidates.allSatisfy { $0.fingerprint == game.contentFingerprint && $0.generation == game.generation }
            }
            return nil
        }
        for (change, record) in validated {
            switch record {
            case .session(let s):
                guard let game = try await resolveGame(s.fingerprint, generation: s.generation) else { try deferRecord(change, record, reason: "unknown game", into: &prepared, now: now, reuseAssets: retryingDeferred); continue }
                if let existing = try await store.playHistory.session(id: s.sessionID),
                   existing.gameID != game.id || existing.generation != s.generation || existing.installationID != s.installationID || existing.coreID.rawValue != s.coreID {
                    prepared.rejected.append((change.key, "session immutable membership differs")); continue
                }
                var screenshot: ContentLocation?
                if s.hasScreenshot, let url = change.assets[.screenshot] {
                    let loc = try LibraryLocation.remoteSessionScreenshotLocation(gameID: game.id, sessionID: s.sessionID)
                    try install(asset: url, to: loc, maxSize: SyncLimits.maxScreenshotSize, expectedFingerprint: nil, into: &prepared)
                    screenshot = loc
                }
                prepared.batch.sessions.append(PlaySession(id: s.sessionID, gameID: game.id, coreID: CoreID(rawValue: s.coreID),
                                                           startedAt: SyncTime.date(s.startedAt), endedAt: s.endedAt.map(SyncTime.date),
                                                           screenshotLocation: screenshot, pausedDuration: Double(s.pausedMs) / 1000,
                                                           installationID: s.installationID, deviceKind: DeviceKind(lenient: s.deviceKind), origin: .remote, generation: s.generation))
                prepared.touched.insert(s.fingerprint)

            case .batteryRevision(let r):
                guard let game = try await resolveGame(r.fingerprint, generation: r.generation) else { try deferRecord(change, record, reason: "unknown game", into: &prepared, now: now, reuseAssets: retryingDeferred); continue }
                if let existing = try await store.saves.batteryRevision(id: r.revisionID) {
                    if existing.gameID != game.id || existing.generation != r.generation || existing.dataFingerprint != r.dataFingerprint || existing.parentIDs != r.parentIDs || existing.installationID != r.installationID { prepared.rejected.append((change.key, "revision bytes differ from the local copy")) }
                    continue
                }
                // Parents must be known (locally or in this batch) for the revision to count; otherwise store it deferred.
                var missingParent = false
                var invalidParent = false
                for parent in r.parentIDs {
                    if let matches = try await revisionMembership(parent, game: game) { invalidParent = invalidParent || !matches }
                    else { missingParent = true }
                }
                if invalidParent { prepared.rejected.append((change.key, "parent belongs to another game generation")); continue }
                if missingParent { try deferRecord(change, record, reason: "missing parent", into: &prepared, now: now, reuseAssets: retryingDeferred); continue }
                guard let dataURL = change.assets[.data] else { prepared.rejected.append((change.key, "missing data asset")); continue }
                let dataLocation = try LibraryLocation.batteryRevisionLocation(gameID: game.id, revisionID: r.revisionID)
                do {
                    try install(asset: dataURL, to: dataLocation, maxSize: SyncLimits.maxBatterySize, expectedFingerprint: r.dataFingerprint, expectedSize: r.dataSize, into: &prepared)
                } catch {
                    prepared.rejected.append((change.key, "data asset rejected: \(error)")); continue
                }
                var screenshot: ContentLocation?
                if r.hasScreenshot, let url = change.assets[.screenshot] {
                    let loc = try LibraryLocation.batteryRevisionScreenshotLocation(gameID: game.id, revisionID: r.revisionID)
                    try? install(asset: url, to: loc, maxSize: SyncLimits.maxScreenshotSize, expectedFingerprint: nil, into: &prepared)
                    screenshot = FileManager.default.fileExists(atPath: location.url(for: loc).path) ? loc : nil
                }
                prepared.batch.revisions.append(BatteryRevision(id: r.revisionID, gameID: game.id, parentIDs: r.parentIDs, createdAt: SyncTime.date(r.createdAt),
                                                                dataFingerprint: r.dataFingerprint, sizeInBytes: r.dataSize, installationID: r.installationID,
                                                                deviceKind: DeviceKind(lenient: r.deviceKind), location: dataLocation, screenshotLocation: screenshot, origin: .remote, generation: r.generation))
                prepared.touched.insert(r.fingerprint)

            case .state(let s):
                guard let game = try await resolveGame(s.fingerprint, generation: s.generation) else { try deferRecord(change, record, reason: "unknown game", into: &prepared, now: now, reuseAssets: retryingDeferred); continue }
                if deletedStates.contains(s.stateID) { continue }
                if try await syncStore.tombstone(for: .saveState(s.stateID)) != nil { continue }
                if let existing = try await store.saves.saveState(id: s.stateID) {
                    if existing.gameID != game.id || existing.generation != s.generation || existing.batteryRevisionID != s.batteryRevisionID || existing.installationID != s.installationID {
                        prepared.rejected.append((change.key, "state immutable membership differs"))
                    }
                    continue
                }
                if let paired = s.batteryRevisionID {
                    guard let matches = try await revisionMembership(paired, game: game) else {
                        try deferRecord(change, record, reason: "missing paired battery", into: &prepared, now: now, reuseAssets: retryingDeferred); continue
                    }
                    guard matches else { prepared.rejected.append((change.key, "paired battery belongs to another game generation")); continue }
                }
                guard let payloadURL = change.assets[.payload], let kind = SaveState.Kind(rawValue: s.kind) else { prepared.rejected.append((change.key, "missing payload")); continue }
                let draft = SaveState(id: s.stateID, gameID: game.id, coreID: CoreID(rawValue: s.coreID), coreVersion: s.coreVersion,
                                      stateCompatibilityVersion: s.stateCompatibilityVersion, formatVersion: s.formatVersion, kind: kind,
                                      createdAt: SyncTime.date(s.createdAt), location: try LibraryLocation.saveStateLocation(gameID: game.id, stateID: s.stateID),
                                      label: s.label, batteryRevisionID: s.batteryRevisionID, installationID: s.installationID,
                                      deviceKind: DeviceKind(lenient: s.deviceKind), origin: .remote, generation: s.generation)
                do {
                    let size = (try? FileManager.default.attributesOfItem(atPath: payloadURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard size > 0, size <= SyncLimits.maxStateSize + 1_000_000 else { throw SyncValidationError.sizeOutOfRange(field: "payload", value: size) }
                    let installed = try saveStates.installRemote(state: draft, game: game, expectedPayloadFingerprint: s.payloadFingerprint,
                                                                 containerURL: payloadURL, screenshotURL: s.hasScreenshot ? change.assets[.screenshot] : nil)
                    prepared.installedFiles.append(location.url(for: installed.location))
                    if let shot = installed.screenshotLocation { prepared.installedFiles.append(location.url(for: shot)) }
                    prepared.batch.states.append(installed)
                    prepared.touched.insert(s.fingerprint)
                } catch {
                    prepared.rejected.append((change.key, "state rejected: \(error)"))
                }

            case .gameContent:
                // Never arrives through the automatic path; content is fetched on demand by ContentManager.
                prepared.rejected.append((change.key, "content record on the lightweight path"))

            case .artwork(let a):
                guard let game = try await resolveGame(a.fingerprint, generation: a.generation) else {
                    try deferRecord(change, record, reason: "unknown game", into: &prepared, now: now, reuseAssets: retryingDeferred); continue
                }
                // A value that does not order after the local one changes nothing (checked again in the transaction).
                if let local = try await store.games.customCover(for: game.id),
                   !SyncArtwork.isLater(updatedAt: a.updatedAt, cover: a.artworkFingerprint, than: SyncTime.millis(local.updatedAt), local.fingerprint) {
                    continue
                }
                if let cover = a.artworkFingerprint {
                    guard let url = change.assets[.data] else { prepared.rejected.append((change.key, "missing cover asset")); continue }
                    do {
                        // Untrusted bytes: declared size and fingerprint, then an image that decodes as HEIC.
                        guard CoverImage.validate(try Data(contentsOf: url)) == .heic else { throw SyncValidationError.invalidField("cover image") }
                        try install(asset: url, to: try LibraryLocation.customCoverLocation(gameID: game.id, fingerprint: cover),
                                    maxSize: SyncLimits.maxArtworkSize, expectedFingerprint: cover, expectedSize: a.artworkSize, into: &prepared)
                    } catch {
                        prepared.rejected.append((change.key, "cover rejected: \(error)")); continue
                    }
                }
                prepared.batch.customCovers.append(RemoteCustomCover(cover: CustomCover(gameID: game.id, fingerprint: a.artworkFingerprint,
                                                                                        sizeInBytes: a.artworkSize ?? 0, updatedAt: SyncTime.date(a.updatedAt)),
                                                                     generation: a.generation))
                prepared.coverGames.insert(game.id)
                prepared.touched.insert(a.fingerprint)

            case .tombstone, .game, .contentIndex:
                break
            }
        }

        // 3. Deletions.
        for key in deletions {
            switch key.type {
            case .state:
                if let id = key.stateID { prepared.batch.deletedStateIDs.append(id) }
            case .contentIndex:
                if let membership = key.contentMembership { prepared.batch.deletedContentMemberships.append(membership) }
            case .game, .session, .batteryRevision, .tombstone, .gameContent, .artwork:
                break   // never deleted as records (tombstones carry deletion, a reset is a value), or handled elsewhere
            }
        }
        return prepared
    }

    // MARK: Files

    /// Copies a transport asset into its final Relay location after checking size and, when known, SHA-256.
    private func install(asset url: URL, to contentLocation: ContentLocation, maxSize: Int64, expectedFingerprint: ContentFingerprint?,
                         expectedSize: Int64? = nil, into prepared: inout Prepared) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= maxSize else { throw SyncValidationError.sizeOutOfRange(field: "asset", value: size) }
        if let expectedSize, size != expectedSize { throw SyncValidationError.sizeOutOfRange(field: "asset", value: size) }
        let data = try Data(contentsOf: url)
        if let expectedFingerprint {
            let actual = try hasher.hash(data: data).fingerprint
            guard actual == expectedFingerprint else { throw SyncValidationError.invalidField("asset fingerprint") }
        }
        let destination = location.url(for: contentLocation)
        let existed = FileManager.default.fileExists(atPath: destination.path)
        try AtomicFile().write(data, to: destination)
        if !existed { prepared.installedFiles.append(destination) }
    }

    /// Keeps a record whose prerequisites are missing, with its assets copied into the inbox.
    private func deferRecord(_ change: InboundChange, _ record: SyncRecord, reason: String, into prepared: inout Prepared, now: Date, reuseAssets: Bool) throws {
        let key = "\(change.key.type.rawValue):\(change.key.name)"
        var assetPaths: [SyncAssetName: String] = [:]
        if reuseAssets {
            // A deferred retry already owns durable inbox assets. Keep the
            // original paths; copying them each pass would leak orphan files.
            for (name, url) in change.assets {
                assetPaths[name] = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
            }
        } else if !change.assets.isEmpty {
            let inbox = try location.makeSyncInboxDirectory()
            for (name, url) in change.assets {
                let destination = inbox.appending(path: name.rawValue)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
                prepared.installedFiles.append(destination)
                assetPaths[name] = inbox.lastPathComponent + "/" + name.rawValue
            }
        }
        let envelope = DeferredEnvelope(record: record, assets: assetPaths)
        prepared.batch.deferred.append(DeferredRemoteRecord(key: key, kind: change.key.type.rawValue, payload: try JSONEncoder().encode(envelope),
                                                            reason: reason, receivedAt: now))
        prepared.deferredCount += 1
    }

    /// Rebuilds inbound changes from deferred records (assets from the inbox).
    func inboundChanges(fromDeferred records: [DeferredRemoteRecord]) -> [(String, InboundChange)] {
        records.compactMap { deferred in
            guard let envelope = try? JSONDecoder().decode(DeferredEnvelope.self, from: deferred.payload) else { return nil }
            var assets: [SyncAssetName: URL] = [:]
            for (name, path) in envelope.assets {
                let url = location.syncInboxDirectory.appending(path: path)
                if FileManager.default.fileExists(atPath: url.path) { assets[name] = url }
            }
            return (deferred.key, InboundChange(key: envelope.record.key, record: envelope.record, assets: assets))
        }
    }

    func removeInboxAssets(of records: [DeferredRemoteRecord]) {
        for deferred in records {
            guard let envelope = try? JSONDecoder().decode(DeferredEnvelope.self, from: deferred.payload) else { continue }
            for (_, path) in envelope.assets {
                let dir = location.syncInboxDirectory.appending(path: path).deletingLastPathComponent()
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
}

// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  BatterySaveManager.swift
//  RelayLibrary
//
//  The game's own persistent memory (SRAM/flash/EEPROM), written by the game
//  through the core into a Relay-managed per-game working directory:
//
//      Saves/<GameID>/battery/work/<rom base name>.sav    live copy the core maps and writes
//      Saves/<GameID>/battery/current.sav                 Relay's canonical snapshot (the `Save` row)
//      Saves/<GameID>/battery/previous.sav                the snapshot before that (local rollback only)
//
//  At safe points (pause, background, exit, quick save) `snapshot` writes the
//  bytes the core holds in memory into an immutable revision file and into
//  `current.sav` atomically, keeping the prior snapshot as `previous.sav`; the
//  `Save` row, the revision row, the active head and the upload intent are
//  committed in one transaction only after the files are durable. On launch,
//  the live copy is restored from the canonical snapshot when it is missing,
//  empty or older than the snapshot. This is a battery save, never a save
//  state: it holds what the game itself wrote, in the game's own format.
//
//  one head means the devices agree; several heads mean "Two versions", which
//  only the player resolves (`resolve`). `reconcile` adopts a single remote
//  head or joins identical bytes automatically; `previous.sav` is never used
//  for any of this.

import Foundation
import RelayDomain

public enum BatterySaveError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSaveSize(Int)
    case revisionDataMismatch(BatteryRevisionID)
    case notAHead(BatteryRevisionID)
    case noConflict(GameID)

    public var description: String {
        switch self {
        case .invalidSaveSize(let n): return "Battery save of \(n) bytes is outside the accepted range"
        case .revisionDataMismatch(let id): return "Battery revision \(id) file does not match its fingerprint"
        case .notAHead(let id): return "Battery revision \(id) is not a head of the game's graph"
        case .noConflict(let g): return "Game \(g) has no battery conflict to resolve"
        }
    }
}

/// The heads of a game's battery graph when they disagree.
public struct BatteryConflict: Equatable, Sendable {
    public let gameID: GameID
    /// Newest first.
    public let heads: [BatteryRevision]

    public init(gameID: GameID, heads: [BatteryRevision]) {
        self.gameID = gameID
        self.heads = heads
    }
}

public struct BatterySaveManager: Sendable {
    /// Largest battery save Relay accepts (cartridge formats top out at 128 KiB; later systems stay far below this).
    public static let maxSaveSize = 8 * 1024 * 1024
    public static let liveFileExtension = "sav"

    public enum ReconcileOutcome: Equatable, Sendable {
        case unchanged
        case adopted(BatteryRevision)
        case joinedIdentical(BatteryRevision)
        case conflict(BatteryConflict)
    }

    private let store: any LibraryStore
    private let location: LibraryLocation
    private let identity: SyncIdentity
    private let atomicFile: AtomicFile
    private let hasher = SHA256ContentHasher()

    public init(store: any LibraryStore, location: LibraryLocation,
                identity: SyncIdentity = SyncIdentity(installationID: InstallationID(), deviceKind: .unknown),
                atomicFile: AtomicFile = AtomicFile()) {
        self.store = store
        self.location = location
        self.identity = identity
        self.atomicFile = atomicFile
    }

    /// Directory the core must use as its battery-save directory for `gameID`.
    public func workingDirectory(for gameID: GameID) -> URL {
        location.batteryWorkingDirectory(forGame: gameID)
    }

    // MARK: Launch

    /// Ensures the working directory exists and that the live copy the core will
    /// load carries the last durable progress: the canonical snapshot is written
    /// over a live copy that is missing, empty, or older than the snapshot (the
    /// core flushes its file some time after the game writes, so after a crash
    /// the file can lag the last Relay snapshot). A live copy newer than the
    /// snapshot is kept: it is the fresher truth. `romBaseName` is the game
    /// file's name without extension: cores derive the live file name from it.
    /// Returns true when the live copy was (re)written from the snapshot.
    @discardableResult
    public func prepareForLaunch(gameID: GameID, romBaseName: String) async throws -> Bool {
        let fm = FileManager.default
        let work = workingDirectory(for: gameID)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try await ensureRootRevision(gameID: gameID)
        let live = work.appending(path: "\(romBaseName).\(Self.liveFileExtension)")
        let canonical = location.url(for: try LibraryLocation.batterySaveLocation(gameID: gameID))
        guard fm.fileExists(atPath: canonical.path), let save = try await currentSave(for: gameID) else { return false }
        let data = try Data(contentsOf: canonical)
        guard !data.isEmpty else { return false }
        if let attributes = try? fm.attributesOfItem(atPath: live.path),
           let size = (attributes[.size] as? NSNumber)?.intValue, size > 0 {
            if (try? Data(contentsOf: live)) == data { return false }
            let liveModified = (attributes[.modificationDate] as? Date) ?? .distantPast
            if liveModified > save.updatedAt.addingTimeInterval(Self.liveFreshnessMargin) { return false }
        }
        try atomicFile.write(data, to: live)
        return true
    }

    /// A live file must be this much newer than the snapshot to win over it.
    static let liveFreshnessMargin: TimeInterval = 1

    /// The live save file the core is writing, if any non-empty one exists.
    public func liveSaveURL(for gameID: GameID) -> URL? {
        let fm = FileManager.default
        let work = workingDirectory(for: gameID)
        guard let entries = try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let candidates = entries.filter { $0.pathExtension.lowercased() == Self.liveFileExtension }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize, size > 0 else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    // MARK: Snapshot (local write)

    /// Writes `data` — the battery bytes the core holds right now — as a new
    /// immutable revision and into the canonical snapshot if they changed, and
    /// commits the `Save` row, the revision, the head and the upload intent in
    /// one transaction. Returns the current `Save` (nil when the game has not
    /// written any save yet). Safe to call while the game runs: files are
    /// replaced atomically. `screenshotLocation` (already written) is recorded
    /// on the revision for the Two versions chooser.
    @discardableResult
    public func snapshot(gameID: GameID, data: Data?, screenshotLocation: ContentLocation? = nil, now: Date = Date()) async throws -> Save? {
        guard let data else { return try await currentSave(for: gameID) }
        guard !data.isEmpty, data.count <= Self.maxSaveSize else { throw BatterySaveError.invalidSaveSize(data.count) }
        let fingerprint = try hasher.hash(data: data).fingerprint
        try await ensureRootRevision(gameID: gameID)
        let existing = try await currentSave(for: gameID)
        let canonicalLocation = try LibraryLocation.batterySaveLocation(gameID: gameID)
        let canonical = location.url(for: canonicalLocation)
        if let existing, existing.fingerprint == fingerprint, FileManager.default.fileExists(atPath: canonical.path) {
            return existing
        }
        let activeID = try await store.saves.activeBatteryRevisionID(for: gameID)
        let revision = try await writeRevisionFile(gameID: gameID, data: data, fingerprint: fingerprint,
                                             parents: activeID.map { [$0] } ?? [], screenshotLocation: screenshotLocation, now: now)
        try replaceCanonical(with: data, gameID: gameID)
        let save = Save(id: existing?.id ?? SaveID(), gameID: gameID, location: canonicalLocation,
                        sizeInBytes: Int64(data.count), fingerprint: fingerprint, updatedAt: now)
        try await store.saves.commitBatterySnapshot(save, revision: revision)
        return save
    }

    /// The canonical `Save` row of a game, if any.
    public func currentSave(for gameID: GameID) async throws -> Save? {
        try await store.saves.saves(for: gameID).first
    }

    /// The previous canonical snapshot, when one exists (local recovery only).
    public func previousSnapshotURL(for gameID: GameID) -> URL? {
        guard let loc = try? LibraryLocation.previousBatterySaveLocation(gameID: gameID) else { return nil }
        let url = location.url(for: loc)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Graph

    /// Every known revision of a game, newest first.
    public func revisions(for gameID: GameID) async throws -> [BatteryRevision] {
        guard let game = try await store.games.game(id: gameID) else { return [] }
        return try await store.saves.batteryRevisions(for: gameID).filter { $0.gameID == game.id && $0.generation == game.generation }
    }

    /// The heads of the game's *complete* revisions (parents all known), newest first.
    public func heads(for gameID: GameID) async throws -> [BatteryRevision] {
        Self.heads(of: try await revisions(for: gameID))
    }

    /// Pure graph computation over a set of revisions.
    public static func heads(of revisions: [BatteryRevision]) -> [BatteryRevision] {
        let byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        // Complete = every ancestor is known (fixpoint over parents).
        var complete: Set<BatteryRevisionID> = []
        var changed = true
        while changed {
            changed = false
            for r in revisions where !complete.contains(r.id) {
                if r.parentIDs.allSatisfy({ complete.contains($0) }) {
                    complete.insert(r.id); changed = true
                }
            }
        }
        var hasChild: Set<BatteryRevisionID> = []
        for r in revisions where complete.contains(r.id) {
            for p in r.parentIDs { hasChild.insert(p) }
        }
        return revisions.filter { complete.contains($0.id) && !hasChild.contains($0.id) }
            .sorted { ($0.createdAt, $0.id.description) > ($1.createdAt, $1.id.description) }
            .compactMap { byID[$0.id] }
    }

    /// The unresolved conflict of a game, if its heads disagree.
    public func conflict(for gameID: GameID) async throws -> BatteryConflict? {
        let heads = try await heads(for: gameID)
        guard heads.count > 1, Set(heads.map(\.dataFingerprint)).count > 1 else { return nil }
        return BatteryConflict(gameID: gameID, heads: heads)
    }

    /// Brings the local canonical save in line with the graph after remote
    /// revisions arrived. Must not be called while the game is running (the
    /// caller knows). One head → adopt it if it is not active; several heads
    /// with identical bytes → join them with a merge revision; otherwise a
    /// conflict is reported and nothing is touched.
    public func reconcile(gameID: GameID, now: Date = Date()) async throws -> ReconcileOutcome {
        let heads = try await heads(for: gameID)
        let active = try await store.saves.activeBatteryRevisionID(for: gameID)
        switch heads.count {
        case 0:
            return .unchanged
        case 1:
            if heads[0].id == active { return .unchanged }
            try await adopt(heads[0])
            return .adopted(heads[0])
        default:
            let fingerprints = Set(heads.map(\.dataFingerprint))
            if fingerprints.count == 1 {
                let merged = try await merge(gameID: gameID, heads: heads, keeping: heads[0], now: now)
                return .joinedIdentical(merged)
            }
            return .conflict(BatteryConflict(gameID: gameID, heads: heads))
        }
    }

    /// Resolves a conflict by creating a merge revision that descends from
    /// every head and carries the bytes of `keepID`; the other heads stay as
    /// immutable revisions ("Previous versions"). Returns the merge revision.
    @discardableResult
    public func resolve(gameID: GameID, keeping keepID: BatteryRevisionID, now: Date = Date()) async throws -> BatteryRevision {
        let heads = try await heads(for: gameID)
        guard heads.count > 1 else { throw BatterySaveError.noConflict(gameID) }
        guard let keep = heads.first(where: { $0.id == keepID }) else { throw BatterySaveError.notAHead(keepID) }
        return try await merge(gameID: gameID, heads: heads, keeping: keep, now: now)
    }

    /// Makes an older revision the current progress by creating a new revision
    /// (child of the active head) with its bytes. History is never rewritten.
    @discardableResult
    public func restore(_ revision: BatteryRevision, now: Date = Date()) async throws -> BatteryRevision {
        guard let game = try await store.games.game(id: revision.gameID), game.generation == revision.generation else {
            throw LibraryError.membershipChanged
        }
        let data = try verifiedData(of: revision)
        let active = try await store.saves.activeBatteryRevisionID(for: revision.gameID)
        let parents = active.map { [$0] } ?? []
        let created = try await writeRevisionFile(gameID: revision.gameID, data: data, fingerprint: revision.dataFingerprint,
                                            parents: parents, screenshotLocation: revision.screenshotLocation, now: now)
        try replaceCanonical(with: data, gameID: revision.gameID)
        let save = try await currentSave(for: revision.gameID)
        let row = Save(id: save?.id ?? SaveID(), gameID: revision.gameID, location: try LibraryLocation.batterySaveLocation(gameID: revision.gameID),
                       sizeInBytes: Int64(data.count), fingerprint: revision.dataFingerprint, updatedAt: now)
        try await store.saves.commitBatterySnapshot(row, revision: created)
        return created
    }

    /// Reads a revision's bytes and verifies them against its fingerprint.
    public func verifiedData(of revision: BatteryRevision) throws -> Data {
        let data = try Data(contentsOf: location.url(for: revision.location))
        guard try hasher.hash(data: data).fingerprint == revision.dataFingerprint, Int64(data.count) == revision.sizeInBytes else {
            throw BatterySaveError.revisionDataMismatch(revision.id)
        }
        return data
    }

    /// Where a revision file must live; used by the sync layer to install remote revisions.
    public func revisionLocation(gameID: GameID, revisionID: BatteryRevisionID) throws -> ContentLocation {
        try LibraryLocation.batteryRevisionLocation(gameID: gameID, revisionID: revisionID)
    }

    // MARK: Internals

    func ensureRootRevision(gameID: GameID) async throws {
        guard let existing = try await currentSave(for: gameID) else { return }
        guard try await store.saves.activeBatteryRevisionID(for: gameID) == nil,
              try await store.saves.batteryRevisions(for: gameID).isEmpty else { return }
        let canonical = location.url(for: existing.location)
        guard let data = try? Data(contentsOf: canonical), !data.isEmpty else { return }
        let fingerprint = try hasher.hash(data: data).fingerprint
        let root = try await writeRevisionFile(gameID: gameID, data: data, fingerprint: fingerprint, parents: [], screenshotLocation: nil, now: existing.updatedAt)
        try await store.saves.commitBatterySnapshot(existing, revision: root)
    }

    private func writeRevisionFile(gameID: GameID, data: Data, fingerprint: ContentFingerprint, parents: [BatteryRevisionID],
                                   screenshotLocation: ContentLocation?, now: Date) async throws -> BatteryRevision {
        guard let game = try await store.games.game(id: gameID) else { throw LibraryError.gameNotFound(gameID) }
        let id = BatteryRevisionID()
        let revisionLocation = try LibraryLocation.batteryRevisionLocation(gameID: gameID, revisionID: id)
        try atomicFile.write(data, to: location.url(for: revisionLocation))
        return BatteryRevision(id: id, gameID: gameID, parentIDs: parents, createdAt: now, dataFingerprint: fingerprint,
                               sizeInBytes: Int64(data.count), installationID: identity.installationID, deviceKind: identity.deviceKind,
                               location: revisionLocation, screenshotLocation: screenshotLocation, origin: .local, generation: game.generation)
    }

    /// Keeps the previous canonical copy for local rollback, then replaces `current.sav` atomically.
    private func replaceCanonical(with data: Data, gameID: GameID) throws {
        let canonical = location.url(for: try LibraryLocation.batterySaveLocation(gameID: gameID))
        if FileManager.default.fileExists(atPath: canonical.path) {
            let previous = location.url(for: try LibraryLocation.previousBatterySaveLocation(gameID: gameID))
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.copyItem(at: canonical, to: previous)
        }
        try atomicFile.write(data, to: canonical)
    }

    private func adopt(_ revision: BatteryRevision) async throws {
        guard let game = try await store.games.game(id: revision.gameID), game.generation == revision.generation else {
            throw LibraryError.membershipChanged
        }
        let data = try verifiedData(of: revision)
        try replaceCanonical(with: data, gameID: revision.gameID)
        let existing = try await currentSave(for: revision.gameID)
        let save = Save(id: existing?.id ?? SaveID(), gameID: revision.gameID,
                        location: try LibraryLocation.batterySaveLocation(gameID: revision.gameID),
                        sizeInBytes: Int64(data.count), fingerprint: revision.dataFingerprint, updatedAt: revision.createdAt)
        try await store.saves.adoptBatteryRevision(revision.id, save: save)
    }

    private func merge(gameID: GameID, heads: [BatteryRevision], keeping keep: BatteryRevision, now: Date) async throws -> BatteryRevision {
        let data = try verifiedData(of: keep)
        let parents = [keep.id] + heads.map(\.id).filter { $0 != keep.id }
        let merged = try await writeRevisionFile(gameID: gameID, data: data, fingerprint: keep.dataFingerprint, parents: parents,
                                           screenshotLocation: keep.screenshotLocation, now: now)
        try replaceCanonical(with: data, gameID: gameID)
        let existing = try await currentSave(for: gameID)
        let save = Save(id: existing?.id ?? SaveID(), gameID: gameID, location: try LibraryLocation.batterySaveLocation(gameID: gameID),
                        sizeInBytes: Int64(data.count), fingerprint: keep.dataFingerprint, updatedAt: now)
        try await store.saves.commitBatterySnapshot(save, revision: merged)
        return merged
    }
}

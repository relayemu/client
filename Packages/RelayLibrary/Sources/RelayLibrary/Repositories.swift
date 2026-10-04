// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Repositories.swift
//  RelayLibrary
//
//  The persistence-facing boundaries of the Relay library. Domain-specific
//  operations only; no database types, no UI types. Implementations live in
//  RelayPersistence (SQLite/GRDB) and in test fakes.
//
//  Contract rules every implementation must honour:
//    - each call is atomic: it either fully happens or leaves no trace;
//    - `insert(_:files:)` rejects an existing content fingerprint with
//      `LibraryError.duplicateContent` and inserts nothing; a game may have
//      no files yet (content in iCloud or on another device);
//    - deleting a game deletes its files, saves, revisions, save states and
//      play sessions (rows only; on-disk content is the ingestion layer's
//      responsibility) and, where the store synchronizes, records a tombstone;
//    - `record(_:)` on play history is an upsert keyed by `PlaySession.id`;
//    - mutations of synchronized state record their sync intent in the same
//      transaction (Sync/SyncContracts.swift).

import Foundation
import RelayDomain

public enum LibraryError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The content fingerprint is already present in the library.
    case duplicateContent(existing: GameID, fingerprint: ContentFingerprint)
    case gameNotFound(GameID)
    case saveNotFound(SaveID)
    case saveStateNotFound(SaveStateID)
    case revisionNotFound(BatteryRevisionID)
    /// A canonical invariant would be violated (e.g. two primary files, file for an unknown game).
    case invalidRelationship(String)
    /// A membership changed after validation; retry preparation before installing/applying it.
    case membershipChanged
    /// The underlying store failed; `String` carries the technical detail for diagnostics.
    case storage(String)

    public var description: String {
        switch self {
        case .duplicateContent(let id, let fp): return "Content \(fp) already in library as game \(id)"
        case .gameNotFound(let id): return "Game \(id) not found"
        case .saveNotFound(let id): return "Save \(id) not found"
        case .saveStateNotFound(let id): return "Save state \(id) not found"
        case .revisionNotFound(let id): return "Battery revision \(id) not found"
        case .invalidRelationship(let s): return "Invalid relationship: \(s)"
        case .membershipChanged: return "Library membership changed; retry synchronization"
        case .storage(let s): return "Storage error: \(s)"
        }
    }
}

public protocol GameRepository: Sendable {
    /// Inserts a game with its files in one atomic operation.
    /// Throws `LibraryError.duplicateContent` if the fingerprint exists,
    /// `LibraryError.invalidRelationship` if `files` contains more than one
    /// `.primary` file, member files without a primary, or files of another game.
    /// An empty `files` is valid: the content is not on this device.
    func insert(_ game: Game, files: [GameFile]) async throws
    /// Generation an explicit new import must use. Insertion rechecks this
    /// answer atomically; a concurrent retirement cannot attach stale content.
    func nextGeneration(for fingerprint: ContentFingerprint) async throws -> Int64
    /// Adds a file to an existing game (content downloaded later). Same relationship rules.
    func insertFile(_ file: GameFile) async throws
    func game(id: GameID) async throws -> Game?
    func game(fingerprint: ContentFingerprint) async throws -> Game?
    /// All games, ordered by title (case-insensitive) then id for a stable order.
    func allGames() async throws -> [Game]
    /// Files of a game, primary first.
    func files(for gameID: GameID) async throws -> [GameFile]
    /// Updates mutable game fields (title, favourite, updatedAt); classification and generation are immutable. Throws `gameNotFound`.
    func update(_ game: Game) async throws
    /// Deletes the game and everything that references it. No-op if absent.
    func deleteGame(id: GameID) async throws
    /// Removes the game's file rows only (Remove Download): the game, its
    /// saves, revisions, states and sessions stay. No sync intent.
    func removeLocalContent(gameID: GameID) async throws

    /// Games matching a query, in the query's sort order. Deterministic ties (id).
    func games(matching query: GameQuery) async throws -> [Game]
    /// Games ordered by `addedAt` descending (then id), newest first.
    func recentlyAdded(limit: Int) async throws -> [Game]
    /// Number of games per system, for systems with at least one game.
    func gameCountsBySystem() async throws -> [SystemID: Int]

    func metadata(for gameID: GameID) async throws -> GameMetadata?
    /// Inserts or replaces the metadata of a game. Throws `gameNotFound`.
    func upsertMetadata(_ metadata: GameMetadata) async throws
    func deleteMetadata(for gameID: GameID) async throws
    /// Cached metadata lookup keys of a piece of content (local only, never synced).
    func lookupDigests(for fingerprint: ContentFingerprint) async throws -> LookupDigests?
    func setLookupDigests(_ digests: LookupDigests, for fingerprint: ContentFingerprint) async throws
    /// Points a game's metadata at its artwork, changing nothing else. No-op without metadata.
    func setArtworkLocation(_ location: ContentLocation?, for gameID: GameID) async throws
    /// When the cover mirror last had no usable cover for `key` (local only, never synced).
    func coverMissedAt(key: String) async throws -> Date?
    func recordCoverMiss(key: String, at date: Date) async throws
    /// The player's cover for a game (or its reset), nil when never chosen.
    func customCover(for gameID: GameID) async throws -> CustomCover?
    func customCovers() async throws -> [CustomCover]
    /// Replaces the game's custom-cover value. Throws `gameNotFound`. Local only (no sync intent yet).
    func setCustomCover(_ cover: CustomCover) async throws
}

public extension GameRepository {
    func nextGeneration(for fingerprint: ContentFingerprint) async throws -> Int64 { 0 }
}

/// Filter + sort for library listings and search.
public struct GameQuery: Hashable, Sendable {
    public enum Sort: String, Hashable, Sendable, CaseIterable {
        case title
        case recentlyAdded
    }

    public var systemID: SystemID?
    public var favoritesOnly: Bool
    /// Case-insensitive substring over title, alternate titles, developer, publisher,
    /// and — resolved by the repository against `SystemCatalog` — system names.
    public var text: String?
    public var sort: Sort
    public var limit: Int?

    public init(systemID: SystemID? = nil, favoritesOnly: Bool = false, text: String? = nil,
                sort: Sort = .title, limit: Int? = nil) {
        self.systemID = systemID
        self.favoritesOnly = favoritesOnly
        self.text = text
        self.sort = sort
        self.limit = limit
    }

    /// Systems whose display names match `text` (used by implementations for the system-name clause).
    public var matchingSystemIDs: [SystemID] {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let needle = text.lowercased()
        return SystemCatalog.all.filter {
            $0.name.lowercased().contains(needle) || $0.shortName.lowercased().contains(needle)
        }.map(\.id)
    }
}

public protocol SaveRepository: Sendable {
    /// Inserts or replaces a battery save by id. Throws `gameNotFound` for an unknown game.
    func upsert(_ save: Save) async throws
    /// Battery saves of a game, most recently updated first.
    func saves(for gameID: GameID) async throws -> [Save]
    func deleteSave(id: SaveID) async throws


    /// One transaction: upsert `save`, insert `revision`, make it the game's
    /// active head, and record the upload intent. The revision file must
    /// already be durable.
    func commitBatterySnapshot(_ save: Save, revision: BatteryRevision) async throws
    /// Inserts a revision without changing the head (remote arrival is done
    /// through `SyncStore.applyRemote`; this is for local roots/backfill).
    func insertBatteryRevision(_ revision: BatteryRevision) async throws
    /// Every known revision of a game, newest first.
    func batteryRevisions(for gameID: GameID) async throws -> [BatteryRevision]
    func batteryRevision(id: BatteryRevisionID) async throws -> BatteryRevision?
    /// The revision whose bytes the game currently plays from, if any.
    func activeBatteryRevisionID(for gameID: GameID) async throws -> BatteryRevisionID?
    /// One transaction: upsert `save` (the adopted bytes) and set the head. No intent.
    func adoptBatteryRevision(_ id: BatteryRevisionID, save: Save) async throws

    /// Inserts a save state. Throws `gameNotFound` for an unknown game.
    func insert(_ state: SaveState) async throws
    /// Save states of a game, newest first.
    func saveStates(for gameID: GameID) async throws -> [SaveState]
    func saveState(id: SaveStateID) async throws -> SaveState?
    /// Deletes a state row and records a permanent UUID tombstone for every kind where the store synchronizes.
    func deleteSaveState(id: SaveStateID) async throws
}

public protocol PlayHistoryRepository: Sendable {
    /// Inserts or replaces the session by id. Throws `gameNotFound` for an unknown game.
    func record(_ session: PlaySession) async throws
    /// Sessions of a game, most recent start first.
    func sessions(for gameID: GameID, limit: Int) async throws -> [PlaySession]
    func session(id: PlaySessionID) async throws -> PlaySession?
    /// Per-game summaries ordered by most recent session start; the local
    /// "Continue Playing" / "Recently Played" source (local and remote sessions).
    func recentlyPlayed(limit: Int) async throws -> [PlayHistoryEntry]
    /// The single most recently started session's summary, if any.
    func lastPlayed() async throws -> PlayHistoryEntry?
}

/// One local library: the repositories over the same store, plus the sync
/// side when the store supports it (nil for stores that do not synchronize).
public protocol LibraryStore: Sendable {
    var games: any GameRepository { get }
    var saves: any SaveRepository { get }
    var playHistory: any PlayHistoryRepository { get }
    var sync: (any SyncStore)? { get }
}

public extension LibraryStore {
    var sync: (any SyncStore)? { nil }
}

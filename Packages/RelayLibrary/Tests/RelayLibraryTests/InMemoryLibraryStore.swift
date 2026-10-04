// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain
import RelayLibrary

/// Reference implementation of the repository contracts, used to test the
/// library services without a database. Enforces the same invariants the
/// SQLite implementation must enforce. No sync store (`sync` is nil).
actor InMemoryLibraryState {
    var games: [GameID: Game] = [:]
    var files: [GameFileID: GameFile] = [:]
    var saves: [SaveID: Save] = [:]
    var states: [SaveStateID: SaveState] = [:]
    var sessions: [PlaySessionID: PlaySession] = [:]
    var metadata: [GameID: GameMetadata] = [:]
    var lookups: [ContentFingerprint: LookupDigests] = [:]
    var coverMisses: [String: Date] = [:]
    var customCovers: [GameID: CustomCover] = [:]
    var revisions: [BatteryRevisionID: BatteryRevision] = [:]
    var heads: [GameID: BatteryRevisionID] = [:]
    var failNextInsert = false
    var failNextCommit = false
}

struct InMemoryLibraryStore: LibraryStore {
    let state = InMemoryLibraryState()
    var games: any GameRepository { Games(state: state) }
    var saves: any SaveRepository { Saves(state: state) }
    var playHistory: any PlayHistoryRepository { History(state: state) }

    struct Games: GameRepository {
        let state: InMemoryLibraryState
        func insert(_ game: Game, files: [GameFile]) async throws {
            if await state.failNextInsert {
                await state.setFailNextInsert(false)
                throw LibraryError.storage("simulated failure")
            }
            if let existing = await state.games.values.first(where: { $0.contentFingerprint == game.contentFingerprint }) {
                throw LibraryError.duplicateContent(existing: existing.id, fingerprint: game.contentFingerprint)
            }
            let primaries = files.filter { $0.role == .primary }.count
            guard primaries <= 1, (files.isEmpty || primaries == 1), files.allSatisfy({ $0.gameID == game.id }) else {
                throw LibraryError.invalidRelationship("at most one primary file belonging to the game is required")
            }
            await state.insert(game, files)
        }
        func insertFile(_ file: GameFile) async throws {
            guard await state.games[file.gameID] != nil else { throw LibraryError.gameNotFound(file.gameID) }
            if file.role == .primary, await state.files.values.contains(where: { $0.gameID == file.gameID && $0.role == .primary }) {
                throw LibraryError.invalidRelationship("game already has a primary file")
            }
            await state.insertFile(file)
        }
        func game(id: GameID) async throws -> Game? { await state.games[id] }
        func game(fingerprint: ContentFingerprint) async throws -> Game? {
            await state.games.values.first { $0.contentFingerprint == fingerprint }
        }
        func allGames() async throws -> [Game] {
            await state.games.values.sorted { ($0.title.lowercased(), $0.id.description) < ($1.title.lowercased(), $1.id.description) }
        }
        func files(for gameID: GameID) async throws -> [GameFile] {
            await state.files.values.filter { $0.gameID == gameID }.sorted { $0.role == .primary && $1.role != .primary }
        }
        func update(_ game: Game) async throws {
            guard await state.games[game.id] != nil else { throw LibraryError.gameNotFound(game.id) }
            await state.insert(game, [])
        }
        func deleteGame(id: GameID) async throws { await state.delete(id) }
        func removeLocalContent(gameID: GameID) async throws { await state.removeFiles(of: gameID) }

        func games(matching query: GameQuery) async throws -> [Game] {
            let meta = await state.metadata
            let systems = Set(query.matchingSystemIDs)
            var result = await state.games.values.filter { game in
                if let s = query.systemID, game.systemID != s { return false }
                if query.favoritesOnly, !game.isFavorite { return false }
                if let text = query.text?.lowercased(), !text.isEmpty {
                    let m = meta[game.id]
                    let haystack = ([game.title] + (m?.alternateTitles ?? []) + [m?.developer ?? "", m?.publisher ?? ""]).joined(separator: "\n").lowercased()
                    return haystack.contains(text) || systems.contains(game.systemID)
                }
                return true
            }
            switch query.sort {
            case .title: result.sort { ($0.title.lowercased(), $0.id.description) < ($1.title.lowercased(), $1.id.description) }
            case .recentlyAdded: result.sort { ($0.addedAt, $1.id.description) > ($1.addedAt, $0.id.description) }
            }
            if let limit = query.limit { result = Array(result.prefix(limit)) }
            return result
        }
        func recentlyAdded(limit: Int) async throws -> [Game] {
            try await games(matching: GameQuery(sort: .recentlyAdded, limit: limit))
        }
        func gameCountsBySystem() async throws -> [SystemID: Int] {
            Dictionary(grouping: await state.games.values, by: \.systemID).mapValues(\.count)
        }
        func metadata(for gameID: GameID) async throws -> GameMetadata? { await state.metadata[gameID] }
        func upsertMetadata(_ metadata: GameMetadata) async throws {
            guard await state.games[metadata.gameID] != nil else { throw LibraryError.gameNotFound(metadata.gameID) }
            await state.put(metadata)
        }
        func deleteMetadata(for gameID: GameID) async throws { await state.removeMetadata(gameID) }
        func lookupDigests(for fingerprint: ContentFingerprint) async throws -> LookupDigests? { await state.lookups[fingerprint] }
        func setLookupDigests(_ digests: LookupDigests, for fingerprint: ContentFingerprint) async throws { await state.putLookup(digests, fingerprint) }
        func setArtworkLocation(_ location: ContentLocation?, for gameID: GameID) async throws { await state.setArtwork(location, for: gameID) }
        func coverMissedAt(key: String) async throws -> Date? { await state.coverMisses[key] }
        func recordCoverMiss(key: String, at date: Date) async throws { await state.putCoverMiss(key, date) }
        func customCover(for gameID: GameID) async throws -> CustomCover? { await state.customCovers[gameID] }
        func customCovers() async throws -> [CustomCover] { Array(await state.customCovers.values) }
        func setCustomCover(_ cover: CustomCover) async throws {
            guard await state.games[cover.gameID] != nil else { throw LibraryError.gameNotFound(cover.gameID) }
            await state.putCustomCover(cover)
        }
    }

    struct Saves: SaveRepository {
        let state: InMemoryLibraryState
        func upsert(_ save: Save) async throws {
            guard await state.games[save.gameID] != nil else { throw LibraryError.gameNotFound(save.gameID) }
            await state.put(save)
        }
        func saves(for gameID: GameID) async throws -> [Save] {
            await state.saves.values.filter { $0.gameID == gameID }.sorted { $0.updatedAt > $1.updatedAt }
        }
        func deleteSave(id: SaveID) async throws { await state.removeSave(id) }

        func commitBatterySnapshot(_ save: Save, revision: BatteryRevision) async throws {
            if await state.failNextCommit {
                await state.setFailNextCommit(false)
                throw LibraryError.storage("simulated commit failure")
            }
            guard await state.games[save.gameID] != nil else { throw LibraryError.gameNotFound(save.gameID) }
            await state.put(save)
            await state.put(revision)
            await state.setHead(revision.id, for: save.gameID)
        }
        func insertBatteryRevision(_ revision: BatteryRevision) async throws {
            guard await state.games[revision.gameID] != nil else { throw LibraryError.gameNotFound(revision.gameID) }
            await state.put(revision)
        }
        func batteryRevisions(for gameID: GameID) async throws -> [BatteryRevision] {
            await state.revisions.values.filter { $0.gameID == gameID }.sorted { ($0.createdAt, $0.id.description) > ($1.createdAt, $1.id.description) }
        }
        func batteryRevision(id: BatteryRevisionID) async throws -> BatteryRevision? { await state.revisions[id] }
        func activeBatteryRevisionID(for gameID: GameID) async throws -> BatteryRevisionID? { await state.heads[gameID] }
        func adoptBatteryRevision(_ id: BatteryRevisionID, save: Save) async throws {
            guard await state.revisions[id] != nil else { throw LibraryError.revisionNotFound(id) }
            await state.put(save)
            await state.setHead(id, for: save.gameID)
        }

        func insert(_ s: SaveState) async throws {
            guard await state.games[s.gameID] != nil else { throw LibraryError.gameNotFound(s.gameID) }
            await state.put(s)
        }
        func saveStates(for gameID: GameID) async throws -> [SaveState] {
            await state.states.values.filter { $0.gameID == gameID }.sorted { $0.createdAt > $1.createdAt }
        }
        func saveState(id: SaveStateID) async throws -> SaveState? { await state.states[id] }
        func deleteSaveState(id: SaveStateID) async throws { await state.removeState(id) }
    }

    struct History: PlayHistoryRepository {
        let state: InMemoryLibraryState
        func record(_ session: PlaySession) async throws {
            guard await state.games[session.gameID] != nil else { throw LibraryError.gameNotFound(session.gameID) }
            await state.put(session)
        }
        func sessions(for gameID: GameID, limit: Int) async throws -> [PlaySession] {
            Array(await state.sessions.values.filter { $0.gameID == gameID }.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
        }
        func session(id: PlaySessionID) async throws -> PlaySession? { await state.sessions[id] }
        func recentlyPlayed(limit: Int) async throws -> [PlayHistoryEntry] {
            let grouped = Dictionary(grouping: await state.sessions.values, by: \.gameID)
            let entries = grouped.map { gameID, sessions -> PlayHistoryEntry in
                let latest = sessions.max { $0.startedAt < $1.startedAt }!
                return PlayHistoryEntry(gameID: gameID, lastPlayedAt: latest.startedAt,
                                        totalPlayDuration: sessions.compactMap(\.duration).reduce(0, +),
                                        sessionCount: sessions.count, latestSession: latest)
            }
            return Array(entries.sorted { $0.lastPlayedAt > $1.lastPlayedAt }.prefix(limit))
        }
        func lastPlayed() async throws -> PlayHistoryEntry? { try await recentlyPlayed(limit: 1).first }
    }
}

extension InMemoryLibraryState {
    func setFailNextInsert(_ v: Bool) { failNextInsert = v }
    func setFailNextCommit(_ v: Bool) { failNextCommit = v }
    func insert(_ game: Game, _ newFiles: [GameFile]) {
        games[game.id] = game
        for f in newFiles { files[f.id] = f }
    }
    func insertFile(_ f: GameFile) { files[f.id] = f }
    func removeFiles(of id: GameID) { files = files.filter { $0.value.gameID != id } }
    func delete(_ id: GameID) {
        games[id] = nil
        files = files.filter { $0.value.gameID != id }
        saves = saves.filter { $0.value.gameID != id }
        states = states.filter { $0.value.gameID != id }
        sessions = sessions.filter { $0.value.gameID != id }
        revisions = revisions.filter { $0.value.gameID != id }
        heads[id] = nil
        metadata[id] = nil
        customCovers[id] = nil
    }
    func put(_ s: Save) { saves[s.id] = s }
    func put(_ s: SaveState) { states[s.id] = s }
    func put(_ s: PlaySession) { sessions[s.id] = s }
    func put(_ m: GameMetadata) { metadata[m.gameID] = m }
    func put(_ r: BatteryRevision) { revisions[r.id] = r }
    func setHead(_ id: BatteryRevisionID, for game: GameID) { heads[game] = id }
    func removeMetadata(_ id: GameID) { metadata[id] = nil }
    func putLookup(_ digests: LookupDigests, _ fingerprint: ContentFingerprint) { lookups[fingerprint] = digests }
    func setArtwork(_ location: ContentLocation?, for id: GameID) { metadata[id]?.artworkLocation = location }
    func putCoverMiss(_ key: String, _ date: Date) { coverMisses[key] = date }
    func putCustomCover(_ cover: CustomCover) { customCovers[cover.gameID] = cover }
    func removeSave(_ id: SaveID) { saves[id] = nil }
    func removeState(_ id: SaveStateID) { states[id] = nil }
}

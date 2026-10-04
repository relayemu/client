// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Records.swift
//  RelayPersistence
//
//  Row types and their mapping to/from RelayDomain values. Internal: nothing
//  outside this package sees a GRDB type.

import Foundation
import GRDB
import RelayDomain
import RelayLibrary

// MARK: Value helpers

/// Relay stores timestamps as integer milliseconds since 1970 UTC. `Date`
/// values carry finer precision; the stored (millisecond) value is the truth,
/// so a value read back may differ from the value written by < 1 ms.
enum Timestamps {
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

extension ContentLocation {
    init(root: String, path: String) throws {
        guard let root = Root(rawValue: root) else { throw LibraryError.storage("unknown content root '\(root)'") }
        self = try ContentLocation(root: root, relativePath: path)
    }
}

// MARK: game

struct GameRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "game"

    var id: String
    var systemId: String
    var title: String
    var contentFingerprint: String
    var addedAt: Int64
    var isFavorite: Bool
    var updatedAt: Int64

    var generation: Int64

    enum CodingKeys: String, CodingKey {
        case generation
        case id, title
        case systemId = "system_id"
        case contentFingerprint = "content_fingerprint"
        case addedAt = "added_at"
        case isFavorite = "is_favorite"
        case updatedAt = "updated_at"
    }

    init(_ game: Game) {
        id = game.id.description
        generation = game.generation
        systemId = game.systemID.rawValue
        title = game.title
        contentFingerprint = game.contentFingerprint.canonicalString
        addedAt = Timestamps.millis(game.addedAt)
        isFavorite = game.isFavorite
        updatedAt = Timestamps.millis(game.updatedAt)
    }

    func toDomain() throws -> Game {
        guard let gameID = GameID(id) else { throw LibraryError.storage("invalid game id '\(id)'") }
        return Game(id: gameID,
                    systemID: SystemID(rawValue: systemId),
                    title: title,
                    contentFingerprint: try ContentFingerprint(parsing: contentFingerprint),
                    addedAt: Timestamps.date(addedAt),
                    isFavorite: isFavorite,
                    updatedAt: Timestamps.date(updatedAt), generation: generation)
    }
}

// MARK: game_metadata

struct GameMetadataRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "game_metadata"

    var gameId: String
    var alternateTitles: String
    var developer: String?
    var publisher: String?
    var releaseYear: Int?
    var genre: String?
    var region: String?
    var summary: String?
    var artworkRoot: String?
    var artworkPath: String?
    var coverKey: String?
    var source: String
    var matchedAt: Int64

    enum CodingKeys: String, CodingKey {
        case developer, publisher, genre, region, summary, source
        case gameId = "game_id"
        case alternateTitles = "alternate_titles"
        case releaseYear = "release_year"
        case artworkRoot = "artwork_root"
        case artworkPath = "artwork_path"
        case coverKey = "cover_key"
        case matchedAt = "matched_at"
    }

    init(_ m: GameMetadata) throws {
        gameId = m.gameID.description
        alternateTitles = String(data: try JSONEncoder().encode(m.alternateTitles), encoding: .utf8) ?? "[]"
        developer = m.developer
        publisher = m.publisher
        releaseYear = m.releaseYear
        genre = m.genre
        region = m.region
        summary = m.summary
        artworkRoot = m.artworkLocation?.root.rawValue
        artworkPath = m.artworkLocation?.relativePath
        coverKey = m.coverKey
        source = m.source
        matchedAt = Timestamps.millis(m.matchedAt)
    }

    func toDomain() throws -> GameMetadata {
        guard let gameID = GameID(gameId) else { throw LibraryError.storage("invalid game id '\(gameId)'") }
        let titles = (try? JSONDecoder().decode([String].self, from: Data(alternateTitles.utf8))) ?? []
        var artwork: ContentLocation?
        if let artworkRoot, let artworkPath { artwork = try ContentLocation(root: artworkRoot, path: artworkPath) }
        return GameMetadata(gameID: gameID, alternateTitles: titles, developer: developer, publisher: publisher,
                            releaseYear: releaseYear, genre: genre, region: region, summary: summary,
                            artworkLocation: artwork, coverKey: coverKey, source: source, matchedAt: Timestamps.date(matchedAt))
    }
}

// MARK: content_lookup

struct ContentLookupRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "content_lookup"

    var fingerprint: String
    var sha1: String
    var headerlessSha1: String?
    var discSerial: String?

    enum CodingKeys: String, CodingKey {
        case fingerprint, sha1
        case headerlessSha1 = "headerless_sha1"
        case discSerial = "disc_serial"
    }

    init(_ digests: LookupDigests, fingerprint: ContentFingerprint) {
        self.fingerprint = fingerprint.description
        sha1 = digests.sha1
        headerlessSha1 = digests.headerlessSHA1
        discSerial = digests.discSerial
    }

    var digests: LookupDigests { LookupDigests(sha1: sha1, headerlessSHA1: headerlessSha1, discSerial: discSerial) }
}

// MARK: game_file

struct GameFileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "game_file"

    var id: String
    var gameId: String
    var role: String
    var fingerprint: String
    var sizeInBytes: Int64
    var originalFileName: String
    var locationRoot: String
    var locationPath: String

    enum CodingKeys: String, CodingKey {
        case id, role, fingerprint
        case gameId = "game_id"
        case sizeInBytes = "size_in_bytes"
        case originalFileName = "original_file_name"
        case locationRoot = "location_root"
        case locationPath = "location_path"
    }

    init(_ file: GameFile) {
        id = file.id.description
        gameId = file.gameID.description
        role = file.role.rawValue
        fingerprint = file.fingerprint.canonicalString
        sizeInBytes = file.sizeInBytes
        originalFileName = file.originalFileName
        locationRoot = file.location.root.rawValue
        locationPath = file.location.relativePath
    }

    func toDomain() throws -> GameFile {
        guard let fileID = GameFileID(id), let gameID = GameID(gameId) else {
            throw LibraryError.storage("invalid game_file ids '\(id)'/'\(gameId)'")
        }
        guard let role = GameFile.Role(rawValue: role) else { throw LibraryError.storage("unknown file role '\(role)'") }
        return GameFile(id: fileID, gameID: gameID, role: role,
                        fingerprint: try ContentFingerprint(parsing: fingerprint),
                        sizeInBytes: sizeInBytes, originalFileName: originalFileName,
                        location: try ContentLocation(root: locationRoot, path: locationPath))
    }
}

// MARK: save

struct SaveRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "save"

    var id: String
    var gameId: String
    var locationRoot: String
    var locationPath: String
    var sizeInBytes: Int64
    var fingerprint: String?
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, fingerprint
        case gameId = "game_id"
        case locationRoot = "location_root"
        case locationPath = "location_path"
        case sizeInBytes = "size_in_bytes"
        case updatedAt = "updated_at"
    }

    init(_ save: Save) {
        id = save.id.description
        gameId = save.gameID.description
        locationRoot = save.location.root.rawValue
        locationPath = save.location.relativePath
        sizeInBytes = save.sizeInBytes
        fingerprint = save.fingerprint?.canonicalString
        updatedAt = Timestamps.millis(save.updatedAt)
    }

    func toDomain() throws -> Save {
        guard let saveID = SaveID(id), let gameID = GameID(gameId) else {
            throw LibraryError.storage("invalid save ids '\(id)'/'\(gameId)'")
        }
        return Save(id: saveID, gameID: gameID,
                    location: try ContentLocation(root: locationRoot, path: locationPath),
                    sizeInBytes: sizeInBytes,
                    fingerprint: try fingerprint.map { try ContentFingerprint(parsing: $0) },
                    updatedAt: Timestamps.date(updatedAt))
    }
}

// MARK: save_state

struct SaveStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "save_state"

    var id: String
    var gameId: String
    var coreId: String
    var coreVersion: String
    var formatVersion: Int
    var kind: String
    var createdAt: Int64
    var locationRoot: String
    var locationPath: String
    var screenshotRoot: String?
    var screenshotPath: String?
    var label: String?
    var stateCompatVersion: String
    var batteryRevisionId: String?
    var installationId: String?
    var deviceKind: String
    var origin: String

    var generation: Int64

    enum CodingKeys: String, CodingKey {
        case generation
        case id, kind, label, origin
        case gameId = "game_id"
        case coreId = "core_id"
        case coreVersion = "core_version"
        case formatVersion = "format_version"
        case createdAt = "created_at"
        case locationRoot = "location_root"
        case locationPath = "location_path"
        case screenshotRoot = "screenshot_root"
        case screenshotPath = "screenshot_path"
        case stateCompatVersion = "state_compat_version"
        case batteryRevisionId = "battery_revision_id"
        case installationId = "installation_id"
        case deviceKind = "device_kind"
    }

    init(_ state: SaveState) {
        id = state.id.description
        generation = state.generation
        gameId = state.gameID.description
        coreId = state.coreID.rawValue
        coreVersion = state.coreVersion
        formatVersion = state.formatVersion
        kind = state.kind.rawValue
        createdAt = Timestamps.millis(state.createdAt)
        locationRoot = state.location.root.rawValue
        locationPath = state.location.relativePath
        screenshotRoot = state.screenshotLocation?.root.rawValue
        screenshotPath = state.screenshotLocation?.relativePath
        label = state.label
        stateCompatVersion = state.stateCompatibilityVersion
        batteryRevisionId = state.batteryRevisionID?.description
        installationId = state.installationID?.description
        deviceKind = state.deviceKind.rawValue
        origin = state.origin.rawValue
    }

    func toDomain() throws -> SaveState {
        guard let stateID = SaveStateID(id), let gameID = GameID(gameId) else {
            throw LibraryError.storage("invalid save_state ids '\(id)'/'\(gameId)'")
        }
        guard let kind = SaveState.Kind(rawValue: kind) else { throw LibraryError.storage("unknown save state kind '\(kind)'") }
        var screenshot: ContentLocation?
        if let screenshotRoot, let screenshotPath {
            screenshot = try ContentLocation(root: screenshotRoot, path: screenshotPath)
        }
        return SaveState(id: stateID, gameID: gameID, coreID: CoreID(rawValue: coreId), coreVersion: coreVersion,
                         stateCompatibilityVersion: stateCompatVersion.isEmpty ? coreVersion : stateCompatVersion,
                         formatVersion: formatVersion, kind: kind, createdAt: Timestamps.date(createdAt),
                         location: try ContentLocation(root: locationRoot, path: locationPath),
                         screenshotLocation: screenshot, label: label,
                         batteryRevisionID: batteryRevisionId.flatMap(BatteryRevisionID.init),
                         installationID: installationId.flatMap(InstallationID.init),
                         deviceKind: DeviceKind(lenient: deviceKind),
                         origin: SyncOrigin(rawValue: origin) ?? .local, generation: generation)
    }
}

// MARK: play_session

struct PlaySessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "play_session"

    var id: String
    var gameId: String
    var coreId: String
    var startedAt: Int64
    var endedAt: Int64?
    var screenshotRoot: String?
    var screenshotPath: String?
    var pausedMs: Int64
    var installationId: String?
    var deviceKind: String
    var origin: String

    var generation: Int64

    enum CodingKeys: String, CodingKey {
        case generation
        case id, origin
        case gameId = "game_id"
        case coreId = "core_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case screenshotRoot = "screenshot_root"
        case screenshotPath = "screenshot_path"
        case pausedMs = "paused_ms"
        case installationId = "installation_id"
        case deviceKind = "device_kind"
    }

    init(_ session: PlaySession) {
        id = session.id.description
        generation = session.generation
        gameId = session.gameID.description
        coreId = session.coreID.rawValue
        startedAt = Timestamps.millis(session.startedAt)
        endedAt = session.endedAt.map(Timestamps.millis)
        screenshotRoot = session.screenshotLocation?.root.rawValue
        screenshotPath = session.screenshotLocation?.relativePath
        pausedMs = Int64((session.pausedDuration * 1000).rounded())
        installationId = session.installationID?.description
        deviceKind = session.deviceKind.rawValue
        origin = session.origin.rawValue
    }

    func toDomain() throws -> PlaySession {
        guard let sessionID = PlaySessionID(id), let gameID = GameID(gameId) else {
            throw LibraryError.storage("invalid play_session ids '\(id)'/'\(gameId)'")
        }
        var screenshot: ContentLocation?
        if let screenshotRoot, let screenshotPath { screenshot = try ContentLocation(root: screenshotRoot, path: screenshotPath) }
        return PlaySession(id: sessionID, gameID: gameID, coreID: CoreID(rawValue: coreId),
                           startedAt: Timestamps.date(startedAt), endedAt: endedAt.map(Timestamps.date),
                           screenshotLocation: screenshot, pausedDuration: Double(pausedMs) / 1000,
                           installationID: installationId.flatMap(InstallationID.init),
                           deviceKind: DeviceKind(lenient: deviceKind),
                           origin: SyncOrigin(rawValue: origin) ?? .local, generation: generation)
    }
}

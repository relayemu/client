// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Game.swift
//  RelayDomain
//
//  A `Game` is one playable library entry. Its `GameID` is the object identity;
//  its `contentFingerprint` is the content identity used to recognise the same
//  game elsewhere. Title and file names are display/bookkeeping data, never
//  identity.
//
//  (exactly one `.primary` file); the file model already carries a role so
//  multi-file games (cue/bin, m3u, companions) can be added without changing
//  identity rules.

import Foundation

public struct Game: Hashable, Codable, Sendable, Identifiable {
    public let id: GameID
    public var systemID: SystemID
    /// Display title. Initially derived from the imported file name; user-editable later.
    public var title: String
    /// Canonical content identity (see `ContentFingerprint` for the derivation rules).
    public let contentFingerprint: ContentFingerprint
    public let generation: Int64
    /// When the game entered the library (import time, never a file-system date).
    public let addedAt: Date
    /// User flag; drives the Favorites shelf and filter.
    public var isFavorite: Bool
    /// When the user-editable fields (title, favourite) last changed; the
    /// last-write-wins key for the synchronized game entry.
    public var updatedAt: Date

    public init(id: GameID = GameID(), systemID: SystemID, title: String,
                contentFingerprint: ContentFingerprint, addedAt: Date, isFavorite: Bool = false, updatedAt: Date? = nil, generation: Int64 = 0) {
        self.id = id
        self.systemID = systemID
        self.title = title
        self.contentFingerprint = contentFingerprint
        self.generation = generation
        self.addedAt = addedAt
        self.isFavorite = isFavorite
        self.updatedAt = updatedAt ?? addedAt
    }
}

/// Optional descriptive metadata attached to a game by a metadata provider
/// (or, later, by the user). Never required to play; absent for most homebrew.
public struct GameMetadata: Hashable, Codable, Sendable, Identifiable {
    public var id: GameID { gameID }
    public let gameID: GameID
    public var alternateTitles: [String]
    public var developer: String?
    public var publisher: String?
    public var releaseYear: Int?
    public var genre: String?
    public var region: String?
    public var summary: String?
    /// Cover artwork in Relay-managed storage, when available.
    public var artworkLocation: ContentLocation?
    /// Key of this game's cover on Relay's cover mirror (see CoverKey), when the catalog knows the game.
    public var coverKey: String?
    /// Identifier of the provider that produced this record (diagnostics only).
    public let source: String
    public let matchedAt: Date

    public init(gameID: GameID, alternateTitles: [String] = [], developer: String? = nil, publisher: String? = nil,
                releaseYear: Int? = nil, genre: String? = nil, region: String? = nil, summary: String? = nil,
                artworkLocation: ContentLocation? = nil, coverKey: String? = nil, source: String, matchedAt: Date) {
        self.gameID = gameID
        self.alternateTitles = alternateTitles
        self.developer = developer
        self.publisher = publisher
        self.releaseYear = releaseYear
        self.genre = genre
        self.region = region
        self.summary = summary
        self.artworkLocation = artworkLocation
        self.coverKey = coverKey
        self.source = source
        self.matchedAt = matchedAt
    }
}

/// What Relay knows about a game's content in the user's cloud storage,
/// independently of whether the bytes are on this device. Keyed by the
/// content fingerprint; a logical game may be one or several parts (and,
/// later, several files) without changing its identity.
public struct GameContentDescriptor: Hashable, Codable, Sendable {
    public struct Part: Hashable, Codable, Sendable {
        public let index: Int
        public let fingerprint: ContentFingerprint
        public let sizeInBytes: Int64

        public init(index: Int, fingerprint: ContentFingerprint, sizeInBytes: Int64) {
            self.index = index
            self.fingerprint = fingerprint
            self.sizeInBytes = sizeInBytes
        }
    }

    /// Fingerprint of the whole content (equals `Game.contentFingerprint`).
    public let fingerprint: ContentFingerprint
    public let generation: Int64
    public let sizeInBytes: Int64
    /// A display/naming hint only (already sanitised to one path component); never a path.
    public let fileName: String
    public let systemID: SystemID
    /// Parts in index order; a single-file cartridge has exactly one part whose fingerprint equals `fingerprint`.
    public let parts: [Part]
    public let uploadedAt: Date

    public init(fingerprint: ContentFingerprint, sizeInBytes: Int64, fileName: String, systemID: SystemID,
                parts: [Part], uploadedAt: Date, generation: Int64 = 0) {
        self.fingerprint = fingerprint
        self.generation = generation
        self.sizeInBytes = sizeInBytes
        self.fileName = fileName
        self.systemID = systemID
        self.parts = parts
        self.uploadedAt = uploadedAt
    }

    /// A single-part descriptor for one file.
    public static func singleFile(fingerprint: ContentFingerprint, sizeInBytes: Int64, fileName: String,
                                  systemID: SystemID, uploadedAt: Date, generation: Int64 = 0) -> GameContentDescriptor {
        GameContentDescriptor(fingerprint: fingerprint, sizeInBytes: sizeInBytes, fileName: fileName, systemID: systemID,
                              parts: [Part(index: 0, fingerprint: fingerprint, sizeInBytes: sizeInBytes)], uploadedAt: uploadedAt, generation: generation)
    }
}

public struct GameFile: Hashable, Codable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        /// The file handed to the emulator to start the game. Exactly one per game.
        case primary
        /// Additional content referenced by the primary file (disc tracks, playlist members). Future.
        case member
    }

    public let id: GameFileID
    public let gameID: GameID
    public let role: Role
    /// SHA-256 of this file's bytes.
    public let fingerprint: ContentFingerprint
    public let sizeInBytes: Int64
    /// The name the file had when imported. Bookkeeping only, never identity.
    public let originalFileName: String
    /// Where the file lives in Relay-managed storage.
    public let location: ContentLocation

    public init(id: GameFileID = GameFileID(), gameID: GameID, role: Role, fingerprint: ContentFingerprint,
                sizeInBytes: Int64, originalFileName: String, location: ContentLocation) {
        self.id = id
        self.gameID = gameID
        self.role = role
        self.fingerprint = fingerprint
        self.sizeInBytes = sizeInBytes
        self.originalFileName = originalFileName
        self.location = location
    }
}

// Legacy records always identify initial generation.
extension Game {
    private enum CodingKeys: String, CodingKey {
        case id, systemID, title, contentFingerprint, addedAt, isFavorite, updatedAt, generation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(GameID.self, forKey: .id),
            systemID: try values.decode(SystemID.self, forKey: .systemID),
            title: try values.decode(String.self, forKey: .title),
            contentFingerprint: try values.decode(ContentFingerprint.self, forKey: .contentFingerprint),
            addedAt: try values.decode(Date.self, forKey: .addedAt),
            isFavorite: try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            updatedAt: try values.decodeIfPresent(Date.self, forKey: .updatedAt),
            generation: try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0
        )
    }
}


// Legacy records always identify initial generation.
extension GameContentDescriptor {
    private enum CodingKeys: String, CodingKey {
        case fingerprint, sizeInBytes, fileName, systemID, parts, uploadedAt, generation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fingerprint: try values.decode(ContentFingerprint.self, forKey: .fingerprint),
            sizeInBytes: try values.decode(Int64.self, forKey: .sizeInBytes),
            fileName: try values.decode(String.self, forKey: .fileName),
            systemID: try values.decode(SystemID.self, forKey: .systemID),
            parts: try values.decode([Part].self, forKey: .parts),
            uploadedAt: try values.decode(Date.self, forKey: .uploadedAt),
            generation: try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0
        )
    }
}

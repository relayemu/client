// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  GameIngestion.swift
//  RelayLibrary
//
//  Deterministic ingestion of an already-known local game file into the
//
//  Sequence: locate → identify system → hash (off main actor) → duplicate
//  check → copy into Games/<GameID>/ → insert game + file atomically.
//  If the insert fails for any reason the copied directory is removed, so a
//  failure never leaves content without a library row or vice versa.

import Foundation
import RelayDomain

public enum GameIngestionError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileNotFound(URL)
    case unsupportedFile(extension: String)
    case ambiguousSystem([SystemID])
    case copyFailed(String)
    /// Downloaded bytes do not match the content they claim to be.
    case contentMismatch(expected: ContentFingerprint, actual: ContentFingerprint)

    public var description: String {
        switch self {
        case .fileNotFound(let url): return "File not found: \(url.path)"
        case .unsupportedFile(let ext): return "Unsupported file type '.\(ext)'"
        case .ambiguousSystem(let ids): return "File matches several systems: \(ids)"
        case .copyFailed(let s): return "Could not copy the file into the library: \(s)"
        case .contentMismatch(let e, let a): return "Downloaded content \(a) does not match expected \(e)"
        }
    }
}

public struct GameIngestion: Sendable {
    public enum Outcome: Sendable, Equatable {
        case inserted(Game)
        /// Content already present; nothing was copied or written.
        case duplicate(existing: Game)
        /// The game existed without its content on this device (in iCloud or on
        /// another device); the file was attached to it.
        case attached(Game)

        public var game: Game {
            switch self {
            case .inserted(let g), .duplicate(let g), .attached(let g): return g
            }
        }
    }

    private let store: any LibraryStore
    private let location: LibraryLocation
    private let hasher: any ContentHasher
    private let clock: @Sendable () -> Date

    public init(store: any LibraryStore, location: LibraryLocation,
                hasher: any ContentHasher = SHA256ContentHasher(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.location = location
        self.hasher = hasher
        self.clock = clock
    }

    /// How the source file reaches the managed library.
    public enum Transfer: Sendable {
        /// Copy; the source is left untouched (external files).
        case copy
        /// Move (rename) — for files Relay already owns, e.g. a staging directory.
        case move
    }

    /// Ingests the file at `url`. With `.copy` the source file is left untouched.
    /// - Parameters:
    ///   - systemID: explicit system; when nil it is derived from the file extension.
    ///   - title: display title; defaults to the file name without extension.
    ///   - originalFileName: the name to record; defaults to `url.lastPathComponent`.
    public func ingestLocalFile(at url: URL, systemID: SystemID? = nil, title: String? = nil,
                                originalFileName: String? = nil, transfer: Transfer = .copy) async throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw GameIngestionError.fileNotFound(url) }

        let system = try systemID ?? Self.identifySystem(fileExtension: url.pathExtension)
        let hashed = try await hasher.hash(fileAt: url)

        let fileName = originalFileName ?? url.lastPathComponent
        if let existing = try await store.games.game(fingerprint: hashed.fingerprint) {
            let files = try await store.games.files(for: existing.id)
            guard !files.contains(where: { $0.role == .primary }) else { return .duplicate(existing: existing) }
            // The library knows the game but not its bytes: attach the content to the existing entry.
            let fileLocation = try LibraryLocation.gameFileLocation(gameID: existing.id, fileName: fileName)
            let destination = location.url(for: fileLocation)
            do {
                try fm.createDirectory(at: location.directory(forGame: existing.id), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                switch transfer {
                case .copy: try fm.copyItem(at: url, to: destination)
                case .move: try fm.moveItem(at: url, to: destination)
                }
            } catch {
                throw GameIngestionError.copyFailed(error.localizedDescription)
            }
            let file = GameFile(gameID: existing.id, role: .primary, fingerprint: hashed.fingerprint, sizeInBytes: hashed.sizeInBytes,
                                originalFileName: fileName, location: fileLocation)
            do {
                try await store.games.insertFile(file)
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
            return .attached(existing)
        }

        let generation = try await store.games.nextGeneration(for: hashed.fingerprint)
        let game = Game(systemID: system,
                        title: title ?? (fileName as NSString).deletingPathExtension,
                        contentFingerprint: hashed.fingerprint,
                        addedAt: clock(), generation: generation)
        let fileLocation = try LibraryLocation.gameFileLocation(gameID: game.id, fileName: fileName)
        let file = GameFile(gameID: game.id, role: .primary, fingerprint: hashed.fingerprint,
                            sizeInBytes: hashed.sizeInBytes, originalFileName: fileName,
                            location: fileLocation)

        let gameDirectory = location.directory(forGame: game.id)
        let destination = location.url(for: fileLocation)
        do {
            try fm.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
            switch transfer {
            case .copy: try fm.copyItem(at: url, to: destination)
            case .move: try fm.moveItem(at: url, to: destination)
            }
        } catch {
            try? fm.removeItem(at: gameDirectory)
            throw GameIngestionError.copyFailed(error.localizedDescription)
        }

        let stored: Game
        do {
            try await store.games.insert(game, files: [file])
            // Return the persisted representation (the store defines timestamp precision).
            guard let persisted = try await store.games.game(id: game.id) else {
                throw LibraryError.storage("game \(game.id) missing right after insert")
            }
            stored = persisted
        } catch {
            try? fm.removeItem(at: gameDirectory)
            if case LibraryError.duplicateContent(let existingID, _) = error,
               let existing = try await store.games.game(id: existingID) {
                // Lost a race with a concurrent ingestion of the same content.
                return .duplicate(existing: existing)
            }
            throw error
        }
        return .inserted(stored)
    }

    /// Removes a game's rows and its managed content, saves and screenshots
    /// (rows first, so a failure can only leave reclaimable orphan files, never
    /// dangling rows). Where the store synchronizes, the repository records
    /// the deletion tombstone in the same transaction (Delete from Library).
    public func remove(gameID: GameID) async throws {
        try await store.games.deleteGame(id: gameID)
        let fm = FileManager.default
        for dir in [location.directory(forGame: gameID), location.savesDirectory(forGame: gameID),
                    location.screenshotsDirectory.appending(path: gameID.description, directoryHint: .isDirectory)] {
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        }
    }

    /// Remove Download: drops the game's file rows and its content directory only.
    /// The game stays in the library with its saves, states and history.
    public func removeLocalContent(gameID: GameID) async throws {
        try await store.games.removeLocalContent(gameID: gameID)
        let dir = location.directory(forGame: gameID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Installs downloaded content for an existing game: verifies the staged
    /// file's size and SHA-256 against `descriptor`, moves it atomically into
    /// a unique path under `Games/<GameID>/`, and inserts the file row. Existing
    /// managed files are never overwritten; a failed row insert removes only
    /// this installation attempt's new file. Returns the committed file row.
    public func installDownloadedContent(gameID: GameID, stagedURL: URL, descriptor: GameContentDescriptor) async throws -> GameFile {
        let fm = FileManager.default
        guard let game = try await store.games.game(id: gameID) else { throw LibraryError.gameNotFound(gameID) }
        guard game.contentFingerprint == descriptor.fingerprint, game.generation == descriptor.generation,
              game.systemID == descriptor.systemID else {
            throw GameIngestionError.copyFailed("content descriptor does not belong to game \(gameID)")
        }
        let hashed = try await hasher.hash(fileAt: stagedURL)
        guard hashed.fingerprint == descriptor.fingerprint, hashed.sizeInBytes == descriptor.sizeInBytes else {
            throw GameIngestionError.contentMismatch(expected: descriptor.fingerprint, actual: hashed.fingerprint)
        }
        let fileName = LibraryLocation.sanitizedFileName(descriptor.fileName)
        // Publication gets a new path even when a previous download/import has
        // the same name. A concurrent primary insert may win the database race;
        // rolling this attempt back must never delete the winner's bytes.
        let managedFileName = "\(UUID().uuidString.lowercased())-\(fileName)"
        let fileLocation = try LibraryLocation.gameFileLocation(gameID: gameID, fileName: managedFileName)
        let destination = location.url(for: fileLocation)
        try fm.createDirectory(at: location.directory(forGame: gameID), withIntermediateDirectories: true)
        try fm.moveItem(at: stagedURL, to: destination)
        let file = GameFile(gameID: gameID, role: .primary, fingerprint: hashed.fingerprint, sizeInBytes: hashed.sizeInBytes,
                            originalFileName: fileName, location: fileLocation)
        do {
            try await store.games.insertFile(file)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        return file
    }

    static func identifySystem(fileExtension: String) throws -> SystemID {
        let candidates = SystemCatalog.systems(forFileExtension: fileExtension)
        switch candidates.count {
        case 0: throw GameIngestionError.unsupportedFile(extension: fileExtension.lowercased())
        case 1: return candidates[0].id
        default: throw GameIngestionError.ambiguousSystem(candidates.map(\.id))
        }
    }
}

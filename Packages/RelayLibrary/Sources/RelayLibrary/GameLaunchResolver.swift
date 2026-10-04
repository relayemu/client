// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  GameLaunchResolver.swift
//  RelayLibrary
//
//  Turns a library `GameID` into everything an emulation session needs to
//  start: the primary file's concrete URL and the core to use. Core choice is
//  "the first registered core that supports the system" — one excellent
//  default per system, no user-facing core selection (spec §2.5, §7.1).

import Foundation
import RelayDomain

public struct ResolvedLaunch: Sendable, Equatable {
    public let game: Game
    public let primaryFile: GameFile
    /// Concrete URL of the primary file on this device.
    public let contentURL: URL
    public let core: EmulatorCoreDescriptor

    public init(game: Game, primaryFile: GameFile, contentURL: URL, core: EmulatorCoreDescriptor) {
        self.game = game
        self.primaryFile = primaryFile
        self.contentURL = contentURL
        self.core = core
    }
}

public enum LaunchResolutionError: Error, Equatable, Sendable, CustomStringConvertible {
    case gameNotFound(GameID)
    case missingPrimaryFile(GameID)
    /// The library row exists but the file is not where the library expects it.
    case contentMissing(GameFileID, URL)
    case noCoreForSystem(SystemID)

    public var description: String {
        switch self {
        case .gameNotFound(let id): return "Game \(id) not found"
        case .missingPrimaryFile(let id): return "Game \(id) has no primary file"
        case .contentMissing(let id, let url): return "Content of file \(id) is missing at \(url.path)"
        case .noCoreForSystem(let s): return "No emulator core available for system \(s)"
        }
    }
}

public struct GameLaunchResolver: Sendable {
    private let store: any LibraryStore
    private let location: LibraryLocation
    private let availableCores: [EmulatorCoreDescriptor]

    public init(store: any LibraryStore, location: LibraryLocation, availableCores: [EmulatorCoreDescriptor]) {
        self.store = store
        self.location = location
        self.availableCores = availableCores
    }

    /// The default core for `system`, or nil when none is registered.
    public func preferredCore(for system: SystemID) -> EmulatorCoreDescriptor? {
        availableCores.first { $0.supports(system) }
    }

    public func resolve(gameID: GameID) async throws -> ResolvedLaunch {
        guard let game = try await store.games.game(id: gameID) else {
            throw LaunchResolutionError.gameNotFound(gameID)
        }
        guard let core = preferredCore(for: game.systemID) else {
            throw LaunchResolutionError.noCoreForSystem(game.systemID)
        }
        let files = try await store.games.files(for: gameID)
        guard let primary = files.first(where: { $0.role == .primary }) else {
            throw LaunchResolutionError.missingPrimaryFile(gameID)
        }
        let url = location.url(for: primary.location)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LaunchResolutionError.contentMissing(primary.id, url)
        }
        let contentURL: URL
        if game.systemID == .playStation {
            guard url.pathExtension.lowercased() == PlayStationDiscPackage.fileExtension else { throw PlayStationImportError.invalidDisc }
            contentURL = try await PlayStationDiscPackage.prepareForLaunch(
                package: url, fingerprint: game.contentFingerprint,
                cache: location.directory(forGame: game.id).appendingPathComponent("Playable", isDirectory: true))
        } else { contentURL = url }
        return ResolvedLaunch(game: game, primaryFile: primary, contentURL: contentURL, core: core)
    }
}

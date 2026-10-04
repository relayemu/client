// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SaveStateManager.swift
//  RelayLibrary
//
//  Save states — snapshots of the emulated machine, bound to a core and its
//  state-compatibility version — with Relay's three kinds and their retention rules:
//
//    auto    Auto Resume: Relay-managed, replaced at every safe point, the last
//            `autoResumeHistory` kept for recovery; never listed in the Saves browser.
//    quick   Quick Save: one convenience slot; the previous one survives as
//            "Previous quick save" for `quickPreviousRetention`, then goes.
//    manual  Saved by the player; append-only; deleted only on request.
//
//  Files: Saves/<GameID>/states/<SaveStateID>.relaystate (SaveStateContainer)
//         Saves/<GameID>/screenshots/<SaveStateID>.png
//  Every write is atomic; the row is inserted only after the file is durable;
//  deletion removes the row first, then the files. Loading validates the
//  compatibility policy (`SaveState.isRestorable(by:)`), the file's own header
//  and its payload fingerprint before any bytes reach the core.
//
//  their origin and the battery revision they were captured with; retention
//  prunes local-origin states only (each device owns its own history); remote
//  states are installed after full validation (`installRemote`).

import Foundation
import RelayDomain
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum SaveStateLoadError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Created by another core or core version; restoring could crash or corrupt.
    case incompatible(SaveState)
    /// The row exists but the file is gone.
    case missing(SaveState)
    /// The file failed validation.
    case corrupt(SaveState, String)

    public var description: String {
        switch self {
        case .incompatible(let s): return "save state \(s.id) was made by \(s.coreID) \(s.coreVersion) (\(s.stateCompatibilityVersion)) and cannot be restored by the running core"
        case .missing(let s): return "save state \(s.id) file is missing"
        case .corrupt(let s, let why): return "save state \(s.id) is corrupt: \(why)"
        }
    }
}

public enum RemoteStateError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidContainer(String)
    case identityMismatch(String)

    public var description: String {
        switch self {
        case .invalidContainer(let s): return "remote save state container is invalid: \(s)"
        case .identityMismatch(let s): return "remote save state does not match its record: \(s)"
        }
    }
}

public struct SaveStateManager: Sendable {
    public static let autoResumeHistory = 3
    public static let quickHistory = 2
    public static let quickPreviousRetention: TimeInterval = 24 * 3600

    private let store: any LibraryStore
    private let location: LibraryLocation
    private let identity: SyncIdentity
    private let atomicFile: AtomicFile
    private let artworkStore: ArtworkStore

    public init(store: any LibraryStore, location: LibraryLocation, artworkStore: ArtworkStore,
                identity: SyncIdentity = SyncIdentity(installationID: InstallationID(), deviceKind: .unknown),
                atomicFile: AtomicFile = AtomicFile()) {
        self.store = store
        self.location = location
        self.artworkStore = artworkStore
        self.identity = identity
        self.atomicFile = atomicFile
    }

    // MARK: Creating

    /// Persists `payload` (the core's state bytes) as a state of `kind`, with an
    /// optional screenshot, then applies the kind's retention rule.
    public func create(kind: SaveState.Kind, game: Game, core: EmulatorCoreDescriptor, payload: Data,
                       screenshot: CGImage? = nil, label: String? = nil,
                       batteryRevisionID: BatteryRevisionID? = nil, now: Date = Date()) async throws -> SaveState {
        let id = SaveStateID()
        let container = try SaveStateContainer(gameID: game.id, contentFingerprint: game.contentFingerprint, core: core, kind: kind, createdAt: now, payload: payload)
        let fileLocation = try LibraryLocation.saveStateLocation(gameID: game.id, stateID: id)
        try atomicFile.write(try container.encoded(), to: location.url(for: fileLocation))
        var screenshotLocation: ContentLocation?
        if let screenshot {
            screenshotLocation = try? artworkStore.storeStateScreenshot(screenshot, for: game.id, stateID: id)
        }
        let state = SaveState(id: id, gameID: game.id, coreID: core.id, coreVersion: core.version,
                              stateCompatibilityVersion: core.stateCompatibilityVersion, kind: kind,
                              createdAt: now, location: fileLocation, screenshotLocation: screenshotLocation,
                              label: label,
                              batteryRevisionID: batteryRevisionID, installationID: identity.installationID,
                              deviceKind: identity.deviceKind, origin: .local, generation: game.generation)
        do {
            try await store.saves.insert(state)
        } catch {
            removeFiles(of: state)
            throw error
        }
        try? await applyRetention(kind: kind, gameID: game.id, now: now)
        return state
    }

    // MARK: Reading

    /// Every state of a game, newest first (all kinds, all origins).
    public func states(for gameID: GameID) async throws -> [SaveState] {
        guard let game = try await store.games.game(id: gameID) else { return [] }
        return try await store.saves.saveStates(for: gameID).filter { $0.gameID == game.id && $0.generation == game.generation }
    }

    /// What the Saves browser shows: the quick slot (current + surviving previous)
    /// and the manual states, newest first. Auto Resume is never listed.
    public func browserStates(for gameID: GameID, now: Date = Date()) async throws -> (quick: [SaveState], manual: [SaveState]) {
        try? await applyRetention(kind: .quick, gameID: gameID, now: now)
        let all = try await states(for: gameID)
        return (all.filter { $0.kind == .quick }, all.filter { $0.kind == .manual })
    }

    /// The newest Auto Resume state, if any (any origin).
    public func latestAutoResume(for gameID: GameID) async throws -> SaveState? {
        try await states(for: gameID).first { $0.kind == .auto }
    }

    /// The newest Auto Resume state that belongs with the game's current battery
    /// progress: captured with `activeRevision` as the head, or — for states
    public func latestAutoResume(for gameID: GameID, activeRevision: BatteryRevisionID?) async throws -> SaveState? {
        try await states(for: gameID).first { state in
            guard state.kind == .auto else { return false }
            if let revision = state.batteryRevisionID { return revision == activeRevision }
            return state.origin == .local
        }
    }

    /// The newest quick save, if any.
    public func latestQuickSave(for gameID: GameID) async throws -> SaveState? {
        try await states(for: gameID).first { $0.kind == .quick }
    }

    /// Validates and returns the payload bytes to hand to the core.
    public func load(_ state: SaveState, game: Game, for core: EmulatorCoreDescriptor) throws -> Data {
        guard state.gameID == game.id, state.generation == game.generation else {
            throw SaveStateLoadError.corrupt(state, "state belongs to another library incarnation")
        }
        guard state.isRestorable(by: core) else { throw SaveStateLoadError.incompatible(state) }
        let url = location.url(for: state.location)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SaveStateLoadError.missing(state) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw SaveStateLoadError.corrupt(state, String(describing: error)) }
        let container: SaveStateContainer
        do { container = try SaveStateContainer.decode(data) } catch { throw SaveStateLoadError.corrupt(state, String(describing: error)) }
        let h = container.header
        guard h.coreID == state.coreID, h.coreVersion == state.coreVersion, h.effectiveCompatibilityVersion == state.stateCompatibilityVersion else {
            throw SaveStateLoadError.corrupt(state, "header core identity does not match the library row")
        }
        if let fingerprint = h.gameFingerprint {
            guard fingerprint == game.contentFingerprint else { throw SaveStateLoadError.corrupt(state, "header names another game") }
        } else {
            guard h.gameID == state.gameID else { throw SaveStateLoadError.corrupt(state, "header identity does not match the library row") }
        }
        guard h.coreID == core.id, h.effectiveCompatibilityVersion == core.stateCompatibilityVersion else { throw SaveStateLoadError.incompatible(state) }
        return container.payload
    }

    // MARK: Remote states

    /// Validates a received container against its record and the local game,
    /// then installs it (and its screenshot) under the canonical locations.
    /// Returns the row to insert; nothing is written unless everything matches.
    public func installRemote(state: SaveState, game: Game, expectedPayloadFingerprint: ContentFingerprint,
                              containerURL: URL, screenshotURL: URL?) throws -> SaveState {
        guard state.gameID == game.id, state.generation == game.generation else {
            throw RemoteStateError.identityMismatch("library incarnation")
        }
        let data: Data
        do { data = try Data(contentsOf: containerURL) } catch { throw RemoteStateError.invalidContainer(String(describing: error)) }
        let container: SaveStateContainer
        do { container = try SaveStateContainer.decode(data) } catch { throw RemoteStateError.invalidContainer(String(describing: error)) }
        let h = container.header
        guard h.payloadFingerprint == expectedPayloadFingerprint else { throw RemoteStateError.identityMismatch("payload fingerprint") }
        guard h.gameFingerprint == game.contentFingerprint else { throw RemoteStateError.identityMismatch("game fingerprint") }
        guard h.coreID == state.coreID, h.coreVersion == state.coreVersion, h.effectiveCompatibilityVersion == state.stateCompatibilityVersion, h.kind == state.kind else {
            throw RemoteStateError.identityMismatch("core or kind")
        }
        let fileLocation = try LibraryLocation.saveStateLocation(gameID: game.id, stateID: state.id)
        try atomicFile.write(data, to: location.url(for: fileLocation))
        var screenshotLocation: ContentLocation?
        if let screenshotURL, let png = try? Data(contentsOf: screenshotURL), !png.isEmpty {
            let loc = try LibraryLocation.stateScreenshotLocation(gameID: game.id, stateID: state.id)
            try atomicFile.write(png, to: location.url(for: loc))
            screenshotLocation = loc
        }
        var installed = state
        installed.location = fileLocation
        installed.screenshotLocation = screenshotLocation
        installed.origin = .remote
        return installed
    }

    // MARK: Deleting

    /// Removes the row, then the state file and its screenshot.
    public func delete(_ state: SaveState) async throws {
        try await store.saves.deleteSaveState(id: state.id)
        removeFiles(of: state)
    }

    /// Removes the files of a state whose row is already gone (remote deletion).
    public func removeFilesOfDeleted(_ state: SaveState) {
        removeFiles(of: state)
    }

    /// Removes every state and screenshot directory of a game (rows cascade with the game).
    public func removeAll(for gameID: GameID) {
        let fm = FileManager.default
        try? fm.removeItem(at: location.saveStatesDirectory(forGame: gameID))
        try? fm.removeItem(at: location.stateScreenshotsDirectory(forGame: gameID))
    }

    private func removeFiles(of state: SaveState) {
        let fm = FileManager.default
        try? fm.removeItem(at: location.url(for: state.location))
        if let shot = state.screenshotLocation { try? fm.removeItem(at: location.url(for: shot)) }
    }

    // MARK: Retention (local-origin states only; each device prunes its own history)

    private func applyRetention(kind: SaveState.Kind, gameID: GameID, now: Date) async throws {
        let ofKind = try await states(for: gameID).filter { $0.kind == kind && $0.origin == .local }   // newest first
        var expired: [SaveState] = []
        switch kind {
        case .auto:
            expired = Array(ofKind.dropFirst(Self.autoResumeHistory))
        case .quick:
            expired = Array(ofKind.dropFirst(Self.quickHistory))
            // The surviving previous quick save is kept for a day only.
            if ofKind.count >= 2, now.timeIntervalSince(ofKind[1].createdAt) > Self.quickPreviousRetention {
                expired.append(ofKind[1])
            }
        case .manual:
            return
        }
        for state in expired { try await delete(state) }
    }
}

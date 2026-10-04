// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LibraryLocation.swift
//  RelayLibrary
//
//  Resolves durable `ContentLocation`s to concrete file URLs on this device
//  and defines the layout of Relay's managed library directory.
//
//    Games/<GameID>/<file name>                 imported game files (one directory per game)
//    Saves/<GameID>/battery/work/<name>.sav     live battery save the core maps and writes
//    Saves/<GameID>/battery/current.sav         canonical battery snapshot (the `Save` row)
//    Saves/<GameID>/battery/previous.sav        the snapshot before that (local rollback only)
//    Saves/<GameID>/battery/revisions/<id>.sav  immutable battery revisions (version graph, synced)
//    Saves/<GameID>/battery/revisions/<id>.png  optional screenshot of a revision
//    Saves/<GameID>/states/<SaveStateID>.relaystate   save states (SaveStateContainer)
//    Saves/<GameID>/screenshots/<SaveStateID>.png     save-state thumbnails
//    Artwork/<GameID>/cover.<ext>               cover artwork from a metadata provider or the user
//    Screenshots/<GameID>/last.png              last frame of the latest local play session (Continue card)
//    Screenshots/<GameID>/sessions/<id>.png     screenshots of sessions received from other devices
//    Staging/<UUID>/…                           in-flight imports; swept on launch (interrupted imports)
//    Sync/Inbox/<UUID>/…                        staged remote assets before validation/installation
//    Sync/…                                     transport state (e.g. CKSyncEngine serialization)
//    relay.sqlite                               the local database (RelayPersistence)

import Foundation
import RelayDomain

public struct LibraryLocation: Sendable, Equatable {
    /// The `ContentLocation.Root.managedLibrary` directory on this device.
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var gamesDirectory: URL { rootURL.appending(path: "Games", directoryHint: .isDirectory) }
    public var savesDirectory: URL { rootURL.appending(path: "Saves", directoryHint: .isDirectory) }
    public var artworkDirectory: URL { rootURL.appending(path: "Artwork", directoryHint: .isDirectory) }
    public var screenshotsDirectory: URL { rootURL.appending(path: "Screenshots", directoryHint: .isDirectory) }
    public var stagingDirectory: URL { rootURL.appending(path: "Staging", directoryHint: .isDirectory) }
    /// Transport state and inbound staging for synchronization.
    public var syncDirectory: URL { rootURL.appending(path: "Sync", directoryHint: .isDirectory) }
    public var syncInboxDirectory: URL { syncDirectory.appending(path: "Inbox", directoryHint: .isDirectory) }
    /// Default location of the local database file.
    public var databaseURL: URL { rootURL.appending(path: "relay.sqlite", directoryHint: .notDirectory) }
    /// Records the metadata-provider revision this library was last backfilled with.
    /// It lives with the library, so another library root or a reset never inherits it.
    public var metadataBackfillMarkerURL: URL { rootURL.appending(path: "metadata-backfill", directoryHint: .notDirectory) }

    /// Canonical location of a game's cover artwork (`ext` without dot, lowercase).
    public static func artworkLocation(gameID: GameID, fileExtension ext: String) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Artwork/\(gameID)/cover.\(ext.lowercased())")
    }

    /// A cover downloaded from Relay's cover mirror. It sits beside, never over,
    /// provider artwork (`cover.*`) and a player's own cover, and is removable as a set.
    public static func catalogCoverLocation(gameID: GameID, format: CoverImage.Format) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Artwork/\(gameID)/catalog.\(format.fileExtension)")
    }

    /// The player's own cover, named by the fingerprint of its normalised bytes.
    public static func customCoverLocation(gameID: GameID, fingerprint: ContentFingerprint) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Artwork/\(gameID)/custom-\(fingerprint.hexDigest).heic")
    }

    public static func isCatalogCover(_ location: ContentLocation) -> Bool {
        location.root == .managedLibrary && location.relativePath.hasPrefix("Artwork/")
            && CoverImage.Format.allCases.contains { location.relativePath.hasSuffix("/catalog.\($0.fileExtension)") }
    }

    /// Canonical location of the latest gameplay screenshot of a game.
    public static func screenshotLocation(gameID: GameID) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Screenshots/\(gameID)/last.png")
    }

    /// Screenshot of a play session received from another device.
    public static func remoteSessionScreenshotLocation(gameID: GameID, sessionID: PlaySessionID) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Screenshots/\(gameID)/sessions/\(sessionID).png")
    }


    /// Everything Relay keeps for a game's progress.
    public func savesDirectory(forGame gameID: GameID) -> URL {
        savesDirectory.appending(path: gameID.description, directoryHint: .isDirectory)
    }

    /// The core's battery-save directory for a game (live copy).
    public func batteryWorkingDirectory(forGame gameID: GameID) -> URL {
        savesDirectory(forGame: gameID).appending(path: "battery/work", directoryHint: .isDirectory)
    }

    public func batteryRevisionsDirectory(forGame gameID: GameID) -> URL {
        savesDirectory(forGame: gameID).appending(path: "battery/revisions", directoryHint: .isDirectory)
    }

    public func saveStatesDirectory(forGame gameID: GameID) -> URL {
        savesDirectory(forGame: gameID).appending(path: "states", directoryHint: .isDirectory)
    }

    public func stateScreenshotsDirectory(forGame gameID: GameID) -> URL {
        savesDirectory(forGame: gameID).appending(path: "screenshots", directoryHint: .isDirectory)
    }

    /// Canonical battery snapshot (`Save.location`).
    public static func batterySaveLocation(gameID: GameID) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Saves/\(gameID)/battery/current.sav")
    }

    /// The battery snapshot before the current one (rollback copy).
    public static func previousBatterySaveLocation(gameID: GameID) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Saves/\(gameID)/battery/previous.sav")
    }

    /// An immutable battery revision (`BatteryRevision.location`).
    public static func batteryRevisionLocation(gameID: GameID, revisionID: BatteryRevisionID) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Saves/\(gameID)/battery/revisions/\(revisionID).sav")
    }

    /// Screenshot taken with a battery revision (`BatteryRevision.screenshotLocation`).
    public static func batteryRevisionScreenshotLocation(gameID: GameID, revisionID: BatteryRevisionID) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Saves/\(gameID)/battery/revisions/\(revisionID).png")
    }

    /// A save-state file (`SaveState.location`).
    public static func saveStateLocation(gameID: GameID, stateID: SaveStateID) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Saves/\(gameID)/states/\(stateID).relaystate")
    }

    /// A save-state screenshot (`SaveState.screenshotLocation`).
    public static func stateScreenshotLocation(gameID: GameID, stateID: SaveStateID) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Saves/\(gameID)/screenshots/\(stateID).png")
    }

    /// A fresh, unique staging directory for one import operation (created on disk).
    public func makeStagingDirectory() throws -> URL {
        let url = stagingDirectory.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh, unique inbox directory for one inbound sync batch or download (created on disk).
    public func makeSyncInboxDirectory() throws -> URL {
        let url = syncInboxDirectory.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes every leftover staging directory (interrupted imports). Returns how many were removed.
    @discardableResult
    public func sweepStaging() -> Int {
        sweep(stagingDirectory)
    }

    /// Removes every leftover inbox directory (interrupted remote applies). Returns how many were removed.
    @discardableResult
    public func sweepSyncInbox() -> Int {
        sweep(syncInboxDirectory)
    }

    private func sweep(_ directory: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for entry in entries where (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        return removed
    }

    /// Concrete URL of `location` on this device.
    public func url(for location: ContentLocation) -> URL {
        switch location.root {
        case .managedLibrary:
            return rootURL.appending(path: location.relativePath, directoryHint: .notDirectory)
        }
    }

    /// Directory holding the files of one game.
    public func directory(forGame gameID: GameID) -> URL {
        gamesDirectory.appending(path: gameID.description, directoryHint: .isDirectory)
    }

    /// Canonical location of an imported game file: `Games/<GameID>/<sanitized name>`.
    public static func gameFileLocation(gameID: GameID, fileName: String) throws -> ContentLocation {
        try ContentLocation(root: .managedLibrary, relativePath: "Games/\(gameID)/\(sanitizedFileName(fileName))")
    }

    /// Makes an imported file name safe to use as a single path component:
    /// keeps the last path component only, replaces path separators, NUL and
    /// control characters, strips leading dots, and falls back to "game".
    public static func sanitizedFileName(_ name: String) -> String {
        var component = name.split(separator: "/").last.map(String.init) ?? ""
        component = String(component.map { c in
            if c == "/" || c == "\\" || c == ":" || c == "\0" { return "_" }
            if let scalar = c.unicodeScalars.first, scalar.value < 0x20 || scalar.value == 0x7f { return "_" }
            return c
        })
        while component.hasPrefix(".") { component.removeFirst() }
        component = component.trimmingCharacters(in: .whitespaces)
        if component.isEmpty || component == ".." { component = "game" }
        if component.count > 255 { component = String(component.suffix(255)) }
        return component
    }

    /// Creates the managed directory layout if needed.
    public func createDirectories() throws {
        let fm = FileManager.default
        for dir in [rootURL, gamesDirectory, savesDirectory, artworkDirectory, screenshotsDirectory, stagingDirectory, syncDirectory, syncInboxDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

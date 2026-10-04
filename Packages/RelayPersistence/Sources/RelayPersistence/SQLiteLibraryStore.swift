// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SQLiteLibraryStore.swift
//  RelayPersistence
//
//  Opens Relay's local library database and exposes the repositories.
//
//  Concurrency: GRDB's `DatabasePool` (on disk, WAL) serialises writes and
//  allows concurrent reads; `DatabaseQueue` backs in-memory stores for tests.
//  Every repository call runs inside `write { }` (one transaction, rolled back
//  on throw) or `read { }`, awaited from the caller's context — never on the
//  main actor's thread.
//
//  Synchronization: repositories record sync intents inside their own
//  transactions when `journaling` is on (the default); `sync` exposes the
//  journal, the identity and the remote-apply transaction.

import Foundation
import GRDB
import RelayDomain
import RelayLibrary

public final class SQLiteLibraryStore: LibraryStore, Sendable {
    /// Current schema version (number of migrations this build knows).
    public static let schemaVersion = Schema.version

    let writer: any DatabaseWriter
    /// Whether local mutations record sync intents (off only for throwaway stores).
    public let journaling: Bool
    /// Time source for tombstones and journal entries (tests inject a fixed clock).
    let now: @Sendable () -> Date

    private init(writer: any DatabaseWriter, deviceKind: DeviceKind, journaling: Bool, clock: @escaping @Sendable () -> Date) throws {
        self.writer = writer
        self.journaling = journaling
        self.now = clock
        try Schema.makeMigrator(deviceKind: deviceKind).migrate(writer)
    }

    /// Opens (creating and migrating as needed) the database file at `url`.
    /// The parent directory is created if missing. `deviceKind` is recorded
    public static func open(at url: URL, deviceKind: DeviceKind = .unknown, journaling: Bool = true,
                            clock: @escaping @Sendable () -> Date = { Date() }) throws -> SQLiteLibraryStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        #if DEBUG
        configuration.publicStatementArguments = true
        #endif
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try SQLiteLibraryStore(writer: pool, deviceKind: deviceKind, journaling: journaling, clock: clock)
    }

    /// A private in-memory database (tests, previews).
    public static func inMemory(deviceKind: DeviceKind = .unknown, journaling: Bool = true,
                                clock: @escaping @Sendable () -> Date = { Date() }) throws -> SQLiteLibraryStore {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try SQLiteLibraryStore(writer: try DatabaseQueue(configuration: configuration), deviceKind: deviceKind, journaling: journaling, clock: clock)
    }

    /// Closes the underlying connections. The store must not be used afterwards.
    public func close() throws {
        try writer.close()
    }

    /// Identifiers of the migrations applied to this database, in order.
    public func appliedMigrations() throws -> [String] {
        try writer.read { db in
            try Schema.makeMigrator().appliedIdentifiers(db).sorted { a, b in
                (Schema.migrationIdentifiers.firstIndex(of: a) ?? .max) < (Schema.migrationIdentifiers.firstIndex(of: b) ?? .max)
            }
        }
    }

    // MARK: LibraryStore

    public var games: any GameRepository { SQLiteGameRepository(writer: writer, journaling: journaling, now: now) }
    public var saves: any SaveRepository { SQLiteSaveRepository(writer: writer, journaling: journaling, now: now) }
    public var playHistory: any PlayHistoryRepository { SQLitePlayHistoryRepository(writer: writer, journaling: journaling, now: now) }
    public var sync: (any SyncStore)? { SQLiteSyncStore(writer: writer) }

    /// The sync side, non-optional for callers that know they hold a SQLite store.
    public var syncStore: any SyncStore { SQLiteSyncStore(writer: writer) }
}

// MARK: Error mapping

extension LibraryError {
    /// Wraps a non-Relay error thrown by GRDB/SQLite; Relay errors pass through.
    static func wrap(_ error: Error) -> Error {
        if error is LibraryError { return error }
        if let dbError = error as? DatabaseError {
            return LibraryError.storage("\(dbError.resultCode.rawValue): \(dbError.message ?? "unknown")")
        }
        return LibraryError.storage(String(describing: error))
    }
}

extension DatabaseWriter {
    /// `write` with Relay error mapping.
    func relayWrite<T: Sendable>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do { return try await write(updates) } catch { throw LibraryError.wrap(error) }
    }

    /// `read` with Relay error mapping.
    func relayRead<T: Sendable>(_ value: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do { return try await read(value) } catch { throw LibraryError.wrap(error) }
    }
}

func gameExists(_ id: GameID, in db: Database) throws -> Bool {
    try GameRecord.exists(db, key: id.description)
}

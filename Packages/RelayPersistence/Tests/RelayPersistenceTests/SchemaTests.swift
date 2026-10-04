// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import GRDB
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class SchemaTests: XCTestCase {
    func testFreshDatabaseGetsAllTablesAndCurrentVersion() throws {
        let store = try SQLiteLibraryStore.inMemory()
        XCTAssertEqual(try store.appliedMigrations(), Schema.migrationIdentifiers)
        XCTAssertEqual(Schema.migrationIdentifiers.count, SQLiteLibraryStore.schemaVersion)
        try store.writer.read { db in
            for table in ["game", "game_file", "save", "save_state", "play_session"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            XCTAssertEqual(try Bool.fetchOne(db, sql: "PRAGMA foreign_keys"), true)
            let indexes = try db.indexes(on: "game_file").map(\.name)
            XCTAssertTrue(indexes.contains("game_file_one_primary"), "\(indexes)")
        }
    }

    func testMigrationIsIdempotentAndAppliesLaterMigrationsToExistingData() throws {
        let url = try Fixtures.temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // v1 database with data.
        let game = Fixtures.game(seed: 1)
        do {
            let store = try SQLiteLibraryStore.open(at: url)
            try store.writer.write { db in
                try GameRecord(game).insert(db)
                try GameFileRecord(Fixtures.primaryFile(for: game)).insert(db)
            }
            try store.close()
        }

        // Re-running the v1 migrator on it is a no-op.
        do {
            let store = try SQLiteLibraryStore.open(at: url)
            XCTAssertEqual(try store.appliedMigrations(), Schema.migrationIdentifiers)
            try store.close()
        }

        // A future migration registered after v1 runs on top and keeps the data.
        var migrator = Schema.makeMigrator()
        migrator.registerMigration("v2-test-only") { db in
            try db.alter(table: "game") { t in t.add(column: "notes", .text) }
        }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try migrator.migrate(pool)
        try pool.read { db in
            XCTAssertEqual(try migrator.appliedIdentifiers(db), Set(Schema.migrationIdentifiers + ["v2-test-only"]))
            XCTAssertEqual(try GameRecord.fetchCount(db), 1)
            XCTAssertEqual(try GameFileRecord.fetchCount(db), 1)
            XCTAssertTrue(try db.columns(in: "game").contains { $0.name == "notes" })
        }
        try pool.close()
    }

    func testOpenCreatesParentDirectory() throws {
        let url = try Fixtures.temporaryDatabaseURL().deletingLastPathComponent()
            .appending(path: "nested/deeper/relay.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let store = try SQLiteLibraryStore.open(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try store.close()
    }
}

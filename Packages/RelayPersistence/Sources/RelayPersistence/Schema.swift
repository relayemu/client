// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Schema.swift
//  RelayPersistence
//
//  The explicit schema of Relay's local library database and its migrations.
//
//  Conventions:
//    - primary keys are Relay entity identifiers stored as lowercase UUID text;
//      SQLite rowids are never exposed (spec: no row ids as domain ids);
//    - timestamps are INTEGER milliseconds since 1970-01-01 UTC (portable,
//      exact arithmetic for durations, trivially ordered);
//    - content fingerprints are stored in their canonical "sha256:<hex>" form;
//    - content locations are stored as (root, relative path) pairs, never
//      absolute paths;
//    - every migration is append-only and registered in `registerMigrations`;
//      never edit a shipped migration.

import Foundation
import GRDB
import RelayDomain

enum Schema {
    /// Schema version = number of registered migrations. Bump when adding one.
    static let version = 10

    /// Identifiers of all migrations, in order.
    static let migrationIdentifiers = ["v1-phase2-library", "v2-phase3-library-ux", "v3-phase4-play", "v4-phase5-sync", "v5-phase8-remote-scopes", "v6-phase8-library-generations", "v7-cover-art-title-catalog", "v8-cover-art-downloads", "v9-cover-art-custom-covers", "v10-cover-art-artwork-journal"]

    static func makeMigrator(upTo count: Int = migrationIdentifiers.count, deviceKind: DeviceKind = .unknown) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerMigrations(into: &migrator, upTo: count, deviceKind: deviceKind)
        return migrator
    }

    /// Registers the first `count` migrations (all by default). Tests use a
    /// smaller count to build databases at an older schema version.
    static func registerMigrations(into migrator: inout DatabaseMigrator, upTo count: Int = migrationIdentifiers.count, deviceKind: DeviceKind = .unknown) {
        guard count >= 1 else { return }
        migrator.registerMigration(migrationIdentifiers[0]) { db in
            try db.create(table: "game") { t in
                t.primaryKey("id", .text)
                t.column("system_id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("content_fingerprint", .text).notNull().unique()
                t.column("added_at", .integer).notNull()
            }

            try db.create(table: "game_file") { t in
                t.primaryKey("id", .text)
                t.column("game_id", .text).notNull().references("game", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("size_in_bytes", .integer).notNull()
                t.column("original_file_name", .text).notNull()
                t.column("location_root", .text).notNull()
                t.column("location_path", .text).notNull()
                t.uniqueKey(["location_root", "location_path"])
            }
            // Exactly one primary file per game (partial unique index).
            try db.execute(sql: "CREATE UNIQUE INDEX game_file_one_primary ON game_file(game_id) WHERE role = 'primary'")
            try db.create(indexOn: "game_file", columns: ["fingerprint"])

            try db.create(table: "save") { t in
                t.primaryKey("id", .text)
                t.column("game_id", .text).notNull().references("game", onDelete: .cascade)
                t.column("location_root", .text).notNull()
                t.column("location_path", .text).notNull()
                t.column("size_in_bytes", .integer).notNull()
                t.column("fingerprint", .text)
                t.column("updated_at", .integer).notNull()
                t.uniqueKey(["location_root", "location_path"])
            }
            try db.create(indexOn: "save", columns: ["game_id", "updated_at"])

            try db.create(table: "save_state") { t in
                t.primaryKey("id", .text)
                t.column("game_id", .text).notNull().references("game", onDelete: .cascade)
                t.column("core_id", .text).notNull()
                t.column("core_version", .text).notNull()
                t.column("format_version", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("location_root", .text).notNull()
                t.column("location_path", .text).notNull()
                t.column("screenshot_root", .text)
                t.column("screenshot_path", .text)
                t.column("label", .text)
                t.uniqueKey(["location_root", "location_path"])
            }
            try db.create(indexOn: "save_state", columns: ["game_id", "created_at"])

            try db.create(table: "play_session") { t in
                t.primaryKey("id", .text)
                t.column("game_id", .text).notNull().references("game", onDelete: .cascade)
                t.column("core_id", .text).notNull()
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
                t.check(sql: "ended_at IS NULL OR ended_at >= started_at")
            }
            try db.create(indexOn: "play_session", columns: ["game_id", "started_at"])
            try db.create(indexOn: "play_session", columns: ["started_at"])
        }

        guard count >= 2 else { return }
        migrator.registerMigration(migrationIdentifiers[1]) { db in
            try db.alter(table: "game") { t in
                t.add(column: "is_favorite", .boolean).notNull().defaults(to: false)
            }
            try db.create(indexOn: "game", columns: ["added_at"])

            try db.create(table: "game_metadata") { t in
                t.primaryKey("game_id", .text).references("game", onDelete: .cascade)
                t.column("alternate_titles", .text).notNull().defaults(to: "[]")   // JSON array of strings
                t.column("developer", .text)
                t.column("publisher", .text)
                t.column("release_year", .integer)
                t.column("genre", .text)
                t.column("region", .text)
                t.column("summary", .text)
                t.column("artwork_root", .text)
                t.column("artwork_path", .text)
                t.column("source", .text).notNull()
                t.column("matched_at", .integer).notNull()
            }

            try db.alter(table: "play_session") { t in
                t.add(column: "screenshot_root", .text)
                t.add(column: "screenshot_path", .text)
            }
        }

        guard count >= 3 else { return }
        migrator.registerMigration(migrationIdentifiers[2]) { db in
            try db.alter(table: "play_session") { t in
                t.add(column: "paused_ms", .integer).notNull().defaults(to: 0)
            }
        }

        guard count >= 4 else { return }
        // battery revision graph, the durable sync journal, tombstones, deferred
        // remote records, cloud content descriptors.
        migrator.registerMigration(migrationIdentifiers[3]) { db in
            let installation = InstallationID().description
            try db.create(table: "sync_meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
            try db.execute(sql: "INSERT INTO sync_meta (key, value) VALUES ('installation_id', ?), ('device_kind', ?)",
                           arguments: [installation, deviceKind.rawValue])

            try db.alter(table: "game") { t in
                t.add(column: "updated_at", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "UPDATE game SET updated_at = added_at")

            try db.alter(table: "play_session") { t in
                t.add(column: "installation_id", .text)
                t.add(column: "device_kind", .text).notNull().defaults(to: DeviceKind.unknown.rawValue)
                t.add(column: "origin", .text).notNull().defaults(to: SyncOrigin.local.rawValue)
            }
            try db.execute(sql: "UPDATE play_session SET installation_id = ?, device_kind = ?", arguments: [installation, deviceKind.rawValue])

            try db.alter(table: "save_state") { t in
                t.add(column: "state_compat_version", .text).notNull().defaults(to: "")
                t.add(column: "battery_revision_id", .text)
                t.add(column: "installation_id", .text)
                t.add(column: "device_kind", .text).notNull().defaults(to: DeviceKind.unknown.rawValue)
                t.add(column: "origin", .text).notNull().defaults(to: SyncOrigin.local.rawValue)
            }
            try db.execute(sql: "UPDATE save_state SET state_compat_version = core_version, installation_id = ?, device_kind = ?",
                           arguments: [installation, deviceKind.rawValue])

            try db.create(table: "battery_revision") { t in
                t.primaryKey("id", .text)
                t.column("game_id", .text).notNull().references("game", onDelete: .cascade)
                t.column("parent_ids", .text).notNull().defaults(to: "[]")   // JSON array of revision ids
                t.column("created_at", .integer).notNull()
                t.column("data_fingerprint", .text).notNull()
                t.column("size_in_bytes", .integer).notNull()
                t.column("installation_id", .text).notNull()
                t.column("device_kind", .text).notNull()
                t.column("location_root", .text).notNull()
                t.column("location_path", .text).notNull()
                t.column("screenshot_root", .text)
                t.column("screenshot_path", .text)
                t.column("origin", .text).notNull()
                t.uniqueKey(["location_root", "location_path"])
            }
            try db.create(indexOn: "battery_revision", columns: ["game_id", "created_at"])

            try db.create(table: "battery_head") { t in
                t.primaryKey("game_id", .text).references("game", onDelete: .cascade)
                t.column("revision_id", .text).notNull().references("battery_revision", onDelete: .cascade)
            }

            try db.create(table: "sync_journal") { t in
                t.autoIncrementedPrimaryKey("sequence")
                t.column("kind", .text).notNull()
                t.column("key", .text).notNull()
                t.column("operation", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
                t.uniqueKey(["kind", "key", "operation"])
            }

            try db.create(table: "sync_tombstone") { t in
                t.column("target_kind", .text).notNull()
                t.column("target_key", .text).notNull()
                t.column("deleted_at", .integer).notNull()
                t.column("installation_id", .text).notNull()
                t.primaryKey(["target_kind", "target_key"])
            }

            try db.create(table: "sync_deferred") { t in
                t.primaryKey("key", .text)
                t.column("kind", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("reason", .text).notNull()
                t.column("received_at", .integer).notNull()
            }

            try db.create(table: "game_content") { t in
                t.primaryKey("fingerprint", .text)
                t.column("size_in_bytes", .integer).notNull()
                t.column("file_name", .text).notNull()
                t.column("system_id", .text).notNull()
                t.column("parts", .text).notNull().defaults(to: "[]")   // JSON array of parts
                t.column("uploaded_at", .integer).notNull()
            }
        }

        guard count >= 5 else { return }
        // Preserve the existing CloudKit inbox/content index while allowing
        // identical logical keys in independent remote accounts.
        migrator.registerMigration(migrationIdentifiers[4]) { db in
            try db.rename(table: "sync_deferred", to: "sync_deferred_v4")
            try db.create(table: "sync_deferred") { t in
                t.column("remote_scope", .text).notNull().defaults(to: "cloudkit")
                t.column("key", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("reason", .text).notNull()
                t.column("received_at", .integer).notNull()
                t.primaryKey(["remote_scope", "key"])
            }
            try db.execute(sql: "INSERT INTO sync_deferred SELECT 'cloudkit', key, kind, payload, reason, received_at FROM sync_deferred_v4")
            try db.drop(table: "sync_deferred_v4")
            try db.rename(table: "game_content", to: "game_content_v4")
            try db.create(table: "game_content") { t in
                t.column("remote_scope", .text).notNull().defaults(to: "cloudkit")
                t.column("fingerprint", .text).notNull()
                t.column("size_in_bytes", .integer).notNull()
                t.column("file_name", .text).notNull()
                t.column("system_id", .text).notNull()
                t.column("parts", .text).notNull().defaults(to: "[]")
                t.column("uploaded_at", .integer).notNull()
                t.primaryKey(["remote_scope", "fingerprint"])
            }
            try db.execute(sql: "INSERT INTO game_content SELECT 'cloudkit', fingerprint, size_in_bytes, file_name, system_id, parts, uploaded_at FROM game_content_v4")
            try db.drop(table: "game_content_v4")
        }

        guard count >= 6 else { return }
        migrator.registerMigration(migrationIdentifiers[5]) { db in
            for table in ["game", "battery_revision", "save_state", "play_session", "game_content"] {
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN generation INTEGER NOT NULL DEFAULT 0 CHECK (generation BETWEEN 0 AND 2147483647)")
            }
            try db.create(table: "sync_game_retirement") { t in
                t.primaryKey("fingerprint", .text)
                t.column("retired_through", .integer).notNull()
                t.check(sql: "retired_through BETWEEN 0 AND 2147483647")
            }
            try db.rename(table: "sync_tombstone", to: "sync_tombstone_v5")
            try db.create(table: "sync_tombstone") { t in
                t.column("target_kind", .text).notNull()
                t.column("target_key", .text).notNull()
                t.column("generation", .integer).notNull().defaults(to: 0)
                t.column("game_fingerprint", .text)
                t.column("deleted_at", .integer).notNull()
                t.column("installation_id", .text).notNull()
                t.primaryKey(["target_kind", "target_key", "generation"])
                t.check(sql: "generation BETWEEN 0 AND 2147483647")
            }
            try db.execute(sql: """
                INSERT INTO sync_tombstone
                SELECT target_kind, target_key, 0, CASE WHEN target_kind = 'game' THEN target_key ELSE NULL END,
                       deleted_at, installation_id FROM sync_tombstone_v5
                """)
            try db.drop(table: "sync_tombstone_v5")
            try db.execute(sql: "INSERT INTO sync_game_retirement SELECT target_key, 0 FROM sync_tombstone WHERE target_kind = 'game'")
            // A surviving game alongside an old tombstone is the old model's
            // explicit reimport. Its FK-owned history survives as generation 1.
            try db.execute(sql: "UPDATE game SET generation = 1 WHERE content_fingerprint IN (SELECT fingerprint FROM sync_game_retirement)")
            for table in ["battery_revision", "save_state", "play_session"] {
                try db.execute(sql: "UPDATE \(table) SET generation = COALESCE((SELECT generation FROM game WHERE game.id = \(table).game_id), 0)")
            }
            // Old availability describes only initial membership; never claim
            // an old remote upload belongs to a surviving reimport.
            try db.execute(sql: "DELETE FROM game_content WHERE fingerprint IN (SELECT fingerprint FROM sync_game_retirement)")
            try db.execute(sql: """
                UPDATE sync_journal SET key = key || '@1'
                WHERE operation = 'upsert' AND kind IN ('gameEntry', 'contentIndex', 'gameContent')
                  AND key IN (SELECT content_fingerprint FROM game WHERE generation = 1)
                """)
            // Every queued legacy state deletion gains permanent suppression.
            try db.execute(sql: """
                INSERT OR IGNORE INTO sync_tombstone (target_kind, target_key, generation, deleted_at, installation_id)
                SELECT 'state', key, 0, created_at, (SELECT value FROM sync_meta WHERE key = 'installation_id')
                FROM sync_journal WHERE kind = 'saveState' AND operation = 'delete'
                """)
            try db.execute(sql: """
                UPDATE OR IGNORE sync_journal SET kind = 'tombstone', key = 'state:' || key, operation = 'upsert'
                WHERE kind = 'saveState' AND operation = 'delete'
                """)
            try db.execute(sql: "DELETE FROM sync_journal WHERE kind = 'saveState' AND operation = 'delete'")
            try db.execute(sql: "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('library.generation.schema', '2')")
        }

        guard count >= 7 else { return }
        // Cover art (2026-09-27): the catalog's cover key, and lookup keys cached
        // per content so a catalog update never rereads game files. Local only.
        migrator.registerMigration(migrationIdentifiers[6]) { db in
            try db.alter(table: "game_metadata") { t in t.add(column: "cover_key", .text) }
            try db.create(table: "content_lookup") { t in
                t.primaryKey("fingerprint", .text)
                t.column("sha1", .text).notNull()
                t.column("headerless_sha1", .text)
                t.column("disc_serial", .text)
            }
        }

        guard count >= 8 else { return }
        // Cover download (2026-09-29): when the cover mirror last had no usable
        // cover for a key, so it is not asked again for a while. Local only.
        migrator.registerMigration(migrationIdentifiers[7]) { db in
            try db.create(table: "cover_miss") { t in
                t.primaryKey("cover_key", .text)
                t.column("missed_at", .integer).notNull()
            }
        }

        guard count >= 9 else { return }
        // Custom covers (2026-09-29): the player's cover per game, or its reset
        // (NULL fingerprint), last writer wins. Separate from provider-owned
        // game_metadata, which a catalog pass replaces whole.
        migrator.registerMigration(migrationIdentifiers[8]) { db in
            try db.create(table: "custom_cover") { t in
                t.primaryKey("game_id", .text).references("game", onDelete: .cascade)
                t.column("fingerprint", .text)
                t.column("size_in_bytes", .integer).notNull().defaults(to: 0)
                t.column("updated_at", .integer).notNull()
            }
        }

        guard count >= 10 else { return }
        // Custom-cover sync (2026-09-30): covers chosen before sync existed get
        // their sync intent once. A reset before sync has nothing to clear remotely.
        migrator.registerMigration(migrationIdentifiers[9]) { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO sync_journal (kind, key, operation, created_at)
                SELECT 'artwork',
                       CASE WHEN g.generation = 0 THEN g.content_fingerprint ELSE g.content_fingerprint || '@' || g.generation END,
                       'upsert', c.updated_at
                FROM custom_cover c JOIN game g ON g.id = c.game_id
                WHERE c.fingerprint IS NOT NULL
                ORDER BY c.updated_at
                """)
        }
    }
}

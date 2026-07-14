import Foundation
@preconcurrency import GRDB

/// Schema for favorite-update tracking owned by `FavoriteUpdateStore`:
/// per-target check baselines, detected-update events, run snapshots, and
/// notification filters. Runtime task state, so it lives in GRDB rather than
/// app settings (which sync over WebDAV) — and unlike the UserDefaults blob
/// it replaced, rows are written individually and the manga-directory rename
/// cascade can join `MangaDirectoryStore`'s transaction.
enum FavoriteUpdateDatabaseSchema: DatabaseSchemaModule {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("favorite_update.v1") { db in
            try db.create(table: "favorite_update_tracked_targets") { table in
                table.column("target_id", .text).primaryKey(onConflict: .replace)
                table.column("target_json", .text).notNull()
            }

            try db.create(table: "favorite_update_events") { table in
                table.column("id", .text).primaryKey(onConflict: .replace)
                // Promoted from event_json for the queries below; kept in sync
                // by every event write.
                table.column("target_id", .text).notNull()
                table.column("detected_at", .double).notNull()
                table.column("dismissed_at", .double)
                table.column("event_json", .text).notNull()
            }
            // Serves activeEvents: dismissed_at IS NULL ORDER BY detected_at DESC.
            try db.create(index: "favorite_update_events_active_idx", on: "favorite_update_events", columns: ["dismissed_at", "detected_at"])
            // Serves insertEvent's replace-per-target delete and the rename cascade.
            try db.create(index: "favorite_update_events_target_idx", on: "favorite_update_events", columns: ["target_id"])

            try db.create(table: "favorite_update_runs") { table in
                table.column("run_id", .text).primaryKey(onConflict: .replace)
                table.column("updated_at", .double).notNull()
                table.column("run_json", .text).notNull()
            }
            try db.create(index: "favorite_update_runs_updated_idx", on: "favorite_update_runs", columns: ["updated_at"])

            try db.create(table: "favorite_update_fid_filters") { table in
                table.column("fid", .text).primaryKey(onConflict: .replace)
                table.column("manual_order", .integer).notNull()
                table.column("filter_json", .text).notNull()
            }

            try db.create(table: "favorite_update_category_filters") { table in
                table.column("category_id", .text).primaryKey(onConflict: .replace)
                table.column("manual_order", .integer).notNull()
                table.column("filter_json", .text).notNull()
            }
        }
    }

    static func erase(in db: Database) throws {
        try db.execute(sql: "DELETE FROM favorite_update_events")
        try db.execute(sql: "DELETE FROM favorite_update_tracked_targets")
        try db.execute(sql: "DELETE FROM favorite_update_runs")
        try db.execute(sql: "DELETE FROM favorite_update_fid_filters")
        try db.execute(sql: "DELETE FROM favorite_update_category_filters")
    }
}

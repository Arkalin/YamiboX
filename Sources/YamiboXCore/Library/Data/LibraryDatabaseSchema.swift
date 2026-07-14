import Foundation
@preconcurrency import GRDB

/// Schema for the local favorite library owned by `FavoriteLibraryStore`.
enum LibraryDatabaseSchema: DatabaseSchemaModule {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("library.v1") { db in
            // The favorite library is a document: every consumer loads and saves
            // it whole (WebDAV sync, remote sync, the organizer all operate on
            // the full `FavoriteLibraryDocument`), and no query ever addressed
            // individual rows. One JSON row replaces the seven relational
            // tables that were rewritten in full on every save.
            try db.create(table: "favorite_library_document") { table in
                table.column("id", .integer).primaryKey(onConflict: .replace).check { $0 == 1 }
                table.column("document_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }
        }

        migrator.registerMigration("library.v2.content-cover") { db in
            // Covers are content metadata, deliberately not part of the
            // favorites document: they outlive un-favoriting and directory
            // deletion.
            try db.create(table: "content_cover") { table in
                table.column("target_type", .text).notNull()
                table.column("target_id", .text).notNull()
                table.column("automatic_url", .text)
                table.column("manual_url", .text)
                table.column("dynamic_enabled", .boolean).notNull()
                // User override that suppresses both cover URLs in favor of
                // the text placeholder cover.
                table.column("text_cover_forced", .boolean).notNull().defaults(to: false)
                table.column("updated_at", .double).notNull()
                table.primaryKey(["target_type", "target_id"], onConflict: .replace)
            }
        }

        migrator.registerMigration("library.v3.sync-runs") { db in
            // Yamibo sync run snapshots: runtime task state, so it lives in
            // GRDB rather than app settings (which sync over WebDAV).
            try db.create(table: "favorite_sync_runs") { table in
                table.column("run_id", .text).primaryKey(onConflict: .replace)
                table.column("status", .text).notNull()
                table.column("snapshot_json", .text).notNull()
                table.column("started_at", .double).notNull()
                table.column("updated_at", .double).notNull()
            }
            try db.create(index: "favorite_sync_runs_updated_idx", on: "favorite_sync_runs", columns: ["updated_at"])
        }
    }

    static func erase(in db: Database) throws {
        try deleteAllRows(in: db)
        try db.execute(sql: "DELETE FROM content_cover")
        try db.execute(sql: "DELETE FROM favorite_sync_runs")
    }

    /// Deletes the favorites document. Covers are intentionally excluded:
    /// clearing the library must not erase content metadata.
    static func deleteAllRows(in db: Database) throws {
        try db.execute(sql: "DELETE FROM favorite_library_document")
    }
}

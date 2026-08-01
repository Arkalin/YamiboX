import Foundation
@preconcurrency import GRDB

/// Schema for the local Bookmark Library owned by `BookmarkStore`.
///
/// Deliberately a separate table from `like_items` rather than a third `kind`
/// on it: a bookmark's upsert is an idempotent per-position toggle while a Like
/// Item appends and merges overlapping ranges, and `excerpt_text` aside, every
/// Like column (`source_image_url`, and later `style` / `note`) is dead weight
/// on a bookmark.
enum BookmarkDatabaseSchema: DatabaseSchemaModule {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("bookmark.v1") { db in
            try db.create(table: "bookmarks") { table in
                table.column("id", .text).primaryKey(onConflict: .replace)
                table.column("work_kind", .text).notNull()
                table.column("work_id", .text).notNull()
                table.column("anchor_json", .text).notNull()
                table.column("excerpt_text", .text)
                // Persisted "book order" position; see `ReaderAnnotationSortKey`.
                table.column("sort_key", .integer).notNull().defaults(to: 0)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
                // Tombstone for WebDAV sync, same contract as `like_items`.
                table.column("deleted_at", .double)
            }
            try db.create(index: "bookmarks_work_idx", on: "bookmarks", columns: ["work_kind", "work_id"])
        }
    }

    static func erase(in db: Database) throws {
        try db.execute(sql: "DELETE FROM bookmarks")
    }
}

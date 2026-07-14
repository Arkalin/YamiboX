import Foundation
@preconcurrency import GRDB

/// Schema for the local Like Library owned by `LikeStore`. Independent of
/// the favorite library document: liking never requires favoriting.
enum LikeDatabaseSchema: DatabaseSchemaModule {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("like.v1") { db in
            try db.create(table: "like_items") { table in
                table.column("id", .text).primaryKey(onConflict: .replace)
                table.column("work_kind", .text).notNull()
                table.column("work_id", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("excerpt_text", .text)
                table.column("source_image_url", .text)
                table.column("anchor_json", .text).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
            }
            try db.create(index: "like_items_work_idx", on: "like_items", columns: ["work_kind", "work_id"])
        }

        // Soft-delete tombstone for WebDAV sync (ADR-0049): deleting a Like Item locally
        // must not physically remove its row, or merging with a stale remote snapshot
        // would resurrect it.
        migrator.registerMigration("like.v2.tombstones") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "deleted_at", .double)
            }
        }
    }

    static func erase(in db: Database) throws {
        try db.execute(sql: "DELETE FROM like_items")
    }
}

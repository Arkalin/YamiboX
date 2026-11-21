import Foundation
@preconcurrency import GRDB

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

        migrator.registerMigration("like.v2.tombstones") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "deleted_at", .double)
            }
        }

        migrator.registerMigration("like.v3.style") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "style", .text).notNull().defaults(to: LikeStyle.default.rawValue)
            }
        }

        migrator.registerMigration("like.v4.note") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "note", .text)
            }
        }

        migrator.registerMigration("like.v5.sort_key") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "sort_key", .integer).notNull().defaults(to: 0)
                table.add(column: "chapter_ordinal", .integer)
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, anchor_json FROM like_items")
            for row in rows {
                guard let data = (row["anchor_json"] as String).data(using: .utf8),
                      let anchor = try? JSONDecoder().decode(LikeAnchorPayload.self, from: data) else {
                    continue
                }
                try db.execute(
                    sql: "UPDATE like_items SET sort_key = ? WHERE id = ?",
                    arguments: [LikeSortKey.of(anchor, chapterOrdinal: nil), row["id"] as String]
                )
            }
        }

        migrator.registerMigration("like.v6.excerpt_context") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "excerpt_prefix", .text)
                table.add(column: "excerpt_suffix", .text)
            }
        }
        migrator.registerMigration("like.v7.sync-deletions") { db in
            try SyncDeletionState.migrateSoftDeletions(from: "like_items", to: "like_sync_state", in: db)
        }
        migrator.registerMigration("like.v8.chapter-title") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "chapter_title", .text)
            }
        }
    }

    static func erase(in db: Database) throws {
        try db.execute(sql: "DELETE FROM like_items")
        try db.execute(sql: "DELETE FROM like_sync_state")
    }
}

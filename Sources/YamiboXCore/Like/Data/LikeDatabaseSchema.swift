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

        // Highlight style. Every pre-existing row becomes yellow, which is
        // lossless: the reader only ever painted highlights in yellow before
        // styles existed.
        migrator.registerMigration("like.v3.style") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "style", .text).notNull().defaults(to: LikeStyle.default.rawValue)
            }
        }

        // Notes. Nullable rather than defaulted-empty so "has a note" stays a
        // single NULL check in SQL as well as in Swift.
        migrator.registerMigration("like.v4.note") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "note", .text)
            }
        }

        // Book-order sorting. `chapter_ordinal` is NULL until a reader session
        // has actually laid out the forum page the annotation lives on — see
        // `LikeStore.resolveChapterOrdinals`. Until then the key orders by
        // (view, segment occurrence, offset), which is exact except when one
        // forum page holds several posts.
        //
        // Both columns are local derived state and never travel in the WebDAV
        // payload: each device recomputes them from the anchor it already has.
        migrator.registerMigration("like.v5.sort_key") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "sort_key", .integer).notNull().defaults(to: 0)
                table.add(column: "chapter_ordinal", .integer)
            }
            // Backfill in Swift rather than SQL: the position lives inside the
            // anchor's JSON blob, which SQLite has no business parsing.
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

        // Clause context around the excerpt, for Apple Books-style list rows.
        // Local derived state like the sort key: never in the WebDAV payload,
        // NULL until the device that displays the item has the chapter text in
        // hand — at capture for new items, at next reader layout for the rest
        // (`LikeStore.resolveExcerptContexts`). No SQL backfill is possible:
        // the surrounding text isn't in this database at all.
        migrator.registerMigration("like.v6.excerpt_context") { db in
            try db.alter(table: "like_items") { table in
                table.add(column: "excerpt_prefix", .text)
                table.add(column: "excerpt_suffix", .text)
            }
        }
    }

    static func erase(in db: Database) throws {
        try db.execute(sql: "DELETE FROM like_items")
    }
}

import Foundation
@preconcurrency import GRDB

/// Schema for the browsing-history timeline owned by `BrowsingHistoryStore`.
///
/// Deliberately independent of `reading_progress` (browsing-history decision
/// #4): history rows are display metadata with their own retention policy
/// (2000-row cap), while resume positions stay in the reader schema. This
/// also deliberately re-introduces a history table after ADR-0031 declined
/// to port Android's `ReadingHistory` — 0031 rejected a history table as the
/// *resume-position* store, and this table never carries resume state.
enum BrowsingHistoryDatabaseSchema: DatabaseSchemaModule {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("history.v1") { db in
            try db.create(table: "browsing_history") { table in
                table.column("id", .text).primaryKey(onConflict: .replace)
                table.column("target_kind", .text).notNull()
                table.column("thread_id", .text)
                table.column("manga_id", .text)
                table.column("clean_book_name", .text)
                table.column("category", .text).notNull()
                table.column("title", .text).notNull()
                table.column("forum_id", .text)
                table.column("author_id", .text)
                table.column("page_index", .integer)
                table.column("page_count", .integer)
                table.column("chapter_title", .text)
                table.column("chapter_thread_id", .text)
                table.column("last_visit_time", .double).notNull()
            }
            try db.create(index: "browsing_history_last_visit_idx", on: "browsing_history", columns: ["last_visit_time"])
            try db.create(index: "browsing_history_thread_idx", on: "browsing_history", columns: ["thread_id"])
            try db.create(index: "browsing_history_category_visit_idx", on: "browsing_history", columns: ["category", "last_visit_time"])
        }
    }

    static func erase(in db: Database) throws {
        try db.execute(sql: "DELETE FROM browsing_history")
    }
}

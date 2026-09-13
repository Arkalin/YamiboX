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
        migrator.registerMigration("history.v2.source") { db in
            try db.alter(table: "browsing_history") { table in
                table.add(column: "last_visited_thread_id", .text)
                table.add(column: "last_visited_thread_title", .text)
            }
        }
        migrator.registerMigration("history.v3.webdav") { db in
            for table in ["browsing_history_sync_state", "browsing_history_local_deletions"] {
                if try !db.tableExists(table) {
                    try SyncDeletionState.createTable(table, in: db)
                }
            }
            let deletions = try SyncDeletionState.load(from: "browsing_history_sync_state", in: db)
            var records = try BrowsingHistoryStore.snapshotEntries(in: db).map(BrowsingHistorySyncRecord.init)
            // The earlier sync-facts migration used the same table names but
            // stored complete history entries. Decode before replacing anything;
            // GRDB rolls back the entire migration if conversion fails.
            if try db.tableExists("browsing_history_sync_records") {
                let columns = Set(try db.columns(in: "browsing_history_sync_records").map(\.name))
                if columns.contains("payload") {
                    records += try Data.fetchAll(db, sql: "SELECT payload FROM browsing_history_sync_records").map {
                        BrowsingHistorySyncRecord(try JSONDecoder().decode(BrowsingHistoryEntry.self, from: $0))
                    }
                } else {
                    records += try BrowsingHistorySyncRecord.load(in: db)
                }
                try db.drop(table: "browsing_history_sync_records")
            }
            try db.create(table: "browsing_history_sync_records") { table in
                table.column("id", .text).primaryKey()
                table.column("record", .blob).notNull()
                table.column("last_visit_time", .double).notNull()
            }
            try db.create(index: "browsing_history_sync_visit_idx", on: "browsing_history_sync_records", columns: ["last_visit_time"])
            let payload = try BrowsingHistoryWebDAVPayload(updatedAt: .distantPast, records: records, deletions: deletions).merging(nil)
            try BrowsingHistorySyncRecord.save(payload.records, in: db)
        }
    }

    static func erase(in db: Database) throws {
        try db.execute(sql: "DELETE FROM browsing_history")
        try db.execute(sql: "DELETE FROM browsing_history_sync_records")
        try db.execute(sql: "DELETE FROM browsing_history_sync_state")
        try db.execute(sql: "DELETE FROM browsing_history_local_deletions")
    }
}

import Foundation
@preconcurrency import GRDB

/// Schema for reader-owned persistence: reading progress (`ReadingProgressStore`),
/// manga directories (`MangaDirectoryStore`), and the offline cache (`OfflineCacheStore`).
enum ReaderDatabaseSchema: DatabaseSchemaModule {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("reader.v1") { db in
            try db.create(table: "reading_progress") { table in
                table.column("id", .text).primaryKey(onConflict: .replace)
                table.column("target_kind", .text).notNull()
                table.column("thread_id", .text)
                table.column("manga_id", .text)
                table.column("clean_book_name", .text)
                table.column("kind", .text).notNull()
                table.column("updated_at", .double).notNull()
                table.column("last_read_at", .double)
                table.column("novel_last_view", .integer)
                table.column("novel_last_chapter", .text)
                table.column("novel_author_id", .text)
                table.column("novel_resume_point_json", .text)
                table.column("novel_max_view", .integer)
                table.column("novel_document_surface_progress_percent", .integer)
                table.column("manga_chapter_thread_id", .text)
                table.column("manga_chapter_view", .integer)
                table.column("manga_last_chapter", .text)
                table.column("manga_page_index", .integer)
                table.column("manga_page_count", .integer)
            }
            try db.create(index: "reading_progress_thread_idx", on: "reading_progress", columns: ["thread_id"])
            // Serves the directory-rename retarget scan (MangaDirectoryStore).
            try db.create(index: "reading_progress_target_book_idx", on: "reading_progress", columns: ["target_kind", "clean_book_name"])
            try db.create(index: "reading_progress_manga_chapter_idx", on: "reading_progress", columns: ["manga_chapter_thread_id"])

            try db.create(table: "manga_directories") { table in
                table.column("clean_book_name", .text).primaryKey(onConflict: .replace)
                table.column("strategy", .text).notNull()
                table.column("source_key", .text).notNull()
                table.column("last_updated_at", .double)
                table.column("search_keyword", .text)
            }

            try db.create(table: "manga_directory_chapters") { table in
                table.column("directory_name", .text).notNull().references("manga_directories", onDelete: .cascade)
                table.column("tid", .text).notNull()
                table.column("view", .integer).notNull()
                table.column("raw_title", .text).notNull()
                table.column("chapter_number", .double).notNull()
                table.column("author_uid", .text)
                table.column("author_name", .text)
                table.column("group_index", .integer).notNull()
                table.column("publish_time", .double)
                table.column("manual_order", .integer).notNull()
                table.primaryKey(["directory_name", "tid"], onConflict: .replace)
            }
            try db.create(index: "manga_directory_chapters_tid_idx", on: "manga_directory_chapters", columns: ["tid"])
            try db.create(index: "manga_directory_chapters_directory_order_idx", on: "manga_directory_chapters", columns: ["directory_name", "manual_order"])

            try db.create(table: "offline_cache_manga_entries") { table in
                table.column("owner_name", .text).notNull()
                table.column("tid", .text).notNull()
                table.column("chapter_title", .text).notNull()
                table.column("source_page_file_name", .text)
                table.column("source_page_schema_version", .integer)
                table.column("source_page_fingerprint", .text)
                table.column("byte_count", .integer).notNull()
                table.column("created_at", .double).notNull()
                table.primaryKey(["owner_name", "tid"], onConflict: .replace)
            }

            try db.create(table: "offline_cache_novel_entries") { table in
                table.column("owner_name", .text).notNull()
                table.column("owner_title", .text).notNull()
                table.column("entry_key", .text).notNull()
                table.column("title", .text).notNull()
                table.column("thread_id", .text).notNull()
                table.column("view", .integer).notNull()
                table.column("author_id", .text)
                table.column("document_json", .text).notNull()
                table.column("source_page_file_name", .text)
                table.column("source_page_schema_version", .integer)
                table.column("source_page_fingerprint", .text)
                table.column("byte_count", .integer).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
                table.primaryKey(["entry_key"], onConflict: .replace)
            }
            try db.create(index: "offline_cache_novel_entries_owner_idx", on: "offline_cache_novel_entries", columns: ["owner_name"])

            try db.create(table: "offline_cache_novel_entry_images") { table in
                table.column("entry_key", .text).notNull()
                table.column("manual_order", .integer).notNull()
                table.column("image_url", .text).notNull()
                table.primaryKey(["entry_key", "manual_order"], onConflict: .replace)
                table.foreignKey(["entry_key"], references: "offline_cache_novel_entries", columns: ["entry_key"], onDelete: .cascade)
            }
            try db.create(index: "offline_cache_novel_entry_images_url_idx", on: "offline_cache_novel_entry_images", columns: ["image_url"])

            try db.create(table: "offline_cache_manga_entry_images") { table in
                table.column("owner_name", .text).notNull()
                table.column("tid", .text).notNull()
                table.column("manual_order", .integer).notNull()
                table.column("image_url", .text).notNull()
                table.primaryKey(["owner_name", "tid", "manual_order"], onConflict: .replace)
                table.foreignKey(["owner_name", "tid"], references: "offline_cache_manga_entries", columns: ["owner_name", "tid"], onDelete: .cascade)
            }
            try db.create(index: "offline_cache_manga_entry_images_url_idx", on: "offline_cache_manga_entry_images", columns: ["image_url"])

            try db.create(table: "offline_cache_works") { table in
                table.column("reader_kind", .text).notNull()
                table.column("work_id", .text).notNull()
                table.column("owner_name", .text).notNull()
                table.column("owner_title", .text).notNull()
                table.column("tid", .text).notNull()
                table.column("chapter_title", .text).notNull()
                table.column("retains_inline_images", .boolean).notNull().defaults(to: false)
                table.column("state", .text).notNull()
                table.column("failure_message", .text)
                table.column("current_bytes_per_second", .integer).notNull()
                table.column("insertion_index", .integer).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
                // No .replace conflict clause: REPLACE deletes the conflicting row, and the
                // ON DELETE CASCADE on both image tables below would wipe the child rows that
                // OfflineCacheStore.save diffs against on every progress update.
                table.primaryKey(["reader_kind", "owner_name", "tid"])
            }
            try db.create(index: "offline_cache_works_work_id_idx", on: "offline_cache_works", columns: ["work_id"], unique: true)
            try db.create(index: "offline_cache_works_insertion_idx", on: "offline_cache_works", columns: ["insertion_index"])

            try db.create(table: "offline_cache_work_images") { table in
                table.column("reader_kind", .text).notNull()
                table.column("owner_name", .text).notNull()
                table.column("tid", .text).notNull()
                table.column("manual_order", .integer).notNull()
                table.column("image_url", .text).notNull()
                table.primaryKey(["reader_kind", "owner_name", "tid", "manual_order"], onConflict: .replace)
                table.foreignKey(["reader_kind", "owner_name", "tid"], references: "offline_cache_works", columns: ["reader_kind", "owner_name", "tid"], onDelete: .cascade)
            }
            try db.create(index: "offline_cache_work_images_url_idx", on: "offline_cache_work_images", columns: ["image_url"])

            try db.create(table: "offline_cache_completed_images") { table in
                table.column("reader_kind", .text).notNull()
                table.column("owner_name", .text).notNull()
                table.column("tid", .text).notNull()
                table.column("manual_order", .integer).notNull()
                table.column("image_url", .text).notNull()
                table.primaryKey(["reader_kind", "owner_name", "tid", "manual_order"], onConflict: .replace)
                table.foreignKey(["reader_kind", "owner_name", "tid"], references: "offline_cache_works", columns: ["reader_kind", "owner_name", "tid"], onDelete: .cascade)
            }
            try db.create(index: "offline_cache_completed_images_url_idx", on: "offline_cache_completed_images", columns: ["image_url"])

            try db.create(table: "offline_cache_image_assets") { table in
                table.column("image_url", .text).primaryKey(onConflict: .replace)
                table.column("file_name", .text).notNull()
                table.column("byte_count", .integer).notNull()
            }

            try db.create(table: "offline_cache_queue_state") { table in
                table.column("key", .text).primaryKey(onConflict: .replace)
                table.column("value", .text).notNull()
            }
        }

        // Normal-thread reading progress (browsing-history decisions #6/#7):
        // page + floor-level anchor for `.normalThread` rows, the first real
        // writer that target kind has ever had.
        migrator.registerMigration("reader.v2.normal-thread-progress") { db in
            try db.alter(table: "reading_progress") { table in
                table.add(column: "thread_last_page", .integer)
                table.add(column: "thread_page_count", .integer)
                table.add(column: "thread_anchor_post_id", .text)
            }
        }
    }

    /// Every offline-cache table, ordered so child tables are wiped before the
    /// parents their foreign keys reference. `OfflineCacheStore.clearAll()` and
    /// `erase(in:)` below previously each maintained this list by hand; a table
    /// added to the schema but only to one of the two wipe paths would leave
    /// stale rows behind, so both now share this single source of truth.
    static let offlineCacheTableNamesInDeletionOrder: [String] = [
        "offline_cache_completed_images",
        "offline_cache_work_images",
        "offline_cache_works",
        "offline_cache_novel_entry_images",
        "offline_cache_novel_entries",
        "offline_cache_manga_entry_images",
        "offline_cache_manga_entries",
        "offline_cache_image_assets",
        "offline_cache_queue_state"
    ]

    static func erase(in db: Database) throws {
        for table in offlineCacheTableNamesInDeletionOrder {
            try db.execute(sql: "DELETE FROM \(table)")
        }
        try db.execute(sql: "DELETE FROM manga_directory_chapters")
        try db.execute(sql: "DELETE FROM manga_directories")
        try db.execute(sql: "DELETE FROM reading_progress")
    }
}

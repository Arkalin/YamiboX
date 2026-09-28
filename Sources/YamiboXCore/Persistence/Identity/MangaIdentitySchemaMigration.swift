import Foundation
@preconcurrency import GRDB

/// Historical migrations have their own frozen rules and wire formats. Runtime
/// identity changes must never alter how an existing database version upgrades.
enum MangaIdentityMigrationV1 {
    static func register(in migrator: inout DatabaseMigrator) {
        IdentityRegistry.registerMigration(in: &migrator)
    }
}

// Keep the original identifiers, SQL, and registration order.
extension MangaIdentityMigrationV1.IdentityRegistry {
    private typealias DirectoryID = MangaIdentityMigrationV1.DirectoryID
    private typealias ReferenceRemapping = MangaIdentityMigrationV1.ReferenceRemapping
    private typealias IdentityJSON = MangaIdentityMigrationV1.IdentityJSON
    private typealias DeletionState = MangaIdentityMigrationV1.DeletionState

    static func registerMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("manga-identity.v1") { db in
            try db.execute(sql: """
                CREATE TABLE manga_identities (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, modified_at DOUBLE NOT NULL DEFAULT 0);
                CREATE TABLE manga_identity_aliases (kind TEXT NOT NULL, alias TEXT NOT NULL, directory_id TEXT NOT NULL REFERENCES manga_identities(id), PRIMARY KEY(kind, alias, directory_id));
                CREATE TABLE manga_identity_redirects (id TEXT PRIMARY KEY NOT NULL, canonical_id TEXT NOT NULL REFERENCES manga_identities(id));
                """)
            let directories = try Row.fetchAll(db, sql: "SELECT * FROM manga_directories")
            for row in directories {
                let name: String = row["clean_book_name"]
                let id = DirectoryID.legacy(name: name).rawValue
                try register(id: id, name: name, modifiedAt: row["modified_at"], in: db)
                let source: String = row["source_key"]
                let strategy: String = row["strategy"]
                let firstTID = try String.fetchOne(db, sql: "SELECT tid FROM manga_directory_chapters WHERE directory_name = ? ORDER BY manual_order, tid LIMIT 1", arguments: [name])
                let oldIdentity = !source.isEmpty && source != name ? "\(strategy):\(source)" : firstTID.map { "chapter:\($0)" } ?? name
                try addAlias(oldIdentity, kind: "favorite", id: id, in: db)
            }
            // Orphan metadata is meaningful even when its regenerable directory
            // was cleared. Assign identities before touching any business rows.
            for table in ["reading_progress", "browsing_history"] {
                let chapterColumn = table == "reading_progress" ? "manga_chapter_thread_id" : "chapter_thread_id"
                for row in try Row.fetchAll(db, sql: "SELECT manga_id, clean_book_name, \(chapterColumn) AS chapter_tid FROM \(table) WHERE target_kind = 'mangaTitle'") {
                    let name: String = row["clean_book_name"]
                    let old: String? = row["manga_id"]
                    let chapter: String? = row["chapter_tid"]
                    guard let id = try resolveLegacyRecord(name: name, identity: old, chapterTID: chapter, in: db) else { continue }
                    try registerLegacyRecord(id: id, name: name, identity: old, in: db)
                }
            }
            let names = try String.fetchAll(db, sql: """
                SELECT target_id FROM content_cover WHERE target_type = 'SmartManga'
                UNION SELECT work_id FROM like_items WHERE work_kind = 'manga'
                UNION SELECT work_id FROM bookmarks WHERE work_kind = 'manga'
                UNION SELECT owner_name FROM offline_cache_manga_entries
                UNION SELECT owner_name FROM offline_cache_works WHERE reader_kind = 'manga'
                """)
            for name in names {
                if try snapshot(in: db).names[name] == nil { try register(id: DirectoryID.legacy(name: name).rawValue, name: name, modifiedAt: 0, in: db) }
            }
            for key in try String.fetchAll(db, sql: "SELECT target_id FROM favorite_update_tracked_targets UNION SELECT target_id FROM favorite_update_events") where key.hasPrefix("manga-directory:") {
                let name = String(key.dropFirst("manga-directory:".count))
                if try snapshot(in: db).names[name] == nil { try register(id: DirectoryID.legacy(name: name).rawValue, name: name, modifiedAt: 0, in: db) }
            }
            for data in try Data.fetchAll(db, sql: "SELECT record FROM browsing_history_sync_records") {
                try registerLegacyJSON(try JSONSerialization.jsonObject(with: data), in: db)
            }
            for json in try String.fetchAll(db, sql: "SELECT document_json FROM favorite_library_document UNION ALL SELECT snapshot_json FROM favorite_sync_runs") {
                try registerLegacyJSON(try JSONSerialization.jsonObject(with: Data(json.utf8)), in: db)
            }
            let snapshot = try snapshot(in: db)
            try ReferenceRemapping.normalizeReferences(snapshot: snapshot, legacy: true, in: db)

            // Copy before dropping the old parent so ON DELETE CASCADE cannot
            // erase chapters. New constraints cannot silently REPLACE directories.
            try db.execute(sql: """
                CREATE TABLE manga_directories_v1 AS SELECT * FROM manga_directories;
                CREATE TABLE manga_directory_chapters_v1 AS SELECT * FROM manga_directory_chapters;
                DROP TABLE manga_directory_chapters;
                DROP TABLE manga_directories;
                CREATE TABLE manga_directories (id TEXT PRIMARY KEY NOT NULL REFERENCES manga_identities(id), clean_book_name TEXT NOT NULL UNIQUE, strategy TEXT NOT NULL, source_key TEXT NOT NULL, last_updated_at DOUBLE, search_keyword TEXT, modified_at DOUBLE NOT NULL);
                CREATE TABLE manga_directory_chapters (directory_id TEXT NOT NULL REFERENCES manga_directories(id) ON DELETE CASCADE, tid TEXT NOT NULL, view INTEGER NOT NULL, raw_title TEXT NOT NULL, chapter_number DOUBLE NOT NULL, author_uid TEXT, author_name TEXT, group_index INTEGER NOT NULL, publish_time DOUBLE, manual_order INTEGER NOT NULL, PRIMARY KEY(directory_id, tid) ON CONFLICT REPLACE);
                INSERT INTO manga_directories SELECT a.directory_id, d.* FROM manga_directories_v1 d JOIN manga_identity_aliases a ON a.kind = 'name' AND a.alias = d.clean_book_name;
                INSERT INTO manga_directory_chapters SELECT a.directory_id, c.tid, c.view, c.raw_title, c.chapter_number, c.author_uid, c.author_name, c.group_index, c.publish_time, c.manual_order FROM manga_directory_chapters_v1 c JOIN manga_identity_aliases a ON a.kind = 'name' AND a.alias = c.directory_name;
                DROP TABLE manga_directory_chapters_v1;
                DROP TABLE manga_directories_v1;
                CREATE INDEX manga_directory_chapters_tid_idx ON manga_directory_chapters(tid);
                CREATE INDEX manga_directory_chapters_directory_order_idx ON manga_directory_chapters(directory_id, manual_order);
                """)
        }
        migrator.registerMigration("manga-identity.v2.content-provenance") { db in
            try db.alter(table: "manga_directories") { table in
                table.add(column: "content_identity_ids_json", .text).notNull().defaults(to: "[]")
            }
            for id in try String.fetchAll(db, sql: "SELECT id FROM manga_directories") {
                let json = String(decoding: try JSONEncoder().encode([id]), as: UTF8.self)
                try db.execute(sql: "UPDATE manga_directories SET content_identity_ids_json = ? WHERE id = ?", arguments: [json, id])
            }
        }
        migrator.registerMigration("manga-identity.v3.pending-tombstones") { db in
            let identities = try snapshot(in: db)
            for table in ["reading_progress_sync_state", "manga_directory_sync_state", "content_cover_sync_state", "browsing_history_sync_state", "browsing_history_local_deletions"] {
                let state = try DeletionState.load(from: table, in: db)
                let normalized = try IdentityJSON.normalize(
                    JSONEncoder().encode(state), identities: identities, legacy: false,
                    datasetID: table == "manga_directory_sync_state" ? "mangaDirectories" : nil
                )
                try JSONDecoder().decode(DeletionState.self, from: normalized).save(to: table, in: db)
            }
        }
    }

    private static func registerLegacyJSON(_ value: Any, chapterTID: String? = nil, in db: Database) throws {
        if let array = value as? [Any] {
            for value in array { try registerLegacyJSON(value, chapterTID: chapterTID, in: db) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        let chapterTID = object["threadID"] as? String ?? chapterTID
        if let name = object["cleanBookName"] as? String {
            let identity = object["mangaID"] as? String
            if let id = try resolveLegacyRecord(name: name, identity: identity, chapterTID: chapterTID, in: db) {
                try registerLegacyRecord(id: id, name: name, identity: identity, in: db)
            }
        }
        for value in object.values { try registerLegacyJSON(value, chapterTID: chapterTID, in: db) }
    }

}

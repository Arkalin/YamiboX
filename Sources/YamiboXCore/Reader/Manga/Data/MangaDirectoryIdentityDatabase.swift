import CryptoKit
import Foundation
@preconcurrency import GRDB

/// One transaction owns identity conversion across otherwise independent stores.
/// Directory cache deletion intentionally never deletes this registry.
enum MangaDirectoryIdentityDatabase {
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
                let id = MangaDirectoryID.legacy(name: name).rawValue
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
                if try snapshot(in: db).names[name] == nil { try register(id: MangaDirectoryID.legacy(name: name).rawValue, name: name, modifiedAt: 0, in: db) }
            }
            for key in try String.fetchAll(db, sql: "SELECT target_id FROM favorite_update_tracked_targets UNION SELECT target_id FROM favorite_update_events") where key.hasPrefix("manga-directory:") {
                let name = String(key.dropFirst("manga-directory:".count))
                if try snapshot(in: db).names[name] == nil { try register(id: MangaDirectoryID.legacy(name: name).rawValue, name: name, modifiedAt: 0, in: db) }
            }
            for data in try Data.fetchAll(db, sql: "SELECT record FROM browsing_history_sync_records") {
                try registerLegacyJSON(try JSONSerialization.jsonObject(with: data), in: db)
            }
            for json in try String.fetchAll(db, sql: "SELECT document_json FROM favorite_library_document UNION ALL SELECT snapshot_json FROM favorite_sync_runs") {
                try registerLegacyJSON(try JSONSerialization.jsonObject(with: Data(json.utf8)), in: db)
            }
            let snapshot = try snapshot(in: db)
            try normalizeReferences(snapshot: snapshot, legacy: true, in: db)

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
                let state = try SyncDeletionState.load(from: table, in: db)
                let normalized = try MangaDirectoryIdentityJSON.normalize(
                    JSONEncoder().encode(state), identities: identities, legacy: false,
                    datasetID: table == "manga_directory_sync_state" ? "mangaDirectories" : nil
                )
                try JSONDecoder().decode(SyncDeletionState.self, from: normalized).save(to: table, in: db)
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

    // A historical display name can now belong to an unrelated directory.
    // Prefer chapter/opaque-identity evidence and retain conflicting records
    // unresolved instead of attaching them to whichever title currently exists.
    static func resolveLegacyRecord(name: String, identity: String?, chapterTID: String?, allowNameFallback: Bool = true, in db: Database) throws -> String? {
        let identities = try snapshot(in: db)
        let usesStableIDs = try db.columns(in: "manga_directory_chapters").contains { $0.name == "directory_id" }
        let ownerColumn = usesStableIDs ? "directory_id" : "directory_name"
        let chapterOwners = Set(try chapterTID.map {
            try String.fetchAll(db, sql: "SELECT DISTINCT \(ownerColumn) FROM manga_directory_chapters WHERE tid = ?", arguments: [$0])
                .map { identities.canonicalID(usesStableIDs ? $0 : MangaDirectoryID.legacy(name: $0).rawValue) }
        } ?? [])
        let identityOwners: Set<String>
        if let identity, identity != name {
            identityOwners = Set(try String.fetchAll(db, sql: "SELECT directory_id FROM manga_identity_aliases WHERE kind = 'favorite' AND alias = ?", arguments: [identity]).map { identities.canonicalID($0) })
        } else { identityOwners = [] }
        if !chapterOwners.isEmpty && !identityOwners.isEmpty {
            let candidates = chapterOwners.intersection(identityOwners)
            return candidates.count == 1 ? candidates.first : nil
        }
        let candidates = chapterOwners.union(identityOwners)
        if !candidates.isEmpty { return candidates.count == 1 ? candidates.first : nil }
        guard allowNameFallback else { return nil }
        let names = Set(try String.fetchAll(db, sql: "SELECT directory_id FROM manga_identity_aliases WHERE kind = 'name' AND alias = ?", arguments: [name]).map { identities.canonicalID($0) })
        return names.count > 1 ? nil : names.first ?? MangaDirectoryID.legacy(name: name).rawValue
    }

    private static func isStableIdentity(_ identity: String?) -> Bool {
        guard let identity else { return false }
        return identity.hasPrefix("manga-id:") || identity.hasPrefix("manga-legacy:") || identity.hasPrefix("manga-thread:")
    }

    private static func registerLegacyRecord(id: String, name: String, identity: String?, in db: Database) throws {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM manga_identities WHERE id = ?)", arguments: [id]) != true {
            try register(id: id, name: name, modifiedAt: 0, in: db)
        } else if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM manga_identity_aliases WHERE kind = 'name' AND alias = ? AND directory_id != ?)", arguments: [name, id]) != true {
            try addAlias(name, kind: "name", id: id, in: db)
        }
        if let identity, identity != name,
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM manga_identity_aliases WHERE kind = 'favorite' AND alias = ? AND directory_id != ?)", arguments: [identity, id]) != true {
            try addAlias(identity, kind: "favorite", id: id, in: db)
        }
    }

    static func register(id: String, name: String, modifiedAt: Double = Date.now.timeIntervalSince1970, in db: Database) throws {
        try db.execute(sql: "INSERT INTO manga_identities(id, name, modified_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, modified_at = excluded.modified_at WHERE manga_identities.name != excluded.name", arguments: [id, name, modifiedAt])
        try addAlias(name, kind: "name", id: id, in: db)
    }

    static func canonicalID(_ id: MangaDirectoryID, in db: Database) throws -> MangaDirectoryID {
        guard try db.tableExists("manga_identity_redirects") else { return id }
        var value = id.rawValue
        var visited: Set<String> = []
        while let next = try String.fetchOne(db, sql: "SELECT canonical_id FROM manga_identity_redirects WHERE id = ?", arguments: [value]), visited.insert(value).inserted {
            value = next
        }
        return MangaDirectoryID(rawValue: value)
    }

    static func canonicalWorkID(_ key: LikeWorkKey, in db: Database) throws -> String {
        key.kind == .manga ? try canonicalID(MangaDirectoryID(rawValue: key.id), in: db).rawValue : key.id
    }

    static func canonicalTarget(_ target: FavoriteContentTarget, in db: Database) throws -> FavoriteContentTarget {
        guard case let .mangaTitle(id, name) = target else { return target }
        return .mangaTitle(mangaID: try canonicalID(MangaDirectoryID(rawValue: id), in: db).rawValue, cleanBookName: name)
    }

    static func addAlias(_ alias: String, kind: String, id: String, in db: Database) throws {
        guard !alias.isEmpty else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO manga_identity_aliases(kind, alias, directory_id) VALUES (?, ?, ?)", arguments: [kind, alias, id])
    }

    static func snapshot(in db: Database) throws -> MangaDirectoryIdentitySnapshot {
        var result = MangaDirectoryIdentitySnapshot()
        for row in try Row.fetchAll(db, sql: "SELECT id, canonical_id FROM manga_identity_redirects") { result.redirects[row["id"]] = row["canonical_id"] }
        var names: [String: Set<String>] = [:]
        var identities: [String: Set<String>] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT kind, alias, directory_id FROM manga_identity_aliases") {
            let alias: String = row["alias"]
            let id = result.canonicalID(row["directory_id"])
            if row["kind"] as String == "name" { names[alias, default: []].insert(id) }
            else { identities[alias, default: []].insert(id) }
        }
        result.names = names.compactMapValues { $0.count == 1 ? $0.first : nil }
        result.legacyIdentities = identities.compactMapValues { $0.count == 1 ? $0.first : nil }
        for row in try Row.fetchAll(db, sql: "SELECT id, name, modified_at FROM manga_identities") {
            let id: String = row["id"]
            guard result.canonicalID(id) == id else { continue }
            result.titles[id] = row["name"]
            result.titleModifiedAt[id] = row["modified_at"]
        }
        return result
    }

    static func redirect(_ source: String, to target: String, in db: Database) throws {
        guard source != target else { return }
        try db.execute(sql: "INSERT INTO manga_identity_redirects(id, canonical_id) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET canonical_id = excluded.canonical_id", arguments: [source, target])
        try db.execute(sql: "UPDATE manga_identity_redirects SET canonical_id = ? WHERE canonical_id = ?", arguments: [target, source])
    }

    static func normalizeReferences(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        for (table, timestamp) in [("reading_progress", "updated_at"), ("browsing_history", "last_visit_time")] {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE target_kind = 'mangaTitle' ORDER BY \(timestamp) ASC, id ASC")
            for row in rows {
                let oldID: String = row["id"]
                let name: String = row["clean_book_name"]
                let id: String
                let oldIdentity: String? = row["manga_id"]
                if !legacy, let oldIdentity, isStableIdentity(oldIdentity) {
                    id = snapshot.canonicalID(oldIdentity)
                } else {
                    let chapterColumn = table == "reading_progress" ? "manga_chapter_thread_id" : "chapter_thread_id"
                    // An earlier migration may deliberately leave an ambiguous
                    // row untouched. Later identity updates must retry the same
                    // evidence, not turn its display name into a binding.
                    guard let resolved = try resolveLegacyRecord(name: name, identity: oldIdentity, chapterTID: row[chapterColumn], allowNameFallback: legacy, in: db) else { continue }
                    try registerLegacyRecord(id: resolved, name: name, identity: oldIdentity, in: db)
                    id = resolved
                }
                let newID = "manga-title:" + id
                guard newID != oldID else { continue }
                let oldTime: Double = row[timestamp]
                let newTime = try Double.fetchOne(db, sql: "SELECT \(timestamp) FROM \(table) WHERE id = ?", arguments: [newID])
                if newTime == nil || oldTime > newTime! {
                    try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [newID])
                    try db.execute(sql: "UPDATE \(table) SET id = ?, manga_id = ? WHERE id = ?", arguments: [newID, id, oldID])
                } else { try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [oldID]) }
            }
        }
        for table in ["like_items", "bookmarks"] {
            for oldID in try String.fetchAll(db, sql: "SELECT DISTINCT work_id FROM \(table) WHERE work_kind = 'manga'") {
                let id = snapshot.resolve(oldID, legacy: legacy)
                try db.execute(sql: "UPDATE \(table) SET work_id = ? WHERE work_kind = 'manga' AND work_id = ?", arguments: [id, oldID])
            }
        }
        let covers = try Row.fetchAll(db, sql: "SELECT target_id, updated_at FROM content_cover WHERE target_type = 'SmartManga'").sorted { lhs, rhs in
            let left: String = lhs["target_id"], right: String = rhs["target_id"]
            let leftIsCurrent = snapshot.titles[snapshot.resolve(left, legacy: legacy)] == left
            let rightIsCurrent = snapshot.titles[snapshot.resolve(right, legacy: legacy)] == right
            if leftIsCurrent != rightIsCurrent { return leftIsCurrent }
            let leftTime: Double = lhs["updated_at"], rightTime: Double = rhs["updated_at"]
            return leftTime == rightTime ? left < right : leftTime > rightTime
        }
        for row in covers {
            let oldID: String = row["target_id"]
            let newID = snapshot.resolve(oldID, legacy: legacy)
            guard oldID != newID else { continue }
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM content_cover WHERE target_type = 'SmartManga' AND target_id = ?)", arguments: [newID]) == true {
                try db.execute(sql: "DELETE FROM content_cover WHERE target_type = 'SmartManga' AND target_id = ?", arguments: [oldID])
            } else {
                try db.execute(sql: "UPDATE content_cover SET target_id = ? WHERE target_type = 'SmartManga' AND target_id = ?", arguments: [newID, oldID])
            }
        }
        try normalizeHistory(snapshot: snapshot, legacy: legacy, in: db)
        try normalizeTracking(snapshot: snapshot, legacy: legacy, in: db)
        for (table, key, column) in [("favorite_library_document", "id", "document_json"), ("favorite_sync_runs", "run_id", "snapshot_json")] {
            for row in try Row.fetchAll(db, sql: "SELECT \(key), \(column) FROM \(table)") {
                let data = Data((row[column] as String).utf8)
                let normalized = try MangaDirectoryIdentityJSON.normalize(data, identities: snapshot, legacy: legacy)
                try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE \(key) = ?", arguments: [String(decoding: normalized, as: UTF8.self).databaseValue, row[key] as DatabaseValue])
            }
        }
        for table in ["reading_progress_sync_state", "manga_directory_sync_state", "content_cover_sync_state", "browsing_history_sync_state", "browsing_history_local_deletions"] {
            let state = try SyncDeletionState.load(from: table, in: db)
            let data = try MangaDirectoryIdentityJSON.normalize(JSONEncoder().encode(state), identities: snapshot, legacy: legacy, datasetID: table == "manga_directory_sync_state" ? "mangaDirectories" : nil)
            try JSONDecoder().decode(SyncDeletionState.self, from: data).save(to: table, in: db)
        }
        try normalizeOffline(snapshot: snapshot, legacy: legacy, in: db)
    }

    private static func normalizeHistory(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        let records = try BrowsingHistorySyncRecord.load(in: db)
        var normalized: [String: BrowsingHistorySyncRecord] = [:]
        for record in records {
            var next = record
            if case let .mangaTitle(identity, name) = record.target {
                if legacy || !isStableIdentity(identity) {
                    if let id = try resolveLegacyRecord(name: name, identity: identity, chapterTID: record.threadID, allowNameFallback: legacy, in: db) {
                        try registerLegacyRecord(id: id, name: name, identity: identity, in: db)
                        next.target = .mangaTitle(mangaID: id, cleanBookName: name)
                    }
                } else {
                    next.target = .mangaTitle(mangaID: snapshot.canonicalID(identity), cleanBookName: name)
                }
            } else {
                let data = try MangaDirectoryIdentityJSON.normalize(JSONEncoder().encode(record), identities: snapshot, legacy: legacy)
                next = try JSONDecoder().decode(BrowsingHistorySyncRecord.self, from: data)
            }
            if let existing = normalized[next.id], existing.lastVisitTime >= next.lastVisitTime { continue }
            normalized[next.id] = next
        }
        try BrowsingHistorySyncRecord.save(Array(normalized.values), in: db)
    }

    private static func normalizeTracking(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        var targets: [String: FavoriteUpdateTrackedTarget] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT target_json FROM favorite_update_tracked_targets ORDER BY target_id") {
            let data = try MangaDirectoryIdentityJSON.normalize(Data((row["target_json"] as String).utf8), identities: snapshot, legacy: legacy)
            var target = try JSONDecoder().decode(FavoriteUpdateTrackedTarget.self, from: data)
            if let existing = targets[target.id] {
                target.knownChapterTIDs = (target.knownChapterTIDs ?? []).union(existing.knownChapterTIDs ?? [])
                target.categoryIDs.formUnion(existing.categoryIDs)
            }
            targets[target.id] = target
        }
        try db.execute(sql: "DELETE FROM favorite_update_tracked_targets")
        for target in targets.values {
            try db.execute(sql: "INSERT INTO favorite_update_tracked_targets(target_id, target_json) VALUES (?, ?)", arguments: [target.id, String(decoding: try JSONEncoder().encode(target), as: UTF8.self)])
        }
        var activeTargets: Set<String> = []
        for row in try Row.fetchAll(db, sql: "SELECT id, event_json FROM favorite_update_events ORDER BY detected_at DESC, id DESC") {
            let data = try MangaDirectoryIdentityJSON.normalize(Data((row["event_json"] as String).utf8), identities: snapshot, legacy: legacy)
            let event = try JSONDecoder().decode(FavoriteUpdateEvent.self, from: data)
            if event.dismissedAt == nil, !activeTargets.insert(event.target.id).inserted {
                try db.execute(sql: "DELETE FROM favorite_update_events WHERE id = ?", arguments: [event.id])
            } else {
                try db.execute(sql: "UPDATE favorite_update_events SET target_id = ?, event_json = ? WHERE id = ?", arguments: [event.target.id, String(decoding: data, as: UTF8.self), event.id])
            }
        }
    }

    private static func normalizeOffline(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        for (table, childTables, predicate) in [
            ("offline_cache_manga_entries", ["offline_cache_manga_entry_images"], "1"),
            ("offline_cache_works", ["offline_cache_work_images", "offline_cache_completed_images"], "reader_kind = 'manga'")
        ] {
            for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE \(predicate)") {
                let owner: String = row["owner_name"]
                let id = snapshot.resolve(owner, legacy: legacy)
                guard owner != id else { continue }
                let tid: String = row["tid"]
                let whereClause = "\(predicate) AND owner_name = ? AND tid = ?"
                let existing = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE \(whereClause)", arguments: [id, tid])
                let oldChildren = try childTables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) WHERE \(whereClause)", arguments: [owner, tid]) }
                var preferSource = existing == nil
                if let existing {
                    if table == "offline_cache_manga_entries" {
                        preferSource = try cacheCompleteness(row, in: db) > cacheCompleteness(existing, in: db)
                    } else {
                        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offline_cache_completed_images WHERE \(whereClause)", arguments: [id, tid]) ?? 0
                        preferSource = oldChildren[1].count > count
                    }
                }
                if preferSource {
                    // Read children first, then delete/copy parents. Cascades are
                    // disabled during GRDB schema migrations, so remove children
                    // explicitly as well. No payload files or assets are touched.
                    for childTable in childTables {
                        try db.execute(sql: "DELETE FROM \(childTable) WHERE \(whereClause)", arguments: [id, tid])
                        try db.execute(sql: "DELETE FROM \(childTable) WHERE \(whereClause)", arguments: [owner, tid])
                    }
                    try db.execute(sql: "DELETE FROM \(table) WHERE \(whereClause)", arguments: [id, tid])
                    try db.execute(sql: "DELETE FROM \(table) WHERE \(whereClause)", arguments: [owner, tid])
                    try insert(row, table: table, replacing: ["owner_name": id.databaseValue], in: db)
                    for (childTable, children) in zip(childTables, oldChildren) {
                        for child in children { try insert(child, table: childTable, replacing: ["owner_name": id.databaseValue], in: db) }
                    }
                } else {
                    for childTable in childTables {
                        try db.execute(sql: "DELETE FROM \(childTable) WHERE \(whereClause)", arguments: [owner, tid])
                    }
                    try db.execute(sql: "DELETE FROM \(table) WHERE \(whereClause)", arguments: [owner, tid])
                }
            }
        }
    }

    /// The app places offline-cache beside the database. Only conflicting
    /// memberships need I/O; compare existing payloads without renaming files.
    private static func cacheCompleteness(_ row: Row, in db: Database) throws -> Int {
        guard let mainDatabase = try Row.fetchAll(db, sql: "PRAGMA database_list").first(where: { $0["name"] as String == "main" }),
              let path: String = mainDatabase["file"], !path.isEmpty else { return 0 }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("offline-cache", isDirectory: true)
        guard let fileName: String = row["source_page_file_name"],
              row["source_page_schema_version"] as Int? == 1,
              let fingerprint: String = row["source_page_fingerprint"],
              let data = try? Data(contentsOf: root.appendingPathComponent("manga-source-pages").appendingPathComponent(fileName)),
              data.count == row["byte_count"] as Int,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == fingerprint,
              let page = try? JSONDecoder().decode(ForumThreadPage.self, from: data),
              page.thread.tid == row["tid"] as String else { return 0 }
        let files = try Row.fetchAll(db, sql: """
            SELECT a.file_name FROM offline_cache_manga_entry_images i
            LEFT JOIN offline_cache_image_assets a ON a.image_url = i.image_url
            WHERE i.owner_name = ? AND i.tid = ?
            """, arguments: [row["owner_name"] as String, row["tid"] as String])
        guard !files.isEmpty else { return 1 }
        for file in files {
            guard let name: String = file["file_name"],
                  FileManager.default.fileExists(atPath: root.appendingPathComponent("images").appendingPathComponent(name).path) else { return 1 }
        }
        return 2
    }

    static func insert(_ row: Row, table: String, replacing changes: [String: DatabaseValue], in db: Database) throws {
        let columns = Array(row.columnNames)
        let arguments = columns.map { changes[$0] ?? (row[$0] as DatabaseValue) }
        try db.execute(sql: "INSERT INTO \(table) (\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(arguments))
    }
}

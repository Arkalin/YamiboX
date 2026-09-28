import CryptoKit
import Foundation
@preconcurrency import GRDB

// Frozen rules for manga-identity.v1 through v3. Intentional historical copies:
// never redirect these helpers to runtime remappers or update them for new features.
// A behavior change requires a new, separately registered migration.
extension MangaIdentityMigrationV1 {
    /// Shared identity registry. Business-table rewrites belong to their feature adapters.
    /// Directory cache deletion intentionally never deletes this registry.
    enum IdentityRegistry {
        // A historical display name can now belong to an unrelated directory.
        // Prefer chapter/opaque-identity evidence and retain conflicting records
        // unresolved instead of attaching them to whichever title currently exists.
        static func resolveLegacyRecord(name: String, identity: String?, chapterTID: String?, allowNameFallback: Bool = true, in db: Database) throws -> String? {
            let identities = try snapshot(in: db)
            let usesStableIDs = try db.columns(in: "manga_directory_chapters").contains { $0.name == "directory_id" }
            let ownerColumn = usesStableIDs ? "directory_id" : "directory_name"
            let chapterOwners = Set(try chapterTID.map {
                try String.fetchAll(db, sql: "SELECT DISTINCT \(ownerColumn) FROM manga_directory_chapters WHERE tid = ?", arguments: [$0])
                    .map { identities.canonicalID(usesStableIDs ? $0 : DirectoryID.legacy(name: $0).rawValue) }
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
            return names.count > 1 ? nil : names.first ?? DirectoryID.legacy(name: name).rawValue
        }

        static func isStableIdentity(_ identity: String?) -> Bool {
            guard let identity else { return false }
            return identity.hasPrefix("manga-id:") || identity.hasPrefix("manga-legacy:") || identity.hasPrefix("manga-thread:")
        }

        static func registerLegacyRecord(id: String, name: String, identity: String?, in db: Database) throws {
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

        static func canonicalID(_ id: DirectoryID, in db: Database) throws -> DirectoryID {
            guard try db.tableExists("manga_identity_redirects") else { return id }
            var value = id.rawValue
            var visited: Set<String> = []
            while let next = try String.fetchOne(db, sql: "SELECT canonical_id FROM manga_identity_redirects WHERE id = ?", arguments: [value]), visited.insert(value).inserted {
                value = next
            }
            return DirectoryID(rawValue: value)
        }

        static func canonicalTarget(_ target: ContentTarget, in db: Database) throws -> ContentTarget {
            guard case let .mangaTitle(id, name) = target else { return target }
            return .mangaTitle(mangaID: try canonicalID(DirectoryID(rawValue: id), in: db).rawValue, cleanBookName: name)
        }

        static func addAlias(_ alias: String, kind: String, id: String, in db: Database) throws {
            guard !alias.isEmpty else { return }
            try db.execute(sql: "INSERT OR IGNORE INTO manga_identity_aliases(kind, alias, directory_id) VALUES (?, ?, ?)", arguments: [kind, alias, id])
        }

        static func snapshot(in db: Database) throws -> IdentitySnapshot {
            var result = IdentitySnapshot()
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
    }

    /// Portable identity information accompanies every manga-bearing dataset.
    struct IdentitySnapshot: Codable, Equatable, Sendable {
        var names: [String: String]
        var legacyIdentities: [String: String]
        var redirects: [String: String]
        var titles: [String: String]
        var titleModifiedAt: [String: Double]

        init(names: [String: String] = [:], legacyIdentities: [String: String] = [:], redirects: [String: String] = [:], titles: [String: String] = [:], titleModifiedAt: [String: Double] = [:]) {
            self.names = names
            self.legacyIdentities = legacyIdentities
            self.redirects = redirects
            self.titles = titles
            self.titleModifiedAt = titleModifiedAt
        }

        private enum CodingKeys: CodingKey { case names, legacyIdentities, redirects, titles, titleModifiedAt }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            names = try values.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
            legacyIdentities = try values.decodeIfPresent([String: String].self, forKey: .legacyIdentities) ?? [:]
            redirects = try values.decodeIfPresent([String: String].self, forKey: .redirects) ?? [:]
            titles = try values.decodeIfPresent([String: String].self, forKey: .titles) ?? [:]
            titleModifiedAt = try values.decodeIfPresent([String: Double].self, forKey: .titleModifiedAt) ?? [:]
        }

        func canonicalID(_ id: String) -> String {
            var current = id
            var visited: Set<String> = []
            while let next = redirects[current], visited.insert(current).inserted {
                current = next
            }
            return current
        }

        func resolve(_ value: String, name: String? = nil, legacy: Bool) -> String {
            if legacy, let id = legacyIdentities[value] ?? name.flatMap({ names[$0] }) ?? names[value] { return canonicalID(id) }
            if value.hasPrefix("manga-id:") || value.hasPrefix("manga-legacy:") || value.hasPrefix("manga-thread:") { return canonicalID(value) }
            if let id = legacyIdentities[value] ?? names[value] ?? name.flatMap({ names[$0] }) { return canonicalID(id) }
            return legacy ? DirectoryID.legacy(name: name ?? value).rawValue : canonicalID(value)
        }
    }

    /// Transforms structured records rather than replacing arbitrary strings. Titles,
    /// URLs, excerpts and chapter TIDs are never interpreted as directory keys.
    enum IdentityJSON {
        static func normalize(_ data: Data, identities: IdentitySnapshot, legacy: Bool, datasetID: String? = nil) throws -> Data {
            let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return try JSONSerialization.data(withJSONObject: normalize(value, identities: identities, legacy: legacy, datasetID: datasetID), options: [.sortedKeys, .fragmentsAllowed])
        }

        private static func normalize(_ value: Any, identities: IdentitySnapshot, legacy: Bool, datasetID: String?) -> Any {
            if let array = value as? [Any] { return array.map { normalize($0, identities: identities, legacy: legacy, datasetID: datasetID) } }
            guard let source = value as? [String: Any] else { return value }
            var object = source.mapValues { normalize($0, identities: identities, legacy: legacy, datasetID: datasetID) }
            if source["strategy"] != nil, source["chapters"] != nil, let name = source["cleanBookName"] as? String {
                let id = identities.resolve(source["id"] as? String ?? name, name: name, legacy: legacy)
                object["id"] = id
                // The title has its own conflict clock. Apply its winning value
                // before merging content so the exported receipt matches storage.
                if let title = identities.titles[id], title != id { object["cleanBookName"] = title }
            }
            if ["mangaTitle", "smartManga"].contains(source["kind"] as? String ?? ""), let name = source["cleanBookName"] as? String {
                let id = source["mangaID"] as? String
                // An unresolved legacy history/progress target may survive local
                // migration. New-format transport must not resolve it by name
                // without the containing record's chapter evidence.
                if legacy || source["kind"] as? String != "mangaTitle" || id.map(isStableID) == true {
                    object["mangaID"] = identities.resolve(id ?? name, name: name, legacy: legacy)
                }
            }
            if var group = source["smartManga"] as? [String: Any], let name = group["cleanBookName"] as? String {
                group["mangaID"] = identities.resolve(group["mangaID"] as? String ?? name, name: name, legacy: legacy)
                object["smartManga"] = group
            }
            if source["kind"] as? String == "manga", let id = source["id"] as? String {
                object["id"] = identities.resolve(id, legacy: legacy)
            }
            if source["targetType"] as? String == "SmartManga", let id = source["targetID"] as? String {
                object["targetID"] = identities.resolve(id, legacy: legacy)
            }
            if let target = source["mangaDirectory"] as? [String: Any] {
                if let id = target["directoryID"] as? String ?? target["cleanBookName"] as? String {
                    object["mangaDirectory"] = ["directoryID": identities.resolve(id, legacy: legacy)]
                }
            }
            // Launch contexts and resolved favorite source metadata have explicit
            // directory fields; guessed names alone do not acquire an identity.
            for field in ["directoryID", "mangaDirectoryID"] {
                if let id = source[field] as? String { object[field] = identities.resolve(id, legacy: legacy) }
            }
            if let id = source["directoryIdentity"] as? String { object["directoryIdentity"] = identities.resolve(id, name: source["cleanBookName"] as? String, legacy: legacy) }
            if let tombstones = source["tombstones"] as? [String: Any] {
                var normalized: [String: Any] = [:]
                let directoryDataset = datasetID == "mangaDirectories"
                func insert(_ key: String, _ date: Any) {
                    if let previous = normalized[key] as? Double, let date = date as? Double {
                        normalized[key] = max(previous, date)
                    } else { normalized[key] = date }
                }
                func retainOriginalKey(_ original: String, resolved: String, date: Any) {
                    guard resolved != original, !resolved.hasPrefix(pendingPrefix),
                          !resolved.hasPrefix(protectedPrefix) else { return }
                    insert(confirmedPrefix + original, date)
                }
                // The first identity format used the same marker for guessed and
                // confirmed hashes. An identity already present in the registry
                // is evidence of a real deletion: never downgrade it just because
                // the directory has since been renamed. Only unregistered guesses
                // may return to pending/old-name protection.
                var recovered: Set<String> = []
                for (marker, date) in tombstones where marker.hasPrefix(protectedPrefix) {
                    let original = String(marker.dropFirst(protectedPrefix.count))
                    guard let parts = mangaKey(original, directoryDataset: directoryDataset),
                          let timestamp = date as? Double else { continue }
                    let guessedID = DirectoryID.legacy(name: parts.value).rawValue
                    let guessed = parts.prefix + guessedID
                    guard let guessedDate = tombstones[guessed] as? Double, guessedDate == timestamp else { continue }
                    recovered.formUnion([marker, guessed])
                    let canonicalID = identities.canonicalID(guessedID)
                    if identities.titles[canonicalID] != nil || tombstones[confirmedPrefix + original] != nil {
                        insert(parts.prefix + canonicalID, date)
                        insert(confirmedPrefix + original, date)
                        continue
                    }
                    let key = resolveLegacyKey(original, identities: identities, directoryDataset: directoryDataset, legacyValue: true, deletedAt: timestamp)
                    insert(key, date)
                    retainOriginalKey(original, resolved: key, date: date)
                }
                for (key, date) in tombstones {
                    guard !recovered.contains(key) else { continue }
                    let newKey = normalizeKey(key, identities: identities, legacy: legacy, directoryDataset: datasetID == "mangaDirectories", deletedAt: date as? Double)
                    insert(newKey, date)
                    // Original-key markers only filter old-format records. Keep
                    // confirmed deletions distinct from rename protection so a
                    // later rename cannot undo a successfully resolved deletion.
                    let original = key.hasPrefix(pendingPrefix) ? String(key.dropFirst(pendingPrefix.count)) : key
                    if (legacy || key.hasPrefix(pendingPrefix)), newKey != key,
                       !original.hasPrefix(protectedPrefix), !original.hasPrefix(confirmedPrefix) {
                        retainOriginalKey(original, resolved: newKey, date: date)
                    }
                }
                object["tombstones"] = normalized
            }
            return object
        }

        private static let protectedPrefix = "legacy-name:"
        private static let pendingPrefix = "legacy-pending:"
        private static let confirmedPrefix = "legacy-resolved:"

        private static func isStableID(_ value: String) -> Bool {
            value.hasPrefix("manga-id:") || value.hasPrefix("manga-legacy:") || value.hasPrefix("manga-thread:")
        }

        private static func mangaKey(_ key: String, directoryDataset: Bool) -> (prefix: String, value: String)? {
            for prefix in ["manga-title:", "manga-directory:", "SmartManga:"] where key.hasPrefix(prefix) {
                return (prefix, String(key.dropFirst(prefix.count)))
            }
            return directoryDataset ? ("", key) : nil
        }

        private static func resolveLegacyKey(_ key: String, identities: IdentitySnapshot, directoryDataset: Bool, legacyValue: Bool, deletedAt: Double?) -> String {
            guard let parts = mangaKey(key, directoryDataset: directoryDataset) else { return key }
            let value = parts.value
            // A legacy title may itself start with "manga-id:". Explicit legacy
            // aliases win for old keys, but never reinterpret a new-format ID as
            // a display name merely because an alias happens to share its text.
            if !legacyValue, isStableID(value) { return parts.prefix + identities.canonicalID(value) }
            guard let id = identities.legacyIdentities[value] ?? identities.names[value] ?? identities.redirects[value] else {
                return pendingPrefix + key
            }
            let resolved = identities.canonicalID(id)
            // A name tombstone can describe the removal of an old name during a
            // rename, not deletion of the surviving identity. Opaque favorite keys
            // have no such name semantics and can safely follow their mapping.
            let isName = identities.names[value] != nil || parts.prefix == "SmartManga:" || parts.prefix.isEmpty
            if isName, let currentName = identities.titles[resolved], currentName != value {
                // A later real deletion can arrive before the alias of an earlier
                // rename. A different current title alone does not prove that the
                // tombstone merely removed the old name. Compare clocks before
                // turning it into permanent old-format-only protection.
                guard let deletedAt, deletedAt.isFinite,
                      let renamedAt = identities.titleModifiedAt[resolved], renamedAt.isFinite, renamedAt > 0 else {
                    return pendingPrefix + key
                }
                // Codable Date uses the 2001 reference epoch; identity title
                // clocks are persisted as Unix seconds.
                if Date(timeIntervalSinceReferenceDate: deletedAt).timeIntervalSince1970 <= renamedAt {
                    return protectedPrefix + key
                }
            }
            return parts.prefix + resolved
        }

        static func normalizeKey(_ key: String, identities: IdentitySnapshot, legacy: Bool, directoryDataset: Bool = false, deletedAt: Double? = nil) -> String {
            if key.hasPrefix(protectedPrefix) || key.hasPrefix(confirmedPrefix) { return key }
            if key.hasPrefix(pendingPrefix) {
                return resolveLegacyKey(String(key.dropFirst(pendingPrefix.count)), identities: identities, directoryDataset: directoryDataset, legacyValue: true, deletedAt: deletedAt)
            }
            // Raw unknown keys from older new-format payloads also remain
            // retryable. Never manufacture a directory identity from a tombstone.
            return resolveLegacyKey(key, identities: identities, directoryDataset: directoryDataset, legacyValue: legacy, deletedAt: deletedAt)
        }
    }

    /// Coordinates feature-owned rewrites within the existing database write/migration.
    /// Never opens a connection, starts a transaction, or catches a participant's error:
    /// the caller commits all changes together or rolls the entire operation back.
    enum ReferenceRemapping {
        static func normalizeReferences(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            try ProgressRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
            try HistoryRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
            try LikeRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
            try BookmarkRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
            try CoverRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
            try HistoryRemapping.normalizeSyncedRecords(snapshot: snapshot, legacy: legacy, in: db)
            try FavoriteRemapping.normalizeTracking(snapshot: snapshot, legacy: legacy, in: db)
            try FavoriteRemapping.normalizeDocuments(snapshot: snapshot, legacy: legacy, in: db)
            try ProgressRemapping.normalizeDeletionState(snapshot: snapshot, legacy: legacy, in: db)
            try ReferenceRemapping.normalizeDeletionState(table: "manga_directory_sync_state", datasetID: "mangaDirectories", snapshot: snapshot, legacy: legacy, in: db)
            try CoverRemapping.normalizeDeletionState(snapshot: snapshot, legacy: legacy, in: db)
            try HistoryRemapping.normalizeDeletionState(snapshot: snapshot, legacy: legacy, in: db)
            try OfflineRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
        }

        static func normalizeDeletionState(table: String, datasetID: String? = nil, snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            let state = try DeletionState.load(from: table, in: db)
            let data = try IdentityJSON.normalize(JSONEncoder().encode(state), identities: snapshot, legacy: legacy, datasetID: datasetID)
            try JSONDecoder().decode(DeletionState.self, from: data).save(to: table, in: db)
        }

        static func insert(_ row: Row, table: String, replacing changes: [String: DatabaseValue], in db: Database) throws {
            let columns = Array(row.columnNames)
            let arguments = columns.map { changes[$0] ?? (row[$0] as DatabaseValue) }
            try db.execute(sql: "INSERT INTO \(table) (\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(arguments))
        }
    }

    /// Rewrites only this feature's references using the caller's transaction.
    enum ProgressRemapping {
        static func normalize(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM reading_progress WHERE target_kind = 'mangaTitle' ORDER BY updated_at ASC, id ASC")
            for row in rows {
                let oldID: String = row["id"]
                let name: String = row["clean_book_name"]
                let id: String
                let oldIdentity: String? = row["manga_id"]
                if !legacy, let oldIdentity, IdentityRegistry.isStableIdentity(oldIdentity) {
                    id = snapshot.canonicalID(oldIdentity)
                } else {
                    let chapterColumn = "manga_chapter_thread_id"
                    // An earlier migration may deliberately leave an ambiguous
                    // row untouched. Later identity updates must retry the same
                    // evidence, not turn its display name into a binding.
                    guard let resolved = try IdentityRegistry.resolveLegacyRecord(name: name, identity: oldIdentity, chapterTID: row[chapterColumn], allowNameFallback: legacy, in: db) else { continue }
                    try IdentityRegistry.registerLegacyRecord(id: resolved, name: name, identity: oldIdentity, in: db)
                    id = resolved
                }
                let newID = "manga-title:" + id
                guard newID != oldID else { continue }
                let oldTime: Double = row["updated_at"]
                let newTime = try Double.fetchOne(db, sql: "SELECT updated_at FROM reading_progress WHERE id = ?", arguments: [newID])
                if newTime == nil || oldTime > newTime! {
                    try db.execute(sql: "DELETE FROM reading_progress WHERE id = ?", arguments: [newID])
                    try db.execute(sql: "UPDATE reading_progress SET id = ?, manga_id = ? WHERE id = ?", arguments: [newID, id, oldID])
                } else { try db.execute(sql: "DELETE FROM reading_progress WHERE id = ?", arguments: [oldID]) }
            }
        }

        static func normalizeDeletionState(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            try ReferenceRemapping.normalizeDeletionState(table: "reading_progress_sync_state", snapshot: snapshot, legacy: legacy, in: db)
        }
    }

    /// Rewrites only this feature's references using the caller's transaction.
    enum HistoryRemapping {
        static func normalize(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM browsing_history WHERE target_kind = 'mangaTitle' ORDER BY last_visit_time ASC, id ASC")
            for row in rows {
                let oldID: String = row["id"]
                let name: String = row["clean_book_name"]
                let id: String
                let oldIdentity: String? = row["manga_id"]
                if !legacy, let oldIdentity, IdentityRegistry.isStableIdentity(oldIdentity) {
                    id = snapshot.canonicalID(oldIdentity)
                } else {
                    let chapterColumn = "chapter_thread_id"
                    // An earlier migration may deliberately leave an ambiguous
                    // row untouched. Later identity updates must retry the same
                    // evidence, not turn its display name into a binding.
                    guard let resolved = try IdentityRegistry.resolveLegacyRecord(name: name, identity: oldIdentity, chapterTID: row[chapterColumn], allowNameFallback: legacy, in: db) else { continue }
                    try IdentityRegistry.registerLegacyRecord(id: resolved, name: name, identity: oldIdentity, in: db)
                    id = resolved
                }
                let newID = "manga-title:" + id
                guard newID != oldID else { continue }
                let oldTime: Double = row["last_visit_time"]
                let newTime = try Double.fetchOne(db, sql: "SELECT last_visit_time FROM browsing_history WHERE id = ?", arguments: [newID])
                if newTime == nil || oldTime > newTime! {
                    try db.execute(sql: "DELETE FROM browsing_history WHERE id = ?", arguments: [newID])
                    try db.execute(sql: "UPDATE browsing_history SET id = ?, manga_id = ? WHERE id = ?", arguments: [newID, id, oldID])
                } else { try db.execute(sql: "DELETE FROM browsing_history WHERE id = ?", arguments: [oldID]) }
            }
        }

        static func normalizeSyncedRecords(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            let records = try HistoryRecord.load(in: db)
            var normalized: [String: HistoryRecord] = [:]
            for record in records {
                var next = record
                if case let .mangaTitle(identity, name) = record.target {
                    if legacy || !IdentityRegistry.isStableIdentity(identity) {
                        if let id = try IdentityRegistry.resolveLegacyRecord(name: name, identity: identity, chapterTID: record.threadID, allowNameFallback: legacy, in: db) {
                            try IdentityRegistry.registerLegacyRecord(id: id, name: name, identity: identity, in: db)
                            next.target = .mangaTitle(mangaID: id, cleanBookName: name)
                        }
                    } else {
                        next.target = .mangaTitle(mangaID: snapshot.canonicalID(identity), cleanBookName: name)
                    }
                } else {
                    let data = try IdentityJSON.normalize(JSONEncoder().encode(record), identities: snapshot, legacy: legacy)
                    next = try JSONDecoder().decode(HistoryRecord.self, from: data)
                }
                if let existing = normalized[next.id], existing.lastVisitTime >= next.lastVisitTime { continue }
                normalized[next.id] = next
            }
            try HistoryRecord.save(Array(normalized.values), in: db)
        }

        static func normalizeDeletionState(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            try ReferenceRemapping.normalizeDeletionState(table: "browsing_history_sync_state", snapshot: snapshot, legacy: legacy, in: db)
            try ReferenceRemapping.normalizeDeletionState(table: "browsing_history_local_deletions", snapshot: snapshot, legacy: legacy, in: db)
        }
    }

    /// Rewrites only this feature's references using the caller's transaction.
    enum LikeRemapping {
        static func normalize(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            for oldID in try String.fetchAll(db, sql: "SELECT DISTINCT work_id FROM like_items WHERE work_kind = 'manga'") {
                let id = snapshot.resolve(oldID, legacy: legacy)
                try db.execute(sql: "UPDATE like_items SET work_id = ? WHERE work_kind = 'manga' AND work_id = ?", arguments: [id, oldID])
            }
        }
    }

    /// Rewrites only this feature's references using the caller's transaction.
    enum BookmarkRemapping {
        static func normalize(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            for oldID in try String.fetchAll(db, sql: "SELECT DISTINCT work_id FROM bookmarks WHERE work_kind = 'manga'") {
                let id = snapshot.resolve(oldID, legacy: legacy)
                try db.execute(sql: "UPDATE bookmarks SET work_id = ? WHERE work_kind = 'manga' AND work_id = ?", arguments: [id, oldID])
            }
        }
    }

    /// Rewrites only this feature's references using the caller's transaction.
    enum CoverRemapping {
        static func normalize(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
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
        }

        static func normalizeDeletionState(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            try ReferenceRemapping.normalizeDeletionState(table: "content_cover_sync_state", snapshot: snapshot, legacy: legacy, in: db)
        }
    }

    /// Rewrites only this feature's references using the caller's transaction.
    enum FavoriteRemapping {
        static func normalizeTracking(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            var targets: [String: TrackedTarget] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT target_json FROM favorite_update_tracked_targets ORDER BY target_id") {
                let data = try IdentityJSON.normalize(Data((row["target_json"] as String).utf8), identities: snapshot, legacy: legacy)
                var target = try JSONDecoder().decode(TrackedTarget.self, from: data)
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
                let data = try IdentityJSON.normalize(Data((row["event_json"] as String).utf8), identities: snapshot, legacy: legacy)
                let event = try JSONDecoder().decode(UpdateEvent.self, from: data)
                if event.dismissedAt == nil, !activeTargets.insert(event.target.id).inserted {
                    try db.execute(sql: "DELETE FROM favorite_update_events WHERE id = ?", arguments: [event.id])
                } else {
                    try db.execute(sql: "UPDATE favorite_update_events SET target_id = ?, event_json = ? WHERE id = ?", arguments: [event.target.id, String(decoding: data, as: UTF8.self), event.id])
                }
            }
        }

        static func normalizeDocuments(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
            for (table, key, column) in [("favorite_library_document", "id", "document_json"), ("favorite_sync_runs", "run_id", "snapshot_json")] {
                for row in try Row.fetchAll(db, sql: "SELECT \(key), \(column) FROM \(table)") {
                    let data = Data((row[column] as String).utf8)
                    let normalized = try IdentityJSON.normalize(data, identities: snapshot, legacy: legacy)
                    try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE \(key) = ?", arguments: [String(decoding: normalized, as: UTF8.self).databaseValue, row[key] as DatabaseValue])
                }
            }
        }
    }

    /// Rewrites only this feature's references using the caller's transaction.
    enum OfflineRemapping {
        static func normalize(snapshot: IdentitySnapshot, legacy: Bool, in db: Database) throws {
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
                        try ReferenceRemapping.insert(row, table: table, replacing: ["owner_name": id.databaseValue], in: db)
                        for (childTable, children) in zip(childTables, oldChildren) {
                            for child in children { try ReferenceRemapping.insert(child, table: childTable, replacing: ["owner_name": id.databaseValue], in: db) }
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
                  let page = try? JSONDecoder().decode(CachedSourcePage.self, from: data),
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
    }
}

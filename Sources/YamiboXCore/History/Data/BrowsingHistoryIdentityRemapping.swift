import Foundation
@preconcurrency import GRDB

/// Rewrites only this feature's references using the caller's transaction.
enum BrowsingHistoryIdentityRemapping {
    static func normalize(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM browsing_history WHERE target_kind = 'mangaTitle' ORDER BY last_visit_time ASC, id ASC")
        for row in rows {
            let oldID: String = row["id"]
            let name: String = row["clean_book_name"]
            let id: String
            let oldIdentity: String? = row["manga_id"]
            if !legacy, let oldIdentity, MangaDirectoryIdentityDatabase.isStableIdentity(oldIdentity) {
                id = snapshot.canonicalID(oldIdentity)
            } else {
                let chapterColumn = "chapter_thread_id"
                // An earlier migration may deliberately leave an ambiguous
                // row untouched. Later identity updates must retry the same
                // evidence, not turn its display name into a binding.
                guard let resolved = try MangaDirectoryIdentityDatabase.resolveLegacyRecord(name: name, identity: oldIdentity, chapterTID: row[chapterColumn], allowNameFallback: legacy, in: db) else { continue }
                try MangaDirectoryIdentityDatabase.registerLegacyRecord(id: resolved, name: name, identity: oldIdentity, in: db)
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

    static func normalizeSyncedRecords(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        let records = try BrowsingHistorySyncRecord.load(in: db)
        var normalized: [String: BrowsingHistorySyncRecord] = [:]
        for record in records {
            var next = record
            if case let .mangaTitle(identity, name) = record.target {
                if legacy || !MangaDirectoryIdentityDatabase.isStableIdentity(identity) {
                    if let id = try MangaDirectoryIdentityDatabase.resolveLegacyRecord(name: name, identity: identity, chapterTID: record.threadID, allowNameFallback: legacy, in: db) {
                        try MangaDirectoryIdentityDatabase.registerLegacyRecord(id: id, name: name, identity: identity, in: db)
                        next.target = .mangaTitle(mangaID: id, cleanBookName: name)
                    }
                } else {
                    next.target = .mangaTitle(mangaID: snapshot.canonicalID(identity), cleanBookName: name)
                }
            }
            if let existing = normalized[next.id], existing.lastVisitTime >= next.lastVisitTime { continue }
            normalized[next.id] = next
        }
        try BrowsingHistorySyncRecord.save(Array(normalized.values), in: db)
    }

    static func normalizeDeletionState(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        try MangaIdentityRemapping.normalizeDeletionState(table: "browsing_history_sync_state", snapshot: snapshot, legacy: legacy, in: db)
        try MangaIdentityRemapping.normalizeDeletionState(table: "browsing_history_local_deletions", snapshot: snapshot, legacy: legacy, in: db)
    }
}

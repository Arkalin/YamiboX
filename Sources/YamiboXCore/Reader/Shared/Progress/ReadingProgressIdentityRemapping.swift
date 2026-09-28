import Foundation
@preconcurrency import GRDB

/// Rewrites only this feature's references using the caller's transaction.
enum ReadingProgressIdentityRemapping {
    static func normalize(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM reading_progress WHERE target_kind = 'mangaTitle' ORDER BY updated_at ASC, id ASC")
        for row in rows {
            let oldID: String = row["id"]
            let name: String = row["clean_book_name"]
            let id: String
            let oldIdentity: String? = row["manga_id"]
            if !legacy, let oldIdentity, MangaDirectoryIdentityDatabase.isStableIdentity(oldIdentity) {
                id = snapshot.canonicalID(oldIdentity)
            } else {
                let chapterColumn = "manga_chapter_thread_id"
                // An earlier migration may deliberately leave an ambiguous
                // row untouched. Later identity updates must retry the same
                // evidence, not turn its display name into a binding.
                guard let resolved = try MangaDirectoryIdentityDatabase.resolveLegacyRecord(name: name, identity: oldIdentity, chapterTID: row[chapterColumn], allowNameFallback: legacy, in: db) else { continue }
                try MangaDirectoryIdentityDatabase.registerLegacyRecord(id: resolved, name: name, identity: oldIdentity, in: db)
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

    static func normalizeDeletionState(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        try MangaIdentityRemapping.normalizeDeletionState(table: "reading_progress_sync_state", snapshot: snapshot, legacy: legacy, in: db)
    }
}

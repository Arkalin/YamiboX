import Foundation
@preconcurrency import GRDB

extension ReadingProgressStore {
    static func renameMangaTitleTargets(from oldName: String, to newName: String, date: Date, in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, manga_id, updated_at
            FROM reading_progress
            WHERE target_kind = ? AND clean_book_name = ?
            """,
            arguments: [FavoriteContentTargetKind.mangaTitle.rawValue, oldName]
        )
        for row in rows {
            let oldID = row["id"] as String
            let existingMangaID = row["manga_id"] as String?
            let mangaID = existingMangaID?.mangaReaderTrimmedNonEmpty == oldName
                ? newName
                : (existingMangaID?.mangaReaderTrimmedNonEmpty ?? newName)
            let newID = FavoriteContentTarget(mangaID: mangaID, mangaCleanBookName: newName).id
            if newID != oldID {
                try recordSyncDeletion(id: oldID,
                    at: max(date, Date(timeIntervalSince1970: row["updated_at"])), in: db)
            }
            if newID != oldID,
               let existing = try Row.fetchOne(
                   db,
                   sql: "SELECT updated_at FROM reading_progress WHERE id = ?",
                   arguments: [newID]
               ) {
                let existingUpdatedAt = existing["updated_at"] as Double
                let oldUpdatedAt = row["updated_at"] as Double
                if existingUpdatedAt >= oldUpdatedAt {
                    try db.execute(sql: "DELETE FROM reading_progress WHERE id = ?", arguments: [oldID])
                    continue
                }
                try db.execute(sql: "DELETE FROM reading_progress WHERE id = ?", arguments: [newID])
            }
            try db.execute(
                sql: """
                UPDATE reading_progress
                SET id = ?, manga_id = ?, clean_book_name = ?, updated_at = MAX(updated_at, ?)
                WHERE id = ?
                """,
                arguments: [newID, mangaID, newName, date.timeIntervalSince1970, oldID]
            )
        }
    }
}

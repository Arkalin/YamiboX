import Foundation
@preconcurrency import GRDB

/// Rewrites only this feature's references using the caller's transaction.
enum BookmarkIdentityRemapping {
    static func normalize(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        for oldID in try String.fetchAll(db, sql: "SELECT DISTINCT work_id FROM bookmarks WHERE work_kind = 'manga'") {
            let id = snapshot.resolve(oldID, legacy: legacy)
            try db.execute(sql: "UPDATE bookmarks SET work_id = ? WHERE work_kind = 'manga' AND work_id = ?", arguments: [id, oldID])
        }
    }
}

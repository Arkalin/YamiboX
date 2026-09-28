import Foundation
@preconcurrency import GRDB

/// Rewrites only this feature's references using the caller's transaction.
enum LikeIdentityRemapping {
    static func normalize(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        for oldID in try String.fetchAll(db, sql: "SELECT DISTINCT work_id FROM like_items WHERE work_kind = 'manga'") {
            let id = snapshot.resolve(oldID, legacy: legacy)
            try db.execute(sql: "UPDATE like_items SET work_id = ? WHERE work_kind = 'manga' AND work_id = ?", arguments: [id, oldID])
        }
    }
}

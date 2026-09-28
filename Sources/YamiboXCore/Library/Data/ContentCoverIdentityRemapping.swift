import Foundation
@preconcurrency import GRDB

/// Rewrites only this feature's references using the caller's transaction.
enum ContentCoverIdentityRemapping {
    static func normalize(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
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

    static func normalizeDeletionState(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        try MangaIdentityRemapping.normalizeDeletionState(table: "content_cover_sync_state", snapshot: snapshot, legacy: legacy, in: db)
    }

    static func preserveDestinationCover(sourceID: MangaDirectoryID, targetID: MangaDirectoryID, canonicalID: MangaDirectoryID, modifiedAt: Double, preserveClock: Bool, in db: Database) throws {
        // An explicit merge is a new cover decision, not merely a key move.
        // Advance beyond both inputs so a pre-merge remote source cover cannot
        // overwrite the chosen destination after its key follows the redirect.
        if let cover = try Row.fetchOne(db, sql: "SELECT * FROM content_cover WHERE target_type = 'SmartManga' AND target_id = ?", arguments: [targetID.rawValue]) {
            let inputClock = try Double.fetchOne(db, sql: "SELECT MAX(updated_at) FROM content_cover WHERE target_type = 'SmartManga' AND target_id IN (?, ?)", arguments: [sourceID.rawValue, targetID.rawValue]) ?? 0
            let coverClock: Double = preserveClock ? cover["updated_at"] : max(modifiedAt, inputClock) + 0.001
            try db.execute(sql: "DELETE FROM content_cover WHERE target_type = 'SmartManga' AND target_id IN (?, ?)", arguments: [sourceID.rawValue, targetID.rawValue])
            try MangaIdentityRemapping.insert(cover, table: "content_cover", replacing: ["target_id": canonicalID.rawValue.databaseValue, "updated_at": coverClock.databaseValue], in: db)
        }
    }
}

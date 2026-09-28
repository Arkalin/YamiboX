import Foundation
@preconcurrency import GRDB

extension BrowsingHistorySyncRecord {
    static func load(in db: Database) throws -> [Self] {
        try Data.fetchAll(db, sql: "SELECT record FROM browsing_history_sync_records ORDER BY id").map {
            try JSONDecoder().decode(Self.self, from: $0)
        }
    }

    static func save(_ records: [Self], in db: Database) throws {
        try db.execute(sql: "DELETE FROM browsing_history_sync_records")
        for record in records {
            try record.save(in: db)
        }
    }

    func save(in db: Database) throws {
        var record = self
        record.target = try MangaDirectoryIdentityDatabase.canonicalTarget(target, in: db)
        try db.execute(sql: "INSERT OR REPLACE INTO browsing_history_sync_records (id, record, last_visit_time) VALUES (?, ?, ?)",
            arguments: [record.id, try JSONEncoder().encode(record), record.lastVisitTime.timeIntervalSince1970])
    }
}

import CryptoKit
import Foundation
@preconcurrency import GRDB

/// Rewrites only this feature's references using the caller's transaction.
enum DownloadIdentityRemapping {
    static func normalize(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        for (table, childTables, predicate) in [
            ("download_manga_entries", ["download_manga_entry_images"], "1"),
            ("download_works", ["download_work_images", "download_completed_images"], "reader_kind = 'manga'")
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
                    if table == "download_manga_entries" {
                        preferSource = try downloadCompleteness(row, in: db) > downloadCompleteness(existing, in: db)
                    } else {
                        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM download_completed_images WHERE \(whereClause)", arguments: [id, tid]) ?? 0
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
                    try MangaIdentityRemapping.insert(row, table: table, replacing: ["owner_name": id.databaseValue], in: db)
                    for (childTable, children) in zip(childTables, oldChildren) {
                        for child in children { try MangaIdentityRemapping.insert(child, table: childTable, replacing: ["owner_name": id.databaseValue], in: db) }
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

    /// The app places downloads beside the database. Only conflicting
    /// memberships need I/O; compare existing payloads without renaming files.
    private static func downloadCompleteness(_ row: Row, in db: Database) throws -> Int {
        guard let mainDatabase = try Row.fetchAll(db, sql: "PRAGMA database_list").first(where: { $0["name"] as String == "main" }),
              let path: String = mainDatabase["file"], !path.isEmpty else { return 0 }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("downloads", isDirectory: true)
        guard let fileName: String = row["source_page_file_name"],
              row["source_page_schema_version"] as Int? == 1,
              let fingerprint: String = row["source_page_fingerprint"],
              let data = try? Data(contentsOf: root.appendingPathComponent("manga-source-pages").appendingPathComponent(fileName)),
              data.count == row["byte_count"] as Int,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == fingerprint,
              let page = try? JSONDecoder().decode(ForumThreadPage.self, from: data),
              page.thread.tid == row["tid"] as String else { return 0 }
        let files = try Row.fetchAll(db, sql: """
            SELECT a.file_name FROM download_manga_entry_images i
            LEFT JOIN download_image_assets a ON a.image_url = i.image_url
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

import Foundation
@preconcurrency import GRDB

extension DownloadStore {
    static func canonicalMangaOwnerKey(_ key: String, in db: Database) throws -> String {
        try MangaDirectoryIdentityDatabase.canonicalID(MangaDirectoryID(rawValue: key), in: db).rawValue
    }

    static func mangaOwnerTitle(_ key: String, fallback: String? = nil, in db: Database) throws -> String {
        let canonical = try canonicalMangaOwnerKey(key, in: db)
        return try String.fetchOne(db, sql: "SELECT name FROM manga_identities WHERE id = ?", arguments: [canonical]) ?? fallback ?? key
    }

    static func downloadMangaIdentitySnapshot(in db: Database) throws -> DownloadMangaIdentitySnapshot {
        var result = DownloadMangaIdentitySnapshot()
        for row in try Row.fetchAll(db, sql: "SELECT CAST(id AS BLOB) AS raw_id, CAST(canonical_id AS TEXT) AS canonical_id FROM manga_identity_redirects WHERE typeof(id) = 'text'") {
            result.redirects[row["raw_id"]] = row["canonical_id"]
        }
        for row in try Row.fetchAll(db, sql: "SELECT CAST(id AS BLOB) AS raw_id, CAST(name AS TEXT) AS name FROM manga_identities WHERE typeof(id) = 'text'") {
            result.titles[row["raw_id"]] = row["name"]
        }
        return result
    }
}

struct DownloadMangaIdentitySnapshot {
    var redirects: [Data: String] = [:]
    var titles: [Data: String] = [:]

    func canonicalID(_ id: String) -> String {
        var value = id
        var visited: Set<String> = []
        while let next = redirects[Data(value.utf8)], visited.insert(value).inserted {
            value = next
        }
        return value
    }

    func title(for id: String) -> String? { titles[Data(id.utf8)] }
}

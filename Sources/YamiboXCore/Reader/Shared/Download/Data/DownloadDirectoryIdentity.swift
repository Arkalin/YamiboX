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

    /// Batch display readers need names and redirects, not the registry's
    /// potentially much larger historical-alias collection.
    static func downloadMangaIdentitySnapshot(in db: Database) throws -> DownloadMangaIdentitySnapshot {
        var result = DownloadMangaIdentitySnapshot()
        // Scalar String fetches coerced SQLite values; cached Row decoding is
        // stricter, so keep that conversion for historical title/redirect data.
        for row in try Row.fetchAll(db, sql: "SELECT CAST(id AS BLOB) AS raw_id, CAST(canonical_id AS TEXT) AS canonical_id FROM manga_identity_redirects WHERE typeof(id) = 'text'") {
            result.redirects[row["raw_id"]] = row["canonical_id"]
        }
        for row in try Row.fetchAll(db, sql: "SELECT CAST(id AS BLOB) AS raw_id, CAST(name AS TEXT) AS name FROM manga_identities WHERE typeof(id) = 'text'") {
            result.titles[row["raw_id"]] = row["name"]
        }
        return result
    }
}

/// SQLite BINARY text keys distinguish NFC/NFD strings; Swift String keys do
/// not. Read their original bytes before GRDB's text decoding can truncate
/// embedded NULs or replace invalid UTF-8. Only TEXT keys match TEXT bindings.
struct DownloadMangaIdentitySnapshot {
    var redirects: [Data: String] = [:]
    var titles: [Data: String] = [:]

    func canonicalID(_ id: String) -> String {
        var value = id
        var visited: Set<String> = []
        // Match canonicalMangaOwnerKey's existing cycle-termination behavior.
        while let next = redirects[Data(value.utf8)], visited.insert(value).inserted {
            value = next
        }
        return value
    }

    func title(for id: String) -> String? { titles[Data(id.utf8)] }
}

import Foundation
@preconcurrency import GRDB

extension OfflineCacheStore {
    static func canonicalMangaOwnerKey(_ key: String, in db: Database) throws -> String {
        try MangaDirectoryIdentityDatabase.canonicalID(MangaDirectoryID(rawValue: key), in: db).rawValue
    }

    static func mangaOwnerTitle(_ key: String, fallback: String? = nil, in db: Database) throws -> String {
        let canonical = try canonicalMangaOwnerKey(key, in: db)
        return try String.fetchOne(db, sql: "SELECT name FROM manga_identities WHERE id = ?", arguments: [canonical]) ?? fallback ?? key
    }
}

import Foundation
@preconcurrency import GRDB

/// Shared identity registry. Business-table rewrites belong to their feature adapters.
/// Directory cache deletion intentionally never deletes this registry.
enum MangaDirectoryIdentityDatabase {
    // A historical display name can now belong to an unrelated directory.
    // Prefer chapter/opaque-identity evidence and retain conflicting records
    // unresolved instead of attaching them to whichever title currently exists.
    static func resolveLegacyRecord(name: String, identity: String?, chapterTID: String?, allowNameFallback: Bool = true, in db: Database) throws -> String? {
        let identities = try snapshot(in: db)
        let usesStableIDs = try db.columns(in: "manga_directory_chapters").contains { $0.name == "directory_id" }
        let ownerColumn = usesStableIDs ? "directory_id" : "directory_name"
        let chapterOwners = Set(try chapterTID.map {
            try String.fetchAll(db, sql: "SELECT DISTINCT \(ownerColumn) FROM manga_directory_chapters WHERE tid = ?", arguments: [$0])
                .map { identities.canonicalID(usesStableIDs ? $0 : MangaDirectoryID.legacy(name: $0).rawValue) }
        } ?? [])
        let identityOwners: Set<String>
        if let identity, identity != name {
            identityOwners = Set(try String.fetchAll(db, sql: "SELECT directory_id FROM manga_identity_aliases WHERE kind = 'favorite' AND alias = ?", arguments: [identity]).map { identities.canonicalID($0) })
        } else { identityOwners = [] }
        if !chapterOwners.isEmpty && !identityOwners.isEmpty {
            let candidates = chapterOwners.intersection(identityOwners)
            return candidates.count == 1 ? candidates.first : nil
        }
        let candidates = chapterOwners.union(identityOwners)
        if !candidates.isEmpty { return candidates.count == 1 ? candidates.first : nil }
        guard allowNameFallback else { return nil }
        let names = Set(try String.fetchAll(db, sql: "SELECT directory_id FROM manga_identity_aliases WHERE kind = 'name' AND alias = ?", arguments: [name]).map { identities.canonicalID($0) })
        return names.count > 1 ? nil : names.first ?? MangaDirectoryID.legacy(name: name).rawValue
    }

    static func isStableIdentity(_ identity: String?) -> Bool {
        guard let identity else { return false }
        return identity.hasPrefix("manga-id:") || identity.hasPrefix("manga-legacy:") || identity.hasPrefix("manga-thread:")
    }

    static func registerLegacyRecord(id: String, name: String, identity: String?, in db: Database) throws {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM manga_identities WHERE id = ?)", arguments: [id]) != true {
            try register(id: id, name: name, modifiedAt: 0, in: db)
        } else if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM manga_identity_aliases WHERE kind = 'name' AND alias = ? AND directory_id != ?)", arguments: [name, id]) != true {
            try addAlias(name, kind: "name", id: id, in: db)
        }
        if let identity, identity != name,
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM manga_identity_aliases WHERE kind = 'favorite' AND alias = ? AND directory_id != ?)", arguments: [identity, id]) != true {
            try addAlias(identity, kind: "favorite", id: id, in: db)
        }
    }

    static func register(id: String, name: String, modifiedAt: Double = Date.now.timeIntervalSince1970, in db: Database) throws {
        try db.execute(sql: "INSERT INTO manga_identities(id, name, modified_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, modified_at = excluded.modified_at WHERE manga_identities.name != excluded.name", arguments: [id, name, modifiedAt])
        try addAlias(name, kind: "name", id: id, in: db)
    }

    static func canonicalID(_ id: MangaDirectoryID, in db: Database) throws -> MangaDirectoryID {
        guard try db.tableExists("manga_identity_redirects") else { return id }
        var value = id.rawValue
        var visited: Set<String> = []
        while let next = try String.fetchOne(db, sql: "SELECT canonical_id FROM manga_identity_redirects WHERE id = ?", arguments: [value]), visited.insert(value).inserted {
            value = next
        }
        return MangaDirectoryID(rawValue: value)
    }

    static func canonicalWorkID(_ key: ReadingWorkKey, in db: Database) throws -> String {
        key.kind == .manga ? try canonicalID(MangaDirectoryID(rawValue: key.id), in: db).rawValue : key.id
    }

    static func canonicalTarget(_ target: FavoriteContentTarget, in db: Database) throws -> FavoriteContentTarget {
        guard case let .mangaTitle(id, name) = target else { return target }
        return .mangaTitle(mangaID: try canonicalID(MangaDirectoryID(rawValue: id), in: db).rawValue, cleanBookName: name)
    }

    static func addAlias(_ alias: String, kind: String, id: String, in db: Database) throws {
        guard !alias.isEmpty else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO manga_identity_aliases(kind, alias, directory_id) VALUES (?, ?, ?)", arguments: [kind, alias, id])
    }

    /// Batch readers only need redirects to resolve stable IDs. Names and
    /// aliases remain live database reads when a transaction registers content.
    static func redirectSnapshot(in db: Database) throws -> MangaDirectoryIdentitySnapshot {
        var result = MangaDirectoryIdentitySnapshot()
        for row in try Row.fetchAll(db, sql: "SELECT id, canonical_id FROM manga_identity_redirects") { result.redirects[row["id"]] = row["canonical_id"] }
        return result
    }

    static func snapshot(in db: Database) throws -> MangaDirectoryIdentitySnapshot {
        var result = try redirectSnapshot(in: db)
        var names: [String: Set<String>] = [:]
        var identities: [String: Set<String>] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT kind, alias, directory_id FROM manga_identity_aliases") {
            let alias: String = row["alias"]
            let id = result.canonicalID(row["directory_id"])
            if row["kind"] as String == "name" { names[alias, default: []].insert(id) }
            else { identities[alias, default: []].insert(id) }
        }
        result.names = names.compactMapValues { $0.count == 1 ? $0.first : nil }
        result.legacyIdentities = identities.compactMapValues { $0.count == 1 ? $0.first : nil }
        for row in try Row.fetchAll(db, sql: "SELECT id, name, modified_at FROM manga_identities") {
            let id: String = row["id"]
            guard result.canonicalID(id) == id else { continue }
            result.titles[id] = row["name"]
            result.titleModifiedAt[id] = row["modified_at"]
        }
        return result
    }

    static func redirect(_ source: String, to target: String, in db: Database) throws {
        guard source != target else { return }
        try db.execute(sql: "INSERT INTO manga_identity_redirects(id, canonical_id) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET canonical_id = excluded.canonical_id", arguments: [source, target])
        try db.execute(sql: "UPDATE manga_identity_redirects SET canonical_id = ? WHERE canonical_id = ?", arguments: [target, source])
    }

}

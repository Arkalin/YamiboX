import Foundation
@preconcurrency import GRDB

/// Cross-feature reference changes happen only for explicit identity merges.
struct GRDBMangaDirectoryIdentityMigration: Sendable {
    private let database: DatabasePool

    init(databasePool: DatabasePool) {
        database = databasePool
    }

    func mergeDirectories(sourceID: MangaDirectoryID, targetID: MangaDirectoryID, cleanBookName: String, searchKeyword: String?) async throws -> MangaDirectory {
        try await database.write { db in
            let canonicalSource = try MangaDirectoryIdentityDatabase.canonicalID(sourceID, in: db)
            let canonicalTarget = try MangaDirectoryIdentityDatabase.canonicalID(targetID, in: db)
            guard let target = try MangaDirectoryStore.directory(id: canonicalTarget, in: db) else {
                throw YamiboPersistenceError(context: "Directory no longer exists")
            }
            let source: MangaDirectory
            if let cached = try MangaDirectoryStore.directory(id: canonicalSource, in: db) { source = cached }
            else if let name = try String.fetchOne(db, sql: "SELECT name FROM manga_identities WHERE id = ?", arguments: [canonicalSource.rawValue]) {
                // Identity-only data can join an existing directory without
                // first fabricating or persisting a directory cache of its own.
                source = MangaDirectory(id: canonicalSource, cleanBookName: name, strategy: target.strategy, sourceKey: target.sourceKey)
            } else { throw YamiboPersistenceError(context: "Directory identity no longer exists") }
            guard source.id != target.id else { return target }
            let result = try Self.merge(source: source, target: target, name: cleanBookName, searchKeyword: searchKeyword, in: db)
            try MangaIdentityRemapping.normalizeReferences(snapshot: MangaDirectoryIdentityDatabase.snapshot(in: db), legacy: false, in: db)
            return result
        }
    }

    @discardableResult
    private static func merge(source: MangaDirectory, target: MangaDirectory, name: String, searchKeyword: String?, preserveClock: Bool = false, in db: Database) throws -> MangaDirectory {
        let canonical = min(source.id, target.id)
        let losing = max(source.id, target.id)
        let sourceContentIDs = try MangaDirectoryStore.contentIdentityIDs(id: source.id, in: db) ?? []
        let targetContentIDs = try MangaDirectoryStore.contentIdentityIDs(id: target.id, in: db) ?? []
        let mergedContentIDs = sourceContentIDs.union(targetContentIDs)
        let modifiedAt = preserveClock ? try Double.fetchOne(db, sql: "SELECT MAX(modified_at) FROM manga_directories WHERE id IN (?, ?)", arguments: [source.id.rawValue, target.id.rawValue]) ?? 0 : Date.now.timeIntervalSince1970
        let titleClock = preserveClock ? try Double.fetchOne(db, sql: "SELECT modified_at FROM manga_identities WHERE id = ?", arguments: [target.id.rawValue]) ?? 0 : modifiedAt
        var result = target.reidentified(as: canonical)
        result.cleanBookName = name
        result.searchKeyword = searchKeyword
        result.chapters = MangaDirectoryMerge.mergeAndSort(target.chapters, source.chapters)
        try ContentCoverIdentityRemapping.preserveDestinationCover(sourceID: source.id, targetID: target.id, canonicalID: canonical, modifiedAt: modifiedAt, preserveClock: preserveClock, in: db)
        try db.execute(sql: "DELETE FROM manga_directories WHERE id IN (?, ?)", arguments: [source.id.rawValue, target.id.rawValue])
        try MangaDirectoryIdentityDatabase.redirect(losing.rawValue, to: canonical.rawValue, in: db)
        try MangaDirectoryStore.save(result, modifiedAt: Date(timeIntervalSince1970: modifiedAt), allowRename: true, contentIdentityIDs: mergedContentIDs, in: db)
        try db.execute(sql: "UPDATE manga_identities SET modified_at = ? WHERE id = ?", arguments: [titleClock, canonical.rawValue])
        return result
    }

    static func mergeIdentitySnapshot(_ remote: MangaDirectoryIdentitySnapshot, in db: Database) throws {
        let local = try MangaDirectoryIdentityDatabase.snapshot(in: db)
        var parent: [String: String] = [:]
        func root(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current { current = next }
            return current
        }
        func unite(_ lhs: String, _ rhs: String) {
            let left = root(lhs), right = root(rhs)
            if left != right { parent[max(left, right)] = min(left, right) }
        }
        for (source, target) in local.redirects { unite(source, target) }
        for (source, target) in remote.redirects { unite(source, target) }
        for (name, id) in remote.names {
            if let existing = local.names[name] { unite(existing, id) }
        }
        for (alias, id) in remote.legacyIdentities {
            if let existing = local.legacyIdentities[alias] { unite(existing, id) }
        }
        let allIDs = Set(remote.names.values).union(remote.legacyIdentities.values).union(remote.redirects.keys).union(remote.redirects.values).union(remote.titles.keys).union(parent.keys).union(parent.values)
        // Keep the same smallest-alias choice without sorting every alias
        // again for each identity, including identities with no name alias.
        var preferredNameByID: [String: String] = [:]
        for (name, id) in remote.names {
            if let current = preferredNameByID[id], current <= name { continue }
            preferredNameByID[id] = name
        }
        for id in allIDs {
            let name = preferredNameByID[id] ?? id
            try db.execute(sql: "INSERT OR IGNORE INTO manga_identities(id, name) VALUES (?, ?)", arguments: [id, name])
        }
        // Merge cached local directories before publishing redirects so lookups
        // still distinguish both source rows. Orphan identities need no directory.
        for id in parent.keys.sorted() {
            let canonical = root(id)
            if let source = try MangaDirectoryStore.directory(id: MangaDirectoryID(rawValue: id), in: db), source.id.rawValue == id {
                if let target = try MangaDirectoryStore.directory(id: MangaDirectoryID(rawValue: canonical), in: db) {
                    try merge(source: source, target: target, name: target.cleanBookName, searchKeyword: target.searchKeyword, preserveClock: true, in: db)
                } else {
                    let contentIdentityIDs = try MangaDirectoryStore.contentIdentityIDs(id: source.id, in: db) ?? [source.id.rawValue]
                    let clock = try Double.fetchOne(db, sql: "SELECT modified_at FROM manga_directories WHERE id = ?", arguments: [id]) ?? 0
                    let titleClock = try Double.fetchOne(db, sql: "SELECT modified_at FROM manga_identities WHERE id = ?", arguments: [id]) ?? 0
                    let canonicalClock = try Double.fetchOne(db, sql: "SELECT modified_at FROM manga_identities WHERE id = ?", arguments: [canonical]) ?? 0
                    let canonicalName = try String.fetchOne(db, sql: "SELECT name FROM manga_identities WHERE id = ?", arguments: [canonical]) ?? ""
                    let adoptsSourceTitle = titleClock > canonicalClock || (titleClock == canonicalClock && source.cleanBookName > canonicalName)
                    try db.execute(sql: "DELETE FROM manga_directories WHERE id = ?", arguments: [id])
                    try MangaDirectoryStore.save(source.reidentified(as: MangaDirectoryID(rawValue: canonical)), modifiedAt: Date(timeIntervalSince1970: clock), allowRename: adoptsSourceTitle, contentIdentityIDs: contentIdentityIDs, in: db)
                    try db.execute(sql: "UPDATE manga_identities SET modified_at = ? WHERE id = ?", arguments: [max(titleClock, canonicalClock), canonical])
                }
            }
            try MangaDirectoryIdentityDatabase.redirect(id, to: canonical, in: db)
        }
        for (name, id) in remote.names { try MangaDirectoryIdentityDatabase.addAlias(name, kind: "name", id: id, in: db) }
        for (alias, id) in remote.legacyIdentities { try MangaDirectoryIdentityDatabase.addAlias(alias, kind: "favorite", id: id, in: db) }
        // Resolve the whole batch before looking for name collisions. A name
        // occupied now may be vacated by another winning rename in this batch.
        var winningTitles: [String: (name: String, modifiedAt: Double)] = [:]
        // The content merges above retain destination metadata. Compare the
        // pre-merge local titles too: a losing ID may have an unsynced rename
        // newer than both the destination and the incoming redirect's title.
        for snapshot in [local, remote] {
            for (id, title) in snapshot.titles {
                let canonical = try MangaDirectoryIdentityDatabase.canonicalID(MangaDirectoryID(rawValue: id), in: db).rawValue
                let row = try Row.fetchOne(db, sql: "SELECT name, modified_at FROM manga_identities WHERE id = ?", arguments: [canonical])
                let currentTime: Double = winningTitles[canonical]?.modifiedAt ?? row?["modified_at"] ?? 0
                let currentTitle: String = winningTitles[canonical]?.name ?? row?["name"] ?? ""
                let candidateTime = snapshot.titleModifiedAt[id] ?? 0
                guard candidateTime > currentTime || (candidateTime == currentTime && title > currentTitle) else { continue }
                winningTitles[canonical] = (title, candidateTime)
            }
        }
        // Stage only the UNIQUE display-name column, inside this transaction.
        // Do not pass temporary names through save/register: they are not
        // identity aliases and must never advance a title's conflict clock.
        for (id, title) in winningTitles {
            guard let name = try String.fetchOne(db, sql: "SELECT clean_book_name FROM manga_directories WHERE id = ?", arguments: [id]), name != title.name else { continue }
            var temporaryName: String
            repeat {
                temporaryName = "manga-title-staging:" + UUID().uuidString
            } while try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM manga_directories WHERE clean_book_name = ?)", arguments: [temporaryName]) == true || winningTitles.values.contains(where: { $0.name == temporaryName })
            try db.execute(sql: "UPDATE manga_directories SET clean_book_name = ? WHERE id = ?", arguments: [temporaryName, id])
        }
        for (id, winningTitle) in winningTitles.sorted(by: { $0.key < $1.key }) {
            let canonical = try MangaDirectoryIdentityDatabase.canonicalID(MangaDirectoryID(rawValue: id), in: db).rawValue
            let title = winningTitle.name
            // A title may already belong to a directory discovered independently.
            // Only final-name collisions remain after staging the batch.
            if let existing = try MangaDirectoryStore.directory(named: title, in: db), existing.id.rawValue != canonical {
                if let source = try MangaDirectoryStore.directory(id: MangaDirectoryID(rawValue: canonical), in: db) {
                    try merge(source: source, target: existing, name: title, searchKeyword: existing.searchKeyword, preserveClock: true, in: db)
                } else {
                    let winner = min(canonical, existing.id.rawValue)
                    let loser = max(canonical, existing.id.rawValue)
                    if existing.id.rawValue != winner {
                        let contentIdentityIDs = try MangaDirectoryStore.contentIdentityIDs(id: existing.id, in: db) ?? [existing.id.rawValue]
                        let clock = try Double.fetchOne(db, sql: "SELECT modified_at FROM manga_directories WHERE id = ?", arguments: [existing.id.rawValue]) ?? 0
                        try db.execute(sql: "DELETE FROM manga_directories WHERE id = ?", arguments: [existing.id.rawValue])
                        try MangaDirectoryStore.save(existing.reidentified(as: MangaDirectoryID(rawValue: winner)), modifiedAt: Date(timeIntervalSince1970: clock), allowRename: true, contentIdentityIDs: contentIdentityIDs, in: db)
                    }
                    try MangaDirectoryIdentityDatabase.redirect(loser, to: winner, in: db)
                }
            }
            let resolved = try MangaDirectoryIdentityDatabase.canonicalID(MangaDirectoryID(rawValue: canonical), in: db).rawValue
            let currentClock = try Double.fetchOne(db, sql: "SELECT modified_at FROM manga_identities WHERE id = ?", arguments: [resolved]) ?? 0
            let titleClock = max(currentClock, winningTitle.modifiedAt)
            try db.execute(sql: "UPDATE manga_identities SET name = ?, modified_at = ? WHERE id = ?", arguments: [title, titleClock, resolved])
            try MangaDirectoryIdentityDatabase.addAlias(title, kind: "name", id: resolved, in: db)
            // Identity metadata can arrive through progress/annotations before
            // directory content. Do not give the cached chapter list the title's
            // newer clock: it would tie with, and potentially replace, the real
            // remote content when directory synchronization runs later.
            try db.execute(sql: "UPDATE manga_directories SET clean_book_name = ? WHERE id = ?", arguments: [title, resolved])
        }
        try MangaIdentityRemapping.normalizeReferences(snapshot: MangaDirectoryIdentityDatabase.snapshot(in: db), legacy: false, in: db)
    }
}

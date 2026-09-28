import Foundation
@preconcurrency import GRDB

public actor MangaDirectoryStore: MangaDirectoryPersisting {
    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let database: DatabasePool
    private let syncSettingsStore: WebDAVSyncSettingsStore
    private let identityMigration: GRDBMangaDirectoryIdentityMigration
    /// These instances receive notifications only; the migration uses this
    /// store's pool. Custom compositions must supply owners of the same data.
    private let favoriteUpdateStore: FavoriteUpdateStore?
    private let readingProgressStore: ReadingProgressStore?
    private var prepareIdentityChange: @Sendable () async throws -> Void
    private var finishIdentityChange: @Sendable () async -> Void
    private let identityChangeCommitted: @Sendable () -> Void
    private var identityChangeInProgress = false
    private var identityChangeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        databasePool: DatabasePool? = nil,
        syncSettingsStore: WebDAVSyncSettingsStore = WebDAVSyncSettingsStore(),
        favoriteUpdateStore: FavoriteUpdateStore? = nil,
        readingProgressStore: ReadingProgressStore? = nil,
        prepareIdentityChange: @escaping @Sendable () async throws -> Void = {},
        finishIdentityChange: @escaping @Sendable () async -> Void = {},
        identityChangeCommitted: @escaping @Sendable () -> Void = {}
    ) {
        let database = databasePool ?? YamiboDatabasePoolResolver.openDefaultPool(storeName: "MangaDirectoryStore")
        self.database = database
        self.syncSettingsStore = syncSettingsStore
        self.identityMigration = GRDBMangaDirectoryIdentityMigration(databasePool: database)
        self.favoriteUpdateStore = favoriteUpdateStore
        self.readingProgressStore = readingProgressStore
        self.prepareIdentityChange = prepareIdentityChange
        self.finishIdentityChange = finishIdentityChange
        self.identityChangeCommitted = identityChangeCommitted
    }

    public func directory(named name: String) async throws -> MangaDirectory? {
        guard let name = name.nilIfBlank else { return nil }
        return try await database.read { db in
            try Self.directory(named: name, in: db)
        }
    }

    public func directory(id: MangaDirectoryID) async throws -> MangaDirectory? {
        try await database.read { db in try Self.directory(id: id, in: db) }
    }

    public func resolveOrCreateDirectory(_ seed: MangaDirectory) async throws -> MangaDirectory {
        let saved = try await database.write { db in
            guard let name = seed.cleanBookName.nilIfBlank else {
                throw YamiboPersistenceError(context: "Directory name is empty")
            }
            let identities = try MangaDirectoryIdentityDatabase.snapshot(in: db)
            let seedID = MangaDirectoryID(rawValue: identities.canonicalID(seed.id.rawValue))
            let hasIdentity = identities.titles[seedID.rawValue] != nil
            // An unpersisted random seed is not a second business identity.
            // Check names and aliases inside the same write transaction as the
            // insert, so simultaneous first discoveries adopt one directory.
            let resolvedID = hasIdentity ? seedID : identities.names[name].map { MangaDirectoryID(rawValue: identities.canonicalID($0)) }
            let existing: MangaDirectory?
            if let resolvedID {
                existing = try Self.directory(id: resolvedID, in: db)
            } else {
                existing = try Self.directory(named: name, in: db)
            }
            var candidate = seed.reidentified(as: resolvedID ?? existing?.id ?? seedID)
            if var existing {
                // Discovery can add a sibling but must not replace a concurrent
                // creator's chapters or overwrite established user metadata.
                var known = Set(existing.chapters.map(\.tid))
                existing.chapters += seed.chapters.filter { known.insert($0.tid).inserted }
                candidate = existing
            }
            try Self.save(candidate, in: db)
            guard let persisted = try Self.directory(id: candidate.id, in: db) else {
                throw YamiboPersistenceError(context: "Directory no longer exists")
            }
            return persisted
        }
        postChangeNotification()
        return saved
    }

    public func directoryRefreshSnapshot(id: MangaDirectoryID) async throws -> MangaDirectoryRefreshSnapshot? {
        try await database.read { db in
            guard let directory = try Self.directory(id: id, in: db) else { return nil }
            return MangaDirectoryRefreshSnapshot(
                directory: directory,
                contentIdentityIDs: try Self.contentIdentityIDs(id: directory.id, in: db) ?? [directory.id.rawValue]
            )
        }
    }

    public func saveRefreshedDirectory(_ directory: MangaDirectory, from snapshot: MangaDirectoryRefreshSnapshot) async throws -> MangaDirectory {
        let saved = try await database.write { db in
            var updated = directory
            if let current = try Self.directory(id: directory.id, in: db),
               let sources = try Self.contentIdentityIDs(id: current.id, in: db),
               current.id != snapshot.directory.id || !sources.isSubset(of: snapshot.contentIdentityIDs) {
                // A merge can retain the refreshing directory's ID. Its old
                // snapshot must not replace the destination's merged content,
                // nor claim the new provenance for an incomplete chapter list.
                let baselineTIDs = Set(snapshot.directory.chapters.map(\.tid))
                var known = Set(current.chapters.map(\.tid))
                updated = current
                updated.chapters += directory.chapters.filter {
                    !baselineTIDs.contains($0.tid) && known.insert($0.tid).inserted
                }
                updated.lastUpdatedAt = [current.lastUpdatedAt, directory.lastUpdatedAt].compactMap { $0 }.max()
            }
            try Self.save(updated, in: db)
            guard let persisted = try Self.directory(id: updated.id, in: db) else {
                throw YamiboPersistenceError(context: "Directory no longer exists")
            }
            return persisted
        }
        postChangeNotification()
        return saved
    }

    public func canonicalDirectoryID(_ id: MangaDirectoryID) async throws -> MangaDirectoryID {
        try await database.read { db in try MangaDirectoryIdentityDatabase.canonicalID(id, in: db) }
    }

    public func registerIdentity(id: MangaDirectoryID, name: String) async throws {
        try await database.write { db in
            let canonical = try MangaDirectoryIdentityDatabase.canonicalID(id, in: db).rawValue
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM manga_identities WHERE id = ?)", arguments: [canonical]) != true {
                try MangaDirectoryIdentityDatabase.register(id: canonical, name: name, in: db)
            } else { try MangaDirectoryIdentityDatabase.addAlias(name, kind: "name", id: canonical, in: db) }
        }
    }

    public func identityName(id: MangaDirectoryID) async throws -> String? {
        try await database.read { db in
            let canonical = try MangaDirectoryIdentityDatabase.canonicalID(id, in: db).rawValue
            return try String.fetchOne(db, sql: "SELECT name FROM manga_identities WHERE id = ?", arguments: [canonical])
        }
    }

    public func resolveDirectoryID(legacyName: String?, legacyIdentity: String?, chapterTID: String?) async throws -> MangaDirectoryID? {
        try await database.read { db in
            let snapshot = try MangaDirectoryIdentityDatabase.snapshot(in: db)
            var candidates: Set<String> = []
            if let name = legacyName, let id = snapshot.names[name] { candidates.insert(id) }
            if let identity = legacyIdentity, let id = snapshot.legacyIdentities[identity] { candidates.insert(id) }
            if let tid = chapterTID {
                let ids = Set(try String.fetchAll(db, sql: "SELECT directory_id FROM manga_directory_chapters WHERE tid = ?", arguments: [tid]))
                if !ids.isEmpty {
                    if candidates.isEmpty { candidates = ids }
                    else { candidates.formIntersection(ids) }
                }
            }
            guard candidates.count == 1, let id = candidates.first else { return nil }
            return MangaDirectoryID(rawValue: snapshot.canonicalID(id))
        }
    }

    public func identitySnapshot() async throws -> MangaDirectoryIdentitySnapshot {
        try await database.read { db in try MangaDirectoryIdentityDatabase.snapshot(in: db) }
    }

    /// Old history can retain a title subsequently reused by another directory.
    /// A conflict is not a license to bind that record by its display name.
    func resolveLegacyImportDirectoryID(name: String, identity: String?, chapterTID: String?, allowNameFallback: Bool = true) async throws -> MangaDirectoryID? {
        try await database.read { db in
            try MangaDirectoryIdentityDatabase.resolveLegacyRecord(name: name, identity: identity, chapterTID: chapterTID, allowNameFallback: allowNameFallback, in: db)
                .map(MangaDirectoryID.init(rawValue:))
        }
    }

    public func mergeIdentitySnapshot(_ snapshot: MangaDirectoryIdentitySnapshot) async throws {
        await acquireIdentityChange()
        defer { releaseIdentityChange() }
        let current = try await identitySnapshot()
        let hasChanges = snapshot.names.contains { current.names[$0.key] != current.canonicalID($0.value) }
            || snapshot.legacyIdentities.contains { current.legacyIdentities[$0.key] != current.canonicalID($0.value) }
            || snapshot.redirects.contains { current.canonicalID($0.key) != current.canonicalID($0.value) }
            || snapshot.titles.contains { id, title in
                let canonical = current.canonicalID(id)
                let incomingTime = snapshot.titleModifiedAt[id] ?? 0
                let localTime = current.titleModifiedAt[canonical] ?? 0
                return incomingTime > localTime || (incomingTime == localTime && title > (current.titles[canonical] ?? ""))
            }
        guard hasChanges else { return }
        do {
            try await prepareIdentityChange()
            try await database.write { db in try GRDBMangaDirectoryIdentityMigration.mergeIdentitySnapshot(snapshot, in: db) }
            await finishIdentityChange()
            notifyIdentityChange()
        } catch {
            await finishIdentityChange()
            throw error
        }
    }

    public func configureOfflineCacheIdentityChange(prepare: @escaping @Sendable () async throws -> Void, finish: @escaping @Sendable () async -> Void) {
        prepareIdentityChange = prepare
        finishIdentityChange = finish
    }

    private func acquireIdentityChange() async {
        if identityChangeInProgress { await withCheckedContinuation { identityChangeWaiters.append($0) } }
        else { identityChangeInProgress = true }
    }

    private func releaseIdentityChange() {
        if identityChangeWaiters.isEmpty { identityChangeInProgress = false }
        else { identityChangeWaiters.removeFirst().resume() }
    }

    private func notifyIdentityChange() {
        favoriteUpdateStore?.notifyExternalMutation()
        readingProgressStore?.notifyIdentityMigrationCommitted()
        identityChangeCommitted()
        postChangeNotification()
    }

    public func directory(containingTID tid: String) async throws -> MangaDirectory? {
        guard let tid = tid.nilIfBlank else { return nil }
        return try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT d.clean_book_name
                FROM manga_directories d
                JOIN manga_directory_chapters c ON c.directory_id = d.id
                WHERE c.tid = ?
                ORDER BY COALESCE(d.last_updated_at, -62135769600) DESC, d.clean_book_name ASC
                LIMIT 1
                """,
                arguments: [tid]
            ) else {
                return nil
            }
            return try Self.directory(named: row["clean_book_name"], in: db)
        }
    }

    /// Bulk tid → owning-directory lookup used by favorites' virtual
    /// merged-directory grouping (smart-comic-mode Phase E). Mirrors
    /// `directory(containingTID:)`'s JOIN/most-recently-updated-directory-
    /// wins ordering, just batched: a single `WHERE c.tid IN (...)` query
    /// resolves every tid's owning directory name in one round trip (chunked
    /// only if the input is larger than `Self.maxInClauseBatchSize` — see
    /// that constant's doc comment), then each *distinct* resolved directory
    /// is loaded once and shared by every tid that maps to it, rather than
    /// once per tid.
    public func directories(containingTIDs tids: [String]) async throws -> [String: MangaDirectory] {
        let normalizedTIDs = Array(Set(tids.compactMap(\.nilIfBlank)))
        guard !normalizedTIDs.isEmpty else { return [:] }
        return try await database.read { db in
            // Ties within a tid (same tid appearing under more than one
            // directory) resolve exactly like the single-tid method: most
            // recently updated directory wins, `clean_book_name` breaks ties.
            // Ordering by `tid` first lets a single pass over the rows keep
            // only the first (best-ranked) directory seen per tid.
            var winningNameByTID: [String: String] = [:]
            for batch in normalizedTIDs.chunked(intoBatchesOf: Self.maxInClauseBatchSize) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT c.tid AS tid, d.clean_book_name AS clean_book_name
                    FROM manga_directories d
                    JOIN manga_directory_chapters c ON c.directory_id = d.id
                    WHERE c.tid IN (\(placeholders))
                    ORDER BY c.tid ASC, COALESCE(d.last_updated_at, -62135769600) DESC, d.clean_book_name ASC
                    """,
                    arguments: StatementArguments(batch)
                )
                for row in rows {
                    let tid: String = row["tid"]
                    guard winningNameByTID[tid] == nil else { continue }
                    winningNameByTID[tid] = row["clean_book_name"]
                }
            }

            var directoriesByName: [String: MangaDirectory] = [:]
            var result: [String: MangaDirectory] = [:]
            for (tid, cleanBookName) in winningNameByTID {
                if let cached = directoriesByName[cleanBookName] {
                    result[tid] = cached
                    continue
                }
                guard let directory = try Self.directory(named: cleanBookName, in: db) else { continue }
                directoriesByName[cleanBookName] = directory
                result[tid] = directory
            }
            return result
        }
    }

    public func saveDirectory(_ directory: MangaDirectory) async throws {
        do {
            try await database.write { db in
                try Self.save(directory, in: db)
            }
        } catch {
            throw persistenceError(from: error)
        }
        postChangeNotification()
    }

    public func deleteDirectory(id: MangaDirectoryID) async throws {
        let synchronizesDeletion = await syncSettingsStore.load().isEnabled(.mangaDirectories)
        try await database.write { db in
            let canonical = try MangaDirectoryIdentityDatabase.snapshot(in: db).canonicalID(id.rawValue)
            if synchronizesDeletion { try Self.recordDeletion(id: canonical, at: .now, in: db) }
            try db.execute(sql: "DELETE FROM manga_directories WHERE id = ?", arguments: [canonical])
        }
        postChangeNotification()
    }

    public func renameDirectory(id: MangaDirectoryID, cleanBookName: String, searchKeyword: String?) async throws -> MangaDirectory {
        guard let name = cleanBookName.nilIfBlank else { throw YamiboPersistenceError(context: "Directory name is empty") }
        if let target = try await directory(named: name), target.id != id {
            return try await mergeDirectories(sourceID: id, targetID: target.id, cleanBookName: name, searchKeyword: searchKeyword)
        }
        let directory = try await database.write { db in
            guard var directory = try Self.directory(id: id, in: db) else { throw YamiboPersistenceError(context: "Directory no longer exists") }
            directory.cleanBookName = name
            directory.searchKeyword = searchKeyword
            try Self.save(directory, allowRename: true, in: db)
            return directory
        }
        postChangeNotification()
        return directory
    }

    public func mergeDirectories(sourceID: MangaDirectoryID, targetID: MangaDirectoryID, cleanBookName: String, searchKeyword: String?) async throws -> MangaDirectory {
        await acquireIdentityChange()
        defer { releaseIdentityChange() }
        do {
            try await prepareIdentityChange()
            let directory = try await identityMigration.mergeDirectories(sourceID: sourceID, targetID: targetID, cleanBookName: cleanBookName, searchKeyword: searchKeyword)
            await finishIdentityChange()
            notifyIdentityChange()
            return directory
        } catch {
            await finishIdentityChange()
            throw error
        }
    }

    public func clearAll() async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM manga_directory_chapters")
            try db.execute(sql: "DELETE FROM manga_directories")
            try db.execute(sql: "DELETE FROM manga_directory_sync_state")
        }
        postChangeNotification()
    }

    public func clearAllForSync(at date: Date = .now) async throws {
        let synchronizesDeletion = await syncSettingsStore.load().isEnabled(.mangaDirectories)
        try await database.write { db in
            if synchronizesDeletion {
                var deletions = try SyncDeletionState.load(from: "manga_directory_sync_state", in: db)
                deletions.clear(at: date)
                try deletions.save(to: "manga_directory_sync_state", in: db)
            }
            try db.execute(sql: "DELETE FROM manga_directories")
        }
        postChangeNotification()
    }

    static func recordDeletion(id: String, at date: Date, in db: Database) throws {
        var deletions = try SyncDeletionState.load(from: "manga_directory_sync_state", in: db)
        deletions.recordDeletion(of: id, at: date)
        try deletions.save(to: "manga_directory_sync_state", in: db)
    }

    func syncSnapshot() async throws -> SyncRecordSnapshot<MangaDirectorySyncRecord> {
        try await database.read { db in try Self.syncSnapshot(in: db) }
    }

    func updateSyncSnapshot<T: Sendable>(
        merging remote: SyncRecordSnapshot<MangaDirectorySyncRecord>?,
        _ transform: @escaping @Sendable (inout SyncRecordSnapshot<MangaDirectorySyncRecord>, SyncRecordSnapshot<MangaDirectorySyncRecord>?) throws -> T
    ) async throws -> T {
        let result = try await database.write { db in
            // A merge may commit after WebDAV normalization. Resolve both
            // sides under the write lock before comparing versions/tombstones.
            let identities = try MangaDirectoryIdentityDatabase.snapshot(in: db)
            let previous = try Self.syncSnapshot(in: db)
            var snapshot = try Self.canonicalSnapshot(previous, identities: identities)
            let remote = try remote.map { try Self.canonicalSnapshot($0, identities: identities) }
            let result = try transform(&snapshot, remote)
            snapshot.records.sort { $0.id < $1.id }
            guard snapshot != previous else { return (result, false) }
            try db.execute(sql: "DELETE FROM manga_directories")
            for record in snapshot.records {
                try Self.save(record.directory, modifiedAt: record.modifiedAt, contentIdentityIDs: record.contentIdentityIDs, in: db)
            }
            try snapshot.deletions.save(to: "manga_directory_sync_state", in: db)
            return (result, true)
        }
        if result.1 { postChangeNotification() }
        return result.0
    }

    private static func canonicalSnapshot(
        _ snapshot: SyncRecordSnapshot<MangaDirectorySyncRecord>,
        identities: MangaDirectoryIdentitySnapshot
    ) throws -> SyncRecordSnapshot<MangaDirectorySyncRecord> {
        let records = snapshot.records.map { record in
            var record = record
            let canonical = identities.canonicalID(record.id)
            record.directory = record.directory.reidentified(as: MangaDirectoryID(rawValue: canonical))
            if let title = identities.titles[canonical], title != canonical {
                record.directory.cleanBookName = title
            }
            // Content lineage tracks incorporated chapters, not redirects.
            // Preserve it so the merger can still identify unseen origins.
            return record
        }
        let deletions = MangaIdentityDeletionRemapping.normalize(
            snapshot.deletions, identities: identities, directoryKeys: true
        )
        return SyncRecordSnapshot(records: records, deletions: deletions)
    }

    private static func syncSnapshot(in db: Database) throws -> SyncRecordSnapshot<MangaDirectorySyncRecord> {
        let records = try Row.fetchAll(db, sql: "SELECT clean_book_name, modified_at, content_identity_ids_json FROM manga_directories ORDER BY clean_book_name").map { row in
            guard let directory = try Self.directory(named: row["clean_book_name"], in: db) else {
                throw YamiboPersistenceError(context: "Invalid manga directory")
            }
            let contentIdentityIDs = try JSONDecoder().decode(Set<String>.self, from: Data((row["content_identity_ids_json"] as String).utf8))
            return MangaDirectorySyncRecord(directory: directory, modifiedAt: Date(timeIntervalSince1970: row["modified_at"]), contentIdentityIDs: contentIdentityIDs)
        }
        return SyncRecordSnapshot(records: records, deletions: try SyncDeletionState.load(from: "manga_directory_sync_state", in: db))
    }

    /// Lightweight per-directory listing for the settings management screen:
    /// name + chapter count instead of every chapter's full metadata.
    public func allDirectorySummaries() async -> [MangaDirectorySummary] {
        do {
            return try await database.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT d.id, d.clean_book_name, d.strategy, d.last_updated_at, COUNT(c.tid) AS chapter_count
                    FROM manga_directories d
                    LEFT JOIN manga_directory_chapters c ON c.directory_id = d.id
                    GROUP BY d.clean_book_name
                    ORDER BY d.clean_book_name ASC
                    """
                ).compactMap { row -> MangaDirectorySummary? in
                    guard let strategy = MangaDirectoryStrategy(rawValue: row["strategy"] as String) else { return nil }
                    return MangaDirectorySummary(
                        id: MangaDirectoryID(rawValue: row["id"]),
                        cleanBookName: row["clean_book_name"],
                        strategy: strategy,
                        chapterCount: row["chapter_count"],
                        lastUpdatedAt: optionalDate(from: row["last_updated_at"] as Double?)
                    )
                }
            }
        } catch {
            YamiboLog.persistence.warning("Failed to list manga directory summaries: \(error)")
            return []
        }
    }

    public func totalDiskUsageBytes() async -> Int {
        do {
            return try await database.read { db in
                let directoryBytes = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COALESCE(SUM(
                        length(CAST(clean_book_name AS BLOB)) +
                        length(CAST(strategy AS BLOB)) +
                        length(CAST(source_key AS BLOB)) +
                        COALESCE(length(CAST(search_keyword AS BLOB)), 0) +
                        16
                    ), 0)
                    FROM manga_directories
                    """
                ) ?? 0
                let chapterBytes = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COALESCE(SUM(
                        length(CAST(directory_id AS BLOB)) +
                        length(CAST(tid AS BLOB)) +
                        length(CAST(raw_title AS BLOB)) +
                        COALESCE(length(CAST(author_uid AS BLOB)), 0) +
                        COALESCE(length(CAST(author_name AS BLOB)), 0) +
                        40
                    ), 0)
                    FROM manga_directory_chapters
                    """
                ) ?? 0
                return directoryBytes + chapterBytes
            }
        } catch {
            YamiboLog.persistence.warning("Failed to read manga directory disk usage: \(error)")
            return 0
        }
    }

    /// Content provenance is not an identity alias: rekeying a directory must
    /// never claim that another directory's chapters have already been merged.
    static func contentIdentityIDs(id: MangaDirectoryID, in db: Database) throws -> Set<String>? {
        guard let json = try String.fetchOne(db, sql: "SELECT content_identity_ids_json FROM manga_directories WHERE id = ?", arguments: [id.rawValue]) else { return nil }
        return try JSONDecoder().decode(Set<String>.self, from: Data(json.utf8))
    }

    static func save(_ directory: MangaDirectory, modifiedAt: Date = .now, allowRename: Bool = false, contentIdentityIDs: Set<String>? = nil, in db: Database) throws {
        let canonical = try MangaDirectoryIdentityDatabase.snapshot(in: db).canonicalID(directory.id.rawValue)
        let sources = try contentIdentityIDs ?? Self.contentIdentityIDs(id: MangaDirectoryID(rawValue: canonical), in: db) ?? [directory.id.rawValue]
        let sourcesJSON = String(decoding: try JSONEncoder().encode(sources.sorted()), as: UTF8.self)
        var normalized = directory.reidentified(as: MangaDirectoryID(rawValue: canonical))
        if canonical != directory.id.rawValue, let current = try Self.directory(id: normalized.id, in: db) {
            // A refresh that began before a merge must not restore the losing
            // title or replace the destination's chapters with its stale subset.
            var known = Set(current.chapters.map(\.tid))
            normalized = current
            normalized.chapters += directory.chapters.filter { known.insert($0.tid).inserted }
        }
        if !allowRename,
           let currentName = try String.fetchOne(db, sql: "SELECT name FROM manga_identities WHERE id = ?", arguments: [canonical]),
           currentName != canonical, currentName != normalized.cleanBookName {
            // Network refreshes may finish after a rename without changing ID.
            // Content writers cannot roll back the authoritative title/keyword.
            if let current = try Self.directory(id: normalized.id, in: db) { normalized.searchKeyword = current.searchKeyword }
            normalized.cleanBookName = currentName
        }
        guard let cleanBookName = normalized.cleanBookName.nilIfBlank else {
            throw YamiboPersistenceError(context: "Directory name is empty")
        }
        normalized.cleanBookName = cleanBookName
        try MangaDirectoryIdentityDatabase.register(id: canonical, name: cleanBookName, modifiedAt: modifiedAt.timeIntervalSince1970, in: db)

        try db.execute(
            sql: """
            INSERT INTO manga_directories
            (id, clean_book_name, strategy, source_key, last_updated_at, search_keyword, modified_at, content_identity_ids_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET clean_book_name = excluded.clean_book_name, strategy = excluded.strategy,
                source_key = excluded.source_key, last_updated_at = excluded.last_updated_at,
                search_keyword = excluded.search_keyword, modified_at = excluded.modified_at,
                content_identity_ids_json = excluded.content_identity_ids_json
            """,
            arguments: [
                canonical,
                normalized.cleanBookName,
                normalized.strategy.rawValue,
                normalized.sourceKey,
                normalized.lastUpdatedAt.map(timeInterval(from:)),
                normalized.searchKeyword,
                modifiedAt.timeIntervalSince1970,
                sourcesJSON,
            ]
        )
        try db.execute(sql: "DELETE FROM manga_directory_chapters WHERE directory_id = ?", arguments: [canonical])
        for (index, chapter) in normalized.chapters.enumerated() {
            guard let tid = chapter.tid.nilIfBlank else { continue }
            try db.execute(
                sql: """
                INSERT INTO manga_directory_chapters
                (directory_id, tid, view, raw_title, chapter_number, author_uid, author_name, group_index, publish_time, manual_order)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    canonical,
                    tid,
                    chapter.view,
                    chapter.rawTitle,
                    chapter.chapterNumber,
                    chapter.authorUID,
                    chapter.authorName,
                    chapter.groupIndex,
                    chapter.publishTime.map(timeInterval(from:)),
                    index,
                ]
            )
        }
    }

    static func directory(named name: String, in db: Database) throws -> MangaDirectory? {
        guard let id = try String.fetchOne(db, sql: "SELECT id FROM manga_directories WHERE clean_book_name = ?", arguments: [name]) else { return nil }
        return try directory(id: MangaDirectoryID(rawValue: id), in: db)
    }

    static func directory(id: MangaDirectoryID, in db: Database) throws -> MangaDirectory? {
        let canonical = try MangaDirectoryIdentityDatabase.snapshot(in: db).canonicalID(id.rawValue)
        guard let directoryRow = try Row.fetchOne(
            db,
            sql: """
            SELECT id, clean_book_name, strategy, source_key, last_updated_at, search_keyword
            FROM manga_directories
            WHERE id = ?
            """,
            arguments: [canonical]
        ) else {
            return nil
        }
        guard let strategy = MangaDirectoryStrategy(rawValue: directoryRow["strategy"] as String) else {
            return nil
        }
        let chapters: [MangaChapter] = try Row.fetchAll(
            db,
            sql: """
            SELECT tid, view, raw_title, chapter_number, author_uid, author_name, group_index, publish_time
            FROM manga_directory_chapters
            WHERE directory_id = ?
            ORDER BY manual_order ASC, tid ASC
            """,
            arguments: [canonical]
        ).compactMap { row -> MangaChapter? in
            let tid = row["tid"] as String
            return MangaChapter(
                tid: tid,
                rawTitle: row["raw_title"],
                chapterNumber: row["chapter_number"],
                view: row["view"],
                authorUID: row["author_uid"] as String?,
                authorName: row["author_name"] as String?,
                groupIndex: row["group_index"],
                publishTime: optionalDate(from: row["publish_time"] as Double?)
            )
        }
        return MangaDirectory(
            id: MangaDirectoryID(rawValue: directoryRow["id"]),
            cleanBookName: directoryRow["clean_book_name"],
            strategy: strategy,
            sourceKey: directoryRow["source_key"],
            chapters: chapters,
            lastUpdatedAt: optionalDate(from: directoryRow["last_updated_at"] as Double?),
            searchKeyword: directoryRow["search_keyword"] as String?
        )
    }

    /// Conservative ceiling for one `WHERE tid IN (...)` query's bound
    /// parameters. SQLite's compiled-in `SQLITE_MAX_VARIABLE_NUMBER` has
    /// varied a lot across versions (historically 999; modern default
    /// builds raise it to 32766), and nothing here pins which SQLite this
    /// app links against, so `directories(containingTIDs:)` chunks well
    /// under the old, stricter ceiling rather than assuming the new one.
    /// No existing chunking helper was found elsewhere in the codebase for
    /// this (checked `ContentCoverStore`/`ReadingProgressStore`/
    /// `FavoriteSyncRunStore` — none of them batch `IN` queries today), so
    /// this is a fresh, file-local constant/helper rather than a reused one.
    private static let maxInClauseBatchSize = 500

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }

}

private extension Array {
    /// Splits into batches of at most `size` elements, preserving order.
    func chunked(intoBatchesOf size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

private func timeInterval(from date: Date) -> Double {
    date.timeIntervalSince1970
}

private func optionalDate(from value: Double?) -> Date? {
    value.map(Date.init(timeIntervalSince1970:))
}

// Same contract as `offlineCachePersistenceError`: domain errors pass through
// untouched, everything else is wrapped with the source error preserved as
// `underlying` for logging.
private func persistenceError(from error: Error) -> any Error {
    if let error = error as? YamiboError {
        return error
    }
    if let error = error as? YamiboPersistenceError {
        return error
    }
    return YamiboPersistenceError(context: error.localizedDescription, underlying: error)
}

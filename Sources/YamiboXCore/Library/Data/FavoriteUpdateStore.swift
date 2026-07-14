import Foundation
@preconcurrency import GRDB

public actor FavoriteUpdateStore {
    public static let didChangeNotification = Notification.Name("yamibox.favoriteUpdateStore.didChange")
    public static let changeIDUserInfoKey = "changeID"
    private static let keptRunCount = 10
    nonisolated(unsafe) private static var databasePoolCache: [String: DatabasePool] = [:]
    private static let databasePoolCacheLock = NSLock()

    public nonisolated let changeID = UUID().uuidString

    private let database: DatabasePool

    /// Convenience for tests/previews, mirroring `FavoriteLibraryStore`:
    /// `.standard` resolves the shared `yamibox.sqlite` pool; any other
    /// defaults suite gets its own temporary database keyed by `key`.
    public init(defaults: UserDefaults = .standard, key: String = "yamibox.favoriteUpdates") {
        self.database = Self.openDatabase(defaults: defaults, key: key)
    }

    init(databasePool: DatabasePool) {
        self.database = databasePool
    }

    private static func openDatabase(defaults: UserDefaults, key: String) -> DatabasePool {
        do {
            if defaults === UserDefaults.standard {
                return try cachedDatabasePool(rootDirectory: YamiboDatabase.defaultRootDirectory())
            }
            let idKey = "\(key).grdbDatabaseID"
            let databaseID: String
            if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
                databaseID = existing
            } else {
                databaseID = UUID().uuidString
                defaults.set(databaseID, forKey: idKey)
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("yamibo-x-favorite-updates", isDirectory: true)
                .appendingPathComponent(databaseID, isDirectory: true)
            return try cachedDatabasePool(rootDirectory: root)
        } catch {
            fatalError("Failed to open FavoriteUpdateStore database: \(error)")
        }
    }

    private static func cachedDatabasePool(rootDirectory: URL) throws -> DatabasePool {
        let key = rootDirectory.standardizedFileURL.path
        databasePoolCacheLock.lock()
        defer { databasePoolCacheLock.unlock() }
        if let pool = databasePoolCache[key] {
            return pool
        }

        let pool = try YamiboDatabase.openPool(rootDirectory: rootDirectory)
        databasePoolCache[key] = pool
        return pool
    }

    public func loadState() async -> FavoriteUpdateStoreState {
        do {
            return try await database.read { db in try Self.state(in: db) }
        } catch {
            YamiboLog.library.error("Failed to load stored favorite update tracking state, returning empty state: \(error)")
            return FavoriteUpdateStoreState()
        }
    }

    public func latestRun() async -> FavoriteUpdateRunSnapshot? {
        try? await database.read { db in
            guard let json = try String.fetchOne(
                db,
                sql: """
                SELECT run_json FROM favorite_update_runs
                ORDER BY updated_at DESC, run_id DESC
                LIMIT 1
                """
            ) else {
                return nil
            }
            return try Self.decode(FavoriteUpdateRunSnapshot.self, from: json)
        }
    }

    public func activeEvents() async -> [FavoriteUpdateEvent] {
        (try? await database.read { db in try Self.activeEvents(in: db) }) ?? []
    }

    public func saveRun(_ snapshot: FavoriteUpdateRunSnapshot) async throws {
        try await write { db in
            try db.execute(
                sql: """
                INSERT INTO favorite_update_runs (run_id, updated_at, run_json)
                VALUES (?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET
                    updated_at = excluded.updated_at,
                    run_json = excluded.run_json
                """,
                arguments: [snapshot.runID, snapshot.updatedAt.timeIntervalSince1970, try Self.encode(snapshot)]
            )
            try db.execute(
                sql: """
                DELETE FROM favorite_update_runs
                WHERE run_id NOT IN (
                    SELECT run_id FROM favorite_update_runs
                    ORDER BY updated_at DESC, run_id DESC
                    LIMIT ?
                )
                """,
                arguments: [Self.keptRunCount]
            )
            return true
        }
    }

    public func upsertTrackedTarget(_ target: FavoriteUpdateTrackedTarget) async throws {
        try await write { db in
            try Self.upsertTrackedTarget(target, in: db)
            return true
        }
    }

    public func replaceTrackedTargets(_ targets: [FavoriteUpdateTrackedTarget]) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM favorite_update_tracked_targets")
            for target in targets {
                try Self.upsertTrackedTarget(target, in: db)
            }
            return true
        }
    }

    public func insertEvent(_ event: FavoriteUpdateEvent) async throws {
        try await write { db in
            try db.execute(
                sql: "DELETE FROM favorite_update_events WHERE target_id = ? AND dismissed_at IS NULL",
                arguments: [event.target.id]
            )
            try Self.insertEventRow(event, in: db)
            return true
        }
    }

    /// Migrates a `.mangaDirectory` tracked target and its events from
    /// `oldCleanBookName` to `newCleanBookName` when `MangaDirectoryStore`
    /// renames/merges a directory. `MangaDirectoryStore` runs the static
    /// variant inside its own rename transaction; this instance method exists
    /// for callers outside that cascade.
    public func renameMangaDirectoryTracking(from oldCleanBookName: String, to newCleanBookName: String) async throws {
        guard oldCleanBookName != newCleanBookName else { return }
        try await write { db in
            try Self.renameMangaDirectoryTracking(from: oldCleanBookName, to: newCleanBookName, in: db)
            return true
        }
    }

    /// A rename that merges into an ALREADY-tracked `newCleanBookName`
    /// unions the two known-chapter-tid baselines (never shrinks either
    /// side) and keeps only the more recently detected of any two
    /// now-colliding undismissed events for the merged target.
    public static func renameMangaDirectoryTracking(
        from oldCleanBookName: String,
        to newCleanBookName: String,
        in db: Database
    ) throws {
        guard oldCleanBookName != newCleanBookName else { return }
        let oldKey = FavoriteUpdateTargetKey.mangaDirectory(cleanBookName: oldCleanBookName)
        let newKey = FavoriteUpdateTargetKey.mangaDirectory(cleanBookName: newCleanBookName)

        if let oldTarget = try trackedTarget(id: oldKey.id, in: db) {
            try db.execute(
                sql: "DELETE FROM favorite_update_tracked_targets WHERE target_id = ?",
                arguments: [oldKey.id]
            )
            if var merged = try trackedTarget(id: newKey.id, in: db) {
                merged.knownChapterTIDs = (merged.knownChapterTIDs ?? []).union(oldTarget.knownChapterTIDs ?? [])
                merged.categoryIDs.formUnion(oldTarget.categoryIDs)
                try upsertTrackedTarget(merged, in: db)
            } else {
                var renamed = oldTarget
                renamed.target = newKey
                renamed.title = newCleanBookName
                try upsertTrackedTarget(renamed, in: db)
            }
        }

        let oldEventRows = try Row.fetchAll(
            db,
            sql: "SELECT id, event_json FROM favorite_update_events WHERE target_id = ?",
            arguments: [oldKey.id]
        )
        for row in oldEventRows {
            var event = try decode(FavoriteUpdateEvent.self, from: row["event_json"] as String)
            event.target = newKey
            event.title = newCleanBookName
            try db.execute(
                sql: "UPDATE favorite_update_events SET target_id = ?, event_json = ? WHERE id = ?",
                arguments: [newKey.id, try encode(event), row["id"] as String]
            )
        }

        // The one-undismissed-event-per-target invariant can only break for
        // the merged target; keep the most recently detected event.
        let collidingIDs = try String.fetchAll(
            db,
            sql: """
            SELECT id FROM favorite_update_events
            WHERE target_id = ? AND dismissed_at IS NULL
            ORDER BY detected_at DESC, id DESC
            """,
            arguments: [newKey.id]
        )
        for id in collidingIDs.dropFirst() {
            try db.execute(sql: "DELETE FROM favorite_update_events WHERE id = ?", arguments: [id])
        }
    }

    /// Commits a whole check run's tracked-target and event changes in one
    /// write transaction instead of the one-`upsertTrackedTarget`/
    /// `insertEvent`-call-per-favorite pattern a check loop would otherwise
    /// produce. Callers pass the complete post-run arrays as accumulated in
    /// memory over the run — but a run takes minutes, and the caller's
    /// arrays were seeded from a store snapshot taken at run start, so
    /// anything written to the store since (the user marking events
    /// read/dismissed from the updates page, another writer inserting) must
    /// not be clobbered by that stale snapshot. This therefore MERGES rather
    /// than replaces: the run is authoritative for its detection products,
    /// the current store state for user-facing markers and rows the run
    /// never saw. See `mergingRunEvents(_:intoStored:)`.
    public func applyCheckRunResults(
        trackedTargets: [FavoriteUpdateTrackedTarget],
        events: [FavoriteUpdateEvent]
    ) async throws {
        try await write { db in
            for target in trackedTargets {
                try Self.upsertTrackedTarget(target, in: db)
            }
            let merged = Self.mergingRunEvents(events, intoStored: try Self.events(in: db))
            try db.execute(sql: "DELETE FROM favorite_update_events")
            for event in merged {
                try Self.insertEventRow(event, in: db)
            }
            return true
        }
    }

    /// Unread undismissed event count as it will stand once the given run's
    /// in-memory events are committed via `applyCheckRunResults` — the number
    /// a mid-run notification badge should show. Counting either side alone
    /// is wrong mid-run: the store is missing this run's not-yet-committed
    /// detections, while the run's snapshot is missing read/dismiss marks the
    /// user applied since the run started.
    public func unreadEventCount(mergingRunEvents runEvents: [FavoriteUpdateEvent]) async -> Int {
        let storedEvents = (try? await database.read { db in try Self.events(in: db) }) ?? []
        return Self.mergingRunEvents(runEvents, intoStored: storedEvents)
            .filter { $0.readAt == nil && $0.dismissedAt == nil }
            .count
    }

    /// Three-way merge of a check run's in-memory event list over the current
    /// store contents, by event id:
    /// - present on both sides: the run never edits an existing event in
    ///   place (it supersedes with a new id), so the copies differ only by
    ///   markers the user may have set since the run's snapshot — a non-nil
    ///   store-side `readAt`/`dismissedAt` wins.
    /// - run-only: a new detection (or a snapshot row another writer has
    ///   since superseded) — kept.
    /// - store-only: either inserted by another writer during the run (kept),
    ///   or the undismissed row this run superseded with an accumulated
    ///   replacement under a new id (dropped, its delta already folded in).
    /// The two are told apart by the final pass, which restores the "at most
    /// one undismissed event per target" invariant both writers maintain
    /// individually: dismissed events all survive, and an undismissed one only
    /// if it is the target's newest detection overall — measured against
    /// dismissed events too, so a stale undismissed copy can never outrank
    /// (and thereby resurrect) newer same-target content the user dismissed.
    private static func mergingRunEvents(
        _ runEvents: [FavoriteUpdateEvent],
        intoStored storedEvents: [FavoriteUpdateEvent]
    ) -> [FavoriteUpdateEvent] {
        let storedByID = Dictionary(uniqueKeysWithValues: storedEvents.map { ($0.id, $0) })
        let runEventIDs = Set(runEvents.map(\.id))
        var merged = runEvents.map { event in
            var event = event
            if let stored = storedByID[event.id] {
                event.readAt = stored.readAt ?? event.readAt
                event.dismissedAt = stored.dismissedAt ?? event.dismissedAt
            }
            return event
        }
        merged.append(contentsOf: storedEvents.filter { !runEventIDs.contains($0.id) })

        var newestByTarget: [FavoriteUpdateTargetKey: FavoriteUpdateEvent] = [:]
        for event in merged {
            if let current = newestByTarget[event.target],
               (current.detectedAt, current.id) >= (event.detectedAt, event.id) {
                continue
            }
            newestByTarget[event.target] = event
        }
        return merged.filter { event in
            event.dismissedAt != nil || newestByTarget[event.target]?.id == event.id
        }
    }

    public func markEventRead(_ id: String, date: Date = .now) async throws {
        try await write { db in
            guard var event = try Self.event(id: id, in: db) else { return false }
            event.readAt = date
            try db.execute(
                sql: "UPDATE favorite_update_events SET event_json = ? WHERE id = ?",
                arguments: [try Self.encode(event), id]
            )
            return true
        }
    }

    public func dismissEvent(_ id: String, date: Date = .now) async throws {
        try await write { db in
            guard var event = try Self.event(id: id, in: db) else { return false }
            event.dismissedAt = date
            try db.execute(
                sql: "UPDATE favorite_update_events SET dismissed_at = ?, event_json = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, try Self.encode(event), id]
            )
            return true
        }
    }

    public func clearAll() async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM favorite_update_tracked_targets")
            try db.execute(sql: "DELETE FROM favorite_update_events")
            try db.execute(sql: "DELETE FROM favorite_update_runs")
            try db.execute(sql: "DELETE FROM favorite_update_fid_filters")
            try db.execute(sql: "DELETE FROM favorite_update_category_filters")
            return true
        }
    }

    public func dismissAllEvents(date: Date = .now) async throws {
        try await write { db in
            for var event in try Self.activeEvents(in: db) {
                event.dismissedAt = date
                try db.execute(
                    sql: "UPDATE favorite_update_events SET dismissed_at = ?, event_json = ? WHERE id = ?",
                    arguments: [date.timeIntervalSince1970, try Self.encode(event), event.id]
                )
            }
            return true
        }
    }

    public func replaceFilters(
        fidFilters: [FavoriteUpdateFidFilter],
        categoryFilters: [FavoriteUpdateCategoryFilter]
    ) async throws {
        try await write { db in
            let previousFids = Dictionary(uniqueKeysWithValues: try Self.fidFilters(in: db).map { ($0.fid, $0.enabled) })
            let previousCategories = Dictionary(uniqueKeysWithValues: try Self.categoryFilters(in: db).map { ($0.categoryID, $0.enabled) })
            try db.execute(sql: "DELETE FROM favorite_update_fid_filters")
            for (index, filter) in fidFilters.enumerated() {
                let resolved = FavoriteUpdateFidFilter(
                    fid: filter.fid,
                    forumName: filter.forumName,
                    enabled: previousFids[filter.fid] ?? filter.enabled,
                    itemCount: filter.itemCount,
                    updatedAt: filter.updatedAt
                )
                try Self.insertFidFilterRow(resolved, order: index, in: db)
            }
            try db.execute(sql: "DELETE FROM favorite_update_category_filters")
            for (index, filter) in categoryFilters.enumerated() {
                let resolved = FavoriteUpdateCategoryFilter(
                    categoryID: filter.categoryID,
                    categoryName: filter.categoryName,
                    enabled: previousCategories[filter.categoryID] ?? filter.enabled,
                    itemCount: filter.itemCount,
                    updatedAt: filter.updatedAt
                )
                try Self.insertCategoryFilterRow(resolved, order: index, in: db)
            }
            return true
        }
    }

    public func setFidEnabled(_ fid: String, enabled: Bool, date: Date = .now) async throws {
        try await write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT manual_order, filter_json FROM favorite_update_fid_filters WHERE fid = ?",
                arguments: [fid]
            ) else {
                return false
            }
            var filter = try Self.decode(FavoriteUpdateFidFilter.self, from: row["filter_json"] as String)
            filter.enabled = enabled
            filter.updatedAt = date
            try Self.insertFidFilterRow(filter, order: row["manual_order"] as Int, in: db)
            return true
        }
    }

    public func setCategoryEnabled(_ categoryID: String, enabled: Bool, date: Date = .now) async throws {
        try await write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT manual_order, filter_json FROM favorite_update_category_filters WHERE category_id = ?",
                arguments: [categoryID]
            ) else {
                return false
            }
            var filter = try Self.decode(FavoriteUpdateCategoryFilter.self, from: row["filter_json"] as String)
            filter.enabled = enabled
            filter.updatedAt = date
            try Self.insertCategoryFilterRow(filter, order: row["manual_order"] as Int, in: db)
            return true
        }
    }

    /// Lets a cascade writer that mutated this store's tables inside its own
    /// GRDB transaction (`MangaDirectoryStore`'s rename) emit the same change
    /// signal the actor's own mutations post.
    public nonisolated func notifyExternalMutation() {
        postChangeNotification()
    }

    /// Runs `updates` in one write transaction and posts the change
    /// notification when the closure reports it actually mutated state.
    private func write(_ updates: @escaping @Sendable (Database) throws -> Bool) async throws {
        let didMutate: Bool
        do {
            didMutate = try await database.write(updates)
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
        if didMutate {
            postChangeNotification()
        }
    }

    private static func state(in db: Database) throws -> FavoriteUpdateStoreState {
        FavoriteUpdateStoreState(
            trackedTargets: try String.fetchAll(
                db,
                sql: "SELECT target_json FROM favorite_update_tracked_targets ORDER BY target_id ASC"
            ).map { try decode(FavoriteUpdateTrackedTarget.self, from: $0) },
            events: try events(in: db),
            runs: try String.fetchAll(
                db,
                sql: "SELECT run_json FROM favorite_update_runs ORDER BY updated_at DESC, run_id DESC"
            ).map { try decode(FavoriteUpdateRunSnapshot.self, from: $0) },
            fidFilters: try fidFilters(in: db),
            categoryFilters: try categoryFilters(in: db)
        )
    }

    private static func events(in db: Database) throws -> [FavoriteUpdateEvent] {
        try String.fetchAll(
            db,
            sql: "SELECT event_json FROM favorite_update_events ORDER BY detected_at DESC, id DESC"
        ).map { try decode(FavoriteUpdateEvent.self, from: $0) }
    }

    private static func activeEvents(in db: Database) throws -> [FavoriteUpdateEvent] {
        try String.fetchAll(
            db,
            sql: """
            SELECT event_json FROM favorite_update_events
            WHERE dismissed_at IS NULL
            ORDER BY detected_at DESC, id DESC
            """
        ).map { try decode(FavoriteUpdateEvent.self, from: $0) }
    }

    private static func event(id: String, in db: Database) throws -> FavoriteUpdateEvent? {
        guard let json = try String.fetchOne(
            db,
            sql: "SELECT event_json FROM favorite_update_events WHERE id = ?",
            arguments: [id]
        ) else {
            return nil
        }
        return try decode(FavoriteUpdateEvent.self, from: json)
    }

    private static func trackedTarget(id: String, in db: Database) throws -> FavoriteUpdateTrackedTarget? {
        guard let json = try String.fetchOne(
            db,
            sql: "SELECT target_json FROM favorite_update_tracked_targets WHERE target_id = ?",
            arguments: [id]
        ) else {
            return nil
        }
        return try decode(FavoriteUpdateTrackedTarget.self, from: json)
    }

    private static func fidFilters(in db: Database) throws -> [FavoriteUpdateFidFilter] {
        try String.fetchAll(
            db,
            sql: "SELECT filter_json FROM favorite_update_fid_filters ORDER BY manual_order ASC, fid ASC"
        ).map { try decode(FavoriteUpdateFidFilter.self, from: $0) }
    }

    private static func categoryFilters(in db: Database) throws -> [FavoriteUpdateCategoryFilter] {
        try String.fetchAll(
            db,
            sql: "SELECT filter_json FROM favorite_update_category_filters ORDER BY manual_order ASC, category_id ASC"
        ).map { try decode(FavoriteUpdateCategoryFilter.self, from: $0) }
    }

    private static func upsertTrackedTarget(_ target: FavoriteUpdateTrackedTarget, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO favorite_update_tracked_targets (target_id, target_json)
            VALUES (?, ?)
            ON CONFLICT(target_id) DO UPDATE SET target_json = excluded.target_json
            """,
            arguments: [target.id, try encode(target)]
        )
    }

    private static func insertEventRow(_ event: FavoriteUpdateEvent, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO favorite_update_events (id, target_id, detected_at, dismissed_at, event_json)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [
                event.id,
                event.target.id,
                event.detectedAt.timeIntervalSince1970,
                event.dismissedAt?.timeIntervalSince1970,
                try encode(event),
            ]
        )
    }

    private static func insertFidFilterRow(_ filter: FavoriteUpdateFidFilter, order: Int, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO favorite_update_fid_filters (fid, manual_order, filter_json)
            VALUES (?, ?, ?)
            """,
            arguments: [filter.fid, order, try encode(filter)]
        )
    }

    private static func insertCategoryFilterRow(_ filter: FavoriteUpdateCategoryFilter, order: Int, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO favorite_update_category_filters (category_id, manual_order, filter_json)
            VALUES (?, ?, ?)
            """,
            arguments: [filter.categoryID, order, try encode(filter)]
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private nonisolated func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
    }
}

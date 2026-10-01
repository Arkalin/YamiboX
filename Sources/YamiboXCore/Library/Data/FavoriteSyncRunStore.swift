import Foundation
@preconcurrency import GRDB

/// Persists Yamibo favorite sync run snapshots in the shared GRDB database.
/// Run state is runtime task bookkeeping, deliberately kept out of the app
/// settings (which sync across devices over WebDAV).
public actor FavoriteSyncRunStore {
    private static let keptRunCount = 10

    private let database: DatabasePool
    private let encoder = JSONEncoder()
    // A full authoritative save changes the persisted revision, even when
    // counts stay equal. Unknown/replaced baselines must never admit a delta.
    private var appendRevisions: [String: String] = [:]
    private var saveEpoch: UInt64 = 0

    public init(databasePool: DatabasePool? = nil) {
        // `.standard` is the resolver's "shared production pool" signal, so
        // the nil-pool fallback and the convenience below stay one code path.
        self.database = databasePool
            ?? YamiboDatabasePoolResolver.resolvePool(defaults: .standard, key: "yamibox.favoriteSyncRuns")
    }

    /// Isolated-storage convenience mirroring `FavoriteLibraryStore`: standard
    /// defaults use the shared database, any other suite gets its own pool in
    /// a temporary directory (tests and previews).
    public init(defaults: UserDefaults, key: String = "yamibox.favoriteSyncRuns") {
        self.database = YamiboDatabasePoolResolver.resolvePool(defaults: defaults, key: key)
    }

    /// The most recently updated run, regardless of status; callers decide
    /// whether an old `running` snapshot needs downgrading to interrupted.
    public func latestSnapshot() async -> FavoriteRemoteSyncSnapshot? {
        do {
            return try await database.read { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM favorite_sync_runs ORDER BY updated_at DESC, run_id DESC LIMIT 1"),
                      let data = (row["snapshot_json"] as String).data(using: .utf8) else { return nil }
                let decoder = JSONDecoder()
                var snapshot = try decoder.decode(FavoriteRemoteSyncSnapshot.self, from: data)
                if row["separated_entries"] as Bool {
                    for entry in try Row.fetchAll(db, sql: "SELECT kind, entry_json FROM favorite_sync_run_entries WHERE run_id = ? ORDER BY kind, position", arguments: [snapshot.runID]) {
                        guard let data = (entry["entry_json"] as String).data(using: .utf8) else {
                            throw YamiboPersistenceError(context: "Invalid favorite sync log data")
                        }
                        switch entry["kind"] as String {
                        case "log": snapshot.logEntries.append(try decoder.decode(FavoriteRemoteSyncLogEntry.self, from: data))
                        case "warning": snapshot.warnings.append(try decoder.decode(FavoriteRemoteSyncWarning.self, from: data))
                        case "error": snapshot.errorMessages.append(try decoder.decode(String.self, from: data))
                        default: throw YamiboPersistenceError(context: "Invalid favorite sync log kind")
                        }
                    }
                }
                return snapshot
            }
        } catch {
            YamiboLog.sync.error("Failed to load latest favorite sync run snapshot: \(error)")
            return nil
        }
    }

    /// Authoritative replacement, including edits to existing entries. Used by
    /// presentation edits, legacy restore, and callers without an append baseline.
    public func save(_ snapshot: FavoriteRemoteSyncSnapshot) async throws {
        appendRevisions[snapshot.runID] = nil
        try await save(snapshot, appendingAfter: nil)
    }

    /// Engine mutations append entries. Each checkpoint is still durable before
    /// publication; interruption/terminal checkpoints need no deferred flush.
    public func saveAppending(_ snapshot: FavoriteRemoteSyncSnapshot, after previousCounts: FavoriteRemoteSyncEntryCounts) async throws {
        try await save(snapshot, appendingAfter: previousCounts)
    }

    /// Presentation owns only this flag. A stale UI snapshot must not replace
    /// the engine's newer durable progress or log prefix while it is hiding.
    public func hideCard(runID: String) async throws {
        do {
            try await database.write { db in
                guard let json = try String.fetchOne(db, sql: "SELECT snapshot_json FROM favorite_sync_runs WHERE run_id = ?", arguments: [runID]) else { return }
                var metadata = try JSONDecoder().decode(FavoriteRemoteSyncSnapshot.self, from: Data(json.utf8))
                metadata.isHiddenFromFavoritePage = true
                let updated = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
                try db.execute(sql: "UPDATE favorite_sync_runs SET snapshot_json = ? WHERE run_id = ?", arguments: [updated, runID])
            }
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    private struct Entry: Sendable {
        let kind: String
        let position: Int
        let json: String
    }

    private nonisolated static func encodedEntries(_ snapshot: FavoriteRemoteSyncSnapshot, after counts: FavoriteRemoteSyncEntryCounts?) throws -> [Entry] {
        let encoder = JSONEncoder()
        func entries<T: Encodable>(_ values: [T], kind: String, start: Int) throws -> [Entry] {
            try values.indices.dropFirst(start).map { position in
                Entry(kind: kind, position: position, json: String(decoding: try encoder.encode(values[position]), as: UTF8.self))
            }
        }
        return try entries(snapshot.logEntries, kind: "log", start: counts?.logs ?? 0)
            + entries(snapshot.warnings, kind: "warning", start: counts?.warnings ?? 0)
            + entries(snapshot.errorMessages, kind: "error", start: counts?.errors ?? 0)
    }

    private func save(_ snapshot: FavoriteRemoteSyncSnapshot, appendingAfter counts: FavoriteRemoteSyncEntryCounts?) async throws {
        saveEpoch &+= 1
        let epoch = saveEpoch
        let knownRevision = counts == nil ? nil : appendRevisions[snapshot.runID]
        let newRevision = UUID().uuidString
        let currentCounts = FavoriteRemoteSyncEntryCounts(snapshot)
        let validCounts = counts.flatMap { previous in
            previous.logs <= currentCounts.logs && previous.warnings <= currentCounts.warnings && previous.errors <= currentCounts.errors ? previous : nil
        }
        var metadata = snapshot
        metadata.logEntries = []
        metadata.warnings = []
        metadata.errorMessages = []
        do {
            let json = String(decoding: try encoder.encode(metadata), as: UTF8.self)
            let delta = try Self.encodedEntries(snapshot, after: validCounts)
            let revision = try await database.write { db in
                let row = try Row.fetchOne(db, sql: "SELECT separated_entries, entries_revision, log_count, warning_count, error_count FROM favorite_sync_runs WHERE run_id = ?", arguments: [snapshot.runID])
                let canAppend = validCounts.map { previous in
                    guard let row, row["separated_entries"] as Bool,
                          let knownRevision, row["entries_revision"] as String? == knownRevision else { return false }
                    return row["log_count"] as Int == previous.logs
                        && row["warning_count"] as Int == previous.warnings
                        && row["error_count"] as Int == previous.errors
                } ?? false
                let revision = canAppend ? knownRevision! : newRevision
                // UPDATE on conflict preserves child rows; REPLACE would cascade
                // a deletion and lose the prefix we are intentionally reusing.
                try db.execute(sql: """
                    INSERT INTO favorite_sync_runs
                    (run_id, status, snapshot_json, started_at, updated_at, separated_entries, entries_revision, log_count, warning_count, error_count)
                    VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
                    ON CONFLICT(run_id) DO UPDATE SET
                        status = excluded.status, snapshot_json = excluded.snapshot_json,
                        started_at = excluded.started_at, updated_at = excluded.updated_at,
                        separated_entries = 1, entries_revision = excluded.entries_revision,
                        log_count = excluded.log_count, warning_count = excluded.warning_count, error_count = excluded.error_count
                    """, arguments: [snapshot.runID, snapshot.status.rawValue, json,
                        snapshot.startedAt.timeIntervalSince1970, snapshot.updatedAt.timeIntervalSince1970,
                        revision, currentCounts.logs, currentCounts.warnings, currentCounts.errors])
                let entries: [Entry]
                if canAppend { entries = delta } else {
                    try db.execute(sql: "DELETE FROM favorite_sync_run_entries WHERE run_id = ?", arguments: [snapshot.runID])
                    entries = validCounts == nil ? delta : try Self.encodedEntries(snapshot, after: nil)
                }
                for entry in entries {
                    try db.execute(sql: "INSERT INTO favorite_sync_run_entries(run_id, kind, position, entry_json) VALUES (?, ?, ?, ?)", arguments: [snapshot.runID, entry.kind, entry.position, entry.json])
                }
                try db.execute(sql: """
                    DELETE FROM favorite_sync_runs WHERE run_id NOT IN (
                        SELECT run_id FROM favorite_sync_runs ORDER BY updated_at DESC, run_id DESC LIMIT ?
                    )
                    """, arguments: [Self.keptRunCount])
                return revision
            }
            // A reentrant authoritative save invalidates even a same-count
            // prefix. Only the most recent append operation establishes reuse.
            if epoch == saveEpoch {
                if counts != nil { appendRevisions[snapshot.runID] = revision }
                else { appendRevisions[snapshot.runID] = nil }
                if appendRevisions.count > Self.keptRunCount { appendRevisions.removeAll() }
            }
        } catch {
            appendRevisions[snapshot.runID] = nil
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    public func clearAll() async throws {
        saveEpoch &+= 1
        appendRevisions.removeAll()
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM favorite_sync_runs")
            }
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }
}

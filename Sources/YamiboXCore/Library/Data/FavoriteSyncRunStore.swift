import Foundation
@preconcurrency import GRDB

/// Persists Yamibo favorite sync run snapshots in the shared GRDB database.
/// Run state is runtime task bookkeeping, deliberately kept out of the app
/// settings (which sync across devices over WebDAV).
public actor FavoriteSyncRunStore {
    private static let keptRunCount = 10

    private let database: DatabasePool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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
        let decoder = decoder
        do {
            return try await database.read { db in
                guard let json = try String.fetchOne(
                    db,
                    sql: "SELECT snapshot_json FROM favorite_sync_runs ORDER BY updated_at DESC, run_id DESC LIMIT 1"
                ), let data = json.data(using: .utf8) else {
                    return nil
                }
                return try decoder.decode(FavoriteRemoteSyncSnapshot.self, from: data)
            }
        } catch {
            YamiboLog.sync.error("Failed to load latest favorite sync run snapshot: \(error)")
            return nil
        }
    }

    public func save(_ snapshot: FavoriteRemoteSyncSnapshot) async throws {
        let json: String
        do {
            json = String(data: try encoder.encode(snapshot), encoding: .utf8) ?? "{}"
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO favorite_sync_runs
                    (run_id, status, snapshot_json, started_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        snapshot.runID,
                        snapshot.status.rawValue,
                        json,
                        snapshot.startedAt.timeIntervalSince1970,
                        snapshot.updatedAt.timeIntervalSince1970,
                    ]
                )
                try db.execute(
                    sql: """
                    DELETE FROM favorite_sync_runs WHERE run_id NOT IN (
                        SELECT run_id FROM favorite_sync_runs ORDER BY updated_at DESC, run_id DESC LIMIT ?
                    )
                    """,
                    arguments: [Self.keptRunCount]
                )
            }
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    public func clearAll() async throws {
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM favorite_sync_runs")
            }
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }
}

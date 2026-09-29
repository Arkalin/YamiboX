import Foundation
@preconcurrency import GRDB

/// Coordinates feature-owned rewrites within the existing database write/migration.
/// Never opens a connection, starts a transaction, or catches a participant's error:
/// the caller commits all changes together or rolls the entire operation back.
enum MangaIdentityRemapping {
    static func normalizeReferences(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        try ReadingProgressIdentityRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
        try BrowsingHistoryIdentityRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
        try LikeIdentityRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
        try BookmarkIdentityRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
        try ContentCoverIdentityRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
        try BrowsingHistoryIdentityRemapping.normalizeSyncedRecords(snapshot: snapshot, legacy: legacy, in: db)
        try FavoriteLibraryIdentityRemapping.normalizeTracking(snapshot: snapshot, legacy: legacy, in: db)
        try FavoriteLibraryIdentityRemapping.normalizeDocuments(snapshot: snapshot, legacy: legacy, in: db)
        try ReadingProgressIdentityRemapping.normalizeDeletionState(snapshot: snapshot, legacy: legacy, in: db)
        try MangaIdentityRemapping.normalizeDeletionState(table: "manga_directory_sync_state", directoryKeys: true, snapshot: snapshot, legacy: legacy, in: db)
        try ContentCoverIdentityRemapping.normalizeDeletionState(snapshot: snapshot, legacy: legacy, in: db)
        try BrowsingHistoryIdentityRemapping.normalizeDeletionState(snapshot: snapshot, legacy: legacy, in: db)
        try DownloadIdentityRemapping.normalize(snapshot: snapshot, legacy: legacy, in: db)
    }

    static func normalizeDeletionState(table: String, directoryKeys: Bool = false, snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        let state = try SyncDeletionState.load(from: table, in: db)
        try MangaIdentityDeletionRemapping.normalize(state, identities: snapshot, legacy: legacy,
            directoryKeys: directoryKeys).save(to: table, in: db)
    }

    static func insert(_ row: Row, table: String, replacing changes: [String: DatabaseValue], in db: Database) throws {
        let columns = Array(row.columnNames)
        let arguments = columns.map { changes[$0] ?? (row[$0] as DatabaseValue) }
        try db.execute(sql: "INSERT INTO \(table) (\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(arguments))
    }
}

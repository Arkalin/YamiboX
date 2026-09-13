import Foundation
@preconcurrency import GRDB

/// Coordinates directory identity changes in one transaction. Each domain
/// owns its SQL and conflict policy; callers publish changes after this returns.
struct GRDBMangaDirectoryIdentityMigration: Sendable {
    private let database: DatabasePool

    init(databasePool: DatabasePool) {
        database = databasePool
    }

    func renameDirectory(
        from oldName: String,
        to newDirectory: MangaDirectory,
        date: Date = .now,
        synchronizesDeletion: Bool = true
    ) async throws {
        try await database.write { db in
            try MangaDirectoryStore.save(newDirectory, modifiedAt: date, in: db)
            let newName = newDirectory.cleanBookName
            guard oldName != newName else { return }
            if synchronizesDeletion { try MangaDirectoryStore.recordDeletion(named: oldName, at: date, in: db) }
            try ReadingProgressStore.renameMangaTitleTargets(from: oldName, to: newName, date: date, in: db)
            try ContentCoverStore.renameSmartMangaCover(from: oldName, to: newName, date: date, in: db)
            try LikeStore.renameMangaTitleLikes(from: oldName, to: newName, date: date, in: db)
            try BookmarkStore.renameMangaTitleBookmarks(from: oldName, to: newName, date: date, in: db)
            try FavoriteUpdateStore.renameMangaDirectoryTracking(from: oldName, to: newName, in: db)
            try MangaDirectoryStore.delete(named: oldName, in: db)
        }
    }
}

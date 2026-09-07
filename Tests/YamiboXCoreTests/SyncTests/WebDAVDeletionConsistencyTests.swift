import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Suite struct WebDAVDeletionConsistencyTests {
    private let old = Date(timeIntervalSince1970: 1_000)
    private let cleared = Date(timeIntervalSince1970: 2_000)
    private let fresh = Date(timeIntervalSince1970: 3_000)

    @Test(arguments: [false, true])
    func progressClearSurvivesThreeDevicesAndRestart(localInitiallyEmpty: Bool) async throws {
        let a = try DeletionTestDatabase()
        let b = try DeletionTestDatabase()
        let c = try DeletionTestDatabase()
        let aStore = ReadingProgressStore(databasePool: a.pool)
        let bStore = ReadingProgressStore(databasePool: b.pool)
        let cStore = ReadingProgressStore(databasePool: c.pool)
        let aSync = ReadingProgressWebDAVParticipant(store: aStore)
        let bSync = ReadingProgressWebDAVParticipant(store: bStore)
        let cSync = ReadingProgressWebDAVParticipant(store: cStore)
        try await cStore.saveNormalThread(threadID: "old", page: 4, date: old)
        try await cStore.saveNormalThread(threadID: "equal", page: 4, date: cleared)
        let stale = try await cSync.mergeAndExport(remoteData: nil, updatedAt: old, accountUID: "1")
        if !localInitiallyEmpty { try await aSync.applyRemote(stale) }

        try await aStore.clearAllForSync(at: cleared)
        try await aStore.clearAllForSync(at: old)
        let applied = try await aSync.applyRemoteSnapshot(stale)
        #expect(applied.requiresUpload)
        #expect(await aStore.loadAll().isEmpty)
        let clearedPayload = try await aSync.mergeAndExport(remoteData: stale, updatedAt: cleared, accountUID: "1")
        try await bSync.applyRemote(clearedPayload)

        let restarted = ReadingProgressStore(databasePool: try b.reopen())
        let restartedSync = ReadingProgressWebDAVParticipant(store: restarted)
        #expect(try await restarted.syncSnapshot().deletions.clearedAt == cleared)
        try await restarted.saveNormalThread(threadID: "new", page: 7, date: fresh)
        let newPayload = try await restartedSync.mergeAndExport(remoteData: stale, updatedAt: fresh, accountUID: "1")
        try await cSync.applyRemote(newPayload)
        let final = try await cSync.mergeAndExport(remoteData: stale, updatedAt: fresh, accountUID: "1")
        try await aSync.applyRemote(final)
        #expect(await aStore.loadAll().map(\.threadID) == ["new"])
        #expect(await cStore.loadAll().map(\.threadID) == ["new"])
    }

    @Test func individualProgressDeletionPersists() async throws {
        let db = try DeletionTestDatabase()
        let store = ReadingProgressStore(databasePool: db.pool)
        let sync = ReadingProgressWebDAVParticipant(store: store)
        try await store.saveNormalThread(threadID: "deleted", page: 2, date: old)
        try await store.saveNormalThread(threadID: "retained", page: 2, date: old)
        let stale = try await sync.mergeAndExport(remoteData: nil, updatedAt: old, accountUID: "1")
        try await store.delete(threadID: "deleted", date: cleared)
        try await sync.applyRemote(stale)
        #expect(await store.loadAll().map(\.threadID) == ["retained"])
        #expect(try await store.syncSnapshot().deletions.tombstones[FavoriteContentTarget.normalThread(threadID: "deleted").id] == cleared)
        try await store.clearAll()
        #expect(try await store.syncSnapshot().deletions == SyncDeletionState())
    }

    @Test(arguments: [false, true])
    func progressIdentityMigrationDoesNotRestoreOldKey(renamesTitle: Bool) async throws {
        let db = try DeletionTestDatabase()
        let store = ReadingProgressStore(databasePool: db.pool)
        let sync = ReadingProgressWebDAVParticipant(store: store)
        let original = try await store.saveMangaTitle(cleanBookName: "old", chapterThreadID: "1",
            chapterTitle: "chapter", pageIndex: 2, date: old)
        let stale = try await sync.mergeAndExport(remoteData: nil, updatedAt: old, accountUID: "1")
        if renamesTitle {
            try await store.migrateMangaTitleKey(from: "old", to: "new", date: cleared)
        } else {
            try await store.saveMangaTitle(cleanBookName: "old", chapterThreadID: "1",
                chapterTitle: "chapter", pageIndex: 3, mangaID: "stable-id", date: cleared)
        }
        let restarted = ReadingProgressStore(databasePool: try db.reopen())
        try await ReadingProgressWebDAVParticipant(store: restarted).applyRemote(stale)
        let records = await restarted.loadAll()
        #expect(records.count == 1)
        #expect(records.first?.id != original.id)
        #expect(records.first?.updatedAt == cleared)
        #expect(try await restarted.syncSnapshot().deletions.tombstones[original.id] == cleared)
    }

    @Test(arguments: [false, true])
    func coverClearSurvivesRemoteOnlyRowsAndNewCovers(localInitiallyEmpty: Bool) async throws {
        let a = try DeletionTestDatabase()
        let b = try DeletionTestDatabase()
        let c = try DeletionTestDatabase()
        let aStore = ContentCoverStore(databasePool: a.pool)
        let bStore = ContentCoverStore(databasePool: b.pool)
        let cStore = ContentCoverStore(databasePool: c.pool)
        let aSync = ContentCoverWebDAVParticipant(store: aStore)
        let bSync = ContentCoverWebDAVParticipant(store: bStore)
        let cSync = ContentCoverWebDAVParticipant(store: cStore)
        let url = try #require(URL(string: "https://example.com/cover.jpg"))
        try await cStore.setManualCover(url, for: .thread(tid: "old"), date: old)
        try await cStore.setTextCoverForced(true, for: .thread(tid: "equal"), date: cleared)
        let stale = try await cSync.mergeAndExport(remoteData: nil, updatedAt: old, accountUID: "1")
        if !localInitiallyEmpty { try await aSync.applyRemote(stale) }
        try await aStore.clearAllForSync(at: cleared)
        let clearedPayload = try await aSync.mergeAndExport(remoteData: stale, updatedAt: cleared, accountUID: "1")
        try await bSync.applyRemote(clearedPayload)
        let restarted = ContentCoverStore(databasePool: try b.reopen())
        let restartedSync = ContentCoverWebDAVParticipant(store: restarted)
        try await restarted.setAutomaticCover(url, for: .thread(tid: "new"), date: fresh)
        let newPayload = try await restartedSync.mergeAndExport(remoteData: stale, updatedAt: fresh, accountUID: "1")
        try await cSync.applyRemote(newPayload)
        #expect(try await cStore.allCovers().map(\.key.targetID) == ["new"])
        #expect(try await restarted.syncSnapshot().deletions.clearedAt == cleared)
        try await restarted.clearAll()
        #expect(try await restarted.syncSnapshot().deletions == SyncDeletionState())
    }

    @Test func likeWorkDeletionAndBareTombstoneForwarding() async throws {
        let a = try DeletionTestDatabase()
        let b = try DeletionTestDatabase()
        let c = try DeletionTestDatabase()
        let aStore = LikeStore(databasePool: a.pool)
        let bStore = LikeStore(databasePool: b.pool)
        let cStore = LikeStore(databasePool: c.pool)
        let key = LikeWorkKey.mangaTitle(cleanBookName: "work")
        let item = try await aStore.upsertImageLike(id: "like", workKey: key,
            anchor: .mangaImage(MangaImageLikeAnchor(chapterTID: "1", pageLocalIndex: 1)), sourceImageURL: nil, date: old)
        let stale = try JSONEncoder().encode(LikeLibraryWebDAVPayload(updatedAt: old, items: [item], tombstones: [:]))
        try await aStore.deleteAll(workKey: key, date: cleared)
        let aSync = LikeLibraryWebDAVParticipant(store: aStore)
        let deleted = try await aSync.mergeAndExport(remoteData: stale, updatedAt: cleared, accountUID: "1")
        #expect(await aStore.likes(for: key).isEmpty)
        try await LikeLibraryWebDAVParticipant(store: bStore).applyRemote(deleted)
        let restarted = LikeStore(databasePool: try b.reopen())
        #expect(await restarted.allIncludingDeleted().isEmpty)
        let forwarded = try await LikeLibraryWebDAVParticipant(store: restarted).mergeAndExport(remoteData: nil, updatedAt: fresh, accountUID: "1")
        let payload = try JSONDecoder().decode(LikeLibraryWebDAVPayload.self, from: forwarded)
        #expect(payload.tombstones[item.id] == cleared)
        try await cStore.replaceAll([item])
        try await LikeLibraryWebDAVParticipant(store: cStore).applyRemote(forwarded)
        #expect(await cStore.likes(for: key).isEmpty)
        try await aSync.applyRemote(stale)
        #expect(await aStore.likes(for: key).isEmpty)
    }

    @Test func bookmarkWorkDeletionAndBareTombstoneForwarding() async throws {
        let a = try DeletionTestDatabase()
        let b = try DeletionTestDatabase()
        let c = try DeletionTestDatabase()
        let aStore = BookmarkStore(databasePool: a.pool)
        let key = LikeWorkKey.novel(threadID: "work")
        let anchor = BookmarkAnchorPayload.novel(NovelBookmarkAnchor(chapterIdentity: nil,
            textSegmentIdentity: nil, displayedTextOffset: 12, view: 1, chapterOrdinal: 0))
        let item = try await aStore.toggle(workKey: key, anchor: anchor, date: old).item
        let stale = try JSONEncoder().encode(BookmarkLibraryWebDAVPayload(updatedAt: old, items: [item], tombstones: [:]))
        try await aStore.deleteAll(workKey: key, date: cleared)
        let aSync = BookmarkLibraryWebDAVParticipant(store: aStore)
        let deleted = try await aSync.mergeAndExport(remoteData: stale, updatedAt: cleared, accountUID: "1")
        try await BookmarkLibraryWebDAVParticipant(store: BookmarkStore(databasePool: b.pool)).applyRemote(deleted)
        let restarted = BookmarkStore(databasePool: try b.reopen())
        #expect(await restarted.allIncludingDeleted().isEmpty)
        let forwarded = try await BookmarkLibraryWebDAVParticipant(store: restarted).mergeAndExport(remoteData: nil, updatedAt: fresh, accountUID: "1")
        #expect(try JSONDecoder().decode(BookmarkLibraryWebDAVPayload.self, from: forwarded).tombstones[item.id] == cleared)
        let cStore = BookmarkStore(databasePool: c.pool)
        try await cStore.replaceAll([item])
        try await BookmarkLibraryWebDAVParticipant(store: cStore).applyRemote(forwarded)
        #expect(await cStore.bookmarks(for: key).isEmpty)
        try await aSync.applyRemote(stale)
        #expect(await aStore.bookmarks(for: key).isEmpty)
    }

    @Test func directoryRenameDoesNotReviveOldProgressOrCoverKeys() async throws {
        let db = try DeletionTestDatabase()
        let progress = ReadingProgressStore(databasePool: db.pool)
        let covers = ContentCoverStore(databasePool: db.pool)
        let progressSync = ReadingProgressWebDAVParticipant(store: progress)
        let coverSync = ContentCoverWebDAVParticipant(store: covers)
        try await progress.saveMangaTitle(cleanBookName: "old", chapterThreadID: "1", chapterTitle: "chapter", pageIndex: 4, date: old)
        try await covers.setManualCover(try #require(URL(string: "https://example.com/cover.jpg")), for: .smartManga(cleanBookName: "old"), date: old)
        let staleProgress = try await progressSync.mergeAndExport(remoteData: nil, updatedAt: old, accountUID: "1")
        let staleCover = try await coverSync.mergeAndExport(remoteData: nil, updatedAt: old, accountUID: "1")
        let date = cleared
        try await db.pool.write { db in
            try MangaDirectoryStore.renameRelatedStructuredMetadata(from: "old", to: "new", date: date, in: db)
        }
        try await progressSync.applyRemote(staleProgress)
        try await coverSync.applyRemote(staleCover)
        #expect(await progress.loadAll().map(\.contentTarget?.mangaCleanBookName) == ["new"])
        #expect(try await covers.allCovers().map(\.key.targetID) == ["new"])
    }

    @Test func syncReadFailuresThrowAndTransactionFailuresRollBack() async throws {
        let db = try DeletionTestDatabase()
        let progress = ReadingProgressStore(databasePool: db.pool)
        try await progress.saveNormalThread(threadID: "retained", page: 3, date: old)
        enum Failure: Error { case injected }
        await #expect(throws: Failure.self) {
            try await progress.updateSyncSnapshot { snapshot in
                snapshot.records = []
                snapshot.deletions.clear(at: .now)
                throw Failure.injected
            }
        }
        #expect(await progress.loadAll().count == 1)
        #expect(try await progress.syncSnapshot().deletions.clearedAt == nil)
        try await db.pool.write { db in
            try db.execute(sql: "DROP TABLE reading_progress")
            try db.execute(sql: "DROP TABLE content_cover")
            try db.execute(sql: "DROP TABLE like_items")
            try db.execute(sql: "DROP TABLE bookmarks")
        }
        let participants: [any WebDAVSyncParticipant] = [
            ReadingProgressWebDAVParticipant(store: progress),
            ContentCoverWebDAVParticipant(store: ContentCoverStore(databasePool: db.pool)),
            LikeLibraryWebDAVParticipant(store: LikeStore(databasePool: db.pool)),
            BookmarkLibraryWebDAVParticipant(store: BookmarkStore(databasePool: db.pool))
        ]
        for participant in participants {
            await #expect(throws: (any Error).self) { _ = try await participant.readLocalFingerprint() }
            await #expect(throws: (any Error).self) {
                _ = try await participant.mergeAndExport(remoteData: nil, updatedAt: .now, accountUID: "1")
            }
        }
    }

    @Test func legacyPayloadsDecodeAndNewVersionsRequireDeletionMetadata() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ReadingProgressWebDAVPayload.self,
            from: Data(#"{"version":2,"updatedAt":0,"records":[]}"#.utf8)).deletions == SyncDeletionState())
        #expect(try decoder.decode(ContentCoverWebDAVPayload.self,
            from: Data(#"{"version":1,"updatedAt":0,"covers":[]}"#.utf8)).deletions == SyncDeletionState())
        #expect(try decoder.decode(LikeLibraryWebDAVPayload.self,
            from: Data(#"{"version":1,"updatedAt":0,"items":[],"tombstones":{"gone":0}}"#.utf8)).tombstones.count == 1)
        #expect(try decoder.decode(BookmarkLibraryWebDAVPayload.self,
            from: Data(#"{"version":1,"updatedAt":0,"items":[],"tombstones":{"gone":0}}"#.utf8)).tombstones.count == 1)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(ReadingProgressWebDAVPayload.self, from: Data(#"{"version":3,"updatedAt":0,"records":[]}"#.utf8))
        }
        #expect(throws: WebDAVSyncError.self) {
            _ = try decoder.decode(ContentCoverWebDAVPayload.self, from: Data(#"{"version":99,"updatedAt":0,"covers":[]}"#.utf8))
        }
    }

    @Test func clearingWhileRemoteIsAppliedNeverLosesTheDeletion() async throws {
        let db = try DeletionTestDatabase()
        let progress = ReadingProgressStore(databasePool: db.pool)
        let sync = ReadingProgressWebDAVParticipant(store: progress)
        let item = try await progress.saveNormalThread(threadID: "old", page: 4, date: old)
        let stale = try JSONEncoder().encode(ReadingProgressWebDAVPayload(updatedAt: old, records: [item]))
        let date = cleared
        for _ in 0..<10 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await progress.clearAllForSync(at: date) }
                group.addTask { try await sync.applyRemote(stale) }
                try await group.waitForAll()
            }
            #expect(await progress.loadAll().isEmpty)
            #expect(try await progress.syncSnapshot().deletions.clearedAt == cleared)
        }
    }

    @Test func softDeletionMigrationPreservesBareMarkersAfterRemovingContent() async throws {
        let db = try DeletionTestDatabase()
        let like = LikeStore(databasePool: db.pool)
        let bookmarks = BookmarkStore(databasePool: db.pool)
        let work = LikeWorkKey.novel(threadID: "work")
        let bookmark = BookmarkItem(id: "bookmark", workKey: work,
            anchor: .novel(NovelBookmarkAnchor(chapterIdentity: nil, textSegmentIdentity: nil,
                displayedTextOffset: 0, view: 1, chapterOrdinal: 0)), createdAt: old, updatedAt: cleared, deletedAt: cleared)
        let liked = LikeItem(id: "like", workKey: work, kind: .image,
            anchor: .mangaImage(MangaImageLikeAnchor(chapterTID: "1", pageLocalIndex: 0)),
            createdAt: old, updatedAt: cleared, deletedAt: cleared)
        try await like.replaceAll([liked])
        try await bookmarks.replaceAll([bookmark])
        // Recreate the exact pre-migration state: soft-deleted content rows
        // exist, but neither independent metadata table has been installed.
        try await db.pool.write { db in
            try db.execute(sql: "DROP TABLE like_sync_state")
            try db.execute(sql: "DROP TABLE bookmark_sync_state")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('like.v7.sync-deletions', 'bookmark.v2.sync-deletions')")
        }
        try YamiboDatabase.migrate(db.pool)
        try await like.replaceAll([])
        try await bookmarks.replaceAll([])
        #expect(try await like.syncSnapshot().deletions.tombstones["like"] == cleared)
        #expect(try await bookmarks.syncSnapshot().deletions.tombstones["bookmark"] == cleared)
        try await like.clearAll()
        try await bookmarks.clearAll()
        #expect(try await like.syncSnapshot().deletions == SyncDeletionState())
        #expect(try await bookmarks.syncSnapshot().deletions == SyncDeletionState())
    }
}

final class DeletionTestDatabase: Sendable {
    let root: URL
    let pool: DatabasePool

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-deletions-\(UUID().uuidString)")
        pool = try YamiboDatabase.openPool(rootDirectory: root)
    }

    func reopen() throws -> DatabasePool { try YamiboDatabase.openPool(rootDirectory: root) }

    deinit {
        try? pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}

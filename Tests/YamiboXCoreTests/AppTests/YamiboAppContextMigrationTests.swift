@preconcurrency import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore
import YamiboXTestSupport

@MainActor
@Test func appContextFreshStartupUsesSeededGRDBAndIgnoresLegacyJSONDefaults() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "app-context-grdb-fresh")
    let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
    let rootDirectory = makeTemporaryAppRoot()
    let legacyLibraryData = Data(#"{"items":[{"id":"legacy-library"}]}"#.utf8)
    let legacyProgressData = Data(#"{"records":[{"id":"legacy-progress"}]}"#.utf8)
    defaults.set(legacyLibraryData, forKey: "yamibox.favoriteLibrary.localFirst")
    defaults.set(legacyProgressData, forKey: "yamibox.readingProgress.records")
    let appContext = try makeIsolatedAppContext(suiteName: suiteName, rootDirectory: rootDirectory)

    let library = try await appContext.localFavoriteLibraryStore.load()
    let progress = await appContext.readingProgressStore.loadAll()

    #expect(library.defaultCategory.id == FavoriteCategory.defaultID)
    #expect(library.items.isEmpty)
    #expect(progress.isEmpty)
    #expect(defaults.data(forKey: "yamibox.favoriteLibrary.localFirst") == legacyLibraryData)
    #expect(defaults.data(forKey: "yamibox.readingProgress.records") == legacyProgressData)
}

@MainActor
@Test func appContextDefaultsWriteMigratedStateToSharedGRDBRoot() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "app-context-grdb-shared")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let rootDirectory = makeTemporaryAppRoot()
    let appContext = try makeIsolatedAppContext(suiteName: suiteName, rootDirectory: rootDirectory)
    let imageURL = try #require(URL(string: "https://img.example.test/7001-1.jpg"))

    try await saveMigratedAppState(appContext: appContext, chapterTID: "7001", imageURL: imageURL)
    try await appContext.novelReaderCacheStore.save(
        NovelReaderProjection(
            threadID: "7001",
            view: 1,
            maxView: 1,
            segments: [.text("Reader GRDB cache", chapterTitle: nil)]
        )
    )
    try await appContext.forumCacheStore.saveThreadPage(
        ForumThreadPage(
            thread: ThreadIdentity(tid: "8001"),
            title: "GRDB thread cache",
            posts: []
        ),
        thread: ThreadIdentity(tid: "8001")
    )

    let database = appContext.databasePool
    let counts = try await database.read { db in
        [
            "favorite_library_document": try tableCount("favorite_library_document", in: db),
            "reading_progress": try tableCount("reading_progress", in: db),
            "manga_directories": try tableCount("manga_directories", in: db),
            "offline_cache_manga_entries": try tableCount("offline_cache_manga_entries", in: db),
            "cache_entries": try tableCount("cache_entries", in: db),
        ]
    }

    #expect(counts["favorite_library_document"] == 1)
    #expect(counts["reading_progress"] == 1)
    #expect(counts["manga_directories"] == 1)
    #expect(counts["offline_cache_manga_entries"] == 1)
    #expect(counts["cache_entries"] == 3)
    let legacyTables = try await database.read { db in
        try legacyStructuredTablePresence(in: db)
    }
    #expect(legacyTables.allSatisfy { !$0.exists })
    let readerCacheEntriesTableExists = try await database.read { db in
        try db.tableExists("reader_cache_entries")
    }
    #expect(!readerCacheEntriesTableExists)
    let imageDataCacheEntriesTableExists = try await database.read { db in
        try db.tableExists("image_data_cache_entries")
    }
    #expect(!imageDataCacheEntriesTableExists)
    let jsonCacheNamespaces = try await database.read { db in
        try String.fetchAll(db, sql: "SELECT namespace FROM cache_entries ORDER BY namespace")
    }
    #expect(jsonCacheNamespaces == ["forum-thread-pages", "manga-reader-projections", "novel-reader-projections"])
    #expect(!FileManager.default.fileExists(atPath: rootDirectory.appendingPathComponent("reader-cache/index.json", isDirectory: false).path))
    #expect(!FileManager.default.fileExists(atPath: rootDirectory.appendingPathComponent("image-data/index.json", isDirectory: false).path))
}

@MainActor
@Test func appContextResetClearsGRDBStateAndManagedCacheFilesWithoutDeletingLegacyJSON() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "app-context-grdb-reset")
    let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
    let rootDirectory = makeTemporaryAppRoot()
    let legacyLibraryData = Data(#"{"items":[{"id":"legacy-library"}]}"#.utf8)
    let legacyProgressData = Data(#"{"records":[{"id":"legacy-progress"}]}"#.utf8)
    defaults.set(legacyLibraryData, forKey: "yamibox.favoriteLibrary.localFirst")
    defaults.set(legacyProgressData, forKey: "yamibox.readingProgress.records")
    let appContext = try makeIsolatedAppContext(suiteName: suiteName, rootDirectory: rootDirectory)
    let imageURL = try #require(URL(string: "https://img.example.test/7002-1.jpg"))

    try await saveMigratedAppState(appContext: appContext, chapterTID: "7002", imageURL: imageURL)
    try await appContext.novelReaderCacheStore.save(
        NovelReaderProjection(
            threadID: "7002",
            view: 1,
            maxView: 1,
            segments: [.text("Reader reset cache", chapterTitle: nil)]
        )
    )
    try await appContext.forumCacheStore.saveHome(
        ForumHomePage(categories: [], fetchedAt: Date(timeIntervalSince1970: 100))
    )
    try await appContext.forumCacheStore.saveBoard(
        ForumBoardPage(
            board: ForumBoardSummary(
                fid: "49",
                name: "百合小说",
                url: ForumRouteResolver.boardURL(fid: "49")
            ),
            fetchedAt: Date(timeIntervalSince1970: 100)
        ),
        fid: "49"
    )
    try await appContext.forumCacheStore.saveThreadPage(
        ForumThreadPage(
            thread: ThreadIdentity(tid: "8002"),
            title: "Reset thread cache",
            posts: []
        ),
        thread: ThreadIdentity(tid: "8002")
    )
    #expect(FileManager.default.fileExists(
        atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
            .appendingPathComponent("novel-reader-projections", isDirectory: true)
            .path
    ))
    #expect(FileManager.default.fileExists(atPath: offlineCacheDirectory(rootDirectory: rootDirectory).appendingPathComponent("images", isDirectory: true).path))
    #expect(FileManager.default.fileExists(atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory).path))
    #expect(FileManager.default.fileExists(
        atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
            .appendingPathComponent("forum-home", isDirectory: true)
            .path
    ))
    #expect(FileManager.default.fileExists(
        atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
            .appendingPathComponent("forum-boards", isDirectory: true)
            .path
    ))

    try await appContext.resetApplicationData()

    let database = appContext.databasePool
    let counts = try await database.read { db in
        [
            "favorite_library_document": try tableCount("favorite_library_document", in: db),
            "reading_progress": try tableCount("reading_progress", in: db),
            "manga_directories": try tableCount("manga_directories", in: db),
            "offline_cache_manga_entries": try tableCount("offline_cache_manga_entries", in: db),
            "offline_cache_image_assets": try tableCount("offline_cache_image_assets", in: db),
            "cache_entries": try tableCount("cache_entries", in: db),
        ]
    }

    // Reset drops the whole favorites document; loading afterwards
    // synthesizes the default-category document from no row at all.
    #expect(counts["favorite_library_document"] == 0)
    let resetLibrary = try await appContext.localFavoriteLibraryStore.load()
    #expect(resetLibrary.categories.map(\.id) == [FavoriteCategory.defaultID])
    #expect(counts["reading_progress"] == 0)
    #expect(counts["manga_directories"] == 0)
    #expect(counts["offline_cache_manga_entries"] == 0)
    #expect(counts["offline_cache_image_assets"] == 0)
    #expect(counts["cache_entries"] == 0)
    let legacyTables = try await database.read { db in
        try legacyStructuredTablePresence(in: db)
    }
    #expect(legacyTables.allSatisfy { !$0.exists })
    let readerCacheEntriesTableExists = try await database.read { db in
        try db.tableExists("reader_cache_entries")
    }
    #expect(!readerCacheEntriesTableExists)
    let imageDataCacheEntriesTableExists = try await database.read { db in
        try db.tableExists("image_data_cache_entries")
    }
    #expect(!imageDataCacheEntriesTableExists)
    #expect(!FileManager.default.fileExists(
        atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
            .appendingPathComponent("novel-reader-projections", isDirectory: true)
            .path
    ))
    #expect(!FileManager.default.fileExists(atPath: offlineCacheDirectory(rootDirectory: rootDirectory).path))
    #expect(!FileManager.default.fileExists(
        atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
            .appendingPathComponent("forum-home", isDirectory: true)
            .path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
            .appendingPathComponent("forum-boards", isDirectory: true)
            .path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
            .appendingPathComponent("forum-thread-pages", isDirectory: true)
            .path
    ))
    #expect(defaults.data(forKey: "yamibox.favoriteLibrary.localFirst") == legacyLibraryData)
    #expect(defaults.data(forKey: "yamibox.readingProgress.records") == legacyProgressData)
}

@MainActor
@Test func appContextDoesNotMigrateLegacyMangaNamedOfflineCacheDirectory() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "app-context-offline-cache-dir")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let rootDirectory = makeTemporaryAppRoot()
    let database = try YamiboDatabase.openPool(rootDirectory: rootDirectory)
    let legacyStore = OfflineCacheStore(
        databasePool: database,
        baseDirectory: legacyOfflineCacheDirectory(rootDirectory: rootDirectory)
    )
    let imageURL = try #require(URL(string: "https://img.example.test/9003-1.jpg"))
    let novelSourcePage = ForumThreadPage(
        thread: ThreadIdentity(tid: "9004"),
        title: "Legacy Novel",
        posts: [
            ForumThreadPost(
                postID: "9004-1",
                author: BlogReaderUser(uid: "42", name: "作者"),
                contentHTML: "<p>Legacy source page</p>",
                contentText: "Legacy source page"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1)
    )

    try await legacyStore.saveOfflineImageData(Data([9, 3]), for: imageURL)
    try await legacyStore.saveMangaOfflineCacheMembership(
        MangaOfflineCacheMembership(
            ownerName: "Legacy Manga",
            tid: "9003",
            chapterTitle: "旧第一话",
            imageURLs: [imageURL],
            sourcePage: makeAppMigrationMangaSourcePage(tid: "9003")
        )
    )
    try await legacyStore.saveNovelOfflineSourcePage(
        novelSourcePage,
        request: NovelOfflineCacheWorkRequest(
            ownerTitle: "Legacy Novel",
            title: "第一页",
            threadID: novelSourcePage.thread.tid,
            view: 1,
            authorID: "42"
        ),
        updatedAt: Date(timeIntervalSince1970: 100),
        completesMatchingWork: true,
        preservesExistingImageReferencesWhenEmpty: false
    )
    #expect(FileManager.default.fileExists(atPath: legacyOfflineCacheDirectory(rootDirectory: rootDirectory).path))
    #expect(!FileManager.default.fileExists(atPath: offlineCacheDirectory(rootDirectory: rootDirectory).path))

    let appContext = try makeIsolatedAppContext(suiteName: suiteName, rootDirectory: rootDirectory, databasePool: database)

    #expect(FileManager.default.fileExists(atPath: legacyOfflineCacheDirectory(rootDirectory: rootDirectory).path))
    // The context eagerly prepares an (empty, backup-excluded) offline-cache
    // directory; the point here is that no legacy payload gets moved into it.
    let newOfflineCacheDirectoryContents = (try? FileManager.default.contentsOfDirectory(
        atPath: offlineCacheDirectory(rootDirectory: rootDirectory).path
    )) ?? []
    #expect(newOfflineCacheDirectoryContents.isEmpty)
    #expect(await appContext.offlineCacheStore.offlineImageData(for: imageURL) == nil)
    #expect(await appContext.offlineCacheStore.mangaOfflineCacheState(ownerName: "Legacy Manga", tid: "9003") == .uncached)
    let loadedNovelSourcePage = await appContext.offlineCacheStore.novelOfflineSourcePage(
        ownerTitle: "Legacy Novel",
        threadID: novelSourcePage.thread.tid,
        view: 1,
        authorID: "42"
    )
    #expect(loadedNovelSourcePage == nil)
}

private func makeTemporaryAppRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("yamibox-app-context-grdb-\(UUID().uuidString)", isDirectory: true)
}

private func offlineCacheDirectory(rootDirectory: URL) -> URL {
    rootDirectory.appendingPathComponent("offline-cache", isDirectory: true)
}

private func legacyOfflineCacheDirectory(rootDirectory: URL) -> URL {
    rootDirectory
        .appendingPathComponent("manga-reader", isDirectory: true)
        .appendingPathComponent("offline-cache", isDirectory: true)
}

private func makeIsolatedAppContext(
    suiteName: String,
    rootDirectory: URL,
    databasePool: DatabasePool? = nil
) throws -> YamiboAppContext {
    let database = try databasePool ?? YamiboDatabase.openPool(rootDirectory: rootDirectory)
    return YamiboAppContext(
        sessionStore: SessionStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "session"),
        profileStore: YamiboProfileStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "profile"),
        checkInStore: YamiboCheckInStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), keyPrefix: "check-in"),
        settingsStore: SettingsStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "settings"),
        webDAVSyncSettingsStore: WebDAVSyncSettingsStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "webdav"),
        readerResumeRouteStore: ReaderResumeRouteStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "resume-route"),
        localFavoriteLibraryStore: FavoriteLibraryStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), databasePool: database),
        favoriteUpdateStore: FavoriteUpdateStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "favorite-updates"),
        readingProgressStore: ReadingProgressStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), databasePool: database),
        contentCoverStore: ContentCoverStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "content-covers"),
        databasePool: database,
        grdbRootDirectory: rootDirectory,
        cachesRootDirectory: rootDirectory,
        uiDefaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        clearsWebDataOnReset: false
    )
}

private func saveMigratedAppState(
    appContext: YamiboAppContext,
    chapterTID: String,
    imageURL: URL
) async throws {
    var library = FavoriteLibraryDocument()
    let favoriteTarget = FavoriteItemTarget(kind: .novelThread, threadID: chapterTID)
    library.upsertItem(
        try FavoriteItem(
            target: favoriteTarget,
            title: "Shared GRDB favorite",
            locations: [.category(library.defaultCategory.id)]
        )
    )
    try await appContext.localFavoriteLibraryStore.save(library)
    try await appContext.readingProgressStore.saveNovel(
        NovelReadingPosition(threadID: chapterTID, view: 3)
    )
    let chapter = MangaChapter(
        tid: chapterTID,
        rawTitle: "第一话",
        chapterNumber: 1
    )
    try await appContext.mangaDirectoryStore.saveDirectory(
        MangaDirectory(
            cleanBookName: "Shared GRDB Manga",
            strategy: .links,
            sourceKey: "shared-grdb",
            chapters: [chapter]
        )
    )
    try await appContext.mangaReaderProjectionStore.save(
        MangaReaderProjection(
            tid: chapter.tid,
            chapterTitle: chapter.rawTitle,
            imageURLs: [imageURL]
        )
    )
    try await appContext.offlineCacheStore.saveMangaOfflineCacheMembership(
        MangaOfflineCacheMembership(
            ownerName: "Shared GRDB Manga",
            tid: chapter.tid,
            chapterTitle: chapter.rawTitle,
            imageURLs: [imageURL],
            sourcePage: makeAppMigrationMangaSourcePage(tid: chapter.tid)
        )
    )
    try await appContext.offlineCacheStore.saveOfflineImageData(Data("offline".utf8), for: imageURL)
}

private func makeAppMigrationMangaSourcePage(tid: String) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "第\(tid)话",
        posts: [
            ForumThreadPost(
                postID: "p-\(tid)",
                author: BlogReaderUser(uid: "author-\(tid)", name: "作者"),
                contentHTML: "",
                contentText: ""
            )
        ]
    )
}

private func tableCount(_ table: String, in db: Database) throws -> Int {
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
}

private func legacyStructuredTablePresence(in db: Database) throws -> [(name: String, exists: Bool)] {
    try [
        "manga_chapter_documents",
        "manga_chapter_document_images",
        "manga_offline_cache_memberships",
        "manga_offline_cache_membership_images",
        "manga_offline_cache_works",
        "manga_offline_cache_work_images",
        "manga_offline_cache_completed_images",
        "manga_offline_cache_images",
        "manga_offline_cache_queue_state",
    ].map { table in
        (name: table, exists: try db.tableExists(table))
    }
}

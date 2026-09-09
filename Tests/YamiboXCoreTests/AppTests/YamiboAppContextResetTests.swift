@preconcurrency import Foundation
@preconcurrency import GRDB
import Testing
@testable import YamiboXCore

@MainActor
@Suite("AppTests: Application Data Reset", .serialized)
struct YamiboAppContextResetTests {
    @Test func everyOwnedStoreIsRegisteredForReset() throws {
        let fixture = try AppResetFixture()
        defer { fixture.cleanup() }
        // Store ownership is declared on the composition root. Detect a new
        // store that was added there without joining the reset inventory.
        let ownedStores = Set(Mirror(reflecting: fixture.context).children.compactMap(\.label)
            .filter { $0.hasSuffix("Store") })
        let registeredStores = Set(AppDataResetParticipant.allCases.map(\.rawValue)
            .filter { $0.hasSuffix("Store") })
        #expect(ownedStores == registeredStores)
    }

    @Test(arguments: [false, true])
    func resetClearsEveryRegisteredCategoryAndPreservesUnownedData(injectSyncRunStore: Bool) async throws {
        let fixture = try AppResetFixture(injectSyncRunStore: injectSyncRunStore)
        defer { fixture.cleanup() }
        for participant in AppDataResetParticipant.allCases {
            try await fixture.seed(participant)
        }
        try await fixture.seedUnownedData()

        try await fixture.context.resetApplicationData()

        for participant in AppDataResetParticipant.allCases {
            try await fixture.verifyReset(participant)
        }
        try await fixture.verifyUnownedData()
        let remainingRows = try await fixture.context.databasePool.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                """)
            return try tables.filter { try Table<Row>($0).fetchCount(db) > 0 }
        }
        #expect(remainingRows.isEmpty)
    }
}

@MainActor
private final class AppResetFixture {
    let suiteName = "app-data-reset-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let context: YamiboAppContext
    let likeStore: LikeStore
    let likeImageStore: LikeImageStore
    let bookmarkStore: BookmarkStore
    let ordinaryImageCache = ResetImageCache()
    let websiteDataClearer = ResetWebsiteDataClearer()
    let httpCache = URLCache(memoryCapacity: 1_024_000, diskCapacity: 0, diskPath: nil)
    let unownedLibrary: FavoriteLibraryStore?
    let imageURL = URL(string: "https://example.test/reset.jpg")!
    let now = Date(timeIntervalSince1970: 1_000)

    init(injectSyncRunStore: Bool = false) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        let database = try YamiboDatabase.openPool(rootDirectory: root.appendingPathComponent("data"))
        let syncRunStore: FavoriteSyncRunStore?
        if injectSyncRunStore {
            let injectedDatabase = try YamiboDatabase.openPool(rootDirectory: root.appendingPathComponent("injected"))
            syncRunStore = FavoriteSyncRunStore(databasePool: injectedDatabase)
            unownedLibrary = FavoriteLibraryStore(databasePool: injectedDatabase)
        } else {
            syncRunStore = nil
            unownedLibrary = nil
        }
        likeStore = LikeStore(databasePool: database)
        likeImageStore = LikeImageStore(baseDirectory: root.appendingPathComponent("like-images"))
        bookmarkStore = BookmarkStore(databasePool: database)
        context = YamiboAppContext(
            sessionStore: SessionStore(defaults: defaults),
            profileStore: YamiboProfileStore(defaults: defaults),
            checkInStore: YamiboCheckInStore(defaults: defaults),
            settingsStore: SettingsStore(defaults: defaults),
            webDAVSyncSettingsStore: WebDAVSyncSettingsStore(defaults: defaults),
            readerResumeRouteStore: ReaderResumeRouteStore(defaults: defaults),
            favoriteSyncRunStore: syncRunStore,
            likeStore: likeStore,
            likeImageStore: likeImageStore,
            bookmarkStore: bookmarkStore,
            ordinaryImageCache: ordinaryImageCache,
            databasePool: database,
            grdbRootDirectory: root.appendingPathComponent("data"),
            cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: defaults,
            clearsWebDataOnReset: false,
            websiteDataClearer: websiteDataClearer,
            httpCache: httpCache
        )
    }

    func seed(_ participant: AppDataResetParticipant) async throws {
        switch participant {
        case .sessionStore:
            try await context.sessionStore.save(SessionState(cookie: "auth=reset-fixture", isLoggedIn: true))
        case .profileStore:
            try await context.profileStore.save(YamiboProfile(
                uid: "42", username: "Fixture", userGroup: "Member", points: 1, partner: 2, totalPoints: 3
            ))
        case .checkInStore:
            await context.checkInStore.importSnapshot(YamiboCheckInSnapshot(
                checkedInDatesByAccountHash: ["fixture-account": "2026-09-09"]
            ))
        case .settingsStore:
            var settings = AppSettings()
            settings.novelReader.fontScale += 0.1
            try await context.settingsStore.save(settings)
        case .webDAVSyncSettingsStore:
            try await context.webDAVSyncSettingsStore.save(WebDAVSyncSettings(
                baseURLString: "https://example.test/dav", username: "Fixture", password: "fixture-only",
                dirtyDatasetIDs: ["favorites"], localRevisionByDatasetID: ["favorites": 2]
            ))
        case .readerResumeRouteStore:
            try await context.readerResumeRouteStore.save(.novel(NovelLaunchContext(
                threadID: "100", threadTitle: "Fixture", source: .forum
            )))
        case .localFavoriteLibraryStore:
            try await context.localFavoriteLibraryStore.save(makeLibrary())
        case .favoriteUpdateStore:
            try await seedFavoriteUpdates()
        case .favoriteSyncRunStore:
            try await context.favoriteSyncRunStore.save(FavoriteRemoteSyncSnapshot(
                status: .running, targetCategoryID: FavoriteCategory.defaultID,
                targetCategoryName: "Fixture", phase: .queued,
                logEntries: [.started(categoryName: "Fixture")]
            ))
            #expect(await context.favoriteSyncRunStore.latestSnapshot() != nil)
        case .readingProgressStore:
            try await context.readingProgressStore.saveNovel(NovelReadingPosition(threadID: "100", view: 3))
        case .browsingHistoryStore:
            try await context.browsingHistoryStore.record(BrowsingHistoryEntry(
                target: .novelThread(threadID: "100"), title: "Fixture"
            ))
        case .contentCoverStore:
            try await context.contentCoverStore.setManualCover(
                imageURL, for: ContentCoverKey(targetType: .thread, targetID: "100")
            )
        case .novelReaderCacheStore:
            try await context.novelReaderCacheStore.save(NovelReaderProjection(
                threadID: "100", view: 1, maxView: 1, segments: [.text("Fixture", chapterTitle: nil)]
            ))
        case .mangaDirectoryStore:
            try await context.mangaDirectoryStore.saveDirectory(MangaDirectory(
                cleanBookName: "Fixture", strategy: .links, sourceKey: "100",
                chapters: [MangaChapter(tid: "100", rawTitle: "Chapter", chapterNumber: 1)]
            ))
        case .mangaDirectorySearchCooldownState:
            _ = await context.mangaDirectorySearchCooldownState.reserveCooldown(now: now, duration: 60)
        case .mangaReaderProjectionStore:
            try await context.mangaReaderProjectionStore.save(MangaReaderProjection(
                tid: "100", chapterTitle: "Chapter", imageURLs: [imageURL]
            ))
        case .offlineCacheStore:
            try await seedOfflineCache()
        case .forumCacheStore:
            try await context.forumCacheStore.saveHome(ForumHomePage(categories: []))
            try await context.forumCacheStore.saveBoard(ForumBoardPage(board: ForumBoardSummary(
                fid: "49", name: "Fixture", url: ForumRouteResolver.boardURL(fid: "49")
            )), fid: "49")
            try await context.forumCacheStore.saveThreadPage(sourcePage, thread: ThreadIdentity(tid: "100"))
        case .favoriteBackgroundImageStore:
            try await context.favoriteBackgroundImageStore.save(Data([1, 2]), imageID: "fixture")
        case .ordinaryImageCache:
            await ordinaryImageCache.seed()
        case .localUIState:
            for key in YamiboAppStorageKey.resettable { defaults.set("fixture", forKey: key) }
        case .webData:
            let response = URLResponse(url: imageURL, mimeType: "image/jpeg", expectedContentLength: 2, textEncodingName: nil)
            httpCache.storeCachedResponse(CachedURLResponse(response: response, data: Data([1, 2])), for: URLRequest(url: imageURL))
        case .likeStore:
            try await likeStore.upsertImageLike(
                id: "fixture", workKey: .mangaTitle(cleanBookName: "Fixture"),
                anchor: .mangaImage(MangaImageLikeAnchor(chapterTID: "100", pageLocalIndex: 0)),
                sourceImageURL: imageURL
            )
            // Reset must remove tombstones as well as visible annotations.
            try await likeStore.delete(id: "fixture")
        case .likeImageStore:
            try await likeImageStore.save(Data([3, 4]), id: "fixture", sourceURL: imageURL)
        case .bookmarkStore:
            let bookmark = try await bookmarkStore.toggle(
                workKey: .mangaTitle(cleanBookName: "Fixture"),
                anchor: .manga(MangaBookmarkAnchor(chapterTID: "100", pageLocalIndex: 0, globalPageIndex: 0))
            )
            try await bookmarkStore.delete(id: bookmark.item.id)
        }
    }

    func verifyReset(_ participant: AppDataResetParticipant) async throws {
        switch participant {
        case .sessionStore:
            let session = await context.sessionStore.load()
            #expect(!session.isLoggedIn)
            #expect(session.cookie.isEmpty)
        case .profileStore:
            #expect(await context.profileStore.load() == nil)
        case .checkInStore:
            #expect(await context.checkInStore.exportSnapshot().checkedInDatesByAccountHash.isEmpty)
        case .settingsStore:
            #expect(await context.settingsStore.load() == AppSettings())
        case .webDAVSyncSettingsStore:
            #expect(await context.webDAVSyncSettingsStore.load() == WebDAVSyncSettings())
        case .readerResumeRouteStore:
            #expect(await context.readerResumeRouteStore.load() == nil)
        case .localFavoriteLibraryStore:
            let library = try await context.localFavoriteLibraryStore.load()
            #expect(library.items.isEmpty)
            #expect(library.categories.map(\.id) == [FavoriteCategory.defaultID])
        case .favoriteUpdateStore:
            #expect(await context.favoriteUpdateStore.loadState() == FavoriteUpdateStoreState())
            #expect(await context.favoriteUpdateStore.latestRun() == nil)
        case .favoriteSyncRunStore:
            #expect(await context.favoriteSyncRunStore.latestSnapshot() == nil)
        case .readingProgressStore:
            #expect(await context.readingProgressStore.loadAll().isEmpty)
        case .browsingHistoryStore:
            #expect(await context.browsingHistoryStore.entries().isEmpty)
        case .contentCoverStore:
            #expect(try await context.contentCoverStore.allCovers().isEmpty)
        case .novelReaderCacheStore:
            #expect(await context.novelReaderCacheStore.totalDiskUsageBytes() == 0)
            #expect(await context.novelReaderCacheStore.loadProjection(for: NovelPageRequest(threadID: "100", view: 1)) == nil)
        case .mangaDirectoryStore:
            #expect(try await context.mangaDirectoryStore.directory(named: "Fixture") == nil)
        case .mangaDirectorySearchCooldownState:
            #expect(await context.mangaDirectorySearchCooldownState.cooldownExpiresAt(now: now) == nil)
        case .mangaReaderProjectionStore:
            #expect(await context.mangaReaderProjectionStore.totalDiskUsageBytes() == 0)
            #expect(await context.mangaReaderProjectionStore.projection(for: MangaReaderProjectionSourceIdentity(
                tid: "100", authorID: nil, view: 1
            )) == nil)
        case .offlineCacheStore:
            #expect(await context.offlineCacheStore.allMangaOfflineCacheMemberships().isEmpty)
            #expect(await context.offlineCacheStore.allNovelOfflineCacheEntries().isEmpty)
            #expect(await context.offlineCacheStore.offlineCacheQueueWorks().isEmpty)
            #expect(await context.offlineCacheStore.offlineImageData(for: imageURL) == nil)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data/offline-cache").path))
        case .forumCacheStore:
            #expect(await context.forumCacheStore.loadHome(allowExpired: true) == nil)
            #expect(await context.forumCacheStore.loadBoard(fid: "49", allowExpired: true) == nil)
            #expect(await context.forumCacheStore.loadThreadPage(thread: ThreadIdentity(tid: "100"), allowExpired: true) == nil)
            #expect(await context.forumCacheStore.totalDiskUsageBytes() == 0)
        case .favoriteBackgroundImageStore:
            #expect(await context.favoriteBackgroundImageStore.loadData(imageID: "fixture") == nil)
        case .ordinaryImageCache:
            #expect(await ordinaryImageCache.hasData == false)
            #expect(await ordinaryImageCache.clearCount == 1)
        case .localUIState:
            for key in YamiboAppStorageKey.resettable { #expect(defaults.object(forKey: key) == nil) }
        case .webData:
            // Isolated contexts opt out of shared browser/cookie cleanup.
            #expect(websiteDataClearer.clearCount == 0)
            #expect(httpCache.cachedResponse(for: URLRequest(url: imageURL)) != nil)
        case .likeStore:
            #expect(await likeStore.allIncludingDeleted().isEmpty)
        case .likeImageStore:
            #expect(await likeImageStore.loadData(id: "fixture") == nil)
        case .bookmarkStore:
            #expect(await bookmarkStore.allIncludingDeleted().isEmpty)
        }
    }

    func seedUnownedData() async throws {
        defaults.set("remembered-login", forKey: YamiboAppStorageKey.loginUsername)
        defaults.set("legacy", forKey: "yamibox.favoriteLibrary.localFirst")
        defaults.set("unrelated", forKey: "unrelated-fixture")
        try Data([5, 6]).write(to: root.appendingPathComponent("unmanaged.bin"))
        try await unownedLibrary?.save(makeLibrary())
    }

    func verifyUnownedData() async throws {
        #expect(defaults.string(forKey: YamiboAppStorageKey.loginUsername) == "remembered-login")
        #expect(defaults.string(forKey: "yamibox.favoriteLibrary.localFirst") == "legacy")
        #expect(defaults.string(forKey: "unrelated-fixture") == "unrelated")
        #expect(try Data(contentsOf: root.appendingPathComponent("unmanaged.bin")) == Data([5, 6]))
        if let unownedLibrary { #expect(try await unownedLibrary.load().items.count == 1) }
    }

    private func seedFavoriteUpdates() async throws {
        try await context.favoriteUpdateStore.saveRun(FavoriteUpdateRunSnapshot())
        try await context.favoriteUpdateStore.upsertTrackedTarget(FavoriteUpdateTrackedTarget(
            target: .mangaDirectory(cleanBookName: "Fixture"), title: "Fixture", mode: .mangaDirectory
        ))
        try await context.favoriteUpdateStore.insertEvent(FavoriteUpdateEvent(
            target: .mangaDirectory(cleanBookName: "Fixture"), title: "Fixture", mode: .mangaDirectory,
            summary: .newChapters(count: 1)
        ))
        try await context.favoriteUpdateStore.replaceFilters(
            fidFilters: [FavoriteUpdateFidFilter(fid: "49", forumName: "Fixture")],
            categoryFilters: [FavoriteUpdateCategoryFilter(categoryID: FavoriteCategory.defaultID, categoryName: "Fixture")]
        )
    }

    private func seedOfflineCache() async throws {
        let store = context.offlineCacheStore
        try await store.saveMangaOfflineCacheMembership(MangaOfflineCacheMembership(
            ownerName: "Fixture", tid: "100", chapterTitle: "Chapter", imageURLs: [imageURL], sourcePage: sourcePage
        ))
        try await store.saveNovelOfflineSourcePage(
            sourcePage,
            request: NovelOfflineCacheWorkRequest(ownerTitle: "Fixture", title: "Chapter", threadID: "100", view: 1, authorID: "42"),
            updatedAt: now, completesMatchingWork: false, preservesExistingImageReferencesWhenEmpty: false
        )
        try await store.saveOfflineImageData(Data([7, 8]), for: imageURL)
        _ = try await store.enqueueMangaOfflineCacheWork(MangaOfflineCacheWorkRequest(
            ownerName: "Fixture", tid: "101", chapterTitle: "Queued chapter", targetImageURLs: [imageURL]
        ))
        _ = try await store.enqueueNovelOfflineCacheWork(NovelOfflineCacheWorkRequest(
            ownerTitle: "Fixture", title: "Queued chapter", threadID: "100", view: 2, authorID: "42"
        ))
        try await store.setOfflineCacheQueueRunState(.running)
    }

    private var sourcePage: ForumThreadPage {
        ForumThreadPage(
            thread: ThreadIdentity(tid: "100"), title: "Fixture",
            posts: [ForumThreadPost(
                postID: "post-100", author: BlogReaderUser(uid: "42", name: "Fixture"),
                contentHTML: "<p>Fixture</p>", contentText: "Fixture"
            )]
        )
    }

    private func makeLibrary() throws -> FavoriteLibraryDocument {
        var library = FavoriteLibraryDocument()
        library.upsertItem(try FavoriteItem(
            target: FavoriteItemTarget(kind: .novelThread, threadID: "100"), title: "Fixture",
            locations: [.category(library.defaultCategory.id)]
        ))
        return library
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ResetImageCache: YamiboOrdinaryImageCacheClearing {
    var hasData = false
    var clearCount = 0

    func seed() { hasData = true }

    func totalDiskUsageBytes() async -> Int { hasData ? 1 : 0 }

    func removeAllCachedData() async {
        hasData = false
        clearCount += 1
    }
}

@MainActor
private final class ResetWebsiteDataClearer: WebsiteDataClearing {
    var clearCount = 0

    func clearYamiboCookies() async {}

    func clearAllWebsiteData() async { clearCount += 1 }
}

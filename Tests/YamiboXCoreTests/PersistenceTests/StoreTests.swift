import CoreGraphics
import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore
import YamiboXTestSupport

@Test func sessionStorePersistsCookieAndLoginState() async throws {
    let defaults = try #require(UserDefaults(suiteName: "session-store-tests"))
    defaults.removePersistentDomain(forName: "session-store-tests")
    let store = SessionStore(defaults: defaults, key: "session")

    try await store.updateCookie("sid=123", isLoggedIn: true)
    let session = await store.load()

    #expect(session.cookie == "sid=123")
    #expect(session.isLoggedIn)
    #expect(session.userAgent == YamiboNetworkConfiguration.defaultMobileUserAgent)
}

@Test func sessionStoreUpdatesUserAgentFromWebSession() async throws {
    let defaults = try #require(UserDefaults(suiteName: "web-session-store-tests"))
    defaults.removePersistentDomain(forName: "web-session-store-tests")
    let store = SessionStore(defaults: defaults, key: "session")

    try await store.updateWebSession(
        cookie: "sid=999; EeqY_2132_auth=web-token",
        userAgent: "Custom-UA",
        isLoggedIn: true
    )
    let session = await store.load()

    #expect(session.cookie == "sid=999; EeqY_2132_auth=web-token")
    #expect(session.userAgent == "Custom-UA")
    #expect(session.isLoggedIn)
}

@Test func sessionStoreIgnoresAnonymousWebCookieWhenNativeSessionIsAuthenticated() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "web-session-anonymous-over-auth-tests")
    let store = SessionStore(defaults: defaults, key: "session")
    let authenticatedSession = SessionState(
        cookie: "sid=1; EeqY_2132_auth=native-token; salt=old",
        userAgent: "Native-UA",
        isLoggedIn: true,
        accountUID: "535977"
    )
    try await store.save(authenticatedSession)

    try await store.updateWebSession(
        cookie: "sid=anonymous; salt=new",
        userAgent: "Web-UA",
        isLoggedIn: false
    )

    let session = await store.load()
    #expect(session.cookie == authenticatedSession.cookie)
    #expect(session.userAgent == authenticatedSession.userAgent)
    #expect(session.isLoggedIn)
    #expect(session.accountUID == "535977")
}

@Test func sessionStoreSavesAnonymousWebCookieWhenNotAuthenticated() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "web-session-anonymous-tests")
    let store = SessionStore(defaults: defaults, key: "session")

    try await store.updateWebSession(
        cookie: "sid=anonymous; salt=web",
        userAgent: "Web-UA",
        isLoggedIn: false
    )

    let session = await store.load()
    #expect(session.cookie == "sid=anonymous; salt=web")
    #expect(session.userAgent == "Web-UA")
    #expect(!session.isLoggedIn)
    #expect(session.accountUID == nil)
}

@Test func sessionStorePromotesAuthenticatedWebCookie() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "web-session-promote-auth-tests")
    let store = SessionStore(defaults: defaults, key: "session")

    try await store.updateWebSession(
        cookie: "sid=web; EeqY_2132_auth=web-token",
        userAgent: "Web-UA",
        isLoggedIn: true
    )

    let session = await store.load()
    #expect(session.cookie == "sid=web; EeqY_2132_auth=web-token")
    #expect(session.userAgent == "Web-UA")
    #expect(session.isLoggedIn)
    #expect(session.accountUID == nil)
}

@Test func sessionStorePreservesAccountUIDWhenWebAuthenticationTokenIsUnchanged() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "web-session-preserve-uid-tests")
    let store = SessionStore(defaults: defaults, key: "session")
    try await store.save(
        SessionState(
            cookie: "sid=old; EeqY_2132_auth=same-token; salt=old",
            userAgent: "Native-UA",
            isLoggedIn: true,
            accountUID: "535977"
        )
    )

    try await store.updateWebSession(
        cookie: "sid=new; EeqY_2132_auth=same-token; salt=new",
        userAgent: "Web-UA",
        isLoggedIn: true
    )

    let session = await store.load()
    #expect(session.cookie == "sid=new; EeqY_2132_auth=same-token; salt=new")
    #expect(session.userAgent == "Web-UA")
    #expect(session.isLoggedIn)
    #expect(session.accountUID == "535977")
}

@Test func sessionStoreIgnoresDifferentWebAuthenticationTokenWhenNativeSessionIsAuthenticated() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "web-session-token-change-tests")
    let store = SessionStore(defaults: defaults, key: "session")
    let nativeSession = SessionState(
        cookie: "sid=old; EeqY_2132_auth=native-token",
        userAgent: "Native-UA",
        isLoggedIn: true,
        accountUID: "535977"
    )
    try await store.save(nativeSession)

    try await store.updateWebSession(
        cookie: "sid=stale; EeqY_2132_auth=stale-web-token",
        userAgent: "Web-UA",
        isLoggedIn: true
    )

    let session = await store.load()
    #expect(session.cookie == nativeSession.cookie)
    #expect(session.userAgent == nativeSession.userAgent)
    #expect(session.isLoggedIn)
    #expect(session.accountUID == "535977")
}

@Test func sessionStateRejectsEmptyAndDeletedAuthenticationCookieValues() {
    #expect(SessionState.authenticationCookieValue(in: "EeqY_2132_auth=valid-token") == "valid-token")
    #expect(SessionState.authenticationCookieValue(in: "sid=1; EeqY_2132_auth=; salt=2") == nil)
    #expect(SessionState.authenticationCookieValue(in: "sid=1; EeqY_2132_auth=deleted; salt=2") == nil)
    #expect(!SessionState.hasAuthenticationCookie("sid=1; EeqY_2132_auth=null; salt=2"))
}

@Test func settingsStorePersistsReaderFlags() async throws {
    let defaults = try #require(UserDefaults(suiteName: "settings-store-tests"))
    defaults.removePersistentDomain(forName: "settings-store-tests")
    let store = SettingsStore(defaults: defaults, key: "settings")
    let settings = AppSettings(
        novelReader: NovelReaderAppearanceSettings(
            fontScale: 1.1,
            fontFamily: .rounded,
            lineHeightScale: 1.6,
            characterSpacingScale: 0.04,
            horizontalPadding: 20,
            usesJustifiedText: true,
            loadsInlineImages: false,
            showsAuthorRepliesToOthers: false,
            showsTwoPagesInLandscapeOnPad: true,
            backgroundStyle: .paper,
            readingMode: .vertical,
            pagedTurnStyle: .quickFade,
            pageTurnDirection: .rightToLeft,
            translationMode: .traditional
        ),
        novelOfflineCache: NovelOfflineCacheSettings(
            retainsInlineImages: true,
            isAutoRefreshEnabled: false
        ),
        manga: MangaReaderSettings(
            readingMode: .paged,
            pagedTurnStyle: .pageCurl,
            pageTurnDirection: .leftToRight,
            pageScaleMode: .fitHeight,
            pageEdgeFillStyle: .system,
            brightness: 0.82,
            zoomEnabled: false,
            showsTwoPagesInLandscapeOnPad: true,
            directorySortOrder: .descending
        ),
        favorites: FavoriteLibrarySettings(
            collapsesSections: true
        ),
        webBrowser: WebBrowserSettings(showsNavigationBar: false),
        system: SystemSettings(
            homePage: .favorites,
            usesDataSaverMode: true,
            applePencilPageTurn: ApplePencilPageTurnSettings(
                isEnabled: true,
                behavior: .doubleTapNextSqueezePrevious
            )
        )
    )

    try await store.save(settings)
    let loaded = await store.load()

    #expect(loaded == settings)
}

@Test func settingsStoreFallsBackToDefaultsWhenStoredDataDoesNotDecode() async throws {
    let defaults = try #require(UserDefaults(suiteName: "settings-store-fallback-tests"))
    defaults.removePersistentDomain(forName: "settings-store-fallback-tests")
    let staleShape = """
    {
      "reader": {
        "fontScale": 1.0
      },
      "usesDataSaverMode": false
    }
    """
    defaults.set(Data(staleShape.utf8), forKey: "settings")
    let store = SettingsStore(defaults: defaults, key: "settings")

    let loaded = await store.load()
    let syncLoaded = SettingsStore.loadSync(defaults: defaults, key: "settings")

    #expect(loaded == AppSettings())
    #expect(syncLoaded == AppSettings())
}

@Test func favoriteBackgroundSettingsEncodesDecodesAndClampsValues() throws {
    let payload = """
    {
      "isEnabled": true,
      "imageID": "image-a",
      "scale": 9.0,
      "offsetX": -4.0,
      "offsetY": 2.0,
      "blurRadius": 80.0
    }
    """

    let decoded = try JSONDecoder().decode(FavoriteBackgroundSettings.self, from: Data(payload.utf8))

    #expect(decoded.isEnabled)
    #expect(decoded.imageID == "image-a")
    #expect(decoded.scale == FavoriteBackgroundSettings.maximumScale)
    #expect(decoded.offsetX == FavoriteBackgroundSettings.minimumOffset)
    #expect(decoded.offsetY == FavoriteBackgroundSettings.maximumOffset)
    #expect(decoded.blurRadius == FavoriteBackgroundSettings.maximumBlurRadius)

    let encoded = try JSONEncoder().encode(decoded)
    let roundTrip = try JSONDecoder().decode(FavoriteBackgroundSettings.self, from: encoded)
    #expect(roundTrip == decoded)
}

@Test func applePencilPageTurnBehaviorMapsGesturesToPageDeltas() {
    #expect(ApplePencilPageTurnBehavior.doubleTapPreviousSqueezeNext.pageDelta(for: .doubleTap) == -1)
    #expect(ApplePencilPageTurnBehavior.doubleTapPreviousSqueezeNext.pageDelta(for: .squeeze) == 1)
    #expect(ApplePencilPageTurnBehavior.doubleTapNextSqueezePrevious.pageDelta(for: .doubleTap) == 1)
    #expect(ApplePencilPageTurnBehavior.doubleTapNextSqueezePrevious.pageDelta(for: .squeeze) == -1)
}

@Test func favoriteLibrarySettingsNormalizesSelectedIdentifiers() {
    let favorites = FavoriteLibrarySettings(
        selectedCategoryID: "  category-1  ",
        selectedCollectionID: "   "
    )

    #expect(favorites.selectedCategoryID == "category-1")
    #expect(favorites.selectedCollectionID == nil)
}

/// Migration path for the "显示智能漫画标识" switch: settings persisted before
/// the field existed must decode with the badge on (its default), and an
/// explicit off must survive a round trip.
@Test func favoriteLibrarySettingsSmartMangaBadgeDefaultsOnAndRoundTrips() throws {
    let missingKey = try JSONDecoder().decode(FavoriteLibrarySettings.self, from: Data("{}".utf8))
    #expect(missingKey.smartMangaBadgeEnabled)

    let encoded = try JSONEncoder().encode(FavoriteLibrarySettings(smartMangaBadgeEnabled: false))
    let decoded = try JSONDecoder().decode(FavoriteLibrarySettings.self, from: encoded)
    #expect(!decoded.smartMangaBadgeEnabled)
}

@Test func appSettingsPersistsHomePageWhenEncodingAndDecoding() throws {
    let settings = AppSettings(system: SystemSettings(homePage: .favorites))

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

    #expect(decoded.system.homePage == .favorites)
}

@Test func readerAppearanceSettingsEncodesAndDecodesPagedTurnOptions() throws {
    let settings = NovelReaderAppearanceSettings(
        readingMode: .paged,
        pagedTurnStyle: .pageCurl,
        pageTurnDirection: .rightToLeft
    )

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(NovelReaderAppearanceSettings.self, from: encoded)

    #expect(decoded.readingMode == .paged)
    #expect(decoded.pagedTurnStyle == .pageCurl)
    #expect(decoded.pageTurnDirection == .rightToLeft)
}

@Test func mangaReaderSettingsEncodesAndDecodesPagedOptions() throws {
    let settings = MangaReaderSettings(
        readingMode: .paged,
        pagedTurnStyle: .quickFade,
        pageTurnDirection: .leftToRight,
        pageScaleMode: .fitHeight,
        pageEdgeFillStyle: .system,
        brightness: 0.9,
        zoomEnabled: false,
        showsTwoPagesInLandscapeOnPad: true,
        directorySortOrder: .descending
    )

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(MangaReaderSettings.self, from: encoded)

    #expect(decoded == settings)
}

@Test func settingsStoreResetRestoresDefaults() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "settings-reset-tests")
    let store = SettingsStore(defaults: defaults, key: "settings")

    try await store.save(AppSettings(
        webBrowser: WebBrowserSettings(showsNavigationBar: false),
        system: SystemSettings(homePage: .favorites)
    ))
    try await store.reset()

    let loaded = await store.load()
    #expect(loaded == AppSettings())
    #expect(loaded.system.homePage == .forum)
}

@Test func settingsStoreLoadSyncMatchesAsyncLoad() async throws {
    let suiteName = makeIsolatedDefaultsSuiteName(prefix: "settings-sync-tests")
    let actorDefaults = try #require(UserDefaults(suiteName: suiteName))
    actorDefaults.removePersistentDomain(forName: suiteName)
    let syncDefaults = try #require(UserDefaults(suiteName: suiteName))
    let store = SettingsStore(defaults: actorDefaults, key: "settings")
    let saved = AppSettings(
        webBrowser: WebBrowserSettings(showsNavigationBar: false),
        system: SystemSettings(homePage: .favorites, usesDataSaverMode: true)
    )

    try await store.save(saved)

    let syncLoaded = SettingsStore.loadSync(defaults: syncDefaults, key: "settings")
    let asyncLoaded = await store.load()

    #expect(syncLoaded == saved)
    #expect(syncLoaded == asyncLoaded)
}

@Test func sessionStoreResetRestoresDefaults() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "session-reset-tests")
    let store = SessionStore(defaults: defaults, key: "session")

    try await store.updateWebSession(
        cookie: "sid=reset",
        userAgent: "Test-UA",
        isLoggedIn: true
    )
    try await store.reset()

    let loaded = await store.load()
    #expect(loaded == SessionState())
}

@Test func readerResumeRouteStorePersistsNovelRouteAndClearsIt() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "reader-resume-novel-tests")
    let store = ReaderResumeRouteStore(defaults: defaults, key: "reader-route")
    let resumePoint = NovelResumePoint(
        view: 2,
        displayedTextOffset: 20,
        chapterOrdinal: 3,
        chapterTitle: "第三章",
        segmentProgress: 0.5,
        authorID: "42",
        readingModeHint: .vertical
    )
    let context = NovelLaunchContext(
        threadID: "611",
        threadTitle: "测试小说",
        source: .resume,
        initialView: 2,
        authorID: "42",
        initialResumePoint: resumePoint
    )

    try await store.save(.novel(context))

    #expect(await store.load() == .novel(context))

    await store.clear()

    #expect(await store.load() == nil)
}

@Test func readerResumeRouteStorePersistsMangaContextAndIgnoresInvalidData() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "reader-resume-manga-tests")
    let store = ReaderResumeRouteStore(defaults: defaults, key: "reader-route")
    let context = MangaLaunchContext(
        originalThreadID: "612",
        chapterTID: "613",
        displayTitle: "测试漫画",
        source: .resume,
        initialPage: 7,
        directoryName: "测试漫画"
    )

    try await store.save(.manga(context))

    let persistedRoute = try persistedResumeRoute(.manga(context))
    #expect(await store.load() == persistedRoute)

    let invalidDefaults = try makeIsolatedDefaults(prefix: "reader-resume-invalid-tests")
    invalidDefaults.set(Data("legacy".utf8), forKey: "reader-route")
    let invalidStore = ReaderResumeRouteStore(defaults: invalidDefaults, key: "reader-route")

    #expect(await invalidStore.load() == nil)
}

private func persistedResumeRoute(_ route: ReaderResumeRoute) throws -> ReaderResumeRoute {
    let data = try JSONEncoder().encode(route)
    return try JSONDecoder().decode(ReaderResumeRoute.self, from: data)
}

@Test func readerResumeRouteStoreSuppressesLatePositionSaveAfterClearUntilNextPresentation() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "reader-resume-suppression-tests")
    let store = ReaderResumeRouteStore(defaults: defaults, key: "reader-route")
    let firstRoute = ReaderResumeRoute.novel(
        NovelLaunchContext(
            threadID: "614",
            threadTitle: "第一本",
            source: .resume
        )
    )
    let secondRoute = ReaderResumeRoute.novel(
        NovelLaunchContext(
            threadID: "615",
            threadTitle: "第二本",
            source: .resume
        )
    )

    try await store.save(firstRoute)
    await store.clear()
    try await store.saveReadingPosition(firstRoute)

    #expect(await store.load() == nil)

    try await store.save(secondRoute)

    #expect(await store.load() == secondRoute)
}

@Test func readingProgressStoreSavesNovelByThreadIDAndMangaProgressByCanonicalThreadURL() async throws {
    let suiteName = makeIsolatedDefaultsSuiteName(prefix: "reading-progress-store-tests")
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let legacyData = Data(#"{"legacy":true}"#.utf8)
    defaults.set(legacyData, forKey: "reading-progress")
    let database = try YamiboDatabase.openPool(
        rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    )
    let store = ReadingProgressStore(
        defaults: defaults,
        key: "reading-progress",
        databasePool: database
    )
    let resumePoint = NovelResumePoint(
        view: 3,
        displayedTextOffset: 128,
        chapterOrdinal: 2,
        chapterTitle: "第三章",
        segmentProgress: 0.4,
        authorID: "42",
        readingModeHint: .vertical
    )

    try await store.saveNovel(NovelReadingPosition(
        threadID: "12345",
        view: 2,
        maxView: 8,
        chapterTitle: "旧章",
        authorID: "1",
        resumePoint: resumePoint,
        documentSurfaceProgressPercent: 37
    ))

    let novel = await store.load(threadID: "12345")
    #expect(novel?.kind == .novel)
    #expect(novel?.threadID == "12345")
    #expect(novel?.novel?.lastView == 3)
    #expect(novel?.novel?.lastChapter == "第三章")
    #expect(novel?.novel?.authorID == "42")
    #expect(novel?.novel?.novelMaxView == 8)
    #expect(novel?.novel?.novelDocumentSurfaceProgressPercent == 37)
    #expect(novel?.novel?.novelResumePoint == resumePoint)

    try await store.saveManga(MangaProgressReadingPosition(
        threadID: "12345",
        chapterThreadID: "12346",
        chapterTitle: "第 12 话",
        pageIndex: 6,
        pageCount: 12
    ))

    let manga = await store.load(threadID: "12345")
    #expect(manga?.kind == .manga)
    #expect(manga?.novel == nil)
    #expect(manga?.threadID == "12345")
    #expect(manga?.manga?.chapterThreadID == "12346")
    #expect(manga?.manga?.lastChapter == "第 12 话")
    #expect(manga?.manga?.mangaPageIndex == 6)
    #expect(manga?.manga?.mangaPageCount == 12)
    let legacyDefaultsAfterSave = try #require(UserDefaults(suiteName: suiteName))
    #expect(legacyDefaultsAfterSave.data(forKey: "reading-progress") == legacyData)

    let databaseState = try await database.read { db in
        let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('reading_progress')")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, kind, target_kind, thread_id, manga_chapter_thread_id, novel_last_view, manga_page_index
            FROM reading_progress
            ORDER BY kind
            """
        )
        return (
            columns: columns,
            rows: rows.map { row in
                (
                    id: row["id"] as String,
                    kind: row["kind"] as String,
                    targetKind: row["target_kind"] as String,
                    threadID: row["thread_id"] as String?,
                    mangaChapterThreadID: row["manga_chapter_thread_id"] as String?,
                    novelLastView: row["novel_last_view"] as Int?,
                    mangaPageIndex: row["manga_page_index"] as Int?
                )
            }
        )
    }
    #expect(!databaseState.columns.contains("thread_url"))
    #expect(!databaseState.columns.contains("last_manga_url"))
    // Smart Comic Mode defaults to on (`MangaProgressReadingPosition.isSmartModeEnabled`
    // defaults `true`), so `saveManga` writes only the directory-level
    // `.mangaTitle` record (thread_id keyed to the launch-context threadID
    // "12345") — no `.mangaThread` row, per smart-comic-mode design decision #15.
    #expect(databaseState.rows.count == 2)
    #expect(databaseState.rows.contains { $0.id == "thread:novel:12345" && $0.threadID == "12345" && $0.novelLastView == 3 })
    #expect(databaseState.rows.contains { $0.id == "manga-title:第 12 话" && $0.threadID == "12345" && $0.mangaChapterThreadID == "12346" && $0.mangaPageIndex == 6 })
}

@Test func readingProgressStoreMatchesNovelProgressWithAndWithoutExtraQuery() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "reading-progress-extra-tests")
    let store = ReadingProgressStore(
        defaults: defaults,
        key: "reading-progress"
    )
    try await store.saveNovel(NovelReadingPosition(threadID: "521519", view: 25, chapterTitle: "第二十五章"))

    let progress = await store.load(threadID: "521519")
    #expect(progress?.kind == .novel)
    #expect(progress?.novel?.lastView == 25)
    #expect(progress?.novel?.lastChapter == "第二十五章")
}

@Test func novelReaderCacheStoreReportsUsageAndCanClearAll() async throws {
    let baseDirectory = makeTemporaryDirectory(prefix: "reader-cache-tests")
    let store = NovelReaderProjectionStore(baseDirectory: baseDirectory)

    try await store.save(
        NovelReaderProjection(
            threadID: "600",
            view: 1,
            maxView: 1,
            segments: [.text("测试内容", chapterTitle: "第一章")]
        )
    )

    let usage = await store.totalDiskUsageBytes()
    #expect(usage > 0)

    try await store.clearAll()

    let clearedUsage = await store.totalDiskUsageBytes()
    #expect(clearedUsage == 0)
}

@Test func novelReaderProjectionStorePrunesToMostRecentOneHundredEntries() async throws {
    let root = makeTemporaryDirectory(prefix: "novel-projection-prune-tests")
    let pool = try YamiboDatabase.openPool(rootDirectory: root)
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 100)
    let diskCache = DiskCacheStore(writer: pool, rootDirectory: root, now: { now })
    let store = NovelReaderProjectionStore(diskCacheStore: diskCache)

    for view in 1...101 {
        now = Date(timeIntervalSince1970: 100 + TimeInterval(view))
        try await store.save(
            NovelReaderProjection(
                threadID: "950",
                view: view,
                maxView: 101,
                segments: [.text("第\(view)页", chapterTitle: nil)]
            )
        )
    }

    let request = { (view: Int) in NovelPageRequest(threadID: "950", view: view, authorID: nil) }
    #expect(await store.loadProjection(for: request(1)) == nil)
    #expect(await store.loadProjection(for: request(2))?.view == 2)
    #expect(await store.loadProjection(for: request(101))?.view == 101)
}

@Test func favoriteBackgroundImageStoreSavesLoadsDeletesAndPrunes() async throws {
    let baseDirectory = makeTemporaryDirectory(prefix: "favorite-background-tests")
    let store = FavoriteBackgroundImageStore(baseDirectory: baseDirectory)
    let firstData = Data(repeating: 3, count: 32)
    let secondData = Data(repeating: 8, count: 48)

    try await store.save(firstData, imageID: "first")
    try await store.save(secondData, imageID: "second")

    #expect(await store.loadData(imageID: "first") == firstData)
    #expect(await store.loadData(imageID: "second") == secondData)

    try await store.prune(keeping: "second")
    #expect(await store.loadData(imageID: "first") == nil)
    #expect(await store.loadData(imageID: "second") == secondData)

    try await store.delete(imageID: "second")
    #expect(await store.loadData(imageID: "second") == nil)

    try await store.save(firstData, imageID: "third")
    try await store.deleteAll()
    #expect(await store.loadData(imageID: "third") == nil)
}

@Test func clearingReaderCacheDoesNotDeleteFavoriteBackground() async throws {
    let rootDirectory = makeTemporaryDirectory(prefix: "cache-clear-background-root")
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: rootDirectory.appendingPathComponent("reader-cache", isDirectory: true))
    let backgroundStore = FavoriteBackgroundImageStore(baseDirectory: rootDirectory.appendingPathComponent("favorite-background", isDirectory: true))
    let backgroundData = Data(repeating: 4, count: 64)

    try await novelReaderCacheStore.save(
        NovelReaderProjection(
            threadID: "701",
            view: 1,
            maxView: 1,
            segments: [.text("测试", chapterTitle: nil)]
        )
    )
    try await backgroundStore.save(backgroundData, imageID: "background")

    try await novelReaderCacheStore.clearAll()

    #expect(await backgroundStore.loadData(imageID: "background") == backgroundData)
}

@Test func favoriteBackgroundLayoutClampsScaleAndOffsetsForDifferentAspectRatios() {
    let settings = FavoriteBackgroundSettings(
        isEnabled: true,
        imageID: "background",
        scale: 4,
        offsetX: 2,
        offsetY: -2,
        blurRadius: 0
    )
    let portraitFrame = FavoriteBackgroundLayout.renderedFrame(
        imageSize: CGSize(width: 200, height: 100),
        containerSize: CGSize(width: 100, height: 200),
        settings: settings
    )
    #expect(portraitFrame.size == CGSize(width: 1200, height: 600))
    #expect(portraitFrame.offset == CGSize(width: 550, height: -200))

    let offsets = FavoriteBackgroundLayout.normalizedOffsets(
        imageSize: CGSize(width: 100, height: 200),
        containerSize: CGSize(width: 300, height: 200),
        scale: 1,
        proposedOffset: CGSize(width: 1000, height: 1000)
    )
    #expect(offsets.offsetX == 0)
    #expect(offsets.offsetY == 1)
}

@Test func appContextResetApplicationDataClearsPersistedState() async throws {
    let suiteName = makeIsolatedDefaultsSuiteName(prefix: "app-reset-tests")
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    let rootDirectory = makeTemporaryDirectory(prefix: "app-reset-root")

    let sessionStore = SessionStore(defaults: try #require(UserDefaults(suiteName: suiteName)), key: "session")
    let settingsStore = SettingsStore(defaults: try #require(UserDefaults(suiteName: suiteName)), key: "settings")
    let readerResumeRouteStore = ReaderResumeRouteStore(defaults: try #require(UserDefaults(suiteName: suiteName)), key: "reader-route")
    let localFavoriteLibraryStore = FavoriteLibraryStore(
        defaults: try #require(UserDefaults(suiteName: suiteName)),
        key: "local-favorites"
    )
    let contentCoverStore = ContentCoverStore(
        defaults: try #require(UserDefaults(suiteName: suiteName)),
        key: "content-covers"
    )
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: rootDirectory.appendingPathComponent("reader-cache", isDirectory: true))
    let favoriteBackgroundImageStore = FavoriteBackgroundImageStore(
        baseDirectory: rootDirectory.appendingPathComponent("favorite-background", isDirectory: true)
    )
    let likeStore = LikeStore(defaults: try #require(UserDefaults(suiteName: suiteName)), key: "like-store")
    let likeImageStore = LikeImageStore(
        baseDirectory: rootDirectory.appendingPathComponent("like-images", isDirectory: true)
    )
    let mangaDirectoryStore = try makeTestMangaDirectoryStore(rootDirectory: rootDirectory)
    let mangaReaderProjectionStore = try makeTestMangaReaderProjectionStore(rootDirectory: rootDirectory)
    let offlineCacheStore = try makeTestOfflineCacheStore(rootDirectory: rootDirectory)
    let appContext = YamiboAppContext(
        sessionStore: sessionStore,
        settingsStore: settingsStore,
        readerResumeRouteStore: readerResumeRouteStore,
        localFavoriteLibraryStore: localFavoriteLibraryStore,
        contentCoverStore: contentCoverStore,
        novelReaderCacheStore: novelReaderCacheStore,
        favoriteBackgroundImageStore: favoriteBackgroundImageStore,
        likeStore: likeStore,
        likeImageStore: likeImageStore,
        mangaDirectoryStore: mangaDirectoryStore,
        mangaReaderProjectionStore: mangaReaderProjectionStore,
        offlineCacheStore: offlineCacheStore
    )
    try await sessionStore.updateWebSession(cookie: "sid=1", userAgent: "UA", isLoggedIn: true)
    try await settingsStore.save(AppSettings(webBrowser: WebBrowserSettings(showsNavigationBar: false)))
    try await readerResumeRouteStore.save(
            .novel(
                NovelLaunchContext(
                    threadID: "700",
                    threadTitle: "测试小说",
                    source: .resume
                )
        )
    )
    var localLibrary = FavoriteLibraryDocument()
    let localTarget = FavoriteItemTarget(kind: .normalThread, threadID: "700")
    try localLibrary.upsertItem(
        FavoriteItem(
            target: localTarget,
            title: "本地优先收藏",
            locations: [.category(localLibrary.defaultCategory.id)]
        )
    )
    try await localFavoriteLibraryStore.save(localLibrary)
    try await novelReaderCacheStore.save(
        NovelReaderProjection(
            threadID: "700",
            view: 1,
            maxView: 1,
            segments: [.text("测试", chapterTitle: nil)]
        )
    )
    try await favoriteBackgroundImageStore.save(Data(repeating: 5, count: 256), imageID: "background")
    try await mangaDirectoryStore.saveDirectory(
        MangaDirectory(
            cleanBookName: "测试漫画",
            strategy: .tag,
            sourceKey: "tag:1",
            chapters: [
                MangaChapter(
                    tid: "700",
                    rawTitle: "第1话",
                    chapterNumber: 1
                )
            ]
        )
    )
    let projectionIdentity = MangaReaderProjectionSourceIdentity(
        tid: "700",
        authorID: nil,
        view: 1
    )
    try await mangaReaderProjectionStore.save(MangaReaderProjection(
        tid: "700",
        chapterTitle: "测试漫画",
        imageURLs: [try #require(URL(string: "https://img.example.com/reset-1.jpg"))],
        sourceIdentity: projectionIdentity,
        sourceFingerprint: "reset-fixture"
    ))
    let offlineImageURL = try #require(URL(string: "https://img.example.com/offline-reset.jpg"))
    try await offlineCacheStore.saveOfflineImageData(
        Data(repeating: 7, count: 64),
        for: offlineImageURL
    )
    try await offlineCacheStore.saveMangaOfflineCacheMembership(
        MangaOfflineCacheMembership(
            ownerName: "测试漫画",
            tid: "700",
            chapterTitle: "测试漫画",
            imageURLs: [offlineImageURL],
            sourcePage: makeStoreTestMangaOfflineSourcePage(tid: "700")
        )
    )
    _ = try await offlineCacheStore.enqueueMangaOfflineCacheWork(
        MangaOfflineCacheWorkRequest(
            ownerName: "测试漫画",
            tid: "701",
            chapterTitle: "测试漫画续篇",
            targetImageURLs: [try #require(URL(string: "https://img.example.com/offline-reset-work.jpg"))]
        )
    )
    try await offlineCacheStore.saveNovelOfflineCacheEntry(
        NovelOfflineCacheEntry(
            ownerTitle: "测试小说",
            title: "第一页",
            document: NovelReaderProjection(
                threadID: "700",
                view: 1,
                maxView: 2,
                resolvedAuthorID: "author-700",
                segments: [.text("离线小说正文", chapterTitle: "第一章")]
            )
        )
    )
    _ = try await offlineCacheStore.enqueueNovelOfflineCacheWork(
        NovelOfflineCacheWorkRequest(
            ownerTitle: "测试小说",
            title: "第二页",
            threadID: "700",
            view: 2,
            authorID: "author-700"
        )
    )
    try await offlineCacheStore.setOfflineCacheQueueRunState(.running)
    let coverKey = ContentCoverKey(targetType: .thread, targetID: "700")
    try await contentCoverStore.setAutomaticCover(
        try #require(URL(string: "https://img.example.com/reset-cover.jpg")),
        for: coverKey
    )
    let likeWorkKey = LikeWorkKey.mangaTitle(cleanBookName: "测试漫画")
    try await likeStore.upsertImageLike(
        workKey: likeWorkKey,
        anchor: .mangaImage(MangaImageLikeAnchor(chapterTID: "700", pageLocalIndex: 0)),
        sourceImageURL: try #require(URL(string: "https://img.example.com/like-reset.jpg"))
    )
    try await likeImageStore.save(Data(repeating: 9, count: 32), id: "like-reset-image", sourceURL: nil)

    try await appContext.resetApplicationData()

    let session = await sessionStore.load()
    let settings = await settingsStore.load()
    let readerResumeRoute = await readerResumeRouteStore.load()
    let localFavoriteLibrary = try await localFavoriteLibraryStore.load()
    let contentCover = await contentCoverStore.cover(for: coverKey)
    let readerCacheBytes = await novelReaderCacheStore.totalDiskUsageBytes()
    let backgroundData = await favoriteBackgroundImageStore.loadData(imageID: "background")
    let mangaDirectoryBytes = await mangaDirectoryStore.totalDiskUsageBytes()
    let mangaReaderProjectionBytes = await mangaReaderProjectionStore.totalDiskUsageBytes()
    let mangaOfflineCacheBytes = await offlineCacheStore.totalDiskUsageBytes()
    let mangaOfflineMemberships = await offlineCacheStore.allMangaOfflineCacheMemberships()
    let mangaOfflineWorks = await offlineCacheStore.mangaQueueWorks()
    let novelOfflineEntries = await offlineCacheStore.allNovelOfflineCacheEntries()
    let offlineQueueWorks = await offlineCacheStore.offlineCacheQueueWorks()
    let mangaOfflineQueueState = await offlineCacheStore.offlineCacheQueueRunState()
    let likeItems = await likeStore.likes(for: likeWorkKey)
    let likeImageData = await likeImageStore.loadData(id: "like-reset-image")

    #expect(session == SessionState())
    #expect(settings == AppSettings())
    #expect(readerResumeRoute == nil)
    #expect(localFavoriteLibrary.items.isEmpty)
    #expect(await !localFavoriteLibraryStore.hasStoredDocument())
    #expect(contentCover == nil)
    #expect(readerCacheBytes == 0)
    #expect(backgroundData == nil)
    #expect(mangaDirectoryBytes == 0)
    #expect(mangaReaderProjectionBytes == 0)
    #expect(mangaOfflineCacheBytes == 0)
    #expect(mangaOfflineMemberships.isEmpty)
    #expect(mangaOfflineWorks.isEmpty)
    #expect(novelOfflineEntries.isEmpty)
    #expect(offlineQueueWorks.isEmpty)
    #expect(mangaOfflineQueueState == .paused)
    #expect(likeItems.isEmpty)
    #expect(likeImageData == nil)
}

@Test func contentCoverStoreNormalizesAndFiltersAutomaticCoverURLs() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "content-cover-normalize")
    let store = ContentCoverStore(defaults: defaults, key: "content-covers")
    let key = ContentCoverKey(targetType: .thread, targetID: "900")

    let ignored = try #require(URL(string: "https://bbs.yamibo.com/static/image/smiley/default/none.gif"))
    let relative = try #require(URL(string: "data/attachment/forum/cover.jpg"))

    #expect(try await store.setAutomaticCover(ignored, for: key) == false)
    #expect(await store.cover(for: key) == nil)
    #expect(try await store.setAutomaticCover(relative, for: key) == true)

    let cover = try #require(await store.cover(for: key))
    #expect(cover.automaticCoverURL?.absoluteString == "https://bbs.yamibo.com/data/attachment/forum/cover.jpg")
    #expect(cover.resolvedURL == cover.automaticCoverURL)
}

@Test func contentCoverStoreResolvesManualCoverWhenDynamicDisabled() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "content-cover-manual")
    let store = ContentCoverStore(defaults: defaults, key: "content-covers")
    let key = ContentCoverKey(targetType: .thread, targetID: "901")
    let automatic = try #require(URL(string: "https://img.example.com/auto.jpg"))
    let manual = try #require(URL(string: "https://img.example.com/manual.jpg"))

    try await store.setAutomaticCover(automatic, for: key)
    try await store.setManualCover(manual, for: key)

    var cover = try #require(await store.cover(for: key))
    #expect(cover.dynamicEnabled == false)
    #expect(cover.resolvedURL == manual)

    try await store.setDynamicEnabled(true, for: key)
    cover = try #require(await store.cover(for: key))
    #expect(cover.resolvedURL == automatic)
}

@Test func contentCoverStoreClearManualCoverRestoresAutomaticMode() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "content-cover-clear-manual")
    let store = ContentCoverStore(defaults: defaults, key: "content-covers")
    let key = ContentCoverKey.smartManga(cleanBookName: "测试漫画")
    let automatic = try #require(URL(string: "https://img.example.com/auto.jpg"))
    let manual = try #require(URL(string: "https://img.example.com/manual.jpg"))

    #expect(try await store.clearManualCover(for: key) == false)

    try await store.setAutomaticCover(automatic, for: key)
    try await store.setManualCover(manual, for: key)
    #expect(try await store.clearManualCover(for: key) == true)

    let cover = try #require(await store.cover(for: key))
    #expect(cover.manualCoverURL == nil)
    #expect(cover.dynamicEnabled == true)
    #expect(cover.resolvedURL == automatic)
}

@Test func contentCoverStoreForcedTextCoverSuppressesResolvedURL() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "content-cover-text-forced")
    let store = ContentCoverStore(defaults: defaults, key: "content-covers")
    let key = ContentCoverKey(targetType: .thread, targetID: "902")
    let automatic = try #require(URL(string: "https://img.example.com/auto.jpg"))
    let manual = try #require(URL(string: "https://img.example.com/manual.jpg"))

    try await store.setAutomaticCover(automatic, for: key)
    try await store.setManualCover(manual, for: key)
    #expect(try await store.setTextCoverForced(true, for: key) == true)

    var cover = try #require(await store.cover(for: key))
    #expect(cover.textCoverForced)
    #expect(cover.resolvedURL == nil)
    // Un-forcing resolves back to whatever the stored URLs already produced,
    // without the toggle itself touching them.
    #expect(cover.manualCoverURL == manual)
    #expect(cover.automaticCoverURL == automatic)

    try await store.setTextCoverForced(false, for: key)
    cover = try #require(await store.cover(for: key))
    #expect(!cover.textCoverForced)
    #expect(cover.resolvedURL == manual)
}

@Test func contentCoverStoreExplicitImageCoverActionsClearForcedTextCover() async throws {
    let defaults = try makeIsolatedDefaults(prefix: "content-cover-text-forced-clear")
    let store = ContentCoverStore(defaults: defaults, key: "content-covers")
    let automaticKey = ContentCoverKey(targetType: .thread, targetID: "manual-clears-forced")
    let automatic = try #require(URL(string: "https://img.example.com/auto.jpg"))
    let manual = try #require(URL(string: "https://img.example.com/manual.jpg"))

    try await store.setAutomaticCover(automatic, for: automaticKey)
    try await store.setTextCoverForced(true, for: automaticKey)
    try await store.setManualCover(manual, for: automaticKey)
    var cover = try #require(await store.cover(for: automaticKey))
    #expect(!cover.textCoverForced)
    #expect(cover.resolvedURL == manual)

    let restoreKey = ContentCoverKey(targetType: .thread, targetID: "restore-clears-forced")
    try await store.setAutomaticCover(automatic, for: restoreKey)
    try await store.setManualCover(manual, for: restoreKey)
    try await store.setTextCoverForced(true, for: restoreKey)
    try await store.clearManualCover(for: restoreKey)
    cover = try #require(await store.cover(for: restoreKey))
    #expect(!cover.textCoverForced)
    #expect(cover.resolvedURL == automatic)
}

@Test func contentCoverKeyMergesThreadKindsAndUsesMangaCleanBookName() throws {
    let normal = ContentCoverKey(target: FavoriteContentTarget(kind: .normalThread, threadID: "77"))
    let novel = ContentCoverKey(target: FavoriteContentTarget(kind: .novelThread, threadID: "77"))
    let manga = ContentCoverKey(target: FavoriteContentTarget(mangaID: "tag:9", mangaCleanBookName: "清理书名"))

    #expect(normal == ContentCoverKey.thread(tid: "77"))
    #expect(novel == normal)
    #expect(manga == ContentCoverKey.smartManga(cleanBookName: "清理书名"))
}

@Test func mangaDirectoryRenameMovesContentCoverRow() async throws {
    let root = makeTemporaryDirectory(prefix: "content-cover-rename")
    let pool = try YamiboDatabase.openPool(rootDirectory: root)
    let directoryStore = MangaDirectoryStore(databasePool: pool)
    let coverStore = ContentCoverStore(databasePool: pool)
    let manual = try #require(URL(string: "https://img.example.com/manual.jpg"))
    let directory = MangaDirectory(
        cleanBookName: "旧书名",
        strategy: .links,
        sourceKey: "chapter:900",
        chapters: [MangaChapter(tid: "900", rawTitle: "第1话", chapterNumber: 1)]
    )
    try await directoryStore.saveDirectory(directory)
    try await coverStore.setManualCover(manual, for: .smartManga(cleanBookName: "旧书名"))

    var renamed = directory
    renamed.cleanBookName = "新书名"
    try await directoryStore.renameDirectory(from: "旧书名", to: renamed)

    #expect(await coverStore.cover(for: .smartManga(cleanBookName: "旧书名")) == nil)
    let moved = try #require(await coverStore.cover(for: .smartManga(cleanBookName: "新书名")))
    #expect(moved.manualCoverURL == manual)
    #expect(moved.dynamicEnabled == false)
}

@Test func contentCoversSurviveFavoriteDocumentSavesAndLibraryClearAll() async throws {
    let root = makeTemporaryDirectory(prefix: "content-cover-survival")
    let pool = try YamiboDatabase.openPool(rootDirectory: root)
    let libraryStore = FavoriteLibraryStore(databasePool: pool)
    let coverStore = ContentCoverStore(databasePool: pool)
    let key = ContentCoverKey.thread(tid: "555")
    let manual = try #require(URL(string: "https://img.example.com/manual.jpg"))
    try await coverStore.setManualCover(manual, for: key)

    // Document saves fully rewrite the favorite rows; covers must survive.
    var document = FavoriteLibraryDocument()
    document.upsertItem(try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "555"),
        title: "主题",
        locations: [.category(document.defaultCategory.id)]
    ))
    try await libraryStore.save(document)
    #expect(await coverStore.cover(for: key)?.manualCoverURL == manual)

    // Clearing the favorite library is favorites-scoped and keeps covers.
    try await libraryStore.clearAll()
    #expect(await coverStore.cover(for: key)?.manualCoverURL == manual)
}

private func makeMangaOfflineMembership(
    ownerName: String,
    tid: String,
    imageURLs: [URL]
) throws -> MangaOfflineCacheMembership {
    MangaOfflineCacheMembership(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs,
        sourcePage: makeStoreTestMangaOfflineSourcePage(tid: tid)
    )
}

private func makeStoreTestMangaOfflineSourcePage(tid: String) -> ForumThreadPage {
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

private func makeMangaOfflineWorkRequest(
    ownerName: String,
    tid: String,
    targetImageURLs: [URL]
) throws -> MangaOfflineCacheWorkRequest {
    MangaOfflineCacheWorkRequest(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        targetImageURLs: targetImageURLs
    )
}

private func makeIsolatedDefaults(prefix: String) throws -> UserDefaults {
    let suiteName = makeIsolatedDefaultsSuiteName(prefix: prefix)
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        struct DefaultsSuiteCreationError: Error {}
        throw DefaultsSuiteCreationError()
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func makeIsolatedDefaultsSuiteName(prefix: String) -> String {
    "\(prefix)-\(UUID().uuidString)"
}

private func makeTemporaryDirectory(prefix: String) -> URL {
    let baseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    return baseURL
}

@Test func yamiboDatabaseQuarantinesCorruptFileAndRecreates() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("yamibo-corrupt-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = YamiboDatabase.databaseURL(rootDirectory: root)
    try Data("this is not a sqlite database, but it is long enough to have a header".utf8)
        .write(to: databaseURL)

    // A corrupt file must not propagate as an error (the callers' fatalError
    // path would crash-loop the app); it is quarantined and recreated.
    let pool = try YamiboDatabase.openPool(rootDirectory: root)
    let migrationsTableExists = try await pool.read { db in
        try db.tableExists("grdb_migrations")
    }
    #expect(migrationsTableExists)

    // The corpse is preserved for diagnosis rather than deleted.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(siblings.contains { $0.contains(".corrupt-") })
}

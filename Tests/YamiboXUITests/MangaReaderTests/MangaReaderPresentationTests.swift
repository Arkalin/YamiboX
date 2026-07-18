import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class MangaReaderPresentationTests: XCTestCase {
    func testBootstrapRestoresNovelResumeRoute() async throws {
        let (appModel, store) = try await makeAppModelWithReaderResumeRouteStore()
        let context = NovelLaunchContext(
            threadID: "720",
            threadTitle: "测试小说",
            source: .resume,
            initialView: 3
        )
        try await store.save(.novel(context))

        await appModel.bootstrap()

        XCTAssertEqual(appModel.activeNovelContext, context)
        XCTAssertNil(appModel.activeMangaContext)
    }

    func testBootstrapRestoresMangaResumeRoute() async throws {
        let (appModel, store) = try await makeAppModelWithReaderResumeRouteStore()
        let context = MangaLaunchContext(
            originalThreadID: "721",
            chapterTID: "722",
            displayTitle: "测试漫画",
            source: .resume,
            initialPage: 6
        )
        try await store.save(.manga(context))

        await appModel.bootstrap()

        XCTAssertNil(appModel.activeNovelContext)
        XCTAssertEqual(appModel.activeMangaContext, try persistedMangaContext(context))
    }

    func testBootstrapIfNeededRestoresNovelRouteFromDownloadedWebDAVProgress() async throws {
        let suiteName = "reader-resume-webdav-novel-\(UUID().uuidString)"
        let fixture = try makeAppModelWebDAVFixture(suiteName: suiteName)
        let host = "reader-restore-novel.example.com"
        let staleResumePoint = NovelResumePoint(
            view: 1,
            displayedTextOffset: 12,
            chapterOrdinal: 0,
            chapterTitle: "第一章",
            segmentProgress: 0.1,
            readingModeHint: .paged
        )
        let staleContext = NovelLaunchContext(
            threadID: "730",
            threadTitle: "本地小说",
            source: .resume,
            initialView: 1,
            initialResumePoint: staleResumePoint
        )
        let remoteResumePoint = NovelResumePoint(
            view: 5,
            displayedTextOffset: 256,
            chapterOrdinal: 4,
            chapterTitle: "第五章",
            segmentProgress: 0.6,
            authorID: "42",
            readingModeHint: .vertical
        )
        let progressPayload = ReadingProgressWebDAVPayload(
            updatedAt: Date(timeIntervalSince1970: 2_000),
            records: [
                ReadingProgressRecord(
                    contentTarget: FavoriteContentTarget(kind: .novelThread, threadID: "730"),
                    threadID: "730",
                    kind: .novel,
                    updatedAt: Date(timeIntervalSince1970: 2_000),
                    lastReadAt: Date(timeIntervalSince1970: 2_000),
                    novel: NovelReadingProgressRecord(
                        lastView: 5,
                        lastChapter: "第五章",
                        authorID: "42",
                        novelResumePoint: remoteResumePoint,
                        novelMaxView: 9
                    )
                )
            ]
        )
        let encodedProgressPayload = try JSONEncoder().encode(progressPayload)

        try await fixture.resumeRouteStore.save(.novel(staleContext))
        try await fixture.sessionStore.save(SessionState(cookie: "sid=local", isLoggedIn: true, accountUID: "100"))
        try await fixture.webDAVSettingsStore.save(WebDAVSyncSettings(
            baseURLString: "https://\(host)",
            username: "admin",
            password: "secret",
            isAutoSyncEnabled: true,
            lastRemoteUpdatedAt: Date(timeIntervalSince1970: 2_000),
            localUpdatedAt: Date(timeIntervalSince1970: 1_000)
        ))

        AppModelWebDAVTestURLProtocol.setHandler(for: host) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            guard request.url?.lastPathComponent == "yamibox-reading-progress-v1.json" else {
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                )
            }
            return (
                encodedProgressPayload,
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            )
        }
        defer { AppModelWebDAVTestURLProtocol.removeHandler(for: host) }

        let appContext = YamiboAppContext(
            sessionStore: fixture.sessionStore,
            settingsStore: fixture.settingsStore,
            webDAVSyncSettingsStore: fixture.webDAVSettingsStore,
            readerResumeRouteStore: fixture.resumeRouteStore,
            grdbRootDirectory: fixture.grdbRootDirectory,
            cachesRootDirectory: fixture.grdbRootDirectory,
            session: fixture.session
        )
        let appModel = YamiboAppModel(appContext: appContext)

        await appModel.bootstrapIfNeeded()

        let expectedContext = NovelLaunchContext(
            threadID: "730",
            threadTitle: "本地小说",
            source: .resume,
            initialView: 5,
            authorID: "42",
            initialResumePoint: remoteResumePoint
        )
        XCTAssertEqual(appModel.activeNovelContext, expectedContext)
        let restoredRoute = await fixture.resumeRouteStore.load()
        XCTAssertEqual(restoredRoute, .novel(expectedContext))
    }

    func testBootstrapIfNeededRestoresMangaContextFromDownloadedWebDAVProgress() async throws {
        let suiteName = "reader-resume-webdav-manga-\(UUID().uuidString)"
        let fixture = try makeAppModelWebDAVFixture(suiteName: suiteName)
        let host = "reader-restore-manga.example.com"
        let staleContext = MangaLaunchContext(
            originalThreadID: "731",
            chapterTID: "732",
            displayTitle: "本地漫画",
            source: .resume,
            initialPage: 0,
            directoryName: "本地目录"
        )
        let progressPayload = ReadingProgressWebDAVPayload(
            updatedAt: Date(timeIntervalSince1970: 2_000),
            records: [
                ReadingProgressRecord(
                    contentTarget: FavoriteContentTarget(mangaCleanBookName: "本地目录"),
                    threadID: "731",
                    kind: .manga,
                    updatedAt: Date(timeIntervalSince1970: 2_000),
                    lastReadAt: Date(timeIntervalSince1970: 2_000),
                    manga: MangaReadingProgressRecord(
                        chapterThreadID: "733",
                        chapterView: 1,
                        lastChapter: "第七页",
                        mangaPageIndex: 7
                    )
                )
            ]
        )
        let encodedProgressPayload = try JSONEncoder().encode(progressPayload)

        try await fixture.resumeRouteStore.save(.manga(staleContext))
        try await fixture.sessionStore.save(SessionState(cookie: "sid=local", isLoggedIn: true, accountUID: "100"))
        try await fixture.webDAVSettingsStore.save(WebDAVSyncSettings(
            baseURLString: "https://\(host)",
            username: "admin",
            password: "secret",
            isAutoSyncEnabled: true,
            lastRemoteUpdatedAt: Date(timeIntervalSince1970: 2_000),
            localUpdatedAt: Date(timeIntervalSince1970: 1_000)
        ))

        AppModelWebDAVTestURLProtocol.setHandler(for: host) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            guard request.url?.lastPathComponent == "yamibox-reading-progress-v1.json" else {
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                )
            }
            return (
                encodedProgressPayload,
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            )
        }
        defer { AppModelWebDAVTestURLProtocol.removeHandler(for: host) }

        let appContext = YamiboAppContext(
            sessionStore: fixture.sessionStore,
            settingsStore: fixture.settingsStore,
            webDAVSyncSettingsStore: fixture.webDAVSettingsStore,
            readerResumeRouteStore: fixture.resumeRouteStore,
            grdbRootDirectory: fixture.grdbRootDirectory,
            cachesRootDirectory: fixture.grdbRootDirectory,
            session: fixture.session
        )
        let appModel = YamiboAppModel(appContext: appContext)

        await appModel.bootstrapIfNeeded()

        let expectedContext = MangaLaunchContext(
            originalThreadID: "731",
            chapterTID: "733",
            displayTitle: "本地漫画",
            source: .resume,
            initialPage: 7,
            directoryName: "本地目录",
            offlineCacheFavoriteID: nil
        )
        XCTAssertEqual(appModel.activeMangaContext, expectedContext)
        let restoredRoute = await fixture.resumeRouteStore.load()
        XCTAssertEqual(restoredRoute, try persistedResumeRoute(.manga(expectedContext)))
    }

    func testBootstrapIfNeededKeepsLocalResumeRouteWhenWebDAVDoesNotDownloadProgress() async throws {
        let suiteName = "reader-resume-webdav-skip-\(UUID().uuidString)"
        let fixture = try makeAppModelWebDAVFixture(suiteName: suiteName)
        let localResumePoint = NovelResumePoint(
            view: 6,
            displayedTextOffset: 512,
            chapterOrdinal: 5,
            chapterTitle: "第六章",
            segmentProgress: 0.8,
            readingModeHint: .vertical
        )
        let localContext = NovelLaunchContext(
            threadID: "734",
            threadTitle: "本地小说",
            source: .resume,
            initialView: 6,
            initialResumePoint: localResumePoint
        )
        try await fixture.resumeRouteStore.save(.novel(localContext))

        let appContext = YamiboAppContext(
            sessionStore: fixture.sessionStore,
            settingsStore: fixture.settingsStore,
            webDAVSyncSettingsStore: fixture.webDAVSettingsStore,
            readerResumeRouteStore: fixture.resumeRouteStore,
            session: fixture.session
        )
        let appModel = YamiboAppModel(appContext: appContext)

        await appModel.bootstrapIfNeeded()

        XCTAssertEqual(appModel.activeNovelContext, localContext)
        let restoredRoute = await fixture.resumeRouteStore.load()
        XCTAssertEqual(restoredRoute, .novel(localContext))
    }

    func testPresentingReadersPersistsResumeRouteAndDismissClearsIt() async throws {
        let (appModel, store) = try await makeAppModelWithReaderResumeRouteStore()
        let readerContext = NovelLaunchContext(
            threadID: "723",
            threadTitle: "测试小说",
            source: .favorites,
            initialView: 2
        )

        appModel.presentNovelReader(readerContext)
        try await waitForReaderResumeRoute(store, equals: .novel(readerContext))

        appModel.dismissNovelReader()
        try await waitForReaderResumeRoute(store, equals: nil)

        let mangaContext = MangaLaunchContext(
            originalThreadID: "723",
            chapterTID: "723",
            displayTitle: "测试漫画",
            source: .favorites,
            initialPage: 2
        )
        appModel.presentMangaReader(mangaContext)
        try await waitForReaderResumeRoute(store, equals: .manga(mangaContext))

        appModel.dismissMangaReader()
        try await waitForReaderResumeRoute(store, equals: nil)
    }

    func testMangaResumeRouteUpdateRefreshesActiveContextWithoutChangingPresentationIdentity() async throws {
        let (appModel, store) = try await makeAppModelWithReaderResumeRouteStore()
        let originalContext = MangaLaunchContext(
            originalThreadID: "726",
            chapterTID: "727",
            displayTitle: "测试漫画",
            source: .favorites,
            initialPage: 12,
            directoryName: "Resolved Directory"
        )
        let resumeContext = MangaLaunchContext(
            originalThreadID: "726",
            chapterTID: "728",
            displayTitle: "测试漫画",
            source: .resume,
            initialPage: 0,
            directoryName: "Resolved Directory"
        )

        appModel.presentMangaReader(originalContext)
        try await waitForReaderResumeRoute(store, equals: .manga(originalContext))

        appModel.updateReaderResumeRoute(.manga(resumeContext))

        XCTAssertEqual(originalContext.id, resumeContext.id)
        XCTAssertEqual(appModel.activeMangaContext, resumeContext)
        try await waitForReaderResumeRoute(store, equals: .manga(resumeContext))
        XCTAssertEqual(appModel.activeMangaContext, resumeContext)
    }

    func testOpenForumURLSuspendsLatestMangaResumeContextAfterProgressUpdate() {
        let appModel = makeIsolatedAppModel(initialTab: .favorites)
        let originalContext = MangaLaunchContext(
            originalThreadID: "726",
            chapterTID: "727",
            displayTitle: "测试漫画",
            source: .favorites,
            initialPage: 12,
            directoryName: "Resolved Directory"
        )
        let resumeContext = MangaLaunchContext(
            originalThreadID: "726",
            chapterTID: "728",
            displayTitle: "测试漫画",
            source: .resume,
            initialPage: 0,
            directoryName: "Resolved Directory"
        )
        let forumURL = URL(string: "https://bbs.yamibo.com/thread-901-1-1.html")!

        appModel.presentMangaReader(originalContext)
        appModel.updateReaderResumeRoute(.manga(resumeContext))
        appModel.openForumURL(forumURL)

        XCTAssertNil(appModel.activeMangaContext)
        XCTAssertEqual(appModel.suspendedMangaContext, resumeContext)
        XCTAssertEqual(appModel.selectedTab, .forum)
        XCTAssertEqual(appModel.forumNavigationRequest?.url, forumURL)
    }

    func testMangaFavoriteLaunchDoesNotNeedProbeBlocker() {
        let manga = Favorite(
            title: "测试漫画",
            threadID: "704",
            type: .manga
        )
        let novel = Favorite(
            title: "测试小说",
            threadID: "705",
            type: .novel
        )
        let unknown = Favorite(
            title: "未知收藏",
            threadID: "706"
        )

        XCTAssertFalse(favoriteLaunchNeedsMangaProbeBlocker(manga))
        XCTAssertFalse(favoriteLaunchNeedsMangaProbeBlocker(novel))
        XCTAssertFalse(favoriteLaunchNeedsMangaProbeBlocker(unknown))
    }

    func testOpeningMangaFavoriteIDBlocksFavoriteInteractions() {
        XCTAssertFalse(shouldBlockFavoriteInteractions(openingMangaFavoriteID: nil))
        XCTAssertTrue(shouldBlockFavoriteInteractions(openingMangaFavoriteID: "favorite-1"))
    }

    func testSelectingFavoritesAfterMangaOpenedForumRestoresManga() {
        let appModel = makeIsolatedAppModel(initialTab: .favorites)
        let originalURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=704&mobile=2")!
        let context = MangaLaunchContext(
            originalThreadID: "704",
            chapterTID: "704",
            displayTitle: "测试漫画",
            source: .favorites,
            chapterView: 3,
            initialPage: 5
        )

        appModel.presentMangaReader(context)
        appModel.dismissMangaReader(openThreadInForum: originalURL)
        appModel.selectTab(.favorites)

        guard let restoredContext = appModel.activeMangaContext else {
            return XCTFail("Expected restored manga context")
        }
        XCTAssertEqual(restoredContext, context)
        XCTAssertNil(appModel.suspendedMangaContext)
        XCTAssertEqual(appModel.selectedTab, .favorites)
    }

    func testRestoredSuspendedMangaReannouncesContinuityForProgressUpdates() async throws {
        let (appModel, store) = try await makeAppModelWithReaderResumeRouteStore()
        let originalURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=704&mobile=2")!
        let staleContext = MangaLaunchContext(
            originalThreadID: "704",
            chapterTID: "704",
            displayTitle: "测试漫画",
            source: .favorites,
            chapterView: 1,
            initialPage: 2,
            directoryName: "测试目录"
        )
        let latestContext = MangaLaunchContext(
            originalThreadID: "704",
            chapterTID: "705",
            displayTitle: "测试漫画",
            source: .resume,
            chapterView: 2,
            initialPage: 4,
            directoryName: "测试目录"
        )
        let progressContext = MangaLaunchContext(
            originalThreadID: "704",
            chapterTID: "706",
            displayTitle: "测试漫画",
            source: .resume,
            chapterView: 3,
            initialPage: 1,
            directoryName: "测试目录"
        )

        appModel.presentMangaReader(staleContext)
        try await waitForReaderResumeRoute(store, equals: .manga(staleContext))
        appModel.dismissMangaReader(openThreadInForum: originalURL, suspendedMangaContext: latestContext)
        try await waitForReaderResumeRoute(store, equals: nil)

        appModel.selectTab(.favorites)

        XCTAssertEqual(appModel.activeMangaContext, latestContext)
        XCTAssertNil(appModel.suspendedMangaContext)
        try await waitForReaderResumeRoute(store, equals: .manga(latestContext))

        appModel.updateReaderResumeRoute(.manga(progressContext))

        XCTAssertEqual(appModel.activeMangaContext, progressContext)
        try await waitForReaderResumeRoute(store, equals: .manga(progressContext))
    }

    func testMangaCoverDismissCallbackDoesNotClearSuspendedMangaContext() {
        let appModel = makeIsolatedAppModel(initialTab: .favorites)
        let originalURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=704&mobile=2")!
        let context = MangaLaunchContext(
            originalThreadID: "704",
            chapterTID: "704",
            displayTitle: "测试漫画",
            source: .favorites,
            initialPage: 2
        )

        appModel.presentMangaReader(context)
        appModel.dismissMangaReader(openThreadInForum: originalURL)
        appModel.dismissMangaReader()
        appModel.selectTab(.favorites)

        guard let restoredContext = appModel.activeMangaContext else {
            return XCTFail("Expected restored manga context")
        }
        XCTAssertEqual(restoredContext, context)
    }

    func testDismissReaderToOriginalPostSelectsForumAndCreatesNavigationRequest() {
        let appModel = makeIsolatedAppModel(initialTab: .mine)
        let originalURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=703&mobile=2")!
        let context = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .forum
        )

        appModel.presentNovelReader(context)
        appModel.dismissNovelReader(openThreadInForum: originalURL)

        XCTAssertNil(appModel.activeNovelContext)
        XCTAssertEqual(appModel.suspendedNovelContext, context)
        XCTAssertEqual(appModel.selectedTab, .forum)
        XCTAssertEqual(appModel.forumNavigationRequest?.url, originalURL)
        // A reader's jump into its own thread is a discussion companion view
        // (browsing-history decision #14): same native-thread routing as
        // `.readerOrigin`, but exempt from history recording.
        XCTAssertEqual(appModel.forumNavigationRequest?.source, .readerDiscussion)
    }

    func testOpenForumURLExitsActiveReaderAndCreatesNavigationRequest() {
        let appModel = makeIsolatedAppModel(initialTab: .mine)
        let clipboardURL = URL(string: "https://bbs.yamibo.com/thread-900-1-1.html")!
        let context = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .forum
        )

        appModel.presentNovelReader(context)
        appModel.openForumURL(clipboardURL)

        XCTAssertNil(appModel.activeNovelContext)
        XCTAssertEqual(appModel.suspendedNovelContext, context)
        XCTAssertEqual(appModel.selectedTab, .forum)
        XCTAssertEqual(appModel.forumNavigationRequest?.url, clipboardURL)
        XCTAssertEqual(appModel.forumNavigationRequest?.source, .external)
    }

    func testConfirmClipboardForumLinkPromptExitsActiveReaderAndCreatesNavigationRequest() {
        let appModel = makeIsolatedAppModel(initialTab: .mine)
        let clipboardURL = URL(string: "https://bbs.yamibo.com/thread-902-1-1.html")!
        let context = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .forum
        )

        appModel.presentNovelReader(context)
        appModel.presentClipboardForumLinkPrompt(url: clipboardURL)
        let prompt = appModel.clipboardForumLinkPrompt!
        appModel.confirmClipboardForumLinkPrompt(prompt)

        XCTAssertNil(appModel.clipboardForumLinkPrompt)
        XCTAssertNil(appModel.activeNovelContext)
        XCTAssertEqual(appModel.suspendedNovelContext, context)
        XCTAssertEqual(appModel.selectedTab, .forum)
        XCTAssertEqual(appModel.forumNavigationRequest?.url, clipboardURL)
        XCTAssertEqual(appModel.forumNavigationRequest?.source, .external)
    }

    func testOpenForumURLExitsActiveMangaAndCreatesNavigationRequest() {
        let appModel = makeIsolatedAppModel(initialTab: .mine)
        let clipboardURL = URL(string: "https://bbs.yamibo.com/thread-901-1-1.html")!
        let context = MangaLaunchContext(
            originalThreadID: "704",
            chapterTID: "704",
            displayTitle: "测试漫画",
            source: .forum,
            initialPage: 2
        )

        appModel.presentMangaReader(context)
        appModel.openForumURL(clipboardURL)

        XCTAssertNil(appModel.activeMangaContext)
        XCTAssertEqual(appModel.suspendedMangaContext, context)
        XCTAssertEqual(appModel.selectedTab, .forum)
        XCTAssertEqual(appModel.forumNavigationRequest?.url, clipboardURL)
        XCTAssertEqual(appModel.forumNavigationRequest?.source, .external)
    }

    func testConfirmClipboardForumLinkPromptExitsActiveMangaAndCreatesNavigationRequest() {
        let appModel = makeIsolatedAppModel(initialTab: .mine)
        let clipboardURL = URL(string: "https://bbs.yamibo.com/thread-903-1-1.html")!
        let context = MangaLaunchContext(
            originalThreadID: "704",
            chapterTID: "704",
            displayTitle: "测试漫画",
            source: .forum,
            initialPage: 2
        )

        appModel.presentMangaReader(context)
        appModel.presentClipboardForumLinkPrompt(url: clipboardURL)
        let prompt = appModel.clipboardForumLinkPrompt!
        appModel.confirmClipboardForumLinkPrompt(prompt)

        XCTAssertNil(appModel.clipboardForumLinkPrompt)
        XCTAssertNil(appModel.activeMangaContext)
        XCTAssertEqual(appModel.suspendedMangaContext, context)
        XCTAssertEqual(appModel.selectedTab, .forum)
        XCTAssertEqual(appModel.forumNavigationRequest?.url, clipboardURL)
        XCTAssertEqual(appModel.forumNavigationRequest?.source, .external)
    }

    func testDismissReaderToOriginalPostSuspendsProvidedLatestContext() {
        let appModel = makeIsolatedAppModel(initialTab: .mine)
        let originalURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=703&mobile=2")!
        let staleContext = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .favorites,
            initialView: 2
        )
        let latestResumePoint = NovelResumePoint(
            view: 4,
            displayedTextOffset: 128,
            chapterOrdinal: 3,
            chapterTitle: "第四章",
            segmentProgress: 0.42,
            readingModeHint: .vertical
        )
        let latestContext = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .resume,
            initialView: 4,
            initialResumePoint: latestResumePoint
        )

        appModel.presentNovelReader(staleContext)
        appModel.dismissNovelReader(openThreadInForum: originalURL, suspendedNovelContext: latestContext)

        XCTAssertNil(appModel.activeNovelContext)
        XCTAssertEqual(appModel.suspendedNovelContext, latestContext)
        XCTAssertEqual(appModel.selectedTab, .forum)
        XCTAssertEqual(appModel.forumNavigationRequest?.url, originalURL)
        // See testDismissReaderToOriginalPostSelectsForumAndCreatesNavigationRequest.
        XCTAssertEqual(appModel.forumNavigationRequest?.source, .readerDiscussion)
    }

    func testSelectingFavoritesAfterReaderOpenedForumRestoresLatestSuspendedReader() {
        let appModel = makeIsolatedAppModel(initialTab: .favorites)
        let originalURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=703&mobile=2")!
        let staleContext = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .favorites,
            initialView: 2
        )
        let latestResumePoint = NovelResumePoint(
            view: 5,
            displayedTextOffset: 256,
            chapterOrdinal: 4,
            chapterTitle: "第五章",
            segmentProgress: 0.67,
            readingModeHint: .paged
        )
        let latestContext = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .resume,
            initialView: 5,
            initialResumePoint: latestResumePoint
        )

        appModel.presentNovelReader(staleContext)
        appModel.dismissNovelReader(openThreadInForum: originalURL, suspendedNovelContext: latestContext)
        appModel.selectTab(.favorites)

        XCTAssertEqual(appModel.activeNovelContext, latestContext)
        XCTAssertNil(appModel.suspendedNovelContext)
        XCTAssertEqual(appModel.selectedTab, .favorites)
    }

    func testRestoredSuspendedNovelReannouncesContinuityForProgressUpdates() async throws {
        let (appModel, store) = try await makeAppModelWithReaderResumeRouteStore()
        let originalURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=703&mobile=2")!
        let staleContext = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .favorites,
            initialView: 2
        )
        let latestResumePoint = NovelResumePoint(
            view: 5,
            displayedTextOffset: 256,
            chapterOrdinal: 4,
            chapterTitle: "第五章",
            segmentProgress: 0.67,
            readingModeHint: .paged
        )
        let latestContext = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .resume,
            initialView: 5,
            initialResumePoint: latestResumePoint
        )
        let progressResumePoint = NovelResumePoint(
            view: 6,
            displayedTextOffset: 384,
            chapterOrdinal: 5,
            chapterTitle: "第六章",
            segmentProgress: 0.75,
            readingModeHint: .vertical
        )
        let progressContext = NovelLaunchContext(
            threadID: "703",
            threadTitle: "测试小说",
            source: .resume,
            initialView: 6,
            initialResumePoint: progressResumePoint
        )

        appModel.presentNovelReader(staleContext)
        try await waitForReaderResumeRoute(store, equals: .novel(staleContext))
        appModel.dismissNovelReader(openThreadInForum: originalURL, suspendedNovelContext: latestContext)
        try await waitForReaderResumeRoute(store, equals: nil)

        appModel.selectTab(.favorites)

        XCTAssertEqual(appModel.activeNovelContext, latestContext)
        XCTAssertNil(appModel.suspendedNovelContext)
        try await waitForReaderResumeRoute(store, equals: .novel(latestContext))

        appModel.updateReaderResumeRoute(.novel(progressContext))

        XCTAssertEqual(appModel.activeNovelContext, progressContext)
        try await waitForReaderResumeRoute(store, equals: .novel(progressContext))
    }

}

private func makeAppModelWithReaderResumeRouteStore() async throws -> (YamiboAppModel, ReaderResumeRouteStore) {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-resume-app-model-tests")
    let store = try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "reader-route")
    let context = YamiboAppContext(
        sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
        settingsStore: try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings"),
        readerResumeRouteStore: store,
    )
    let appModel = await MainActor.run {
        YamiboAppModel(appContext: context)
    }
    return (appModel, store)
}

@MainActor
private func makeIsolatedAppModel(initialTab: AppTab = .forum) -> YamiboAppModel {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-presentation-route")
    let context = YamiboAppContext(
        sessionStore: try! SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
        settingsStore: try! SettingsStore(testSuiteName: defaultsSuiteName, key: "settings"),
        readerResumeRouteStore: try! ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "reader-route"),
    )
    return YamiboAppModel(appContext: context, initialTab: initialTab)
}

private func waitForReaderResumeRoute(
    _ store: ReaderResumeRouteStore,
    equals expected: ReaderResumeRoute?,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let persistedExpected = try persistedResumeRoute(expected)
    do {
        try await waitForCondition(timeout: .milliseconds(500), pollInterval: .milliseconds(25)) {
            await store.load() == persistedExpected
        }
    } catch is TestWaitTimeoutError {
        let loaded = await store.load()
        XCTAssertEqual(loaded, persistedExpected, file: file, line: line)
    }
}

private func persistedResumeRoute(_ route: ReaderResumeRoute?) throws -> ReaderResumeRoute? {
    guard let route else { return nil }
    let data = try JSONEncoder().encode(route)
    return try JSONDecoder().decode(ReaderResumeRoute.self, from: data)
}

private func persistedMangaContext(_ context: MangaLaunchContext) throws -> MangaLaunchContext {
    let data = try JSONEncoder().encode(context)
    return try JSONDecoder().decode(MangaLaunchContext.self, from: data)
}

private struct AppModelWebDAVFixture: Sendable {
    let sessionStore: SessionStore
    let settingsStore: SettingsStore
    let webDAVSettingsStore: WebDAVSyncSettingsStore
    let resumeRouteStore: ReaderResumeRouteStore
    let grdbRootDirectory: URL
    let session: URLSession
}

private func makeAppModelWebDAVFixture(suiteName: String) throws -> AppModelWebDAVFixture {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: suiteName)
    return AppModelWebDAVFixture(
        sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
        settingsStore: try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings"),
        webDAVSettingsStore: try WebDAVSyncSettingsStore(testSuiteName: defaultsSuiteName, key: "webdav"),
        resumeRouteStore: try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "reader-route"),
        grdbRootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("yamibo-webdav-route-\(UUID().uuidString)", isDirectory: true),
        session: makeAppModelWebDAVTestSession()
    )
}

private final class AppModelWebDAVTestURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Data, HTTPURLResponse)

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func setHandler(for host: String, _ handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
        }
    }

    static func removeHandler(for host: String) {
        _ = lock.withLock {
            handlers.removeValue(forKey: host)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let host = request.url?.host,
            let handler = Self.lock.withLock({ Self.handlers[host] })
        else {
            client?.urlProtocol(self, didFailWithError: AppModelWebDAVTestError.missingHandler)
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum AppModelWebDAVTestError: Error {
    case missingHandler
}

private func makeAppModelWebDAVTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AppModelWebDAVTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

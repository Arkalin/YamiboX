import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class MangaReaderViewModelSettingsProgressTests: XCTestCase {
    func testPrepareExposesPersistedMangaSettingsWithClampedBrightness() async throws {
        let fixture = try await makeFixture(
            appSettings: AppSettings(
                manga: MangaReaderSettings(
                    readingMode: .paged,
                    pagedTurnStyle: .pageCurl,
                    pageTurnDirection: .leftToRight,
                    pageScaleMode: .fitHeight,
                    pageEdgeFillStyle: .system,
                    brightness: 2.0,
                    zoomEnabled: false,
                    showsTwoPagesInLandscapeOnPad: true,
                    directorySortOrder: .descending
                )
            )
        )

        await fixture.model.prepare()

        XCTAssertEqual(fixture.model.presentation.settings.readingMode, .paged)
        XCTAssertEqual(fixture.model.presentation.settings.pagedTurnStyle, .pageCurl)
        XCTAssertEqual(fixture.model.presentation.settings.pageTurnDirection, .leftToRight)
        XCTAssertEqual(fixture.model.presentation.settings.pageScaleMode, .fitHeight)
        XCTAssertEqual(fixture.model.presentation.settings.pageEdgeFillStyle, .system)
        XCTAssertEqual(fixture.model.presentation.settings.brightness, 1.5)
        XCTAssertFalse(fixture.model.presentation.settings.zoomEnabled)
        XCTAssertTrue(fixture.model.presentation.settings.showsTwoPagesInLandscapeOnPad)
        XCTAssertEqual(fixture.model.presentation.settings.directorySortOrder, .descending)
    }

    func testPrepareExposesPersistedApplePencilPageTurnSettings() async throws {
        let applePencilSettings = ApplePencilPageTurnSettings(
            isEnabled: true,
            behavior: .doubleTapNextSqueezePrevious
        )
        let fixture = try await makeFixture(
            appSettings: AppSettings(system: SystemSettings(applePencilPageTurn: applePencilSettings))
        )

        await fixture.model.prepare()

        XCTAssertEqual(fixture.model.applePencilPageTurnSettings, applePencilSettings)
    }

    func testRetryInitialLoadReloadsAfterFailedInitialLoad() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-retry-initial-load")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        try await settingsStore.save(AppSettings())

        let context = MangaLaunchContext(
            originalThreadID: "700",
            chapterTID: "701",
            displayTitle: "测试漫画",
            source: .forum,
            initialPage: 0,
            directoryName: nil
        )
        let document = MangaReaderProjection(
            tid: "701",
            ownerPostID: "9001",
            chapterTitle: "第1话",
            imageURLs: [
                try XCTUnwrap(URL(string: "https://img.example.com/701-0.jpg")),
                try XCTUnwrap(URL(string: "https://img.example.com/701-1.jpg"))
            ]
        )
        let loader = RetryableMangaReaderProjectionLoader(outputs: [
            .failure(.offline),
            .success(document)
        ])
        let repository = StubMangaDirectoryRepository(
            seed: MangaDirectorySeed(
                currentChapter: MangaChapter(
                    tid: "701",
                    rawTitle: "第1话",
                    chapterNumber: 1
                ),
                cleanBookName: "Resolved Directory",
                firstPostID: "9001"
            )
        )
        let store = StubMangaDirectoryStore()
        let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
        #if os(iOS)
        let dependencies = MangaReaderViewModelDependencies(
            settingsStore: settingsStore,
            makeProjectionLoader: { loader },
            makeDirectoryRepository: { repository },
            makeDirectoryStore: { store },
            progressSync: ProgressSyncModule(
                adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: readingProgressStore
                ),
                debounceNanoseconds: 0
            )
        )
        #else
        let dependencies = MangaReaderViewModelDependencies(
            settingsStore: settingsStore,
            makeProjectionLoader: { loader },
            makeDirectoryRepository: { repository },
            makeDirectoryStore: { store },
            progressSync: ProgressSyncModule(
                adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: readingProgressStore
                ),
                debounceNanoseconds: 0
            )
        )
        #endif
        let model = MangaReaderViewModel(context: context, viewModelDependencies: dependencies)

        await model.prepare()

        guard case .failed = model.presentation.state else {
            XCTFail("Expected initial failure")
            return
        }
        let initialLoadCount = await loader.currentLoadCount()
        XCTAssertEqual(initialLoadCount, 1)

        await model.retryInitialLoad()

        guard case let .loaded(loaded) = model.presentation.state else {
            XCTFail("Expected retry to load manga")
            return
        }
        XCTAssertEqual(loaded.pages.count, 2)
        let retryLoadCount = await loader.currentLoadCount()
        XCTAssertEqual(retryLoadCount, 2)
    }

    func testApplySettingsUpdatesPresentationAndPersistsOnlyMangaSettings() async throws {
        let initialNovelReaderSettings = NovelReaderAppearanceSettings(fontScale: 1.2, readingMode: .vertical)
        let initialApplePencilSettings = ApplePencilPageTurnSettings(
            isEnabled: true,
            behavior: .doubleTapNextSqueezePrevious
        )
        let fixture = try await makeFixture(
            appSettings: AppSettings(
                novelReader: initialNovelReaderSettings,
                manga: MangaReaderSettings(brightness: 0.8),
                system: SystemSettings(
                    usesDataSaverMode: true,
                    applePencilPageTurn: initialApplePencilSettings
                )
            )
        )

        let updatedMangaSettings = MangaReaderSettings(
            readingMode: .vertical,
            pagedTurnStyle: .quickFade,
            pageTurnDirection: .leftToRight,
            pageScaleMode: .fitHeight,
            pageEdgeFillStyle: .white,
            brightness: -1,
            zoomEnabled: false,
            showsTwoPagesInLandscapeOnPad: true,
            directorySortOrder: .descending
        )
        fixture.model.applySettings(updatedMangaSettings)

        XCTAssertEqual(fixture.model.presentation.settings.brightness, 0.25)
        XCTAssertEqual(fixture.model.presentation.settings.readingMode, .vertical)
        XCTAssertEqual(fixture.model.presentation.settings.pageEdgeFillStyle, .white)
        XCTAssertFalse(fixture.model.presentation.settings.zoomEnabled)

        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return loaded.manga.brightness == 0.25 &&
                loaded.manga.readingMode == .vertical &&
                loaded.manga.pagedTurnStyle == .quickFade &&
                loaded.manga.pageTurnDirection == .leftToRight &&
                loaded.manga.pageScaleMode == .fitHeight &&
                loaded.manga.pageEdgeFillStyle == .white &&
                loaded.manga.zoomEnabled == false
        }

        let loaded = await fixture.settingsStore.load()
        XCTAssertEqual(loaded.novelReader, initialNovelReaderSettings)
        XCTAssertEqual(loaded.system.applePencilPageTurn, initialApplePencilSettings)
        XCTAssertTrue(loaded.system.usesDataSaverMode)
    }

    func testInitialSamePageViewportReportQueuesMangaProgressAndSavesResumeRoute() async throws {
        let progressAdapter = RecordingMangaProgressAdapter()
        let fixture = try await makeFixture(
            initialPage: 1,
            progressSync: ProgressSyncModule(adapter: progressAdapter, debounceNanoseconds: 0)
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 1)

        try await waitFor {
            await progressAdapter.savedPositions.count == 1
        }

        let savedPositions = await progressAdapter.savedPositions
        let savedPosition = try XCTUnwrap(savedPositions.first)
        XCTAssertEqual(savedPosition.threadID, "700")
        XCTAssertEqual(savedPosition.chapterThreadID, "701")
        XCTAssertEqual(savedPosition.chapterView, 1)
        XCTAssertEqual(savedPosition.chapterTitle, "第701话")
        XCTAssertEqual(savedPosition.pageIndex, 1)
        XCTAssertEqual(savedPosition.pageCount, 3)
        XCTAssertEqual(savedPosition.mangaID, "chapter:701")

        guard case let .manga(savedContext)? = await fixture.resumeRouteStore.load() else {
            XCTFail("Expected saved manga resume route")
            return
        }
        XCTAssertEqual(savedContext.source, .resume)
        XCTAssertEqual(savedContext.chapterTID, "701")
        XCTAssertEqual(savedContext.initialPage, 1)
        XCTAssertEqual(savedContext.directoryName, "Resolved Directory")
    }

    func testRepeatedSamePageViewportReportsAreDedupedByProgressSync() async throws {
        let progressAdapter = RecordingMangaProgressAdapter()
        let fixture = try await makeFixture(
            initialPage: 1,
            progressSync: ProgressSyncModule(adapter: progressAdapter, debounceNanoseconds: 0)
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 1)
        try await waitFor {
            await progressAdapter.savedPositions.count == 1
        }

        fixture.model.updateCurrentPage(globalIndex: 1)
        try await Task.sleep(nanoseconds: 80_000_000)

        let savedCount = await progressAdapter.savedPositions.count
        XCTAssertEqual(savedCount, 1)
    }

    func testViewportPageReportClearsStaleViewportPlacement() async throws {
        let fixture = try await makeFixture(initialPage: 1)

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 2)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.currentPageIndex, 2)
        XCTAssertEqual(loaded.currentPage?.localIndex, 2)
        XCTAssertNil(loaded.viewportPlacement)
    }

    func testNavigationHistoryRestoresPreviousMangaReadingPositionAfterNonlinearPageJump() async throws {
        let fixture = try await makeFixture(initialPage: 0)

        await fixture.model.prepare()
        XCTAssertFalse(fixture.model.canNavigateBack)
        XCTAssertFalse(fixture.model.canNavigateForward)

        await fixture.model.jumpToPage(localIndex: 2)
        XCTAssertTrue(fixture.model.canNavigateBack)
        XCTAssertFalse(fixture.model.canNavigateForward)

        await fixture.model.navigateBack()

        guard case let .loaded(backLoaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation after navigating back")
            return
        }
        XCTAssertEqual(backLoaded.currentPage?.localIndex, 0)
        XCTAssertFalse(fixture.model.canNavigateBack)
        XCTAssertTrue(fixture.model.canNavigateForward)

        await fixture.model.navigateForward()

        guard case let .loaded(forwardLoaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation after navigating forward")
            return
        }
        XCTAssertEqual(forwardLoaded.currentPage?.localIndex, 2)
        XCTAssertTrue(fixture.model.canNavigateBack)
        XCTAssertFalse(fixture.model.canNavigateForward)
    }

    func testNavigationHistoryClearsAfterFiveLinearCurrentPageUpdates() async throws {
        let fixture = try await makeFixture(initialPage: 0, imageCount: 7)

        await fixture.model.prepare()
        await fixture.model.jumpToPage(localIndex: 1)
        XCTAssertTrue(fixture.model.canNavigateBack)
        XCTAssertFalse(fixture.model.canNavigateForward)

        for globalIndex in 2...5 {
            fixture.model.updateCurrentPage(globalIndex: globalIndex)
        }
        XCTAssertTrue(fixture.model.canNavigateBack)

        fixture.model.updateCurrentPage(globalIndex: 6)
        XCTAssertFalse(fixture.model.canNavigateBack)
        XCTAssertFalse(fixture.model.canNavigateForward)
    }

    func testNavigationHistoryClearsAfterFiveLinearPagedRelativeTurns() async throws {
        let fixture = try await makeFixture(
            initialPage: 0,
            imageCount: 7,
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .paged))
        )

        await fixture.model.prepare()
        await fixture.model.jumpToPage(localIndex: 1)
        XCTAssertTrue(fixture.model.canNavigateBack)

        for _ in 0..<4 {
            await fixture.model.jumpRelativePage(1, usesTwoPageSpread: false)
        }
        XCTAssertTrue(fixture.model.canNavigateBack)

        await fixture.model.jumpRelativePage(1, usesTwoPageSpread: false)
        XCTAssertFalse(fixture.model.canNavigateBack)
        XCTAssertFalse(fixture.model.canNavigateForward)
    }

    func testSaveProgressFlushesLatestPageIntoReadingProgressAndResumeRoute() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-save-progress-existing")
        let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
        let fixture = try await makeFixture(
            progressSync: ProgressSyncModule(
                adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: readingProgressStore
                ),
                debounceNanoseconds: 100_000_000
            )
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 2)
        let route = await fixture.model.saveProgress()

        let progress = await readingProgressStore.load(threadID: "700")
        XCTAssertEqual(progress?.manga?.chapterThreadID, "701")
        XCTAssertEqual(progress?.manga?.chapterView, 1)
        XCTAssertEqual(progress?.manga?.mangaPageIndex, 2)

        let savedContext = route
        XCTAssertEqual(savedContext.source, .resume)
        XCTAssertEqual(savedContext.initialPage, 2)
        XCTAssertEqual(savedContext.directoryName, "Resolved Directory")
        let storedResumeRoute = await fixture.resumeRouteStore.load()
        XCTAssertEqual(storedResumeRoute, try persistedResumeRoute(.manga(route)))
    }

    func testUpdateCurrentPageInPreviewModeDoesNotQueueReadingProgress() async throws {
        let progressAdapter = RecordingMangaProgressAdapter()
        let fixture = try await makeFixture(
            progressSync: ProgressSyncModule(adapter: progressAdapter, debounceNanoseconds: 0),
            isPreview: true
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 2)
        try await Task.sleep(nanoseconds: 80_000_000)

        let savedPositions = await progressAdapter.savedPositions
        XCTAssertTrue(savedPositions.isEmpty)
        let storedResumeRoute = await fixture.resumeRouteStore.load()
        XCTAssertNil(storedResumeRoute)
    }

    func testSaveProgressInPreviewModeDoesNotPersistReadingProgressOrResumeRoute() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-save-progress-preview")
        let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
        let fixture = try await makeFixture(
            progressSync: ProgressSyncModule(
                adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: readingProgressStore
                ),
                debounceNanoseconds: 0
            ),
            isPreview: true
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 2)
        let route = await fixture.model.saveProgress()

        XCTAssertTrue(route.isPreview)
        XCTAssertEqual(route.initialPage, 2)
        let progress = await readingProgressStore.load(threadID: "700")
        XCTAssertNil(progress?.manga)
        let storedResumeRoute = await fixture.resumeRouteStore.load()
        XCTAssertNil(storedResumeRoute)
    }

    func testSaveProgressDoesNotCreateMissingFavorite() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-save-progress-missing")
        let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
        let fixture = try await makeFixture(
            progressSync: ProgressSyncModule(
                adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: readingProgressStore
                ),
                debounceNanoseconds: 0
            )
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 2)
        _ = await fixture.model.saveProgress()

        let favorites = try await fixture.localFavoriteLibraryStore.load().items
        XCTAssertTrue(favorites.isEmpty)
        let progress = await readingProgressStore.load(threadID: "700")
        XCTAssertEqual(progress?.manga?.chapterThreadID, "701")
        XCTAssertEqual(progress?.manga?.chapterView, 1)
        XCTAssertEqual(progress?.manga?.mangaPageIndex, 2)
    }

    func testCurrentChapterCommentTargetUsesCurrentMangaPageProjection() async throws {
        let fixture = try await makeFixture()

        await fixture.model.prepare()

        let target = try XCTUnwrap(fixture.model.currentChapterCommentTarget)
        XCTAssertEqual(target.threadID, "701")
        XCTAssertEqual(target.view, 1)
        XCTAssertEqual(target.ownerPostID, "post-701")
        XCTAssertEqual(target.title, "第701话")
    }

    func testNilMangaChapterCommentTargetShowsUnsupportedCommentsState() async throws {
        let fixture = try await makeFixture()

        await fixture.model.loadChapterComments(for: nil)

        XCTAssertEqual(fixture.model.chapterCommentsState, .unsupported)
    }

    func testCurrentForumTargetURLUsesCurrentChapterNotLaunchThread() async throws {
        let fixture = try await makeFixture()

        await fixture.model.prepare()

        // Launch context's originalThreadID is "700"; the chapter on screen is
        // thread "701" — 打开原帖 must anchor on the latter's owner post.
        XCTAssertEqual(
            fixture.model.currentForumTargetURL.absoluteString,
            "https://bbs.yamibo.com/forum.php?goto=findpost&mobile=2&mod=redirect&pid=post-701&ptid=701"
        )
    }

    func testCurrentForumTargetURLFollowsChapterAcrossBoundaryJump() async throws {
        let current = try makeFixtureDocument(tid: "701", pageCount: 4)
        let next = try makeFixtureDocument(tid: "702", pageCount: 3)
        let fixture = try await makeFixture(
            initialPage: 3,
            document: current,
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .paged)),
            documents: [current, next],
            directory: makeFixtureDirectory(tids: ["701", "702"])
        )

        await fixture.model.prepare()
        await fixture.model.jumpRelativePage(1, usesTwoPageSpread: false)

        XCTAssertEqual(
            fixture.model.currentForumTargetURL.absoluteString,
            "https://bbs.yamibo.com/forum.php?goto=findpost&mobile=2&mod=redirect&pid=post-702&ptid=702"
        )
    }

    func testCurrentForumTargetURLFallsBackToLaunchThreadBeforeContentLoads() async throws {
        let fixture = try await makeFixture()

        XCTAssertEqual(
            fixture.model.currentForumTargetURL.absoluteString,
            "https://bbs.yamibo.com/forum.php?mobile=2&mod=viewthread&page=1&tid=700"
        )
    }

    func testJumpToPagePublishesViewportPlacementForSharedScrubberCommit() async throws {
        let fixture = try await makeFixture()

        await fixture.model.prepare()
        await fixture.model.jumpToPage(localIndex: 2)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.currentPageIndex, 2)
        XCTAssertEqual(loaded.currentPage?.globalIndex, 2)
        XCTAssertEqual(loaded.currentPage?.localIndex, 2)
        XCTAssertEqual(loaded.currentPage?.chapterPageCount, 3)
        XCTAssertEqual(loaded.viewportPlacement?.targetPageIndex, 2)
    }

    func testJumpRelativePagePublishesViewportPlacementForSinglePagePagedMode() async throws {
        let fixture = try await makeFixture(
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .paged))
        )

        await fixture.model.prepare()
        await fixture.model.jumpRelativePage(1, usesTwoPageSpread: false)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.currentPageIndex, 1)
        XCTAssertEqual(loaded.currentPage?.globalIndex, 1)
        XCTAssertEqual(loaded.currentPage?.localIndex, 1)
        let placement = try XCTUnwrap(loaded.viewportPlacement)
        XCTAssertEqual(placement.targetPageIndex, 1)
        XCTAssertTrue(placement.animated)
    }

    func testJumpRelativePageAdvancesBySpreadInTwoPagePagedMode() async throws {
        let fixture = try await makeFixture(
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .paged))
        )

        await fixture.model.prepare()
        await fixture.model.jumpRelativePage(1, usesTwoPageSpread: true)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.currentPageIndex, 2)
        XCTAssertEqual(loaded.currentPage?.globalIndex, 2)
        XCTAssertEqual(loaded.currentPage?.localIndex, 2)
        let placement = try XCTUnwrap(loaded.viewportPlacement)
        XCTAssertEqual(placement.targetPageIndex, 2)
        XCTAssertTrue(placement.animated)
    }

    func testJumpRelativePageAtBoundaryLeavesPresentationUnchanged() async throws {
        let fixture = try await makeFixture(
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .paged))
        )

        await fixture.model.prepare()
        let initialPresentation = fixture.model.presentation
        await fixture.model.jumpRelativePage(-1, usesTwoPageSpread: false)

        XCTAssertEqual(fixture.model.presentation, initialPresentation)
    }

    func testJumpRelativePageAtPreviousBoundaryLoadsPreviousChapterLastPage() async throws {
        let progressAdapter = RecordingMangaProgressAdapter()
        let previous = try makeFixtureDocument(tid: "700", pageCount: 4)
        let current = try makeFixtureDocument(tid: "701", pageCount: 4)
        let fixture = try await makeFixture(
            document: current,
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .paged)),
            progressSync: ProgressSyncModule(adapter: progressAdapter, debounceNanoseconds: 0),
            documents: [previous, current],
            directory: makeFixtureDirectory(tids: ["700", "701"])
        )

        await fixture.model.prepare()
        await fixture.model.jumpRelativePage(-1, usesTwoPageSpread: false)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.pages.map(\.id), [
            "700#0", "700#1", "700#2", "700#3",
            "701#0", "701#1", "701#2", "701#3"
        ])
        XCTAssertEqual(loaded.currentPage?.id, "700#3")
        XCTAssertEqual(loaded.readingPosition, MangaReadingPosition(tid: "700", localIndex: 3))
        XCTAssertEqual(loaded.viewportPlacement?.targetPageIndex, 3)
        XCTAssertTrue(loaded.viewportPlacement?.animated == true)

        try await waitFor {
            await progressAdapter.savedPositions.contains { position in
                position.chapterThreadID == previous.tid &&
                    position.chapterView == previous.sourceIdentity.view &&
                    position.pageIndex == 3
            }
        }
    }

    func testJumpRelativePageAtNextBoundaryLoadsNextChapterFirstPage() async throws {
        let current = try makeFixtureDocument(tid: "701", pageCount: 4)
        let next = try makeFixtureDocument(tid: "702", pageCount: 3)
        let fixture = try await makeFixture(
            initialPage: 3,
            document: current,
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .paged)),
            documents: [current, next],
            directory: makeFixtureDirectory(tids: ["701", "702"])
        )

        await fixture.model.prepare()
        await fixture.model.jumpRelativePage(1, usesTwoPageSpread: false)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.pages.map(\.id), [
            "701#0", "701#1", "701#2", "701#3",
            "702#0", "702#1", "702#2"
        ])
        XCTAssertEqual(loaded.currentPage?.id, "702#0")
        XCTAssertEqual(loaded.readingPosition, MangaReadingPosition(tid: "702", localIndex: 0))
        XCTAssertEqual(loaded.viewportPlacement?.targetPageIndex, 4)
        XCTAssertTrue(loaded.viewportPlacement?.animated == true)
    }

    func testJumpRelativePageAtTwoPageBoundaryLoadsAdjacentChapterByChapterSemantics() async throws {
        let previous = try makeFixtureDocument(tid: "700", pageCount: 3)
        let current = try makeFixtureDocument(tid: "701", pageCount: 4)
        let fixture = try await makeFixture(
            document: current,
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .paged)),
            documents: [previous, current],
            directory: makeFixtureDirectory(tids: ["700", "701"])
        )

        await fixture.model.prepare()
        await fixture.model.jumpRelativePage(-1, usesTwoPageSpread: true)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.currentPage?.id, "700#2")
        XCTAssertEqual(loaded.readingPosition, MangaReadingPosition(tid: "700", localIndex: 2))
        XCTAssertEqual(loaded.viewportPlacement?.targetPageIndex, 2)
    }

    func testJumpRelativePageBoundaryFailureLeavesPresentationAndProgressUnchanged() async throws {
        let progressAdapter = RecordingMangaProgressAdapter()
        let current = try makeFixtureDocument(tid: "701", pageCount: 4)
        let missingPrevious = makeFixtureChapter(tid: "700")
        let directory = MangaDirectory(
            cleanBookName: "Resolved Directory",
            strategy: .links,
            sourceKey: "Resolved Directory",
            chapters: [missingPrevious, makeFixtureChapter(tid: "701")]
        )
        let fixture = try await makeFixture(
            document: current,
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .paged)),
            progressSync: ProgressSyncModule(adapter: progressAdapter, debounceNanoseconds: 0),
            documents: [current],
            directory: directory
        )

        await fixture.model.prepare()
        let before = fixture.model.presentation
        await fixture.model.jumpRelativePage(-1, usesTwoPageSpread: false)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(fixture.model.presentation, before)
        let savedPositions = await progressAdapter.savedPositions
        let storedResumeRoute = await fixture.resumeRouteStore.load()
        XCTAssertTrue(savedPositions.isEmpty)
        XCTAssertNil(storedResumeRoute)
    }

    func testJumpRelativePageIgnoresVerticalReadingMode() async throws {
        let fixture = try await makeFixture(
            appSettings: AppSettings(manga: MangaReaderSettings(readingMode: .vertical))
        )

        await fixture.model.prepare()
        let initialPresentation = fixture.model.presentation
        await fixture.model.jumpRelativePage(1, usesTwoPageSpread: false)

        XCTAssertEqual(fixture.model.presentation, initialPresentation)
    }

    func testSaveProgressInLoadingStateDoesNotOverwriteExistingResumeRoute() async throws {
        let progressAdapter = RecordingMangaProgressAdapter()
        let fixture = try await makeFixture(
            progressSync: ProgressSyncModule(adapter: progressAdapter, debounceNanoseconds: 0)
        )
        let existingRoute = ReaderResumeRoute.manga(
            MangaLaunchContext(
                originalThreadID: fixture.context.originalThreadID,
                chapterTID: fixture.context.chapterTID,
                displayTitle: "Existing",
                source: .resume,
                initialPage: 6,
                directoryName: "Existing Directory"
            )
        )
        try await fixture.resumeRouteStore.save(existingRoute)

        let route = await fixture.model.saveProgress()

        XCTAssertEqual(route, fixture.context)
        let storedResumeRoute = await fixture.resumeRouteStore.load()
        let savedPositions = await progressAdapter.savedPositions
        XCTAssertEqual(storedResumeRoute, try persistedResumeRoute(existingRoute))
        XCTAssertTrue(savedPositions.isEmpty)
    }

    func testDismissMangaOpeningForumPreservesSuppliedLatestSuspendedRoute() throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-dismiss-forum")
        let appModel = YamiboAppModel(
            appContext: YamiboAppContext(
                sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
                settingsStore: try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings"),
                readerResumeRouteStore: try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "resume"),
            )
        )
        let originalURL = try XCTUnwrap(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=700&mobile=2"))
        let originalContext = MangaLaunchContext(
            originalThreadID: "700",
            chapterTID: "701",
            displayTitle: "测试漫画",
            source: .forum,
            initialPage: 0,
            directoryName: "Old Directory"
        )
        let latestContext = MangaLaunchContext(
            originalThreadID: "700",
            chapterTID: "702",
            displayTitle: "测试漫画",
            source: .resume,
            initialPage: 4,
            directoryName: "Resolved Directory"
        )

        appModel.presentMangaReader(originalContext)
        appModel.dismissMangaReader(openThreadInForum: originalURL, suspendedMangaContext: latestContext)

        XCTAssertNil(appModel.activeMangaContext)
        XCTAssertEqual(appModel.suspendedMangaContext, latestContext)
        XCTAssertEqual(appModel.selectedTab, .forum)
    }

}

private func persistedResumeRoute(_ route: ReaderResumeRoute?) throws -> ReaderResumeRoute? {
    guard let route else { return nil }
    let data = try JSONEncoder().encode(route)
    return try JSONDecoder().decode(ReaderResumeRoute.self, from: data)
}

private struct MangaReaderViewModelSettingsProgressFixture {
    let model: MangaReaderViewModel
    let context: MangaLaunchContext
    let settingsStore: SettingsStore
    let resumeRouteStore: ReaderResumeRouteStore
    let localFavoriteLibraryStore: FavoriteLibraryStore
}

@MainActor
private func makeFixture(
    initialPage: Int = 0,
    imageCount: Int = 3,
    document suppliedDocument: MangaReaderProjection? = nil,
    appSettings: AppSettings = AppSettings(),
    progressSync: ProgressSyncModule? = nil,
    documents suppliedDocuments: [MangaReaderProjection]? = nil,
    directory suppliedDirectory: MangaDirectory? = nil,
    isPreview: Bool = false
) async throws -> MangaReaderViewModelSettingsProgressFixture {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-settings-progress-fixture")
    let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
    let resumeRouteStore = try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "resume")
    try await settingsStore.save(appSettings)

    let context = MangaLaunchContext(
        originalThreadID: "700",
        chapterTID: suppliedDocument?.tid ?? "701",
        displayTitle: "测试漫画",
        source: .forum,
        initialPage: initialPage,
        directoryName: nil,
        isPreview: isPreview
    )
    let document = try suppliedDocument ?? makeFixtureDocument(tid: "701", pageCount: max(imageCount, 1))
    let repository = StubMangaDirectoryRepository(
        seed: MangaDirectorySeed(
            currentChapter: MangaChapter(
                tid: document.tid,
                rawTitle: document.chapterTitle,
                chapterNumber: MangaTitleCleaner.extractChapterNumber(document.chapterTitle)
            ),
            cleanBookName: "Resolved Directory",
            firstPostID: document.ownerPostID
        )
    )
    let store = StubMangaDirectoryStore(directories: suppliedDirectory.map { [$0] } ?? [])
    let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
    let localFavoriteLibraryStore = FavoriteLibraryStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: defaultsSuiteName),
        key: "local-favorites"
    )
    let resolvedProgressSync = progressSync ?? ProgressSyncModule(
        adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: readingProgressStore
        ),
        debounceNanoseconds: 0
    )
    #if os(iOS)
    let dependencies = MangaReaderViewModelDependencies(
        settingsStore: settingsStore,
        makeProjectionLoader: { StubMangaReaderProjectionLoader(documents: suppliedDocuments ?? [document]) },
        makeDirectoryRepository: { repository },
        makeDirectoryStore: { store },
        progressSync: resolvedProgressSync
    )
    #else
    let dependencies = MangaReaderViewModelDependencies(
        settingsStore: settingsStore,
        makeProjectionLoader: { StubMangaReaderProjectionLoader(documents: suppliedDocuments ?? [document]) },
        makeDirectoryRepository: { repository },
        makeDirectoryStore: { store },
        progressSync: resolvedProgressSync
    )
    #endif
    let model = MangaReaderViewModel(
        context: context,
        viewModelDependencies: dependencies,
        onReaderResumeRouteChange: { route in
            try? await resumeRouteStore.saveReadingPosition(route)
        }
    )

    return MangaReaderViewModelSettingsProgressFixture(
        model: model,
        context: context,
        settingsStore: settingsStore,
        resumeRouteStore: resumeRouteStore,
        localFavoriteLibraryStore: localFavoriteLibraryStore
    )
}

private actor StubMangaReaderProjectionLoader: MangaReaderProjectionLoading {
    let documents: [String: MangaReaderProjection]

    init(documents: [MangaReaderProjection]) {
        self.documents = Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) })
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        guard let document = documents[request.threadID] else {
            throw YamiboError.unreadableBody
        }
        return document
    }
}

private actor RetryableMangaReaderProjectionLoader: MangaReaderProjectionLoading {
    enum Output: Sendable {
        case success(MangaReaderProjection)
        case failure(YamiboError)
    }

    private var outputs: [Output]
    private var loadCountValue = 0

    func currentLoadCount() -> Int {
        loadCountValue
    }

    init(outputs: [Output]) {
        self.outputs = outputs
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        loadCountValue += 1
        guard !outputs.isEmpty else {
            throw YamiboError.unreadableBody
        }

        switch outputs.removeFirst() {
        case let .success(document):
            return document
        case let .failure(error):
            throw error
        }
    }
}

private actor StubMangaDirectoryRepository: MangaDirectoryRepository {
    let seed: MangaDirectorySeed

    init(seed: MangaDirectorySeed) {
        self.seed = seed
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        seed
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        []
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        []
    }
}

private actor StubMangaDirectoryStore: MangaDirectoryPersisting {
    private var directories: [String: MangaDirectory]

    init(directories: [MangaDirectory] = []) {
        self.directories = Dictionary(uniqueKeysWithValues: directories.map { ($0.cleanBookName, $0) })
    }

    func directory(named name: String) async throws -> MangaDirectory? {
        directories[name]
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        directories.values.first { directory in
            directory.chapters.contains { $0.tid == tid }
        }
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {
        directories[directory.cleanBookName] = directory
    }

    func deleteDirectory(named name: String) async throws {
        directories.removeValue(forKey: name)
    }
}

private func makeFixtureDocument(tid: String, pageCount: Int) throws -> MangaReaderProjection {
    MangaReaderProjection(
        tid: tid,
        ownerPostID: "post-\(tid)",
        chapterTitle: "第\(tid)话",
        imageURLs: try (0..<max(pageCount, 0)).map { index in
            try XCTUnwrap(URL(string: "https://img.example.com/\(tid)-\(index).jpg"))
        }
    )
}

private func makeFixtureDirectory(tids: [String]) -> MangaDirectory {
    MangaDirectory(
        cleanBookName: "Resolved Directory",
        strategy: .links,
        sourceKey: "Resolved Directory",
        chapters: tids.map(makeFixtureChapter)
    )
}

private func makeFixtureChapter(tid: String) -> MangaChapter {
    MangaChapter(
        tid: tid,
        rawTitle: "第\(tid)话",
        chapterNumber: Double(tid) ?? 0
    )
}

#if os(iOS)
#endif

private actor RecordingMangaProgressAdapter: ProgressSyncAdapter {
    private var saved: [MangaProgressReadingPosition] = []

    var savedPositions: [MangaProgressReadingPosition] {
        saved
    }

    func saveNovelReadingPosition(_ position: NovelReadingPosition) async throws {}

    func saveMangaReadingPosition(_ position: MangaProgressReadingPosition) async throws {
        saved.append(position)
    }

    func saveThreadReadingPosition(_ position: ThreadReadingPosition) async throws {}
}

@MainActor
private func waitFor(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    pollIntervalNanoseconds: UInt64 = 20_000_000,
    predicate: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    do {
        try await waitForCondition(
            timeout: .nanoseconds(Int64(timeoutNanoseconds)),
            pollInterval: .nanoseconds(Int64(pollIntervalNanoseconds))
        ) { await predicate() }
    } catch is TestWaitTimeoutError {
        XCTFail("Timed out waiting for condition")
    }
}

import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
@Suite("Reader mode switching")
final class ReaderSessionTests {
    private let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderSessionTests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    @Test(arguments: [ReaderReadingMode.paged, .vertical])
    func novelRoundTripKeepsPresentationAndResumePoint(mode: ReaderReadingMode) async throws {
        let app = try makeApp()
        let initial = NovelLaunchContext(threadID: "701", threadTitle: "Novel", source: .favorites, forumID: "49")
        app.presentNovelReader(initial)
        let session = try #require(app.presentedReaderSession)
        let sessionID = session.id
        let staleContentID = session.contentID
        var latest = initial
        latest.initialView = 4
        latest.initialResumePoint = NovelResumePoint(
            view: 4, displayedTextOffset: 162, chapterOrdinal: 3,
            segmentProgress: 0.42, readingModeHint: mode
        )
        session.updateResumeRoute(.novel(latest), contentID: staleContentID)

        for _ in 0..<3 {
            #expect(await session.openOriginalPost(url: threadURL("701", page: 4), resumeRoute: .novel(latest)))
            guard case let .thread(context) = session.content else {
                Issue.record("Expected original thread")
                return
            }
            #expect(context.initialPage == 4)
            #expect(context.isDiscussionView)
            #expect(app.presentedReaderSession?.id == sessionID)
            #expect(app.activeNovelContext == nil)
            #expect(app.hasActiveReaderPresentation)
            #expect(app.forumNavigationRequest == nil)
            #expect(app.selectedTab == .favorites)

            session.updateResumeRoute(.novel(initial), contentID: staleContentID)
            #expect(app.activeNovelContext == nil)
            await session.openReader(.novel, from: session.threadModel(for: context, dependencies: app.appContext.forumDependencies))
            #expect(app.activeNovelContext == latest)
            #expect(app.presentedReaderSession?.id == sessionID)
        }
        session.close()
        #expect(app.presentedReaderSession == nil)
        #expect(app.activeNovelContext == nil)
        #expect(app.selectedTab == .favorites)
    }

    @Test func mangaRoundTripUsesCurrentChapterAndPreservesWorkContext() async throws {
        let app = try makeApp()
        let initial = MangaLaunchContext(
            originalThreadID: "710", chapterTID: "711", displayTitle: "Manga",
            source: .history, directoryName: "Manga", offlineCacheFavoriteID: "cached-work",
            isSmartModeEnabled: true, forumID: "30"
        )
        app.presentMangaReader(initial)
        let session = try #require(app.presentedReaderSession)
        var latest = initial
        latest.chapterTID = "712"
        latest.chapterView = 3
        latest.initialPage = 17
        #expect(await session.openOriginalPost(url: threadURL("712", page: 3), resumeRoute: .manga(latest)))
        guard case let .thread(context) = session.content else { Issue.record("Expected thread"); return }
        #expect(context.thread.tid == "712")
        #expect(context.thread.fid == "30")
        await session.openReader(.manga, from: session.threadModel(for: context, dependencies: app.appContext.forumDependencies))
        #expect(app.activeMangaContext == latest)
        #expect(app.activeNovelContext == nil)
        session.close()
    }

    @Test func embeddedThreadSwitchNeverCreatesCoverOrChangesNavigation() async throws {
        let app = try makeApp()
        let context = ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "720", fid: "40"), title: "Thread")
        let session = ReaderSession(content: .thread(context), appModel: app)
        let navigator = ForumDestinationNavigator(dependencies: app.appContext.forumDependencies, appModel: app, mode: .forumTab)
        navigator.push(.threadReader(context))
        let path = navigator.path
        session.activate()
        let model = session.threadModel(for: context, dependencies: app.appContext.forumDependencies)
        await session.openReader(.novel, from: model)
        #expect(model.becameReaderCompanion)
        #expect(app.activeNovelContext?.threadID == "720")
        #expect(app.activeNovelContext?.forumID == "40")
        #expect(app.presentedReaderSession == nil)
        #expect(navigator.path == path)
        #expect(app.selectedTab == .favorites)
        let novel = try #require(app.activeNovelContext)
        await session.openOriginalPost(url: threadURL("720"), resumeRoute: .novel(novel))
        await session.openReader(.manga, from: model)
        #expect(app.activeMangaContext?.chapterTID == "720")
        #expect(app.activeMangaContext?.isSmartModeEnabled == false)
        #expect(app.activeNovelContext == nil)
        #expect(app.presentedReaderSession == nil)
        #expect(navigator.path == path)
        session.close()
        #expect(app.activeMangaContext == nil)
    }

    @Test func firstModeSwitchLoadsIndependentPersistedPositions() async throws {
        let app = try makeApp()
        let point = NovelResumePoint(view: 5, displayedTextOffset: 93, chapterOrdinal: 2, segmentProgress: 0.6, readingModeHint: .vertical)
        try await app.appContext.readingProgressStore.replaceAll([
            ReadingProgressRecord(contentTarget: .novelThread(threadID: "730"), kind: .novel,
                                  novel: NovelReadingProgressRecord(lastView: 5, novelResumePoint: point)),
            ReadingProgressRecord(contentTarget: .mangaThread(threadID: "730"), kind: .manga,
                                  manga: MangaReadingProgressRecord(chapterThreadID: "730", chapterView: 2, lastChapter: "Chapter", mangaPageIndex: 12))
        ])
        let resolver = ReaderModeLaunchResolver(dependencies: app.appContext.forumDependencies)
        let thread = ThreadIdentity(tid: "730", fid: "40")
        let novel = await resolver.novelContext(thread: thread, title: "Thread", authorID: nil, isPreview: false)
        let manga = try await resolver.mangaContext(thread: thread, title: "Thread", isPreview: false)
        #expect(novel.initialResumePoint == point)
        #expect(novel.forumID == "40")
        #expect(manga.chapterView == 2)
        #expect(manga.initialPage == 12)
        #expect(!manga.isSmartModeEnabled)
    }

    @Test(arguments: [true, false])
    func mangaSwitchHonorsBoardSmartSettingWithoutChangingIt(smartMode: Bool) async throws {
        let app = try makeApp()
        var settings = await app.appContext.settingsStore.load()
        settings.boardReader.setEntry(.init(mode: .manga(smartEnabled: smartMode)), forumID: "40")
        try await app.appContext.settingsStore.save(settings)
        let resolver = ReaderModeLaunchResolver(dependencies: app.appContext.forumDependencies)
        let context = try await resolver.mangaContext(thread: ThreadIdentity(tid: "740", fid: "40"), title: "Manga", isPreview: false)
        #expect(context.isSmartModeEnabled == smartMode)
        #expect(context.initialPage == 0)
        #expect(context.chapterView == 1)
        #expect(await app.appContext.settingsStore.load().boardReader == settings.boardReader)
    }

    @Test func previewFlagSurvivesCrossModeSwitching() async throws {
        let app = try makeApp()
        let novel = NovelLaunchContext(threadID: "750", threadTitle: "Preview", source: .forum, isPreview: true)
        app.presentNovelReader(novel)
        let session = try #require(app.presentedReaderSession)
        await session.openOriginalPost(url: threadURL("750"), resumeRoute: .novel(novel))
        guard case let .thread(context) = session.content else { Issue.record("Expected thread"); return }
        let model = session.threadModel(for: context, dependencies: app.appContext.forumDependencies)
        #expect(!model.persistsReadingActivity)
        await session.openReader(.manga, from: model)
        #expect(app.activeMangaContext?.isPreview == true)
        #expect(await app.appContext.readerResumeRouteStore.load() == nil)
        session.close()
    }

    @Test func smartMangaSwitchUsesDirectoryResumeInsteadOfStaleChapterProgress() async throws {
        let app = try makeApp()
        let directory = MangaDirectory(cleanBookName: "Book", strategy: .links, sourceKey: "Book", chapters: [
            MangaChapter(tid: "751", rawTitle: "Chapter 1", chapterNumber: 1),
            MangaChapter(tid: "752", rawTitle: "Chapter 2", chapterNumber: 2)
        ])
        try await app.appContext.mangaDirectoryStore.saveDirectory(directory)
        try await app.appContext.readingProgressStore.replaceAll([
            ReadingProgressRecord(contentTarget: .mangaThread(threadID: "751"), kind: .manga,
                                  manga: MangaReadingProgressRecord(chapterThreadID: "751", lastChapter: "Chapter 1", mangaPageIndex: 1)),
            ReadingProgressRecord(contentTarget: FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: "Book"), kind: .manga,
                                  manga: MangaReadingProgressRecord(chapterThreadID: "752", lastChapter: "Chapter 2", mangaPageIndex: 9))
        ])
        let resolver = ReaderModeLaunchResolver(dependencies: app.appContext.forumDependencies)
        let context = try await resolver.mangaContext(thread: ThreadIdentity(tid: "751", fid: "30"), title: "Chapter 1", isPreview: false)
        #expect(context.originalThreadID == "751")
        #expect(context.chapterTID == "752")
        #expect(context.initialPage == 9)
        #expect(context.directoryName == "Book")
        #expect(context.isSmartModeEnabled)
    }

    @Test func invalidOriginalTargetKeepsReaderAndAllowsRetry() async throws {
        let app = try makeApp()
        let novel = NovelLaunchContext(threadID: "760", threadTitle: "Novel", source: .forum)
        app.presentNovelReader(novel)
        let session = try #require(app.presentedReaderSession)
        let contentID = session.contentID
        #expect(await session.openOriginalPost(url: URL(string: "https://bbs.yamibo.com/")!, resumeRoute: .novel(novel)) == false)
        #expect(session.contentID == contentID)
        #expect(session.switchFailure != nil)
        #expect(!session.isSwitching)
        #expect(await session.openOriginalPost(url: threadURL("760"), resumeRoute: .novel(novel)))
        #expect(session.switchFailure == nil)
        session.close()
    }

    @Test func closedSessionRejectsSwitchAndLateProgress() async throws {
        let app = try makeApp()
        let novel = NovelLaunchContext(threadID: "770", threadTitle: "Novel", source: .forum)
        app.presentNovelReader(novel)
        let session = try #require(app.presentedReaderSession)
        let contentID = session.contentID
        session.close()
        session.updateResumeRoute(.novel(novel), contentID: contentID)
        #expect(await session.openOriginalPost(url: threadURL("770"), resumeRoute: .novel(novel)) == false)
        #expect(app.presentedReaderSession == nil)
        #expect(app.activeNovelContext == nil)
    }

    @Test func duplicateSwitchesAndSupersededResolutionCannotReplaceNewMode() async throws {
        let app = try makeApp()
        app.presentNovelReader(NovelLaunchContext(threadID: "780", threadTitle: "Novel", source: .forum))
        let session = try #require(app.presentedReaderSession)
        let gate = ReaderSessionResolutionGate()
        let pending = Task {
            await session.transition {
                await gate.wait()
                return .thread(ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "780"), title: "Old thread"))
            }
        }
        await gate.waitUntilStarted()
        var duplicateWasResolved = false
        await session.transition {
            duplicateWasResolved = true
            throw CancellationError()
        }
        #expect(!duplicateWasResolved)
        let manga = MangaLaunchContext(originalThreadID: "781", chapterTID: "781", displayTitle: "New manga", source: .forum)
        app.presentMangaReader(manga)
        let newContentID = session.contentID
        gate.release()
        await pending.value
        #expect(session.contentID == newContentID)
        #expect(app.activeMangaContext == manga)
        #expect(app.activeNovelContext == nil)
        #expect(!session.isSwitching)
        session.close()
    }

    @Test func closingDuringResolutionDoesNotReopenTheSession() async throws {
        let app = try makeApp()
        app.presentNovelReader(NovelLaunchContext(threadID: "790", threadTitle: "Novel", source: .forum))
        let session = try #require(app.presentedReaderSession)
        let gate = ReaderSessionResolutionGate()
        let pending = Task {
            await session.transition {
                await gate.wait()
                return .thread(ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "790"), title: "Thread"))
            }
        }
        await gate.waitUntilStarted()
        session.close()
        gate.release()
        await pending.value
        #expect(session.isClosed)
        #expect(!session.isSwitching)
        #expect(app.presentedReaderSession == nil)
        #expect(app.activeNovelContext == nil)
        #expect(app.forumNavigationRequest == nil)
    }

    @Test func nonMangaSwitchStaysOnThreadAndDoesNotChangeHistoryMode() async throws {
        let app = try makeApp(validator: MangaReaderOpenValidator { _ in
            throw MangaReaderDataSupport.currentMangaChapterParsingFailure()
        })
        let context = ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "800", fid: "40"), title: "Text only")
        let session = ReaderSession(content: .thread(context), appModel: app)
        session.activate()
        let model = session.threadModel(for: context, dependencies: app.appContext.forumDependencies)
        let contentID = session.contentID
        await session.openReader(.manga, from: model)
        #expect(session.contentID == contentID)
        #expect(!model.becameReaderCompanion)
        #expect(session.switchFailure?.summary == L10n.string("manga.open.no_readable_images"))
        #expect(!session.isSwitching)
        #expect(app.activeMangaContext == nil)
        #expect(app.presentedReaderSession == nil)
        session.close()
    }

    @Test func requestedMangaOpenRejectsBeforePresentation() async throws {
        let app = try makeApp(validator: MangaReaderOpenValidator { _ in throw MangaReaderOpenError.noReadableImages })
        let context = MangaLaunchContext(originalThreadID: "801", chapterTID: "801", displayTitle: "Text", source: .favorites)
        let task = app.requestMangaReader(context)
        #expect(app.isOpeningMangaReader)
        #expect(app.presentedReaderSession == nil)
        await task.value
        #expect(!app.isOpeningMangaReader)
        #expect(app.activeMangaContext == nil)
        #expect(app.presentedReaderSession == nil)
        #expect(app.mangaOpenFailure?.summary == L10n.string("manga.open.no_readable_images"))
        #expect(app.selectedTab == .favorites)
        #expect(await app.appContext.readerResumeRouteStore.load() == nil)
    }

    @Test func requestedMangaOpenCarriesValidatedProjectionIntoReader() async throws {
        let app = try makeApp()
        let context = MangaLaunchContext(originalThreadID: "802", chapterTID: "802", displayTitle: "Manga", source: .favorites, chapterView: 3)
        await app.requestMangaReader(context).value
        #expect(app.activeMangaContext == context)
        #expect(app.presentedReaderSession?.preparedMangaProjection?.tid == "802")
        #expect(app.presentedReaderSession?.preparedMangaProjection?.sourceIdentity.view == 3)
        #expect(!app.isOpeningMangaReader)
        app.dismissMangaReader()
    }

    @Test func cancelOpeningMangaPreventsLatePresentation() async throws {
        let gate = ReaderSessionResolutionGate()
        let app = try makeApp(validator: MangaReaderOpenValidator { _ in
            await gate.wait()
            throw MangaReaderOpenError.noReadableImages
        })
        let context = MangaLaunchContext(originalThreadID: "803", chapterTID: "803", displayTitle: "Manga", source: .forum)
        let opening = app.requestMangaReader(context)
        await gate.waitUntilStarted()
        app.cancelMangaReaderOpen()
        gate.release()
        await opening.value
        #expect(!app.isOpeningMangaReader)
        #expect(app.mangaOpenFailure == nil)
        #expect(app.activeMangaContext == nil)
        #expect(app.presentedReaderSession == nil)
    }

    private func makeApp(validator: MangaReaderOpenValidator? = nil) throws -> YamiboAppModel {
        let suite = YamiboTestDefaults.suiteName(prefix: "reader-session")
        let context = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: suite, key: "session"),
            settingsStore: try SettingsStore(testSuiteName: suite, key: "settings"),
            readerResumeRouteStore: try ReaderResumeRouteStore(testSuiteName: suite, key: "resume"),
            readingProgressStore: try ReadingProgressStore(testSuiteName: suite, key: "progress"),
            grdbRootDirectory: rootDirectory,
            cachesRootDirectory: rootDirectory.appendingPathComponent("Caches")
        )
        let validator = validator ?? MangaReaderOpenValidator { request in
            MangaReaderProjection(
                tid: request.threadID, chapterTitle: "Manga",
                imageURLs: [URL(string: "https://example.com/page.jpg")!],
                sourceIdentity: MangaReaderProjectionSourceIdentity(tid: request.threadID, authorID: "42", view: request.view)
            )
        }
        return YamiboAppModel(appContext: context, initialTab: .favorites, mangaReaderOpenValidator: validator)
    }

    private func threadURL(_ tid: String, page: Int = 1) -> URL {
        YamiboRoute.threadByID(tid: tid, page: page, authorID: nil, reverse: false).url
    }
}

@MainActor
private final class ReaderSessionResolutionGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

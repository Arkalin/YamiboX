import Foundation
import Observation
import os
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

    @Test func bookReturnSourceSurvivesModeSwitchAndClosingAnimation() async throws {
        let app = try makeApp()
        let source = try makeBookOpeningTransitionForTest()
        let novel = NovelLaunchContext(threadID: "690", threadTitle: "Book", source: .favorites)
        app.presentNovelReader(novel, bookOpeningTransition: source)
        let session = try #require(app.presentedReaderSession)
        #expect(session.bookOpeningTransition == source)
        #expect(app.isReaderCoverVisible)

        #expect(await session.openOriginalPost(url: threadURL("690"), resumeRoute: .novel(novel)))
        #expect(session.bookOpeningTransition == source)
        app.presentNovelReader(novel)
        #expect(app.presentedReaderSession === session)
        #expect(session.bookOpeningTransition == source)

        // Explicit close retains the source until the closing animation ends.
        app.dismissPresentedReaderSession()
        #expect(session.isClosed)
        #expect(app.presentedReaderSession == nil)
        #expect(app.isReaderCoverVisible)
        #expect(session.bookOpeningTransition == source)
        app.readerCoverDidDismiss()
        #expect(!app.isReaderCoverVisible)

        app.presentNovelReader(novel)
        #expect(app.presentedReaderSession?.bookOpeningTransition == nil)
        app.dismissPresentedReaderSession()
        app.readerCoverDidDismiss()
    }

    @Test func validatedMangaRetainsItsTappedCoverSource() async throws {
        let app = try makeApp()
        let source = try makeBookOpeningTransitionForTest()
        let manga = MangaLaunchContext(originalThreadID: "691", chapterTID: "691", displayTitle: "Manga", source: .favorites)
        await app.requestMangaReader(manga, bookOpeningTransition: source).value
        #expect(app.presentedReaderSession?.bookOpeningTransition == source)
        #expect(app.isReaderCoverVisible)
        app.dismissPresentedReaderSession()
        app.readerCoverDidDismiss()
    }

    @Test func failedBookOpenDoesNotLeakSourceToNextPresentation() async throws {
        let app = try makeApp(validator: MangaReaderOpenValidator { _ in throw MangaReaderOpenError.noReadableImages })
        let source = try makeBookOpeningTransitionForTest()
        let manga = MangaLaunchContext(originalThreadID: "692", chapterTID: "692", displayTitle: "Manga", source: .favorites)
        await app.requestMangaReader(manga, bookOpeningTransition: source).value
        #expect(app.presentedReaderSession == nil)
        #expect(!app.isReaderCoverVisible)

        app.presentNovelReader(NovelLaunchContext(threadID: "693", threadTitle: "Unrelated", source: .forum))
        #expect(app.presentedReaderSession?.bookOpeningTransition == nil)
        // A stale onDismiss from an older cover cannot unfreeze a new one.
        app.readerCoverDidDismiss()
        #expect(app.isReaderCoverVisible)
        app.dismissPresentedReaderSession()
        app.readerCoverDidDismiss()
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

    @Test(arguments: [YamiboThreadReaderOverride.novel, .manga])
    func embeddedThreadSwitchTransfersSessionAndRemovesSource(mode: YamiboThreadReaderOverride) async throws {
        let app = try makeApp()
        let context = ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "720", fid: "40"), title: "Thread")
        let navigator = ForumDestinationNavigator(dependencies: app.appContext.forumDependencies, appModel: app, mode: .forumTab)
        navigator.push(.board(fid: "40", title: "Board", page: nil))
        let returnPath = navigator.path
        navigator.push(.threadReader(context))
        let path = navigator.path
        let session = app.makeReaderSession(
            content: .thread(context), presentation: .embeddedThread
        )
        session.activate()
        let model = session.threadModel(for: context, dependencies: app.appContext.forumDependencies)
        let originalContentID = session.contentID
        await session.openReader(mode, from: model, onFullScreenHandoff: navigator.readerSourceHandoff())
        #expect(model.becameReaderCompanion)
        let reader = try #require(app.presentedReaderSession)
        #expect(reader === session)
        #expect(reader.presentation == .fullScreen)
        #expect(app.isReaderCoverVisible)
        #expect(session.contentID != originalContentID)
        #expect(session.resumeRoute != nil)
        #expect(session.threadModel(for: context, dependencies: app.appContext.forumDependencies) === model)
        #expect(!session.isSwitching)
        #expect(navigator.path == path)
        #expect(app.selectedTab == .favorites)

        if mode == .novel {
            #expect(app.activeNovelContext?.threadID == "720")
            #expect(app.activeNovelContext?.forumID == "40")
        } else {
            #expect(app.activeMangaContext?.chapterTID == "720")
            #expect(app.activeMangaContext?.isSmartModeEnabled == false)
            #expect(reader.preparedMangaProjection?.tid == "720")
        }
        session.completeFullScreenHandoff()
        #expect(navigator.path == returnPath)
        session.completeFullScreenHandoff()
        #expect(navigator.path == returnPath)

        let staleContentID = session.contentID
        let initialRoute = try #require(session.resumeRoute)
        let latestRoute: ReaderResumeRoute
        switch initialRoute {
        case var .novel(novel):
            novel.initialView = 4
            novel.initialResumePoint = NovelResumePoint(
                view: 4, displayedTextOffset: 162, chapterOrdinal: 3,
                segmentProgress: 0.42, readingModeHint: .vertical
            )
            latestRoute = .novel(novel)
        case var .manga(manga):
            manga.chapterView = 3
            manga.initialPage = 17
            latestRoute = .manga(manga)
        }
        session.updateResumeRoute(latestRoute, contentID: session.contentID)

        // Round trips retain the original thread model in the transferred session.
        for _ in 0..<3 {
            let route = try #require(session.resumeRoute)
            #expect(await session.openOriginalPost(url: threadURL("720"), resumeRoute: route))
            guard case let .thread(thread) = session.content else {
                Issue.record("Expected original thread")
                return
            }
            #expect(session.threadModel(for: thread, dependencies: app.appContext.forumDependencies) === model)
            session.updateResumeRoute(initialRoute, contentID: staleContentID)
            #expect(session.resumeRoute == nil)
            await session.openReader(mode, from: model)
            #expect(session.resumeRoute == latestRoute)
            #expect(app.presentedReaderSession === session)
            #expect(navigator.path == returnPath)
        }
        #expect(app.presentedReaderSession === reader)
        app.dismissPresentedReaderSession()
        app.readerCoverDidDismiss()
        #expect(app.presentedReaderSession == nil)
        #expect(!app.isReaderCoverVisible)
        #expect(session.isClosed)
        #expect(navigator.path == returnPath)
        #expect(app.activeNovelContext == nil)
        #expect(app.activeMangaContext == nil)

        await session.openReader(mode, from: model)
        #expect(app.presentedReaderSession == nil)
    }

    @Test(arguments: [false, true])
    func fullScreenHandoffRemovesOnlyItsSourceIncludingSplitDetailRoot(split: Bool) throws {
        let app = try makeApp()
        let navigator = ForumDestinationNavigator(
            dependencies: app.appContext.forumDependencies, appModel: app,
            mode: .forumTab, usesSplitNavigation: split
        )
        navigator.push(.board(fid: "40", title: "Board", page: nil))
        let returnPath = navigator.path
        let source = ForumDestination.threadReader(ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "720"), title: "Thread"))
        navigator.push(source)
        let handoff = navigator.readerSourceHandoff()
        handoff()
        #expect(navigator.path == returnPath)
        #expect(navigator.browserDetailPath.isEmpty)
        #expect(navigator.selectedBrowserThreadID == nil)
        navigator.push(source)
        let reopenedPath = navigator.path
        handoff()
        #expect(navigator.path == reopenedPath)
        navigator.push(.search(fid: nil))
        let newPath = navigator.path
        handoff()
        #expect(navigator.path == newPath)
    }

    @Test func closingBeforeFullScreenAppearsStillRemovesSource() async throws {
        let app = try makeApp()
        let navigator = ForumDestinationNavigator(dependencies: app.appContext.forumDependencies, appModel: app, mode: .forumTab)
        let context = ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "720"), title: "Thread")
        navigator.push(.threadReader(context))
        let session = app.makeReaderSession(
            content: .thread(context), presentation: .embeddedThread
        )
        session.activate()
        await session.openReader(
            .novel, from: session.threadModel(for: context, dependencies: app.appContext.forumDependencies),
            onFullScreenHandoff: navigator.readerSourceHandoff()
        )
        #expect(app.presentedReaderSession === session)
        session.close()
        #expect(navigator.path.isEmpty)
        #expect(app.presentedReaderSession == nil)
    }

    @Test(arguments: [YamiboThreadReaderOverride.novel, .manga])
    func directReaderLaunchDoesNotReuseEmbeddedThread(mode: YamiboThreadReaderOverride) async throws {
        let app = try makeApp()
        let context = ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "721"), title: "Thread")
        let embedded = app.makeReaderSession(content: .thread(context), presentation: .embeddedThread)
        embedded.activate()
        let model = embedded.threadModel(for: context, dependencies: app.appContext.forumDependencies)
        let contentID = embedded.contentID
        if mode == .novel {
            app.presentNovelReader(NovelLaunchContext(threadID: "722", threadTitle: "Novel", source: .forum))
        } else {
            await app.requestMangaReader(MangaLaunchContext(
                originalThreadID: "722", chapterTID: "722", displayTitle: "Manga", source: .forum
            )).value
        }
        #expect(app.presentedReaderSession != nil)
        #expect(app.presentedReaderSession !== embedded)
        #expect(app.isReaderCoverVisible)
        #expect(embedded.contentID == contentID)
        #expect(embedded.resumeRoute == nil)
        #expect(model.becameReaderCompanion)
        app.dismissPresentedReaderSession()
        app.readerCoverDidDismiss()
        embedded.close()
    }

    @Test(arguments: [YamiboThreadReaderOverride.novel, .manga])
    func pendingEmbeddedSwitchCannotReplaceANewerFullScreenLaunch(mode: YamiboThreadReaderOverride) async throws {
        let app = try makeApp()
        let embedded = app.makeReaderSession(content: .thread(ThreadNovelLaunchContext(
            thread: ThreadIdentity(tid: "723"), title: "Thread"
        )), presentation: .embeddedThread)
        embedded.activate()
        let gate = ReaderSessionResolutionGate()
        let pending = Task {
            await embedded.transition {
                await gate.wait()
                return .novel(NovelLaunchContext(threadID: "723", threadTitle: "Old", source: .forum))
            }
        }
        await gate.waitUntilStarted()
        let next: ReaderResumeRoute
        if mode == .novel {
            let novel = NovelLaunchContext(threadID: "724", threadTitle: "New", source: .forum)
            next = .novel(novel)
            app.presentNovelReader(novel)
        } else {
            let manga = MangaLaunchContext(originalThreadID: "724", chapterTID: "724", displayTitle: "New", source: .forum)
            next = .manga(manga)
            await app.requestMangaReader(manga).value
        }
        let reader = try #require(app.presentedReaderSession)
        gate.release()
        await pending.value
        #expect(app.presentedReaderSession === reader)
        #expect(reader.resumeRoute == next)
        #expect(embedded.resumeRoute == nil)
        #expect(!embedded.isSwitching)
        app.dismissPresentedReaderSession()
        app.readerCoverDidDismiss()
        embedded.close()
    }

    @Test func leavingEmbeddedThreadCancelsLateFullScreenPresentation() async throws {
        let app = try makeApp()
        let embedded = app.makeReaderSession(content: .thread(ThreadNovelLaunchContext(
            thread: ThreadIdentity(tid: "725"), title: "Thread"
        )), presentation: .embeddedThread)
        embedded.activate()
        let gate = ReaderSessionResolutionGate()
        let pending = Task {
            await embedded.transition {
                await gate.wait()
                return .novel(NovelLaunchContext(threadID: "725", threadTitle: "Old", source: .forum))
            }
        }
        await gate.waitUntilStarted()
        embedded.deactivate()
        gate.release()
        await pending.value
        #expect(app.presentedReaderSession == nil)
        #expect(!app.isReaderCoverVisible)
        #expect(embedded.resumeRoute == nil)
        #expect(!embedded.isSwitching)
        embedded.close()
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
        let session = app.makeReaderSession(content: .thread(context), presentation: .embeddedThread)
        session.activate()
        let model = session.threadModel(for: context, dependencies: app.appContext.forumDependencies)
        let contentID = session.contentID
        var handoffCount = 0
        await session.openReader(.manga, from: model, onFullScreenHandoff: { handoffCount += 1 })
        #expect(session.contentID == contentID)
        #expect(!model.becameReaderCompanion)
        #expect(session.switchFailure?.summary == L10n.string("manga.open.no_readable_images"))
        #expect(!session.isSwitching)
        #expect(app.activeMangaContext == nil)
        #expect(app.presentedReaderSession == nil)
        #expect(session.presentation == .embeddedThread)
        session.completeFullScreenHandoff()
        session.close()
        #expect(handoffCount == 0)
    }

    @Test func cancelledEmbeddedValidationNeverHandsOffSource() async throws {
        let gate = ReaderSessionResolutionGate()
        let app = try makeApp(validator: MangaReaderOpenValidator { _ in
            await gate.wait()
            throw MangaReaderOpenError.noReadableImages
        })
        let context = ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "805", fid: "40"), title: "Thread")
        let session = app.makeReaderSession(content: .thread(context), presentation: .embeddedThread)
        session.activate()
        let model = session.threadModel(for: context, dependencies: app.appContext.forumDependencies)
        let contentID = session.contentID
        var handoffCount = 0
        let pending = Task {
            await session.openReader(.manga, from: model, onFullScreenHandoff: { handoffCount += 1 })
        }
        await gate.waitUntilStarted()
        session.cancelSwitch()
        gate.release()
        await pending.value
        #expect(session.contentID == contentID)
        #expect(session.presentation == .embeddedThread)
        #expect(session.switchFailure == nil)
        #expect(!model.becameReaderCompanion)
        #expect(app.presentedReaderSession == nil)
        session.close()
        #expect(handoffCount == 0)
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

    @Test func rejectedIndependentMangaOpenDoesNotSuspendEmbeddedThread() async throws {
        let app = try makeApp(validator: MangaReaderOpenValidator { _ in throw MangaReaderOpenError.noReadableImages })
        let context = ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "806"), title: "Thread")
        let session = app.makeReaderSession(content: .thread(context), presentation: .embeddedThread)
        let model = session.threadModel(for: context, dependencies: app.appContext.forumDependencies)
        let contentID = session.contentID
        session.activate()
        await app.requestMangaReader(MangaLaunchContext(
            originalThreadID: "807", chapterTID: "807", displayTitle: "Other thread", source: .forum
        )).value
        #expect(!model.becameReaderCompanion)
        #expect(session.contentID == contentID)
        #expect(session.presentation == .embeddedThread)
        #expect(app.presentedReaderSession == nil)
        #expect(app.mangaOpenFailure != nil)
        session.close()
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
        let source = try makeBookOpeningTransitionForTest()
        let opening = app.requestMangaReader(context, bookOpeningTransition: source)
        await gate.waitUntilStarted()
        app.cancelMangaReaderOpen()
        gate.release()
        await opening.value
        #expect(!app.isOpeningMangaReader)
        #expect(app.mangaOpenFailure == nil)
        #expect(app.activeMangaContext == nil)
        #expect(app.presentedReaderSession == nil)
        #expect(!app.isReaderCoverVisible)
        app.presentNovelReader(NovelLaunchContext(threadID: "804", threadTitle: "New book", source: .forum))
        #expect(app.presentedReaderSession?.bookOpeningTransition == nil)
        app.dismissPresentedReaderSession()
        app.readerCoverDidDismiss()
    }

    @Test func activeContextProjectionsObserveSessionActivationProgressAndModeChanges() throws {
        let app = try makeApp()
        let novel = NovelLaunchContext(threadID: "810", threadTitle: "Novel", source: .forum)
        let session = app.makeReaderSession(content: .novel(novel))
        let changes = OSAllocatedUnfairLock(initialState: 0)
        func observeContext() {
            withObservationTracking {
                _ = app.activeNovelContext
                _ = app.activeMangaContext
            } onChange: {
                changes.withLock { $0 += 1 }
            }
        }

        observeContext()
        session.activate()
        #expect(changes.withLock { $0 } == 1)
        #expect(app.activeNovelContext == novel)

        observeContext()
        var updated = novel
        updated.initialView = 4
        app.updateReaderResumeRoute(.novel(updated))
        #expect(changes.withLock { $0 } == 2)
        #expect(session.resumeRoute == .novel(updated))
        #expect(app.activeNovelContext == updated)

        observeContext()
        let manga = MangaLaunchContext(originalThreadID: "810", chapterTID: "810", displayTitle: "Manga", source: .forum)
        session.present(.manga(manga))
        #expect(changes.withLock { $0 } == 3)
        #expect(app.activeNovelContext == nil)
        #expect(app.activeMangaContext == manga)

        observeContext()
        session.deactivate()
        #expect(changes.withLock { $0 } == 4)
        #expect(app.activeMangaContext == nil)
        #expect(session.resumeRoute == .manga(manga))
    }

    @Test func oldSessionProgressAndCloseCannotReplaceNewActiveSession() throws {
        let app = try makeApp()
        let novel = NovelLaunchContext(threadID: "811", threadTitle: "Old", source: .forum)
        app.presentNovelReader(novel)
        let oldSession = try #require(app.presentedReaderSession)
        let manga = MangaLaunchContext(originalThreadID: "812", chapterTID: "812", displayTitle: "New", source: .forum)
        let newSession = app.makeReaderSession(content: .manga(manga))
        newSession.activate()

        var updated = novel
        updated.initialView = 6
        oldSession.updateResumeRoute(.novel(updated), contentID: oldSession.contentID)
        oldSession.deactivate()
        oldSession.close()
        #expect(app.activeNovelContext == nil)
        #expect(app.activeMangaContext == manga)
        #expect(!newSession.isClosed)

        newSession.close()
        #expect(app.activeMangaContext == nil)
        app.readerCoverDidDismiss()
        #expect(!app.hasActiveReaderPresentation)
    }

    @Test func publicResumeUpdateCannotChangeTheCurrentReadingMode() throws {
        let app = try makeApp()
        let novel = NovelLaunchContext(threadID: "813", threadTitle: "Novel", source: .forum)
        app.presentNovelReader(novel)
        let manga = MangaLaunchContext(originalThreadID: "813", chapterTID: "813", displayTitle: "Manga", source: .forum)
        app.updateReaderResumeRoute(.manga(manga))
        #expect(app.activeNovelContext == novel)
        #expect(app.activeMangaContext == nil)
        #expect(app.presentedReaderSession?.resumeRoute == .novel(novel))
        app.dismissPresentedReaderSession()
    }

    @Test func reusedPreviewSessionPersistsTheNewRegularReadingPosition() async throws {
        let app = try makeApp()
        let preview = NovelLaunchContext(threadID: "814", threadTitle: "Preview", source: .forum, isPreview: true)
        app.presentNovelReader(preview)
        let session = try #require(app.presentedReaderSession)
        let regular = NovelLaunchContext(threadID: "815", threadTitle: "Regular", source: .forum)
        app.presentNovelReader(regular)
        #expect(app.presentedReaderSession === session)
        let store = app.appContext.readerResumeRouteStore
        for _ in 0..<100 where store.loadSync() != .novel(regular) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.loadSync() == .novel(regular))

        var updated = regular
        updated.initialView = 9
        app.updateReaderResumeRoute(.novel(updated))
        for _ in 0..<100 where store.loadSync() != .novel(updated) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.loadSync() == .novel(updated))
        app.dismissPresentedReaderSession()
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

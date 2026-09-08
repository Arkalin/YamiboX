import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@MainActor
@Test(arguments: [nil, "55"] as [String?], [true, false])
func appContinuityRestoreReconcilesNovelRouteWithReadingProgress(forumID: String?, reconciles: Bool) async throws {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "app-continuity-restore-novel")
    let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
    let localFavoriteLibraryStore = FavoriteLibraryStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: defaultsSuiteName),
        key: "favorite-library"
    )
    let resumeRouteStore = try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "resume")
    let threadID = "901"
    let staleRoute = ReaderResumeRoute.novel(
        NovelLaunchContext(
            threadID: threadID,
            threadTitle: "旧标题",
            source: .resume,
            initialView: 2,
            forumID: forumID
        )
    )
    let resumePoint = NovelResumePoint(
        view: 5,
        displayedTextOffset: 120,
        chapterOrdinal: 2,
        chapterTitle: "第二章",
        segmentProgress: 0.4,
        authorID: "42",
        readingModeHint: .paged
    )
    try await resumeRouteStore.save(staleRoute)
    try await readingProgressStore.saveNovel(
        NovelReadingPosition(
            threadID: threadID,
            view: 5,
            authorID: "42",
            resumePoint: resumePoint
        )
    )
    var document = FavoriteLibraryDocument()
    try document.importThreadFavorite(
        probeResult: FavoriteThreadProbeResult(
            target: FavoriteItemTarget(kind: .novelThread, threadID: threadID),
            title: "远端小说",
            forumID: "49"
        )
    )
    try await localFavoriteLibraryStore.save(document)
    let workflow = AppContinuityWorkflow(
        appContext: YamiboAppContext(
            readerResumeRouteStore: resumeRouteStore,
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore
        )
    )

    let restoredRoute = await workflow.restoreExplicitly(
        canRestoreReaderRoute: true,
        reconcilesWithReadingProgress: reconciles
    )

    let expectedContext = NovelLaunchContext(
        threadID: threadID,
        threadTitle: reconciles ? "远端小说" : "旧标题",
        source: .resume,
        initialView: reconciles ? 5 : 2,
        authorID: reconciles ? "42" : nil,
        initialResumePoint: reconciles ? resumePoint : nil,
        forumID: forumID ?? "49"
    )
    #expect(restoredRoute == .novel(expectedContext))
    #expect(await resumeRouteStore.load() == .novel(expectedContext))
}

@MainActor
@Test func appContinuityDoesNotRestoreOrphanMangaContextWithoutReadingProgress() async throws {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "app-continuity-orphan-manga")
    let resumeRouteStore = try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "resume")
    let context = MangaLaunchContext(
        originalThreadID: "700",
        chapterTID: "700",
        displayTitle: "大家不可以忘記三之昔的一個貢獻",
        source: .resume,
        initialPage: 0
    )
    try await resumeRouteStore.save(.manga(context))
    let workflow = AppContinuityWorkflow(
        appContext: YamiboAppContext(
            readerResumeRouteStore: resumeRouteStore
        )
    )

    let restoredRoute = await workflow.restoreExplicitly(
        canRestoreReaderRoute: true,
        reconcilesWithReadingProgress: true
    )

    #expect(restoredRoute == nil)
    #expect(await resumeRouteStore.load() == nil)
}

@MainActor
@Test func appContinuityIgnoresLateReadingPositionAfterRouteDismissal() async throws {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "app-continuity-dismissal")
    let resumeRouteStore = try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "resume")
    let workflow = AppContinuityWorkflow(
        appContext: YamiboAppContext(readerResumeRouteStore: resumeRouteStore)
    )
    let threadID = "902"
    let route = ReaderResumeRoute.novel(
        NovelLaunchContext(
            threadID: threadID,
            threadTitle: "测试小说",
            source: .resume,
            initialView: 1
        )
    )

    workflow.readerRoutePresented(route)
    try await waitForReaderResumeRoute(resumeRouteStore, equals: route)
    workflow.readerRouteDismissed()
    workflow.readerReadingPositionChanged(route)

    #expect(await resumeRouteStore.load() == nil)
}

private func waitForReaderResumeRoute(
    _ store: ReaderResumeRouteStore,
    equals expected: ReaderResumeRoute?,
    timeout: TimeInterval = 1
) async throws {
    do {
        try await waitForCondition(timeout: .seconds(timeout), pollInterval: .milliseconds(20)) {
            await store.load() == expected
        }
    } catch is TestWaitTimeoutError {
        #expect(await store.load() == expected)
    }
}

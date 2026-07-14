import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Test func progressSyncFlushCancelsPendingAndPersistsLatestPosition() async throws {
    let adapter = RecordingProgressSyncAdapter()
    let sync = ProgressSyncModule(adapter: adapter, debounceNanoseconds: 100_000_000)
    let threadID = "2"

    await sync.queue(.novel(NovelReadingPosition(threadID: threadID, view: 1)))
    try await sync.flush(.novel(NovelReadingPosition(threadID: threadID, view: 3)))
    try await Task.sleep(nanoseconds: 140_000_000)

    let saved = await adapter.savedPositions
    #expect(saved == [
        .novel(NovelReadingPosition(threadID: threadID, view: 3))
    ])
}

@Test func progressSyncCancelPendingDoesNotPersistQueuedPosition() async throws {
    let adapter = RecordingProgressSyncAdapter()
    let sync = ProgressSyncModule(adapter: adapter, debounceNanoseconds: 20_000_000)

    await sync.queue(.novel(NovelReadingPosition(threadID: "3", view: 1)))
    await sync.cancelPending()
    try await Task.sleep(nanoseconds: 60_000_000)

    let saved = await adapter.savedPositions
    #expect(saved.isEmpty)
}

@Test func progressSyncDedupesRepeatedPosition() async throws {
    let adapter = RecordingProgressSyncAdapter()
    let sync = ProgressSyncModule(adapter: adapter, debounceNanoseconds: 20_000_000)
    let position = ProgressSyncPosition.novel(NovelReadingPosition(threadID: "4", view: 4))

    await sync.queue(position)
    try await Task.sleep(nanoseconds: 60_000_000)
    await sync.queue(position)
    try await Task.sleep(nanoseconds: 60_000_000)

    let saved = await adapter.savedPositions
    #expect(saved == [position])
}

@Test func favoriteLibraryProgressSyncDoesNotCreateMissingFavorite() async throws {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "progress-sync-missing-favorite")
    let localFavoriteLibraryStore = FavoriteLibraryStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: defaultsSuiteName),
        key: "local-favorites"
    )
    let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
    let adapter = FavoriteLibraryProgressSyncAdapter(
        readingProgressStore: readingProgressStore
    )
    let sync = ProgressSyncModule(adapter: adapter, debounceNanoseconds: 0)

    try await sync.flush(.novel(NovelReadingPosition(threadID: "6", view: 6)))

    #expect(try await localFavoriteLibraryStore.load().items.isEmpty)
    let progress = await readingProgressStore.load(threadID: "6")
    #expect(progress?.novel?.lastView == 6)
}

@Test func favoriteLibraryProgressSyncWritesIndependentProgressWithoutMutatingFavorites() async throws {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "progress-sync-existing-favorite")
    let localFavoriteLibraryStore = FavoriteLibraryStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: defaultsSuiteName),
        key: "local-favorites"
    )
    let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
    let adapter = FavoriteLibraryProgressSyncAdapter(
        readingProgressStore: readingProgressStore
    )
    let sync = ProgressSyncModule(adapter: adapter, debounceNanoseconds: 0)
    var favoriteLibrary = FavoriteLibraryDocument()
    favoriteLibrary.upsertItem(try FavoriteItem(
        target: FavoriteItemTarget(kind: .novelThread, threadID: "7"),
        title: "小说",
        locations: [.category(favoriteLibrary.defaultCategory.id)]
    ))
    favoriteLibrary.upsertItem(try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "8"),
        title: "漫画",
        locations: [.category(favoriteLibrary.defaultCategory.id)]
    ))
    try await localFavoriteLibraryStore.save(favoriteLibrary)

    try await sync.flush(.novel(NovelReadingPosition(
        threadID: "7",
        view: 2,
        maxView: 7,
        chapterTitle: "第二章",
        authorID: "42",
        resumePoint: NovelResumePoint(
            view: 2,
            displayedTextOffset: 120,
            chapterOrdinal: 1,
            chapterTitle: "第二章",
            segmentProgress: 0.5,
            authorID: "42",
            readingModeHint: .paged
        )
    )))
    try await sync.flush(.manga(MangaProgressReadingPosition(
        threadID: "8",
        chapterThreadID: "9",
        chapterTitle: "第9话",
        pageIndex: 4,
        pageCount: 9
    )))

    let storedFavoriteLibrary = try await localFavoriteLibraryStore.load()
    let novelProgress = await readingProgressStore.load(threadID: "7")
    let mangaProgress = await readingProgressStore.load(threadID: "8")
    #expect(storedFavoriteLibrary == favoriteLibrary)
    #expect(novelProgress?.novel?.novelResumePoint?.displayedTextOffset == 120)
    #expect(mangaProgress?.manga?.chapterThreadID == "9")
    #expect(mangaProgress?.manga?.mangaPageIndex == 4)
    #expect(mangaProgress?.manga?.mangaPageCount == 9)
}

private actor RecordingProgressSyncAdapter: ProgressSyncAdapter {
    private var saved: [ProgressSyncPosition] = []
    private var remainingFailures = 0
    private var failures = 0

    var savedPositions: [ProgressSyncPosition] {
        saved
    }

    var failureCount: Int {
        failures
    }

    func failNextSave() {
        remainingFailures += 1
    }

    func saveNovelReadingPosition(_ position: NovelReadingPosition) async throws {
        try failIfNeeded()
        saved.append(.novel(position))
    }

    func saveMangaReadingPosition(_ position: MangaProgressReadingPosition) async throws {
        try failIfNeeded()
        saved.append(.manga(position))
    }

    func saveThreadReadingPosition(_ position: ThreadReadingPosition) async throws {
        try failIfNeeded()
        saved.append(.thread(position))
    }

    private func failIfNeeded() throws {
        guard remainingFailures > 0 else { return }
        remainingFailures -= 1
        failures += 1
        throw TestProgressSyncError.saveFailed
    }
}

private enum TestProgressSyncError: Error {
    case saveFailed
}

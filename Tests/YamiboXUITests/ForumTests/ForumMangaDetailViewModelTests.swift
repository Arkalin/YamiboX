import Foundation
@preconcurrency import GRDB
import Testing
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

/// Regression coverage for the precise directory-scoped reading-progress
/// lookup `ForumMangaDetailViewModel` must use once its `MangaDirectory` is
/// known — see `ForumMangaDetailViewModel.loadReadingProgress()`. Mirrors
/// `LocalFavoriteOpenTargetResolver.mangaDirectoryResumeTarget`'s existing
/// pattern and the collision scenario documented there.
@MainActor
@Test func forumMangaDetailReloadUsesDirectoryLevelProgressNotStaleChapterThreadRecord() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-precise-progress")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    // `lastUpdatedAt` is set so `reload()` doesn't schedule the fresh-tag
    // automatic directory update — this test is about progress lookups and
    // its repository stub traps on any network-path call.
    let directory = MangaDirectory(
        cleanBookName: "测试漫画",
        strategy: .tag,
        sourceKey: "测试漫画",
        chapters: [
            MangaChapter(tid: "910", rawTitle: "第一话", chapterNumber: 1, view: 1),
            MangaChapter(tid: "911", rawTitle: "第二话", chapterNumber: 2, view: 2)
        ],
        lastUpdatedAt: Date()
    )
    try await mangaDirectoryStore.saveDirectory(directory)

    // The directory's TRUE current position: chapter 911, page 5 — written
    // the way a mode-on session actually advances the directory-level row.
    _ = try await readingProgressStore.saveMangaTitle(
        cleanBookName: directory.cleanBookName,
        chapterThreadID: "911",
        chapterView: 2,
        chapterTitle: "第二话",
        pageIndex: 5,
        mangaID: directory.favoriteIdentity
    )

    // A STALE, unrelated per-chapter record for chapter 910 — this is what
    // the old fuzzy `load(threadID:)` query would coincidentally match when
    // this view model is opened for chapter 910's own thread, since its
    // `thread_id`/`manga_chapter_thread_id` columns literally equal "910".
    _ = try await readingProgressStore.saveMangaThread(
        MangaProgressReadingPosition(
            chapterThreadID: "910",
            chapterView: 1,
            chapterTitle: "第一话",
            pageIndex: 0
        )
    )

    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "910": makeTestMangaReaderProjection(tid: "910", chapterTitle: "第一话")
        ])
    )
    let model = makeForumMangaDetailViewModel(dependencies: dependencies, threadTID: "910")

    await model.reload()

    #expect(model.errorMessage == nil)
    let resolvedDirectory = try #require(model.directory)
    #expect(resolvedDirectory.cleanBookName == "测试漫画")

    let context = try #require(model.continueLaunchContext())
    #expect(context.chapterTID == "911")
    #expect(context.chapterView == 2)
    #expect(context.initialPage == 5)
    #expect(context.chapterTID != "910")
}

/// Live-update regression test: after `reload()` has resolved `directory`,
/// a progress update saved elsewhere (e.g. Favorites reading the same
/// directory) must reach `readingProgress` via the same precise
/// directory-scoped query, not just at `reload()` time. Mirrors
/// `forumNovelDetailRefreshesReadingProgressWhenReadingProgressStoreChanges`'s
/// polling style, since the update arrives asynchronously through
/// `ReadingProgressStore.didChangeNotification`.
@MainActor
@Test func forumMangaDetailLiveUpdateUsesDirectoryLevelProgressAfterReload() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-live-progress")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    // See the reload test above: `lastUpdatedAt` keeps the fresh-tag
    // automatic update from reaching the trapping repository stub.
    let directory = MangaDirectory(
        cleanBookName: "测试漫画二",
        strategy: .tag,
        sourceKey: "测试漫画二",
        chapters: [
            MangaChapter(tid: "920", rawTitle: "第一话", chapterNumber: 1, view: 1),
            MangaChapter(tid: "921", rawTitle: "第二话", chapterNumber: 2, view: 2)
        ],
        lastUpdatedAt: Date()
    )
    try await mangaDirectoryStore.saveDirectory(directory)

    // A stale chapter-920-specific record sharing this view model's own tid,
    // matching the collision fixture pattern used in the reload test above.
    _ = try await readingProgressStore.saveMangaThread(
        MangaProgressReadingPosition(
            chapterThreadID: "920",
            chapterView: 1,
            chapterTitle: "第一话",
            pageIndex: 0
        )
    )

    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "920": makeTestMangaReaderProjection(tid: "920", chapterTitle: "第一话")
        ])
    )
    let model = makeForumMangaDetailViewModel(dependencies: dependencies, threadTID: "920")

    await model.reload()
    #expect(model.directory != nil)
    #expect(model.readingProgress?.manga?.chapterThreadID != "921")

    // Simulate a live progress update arriving from elsewhere (e.g. the
    // user advancing this same directory through Favorites) after reload.
    _ = try await readingProgressStore.saveMangaTitle(
        cleanBookName: directory.cleanBookName,
        chapterThreadID: "921",
        chapterView: 2,
        chapterTitle: "第二话",
        pageIndex: 3,
        mangaID: directory.favoriteIdentity
    )

    for _ in 0..<50 where model.readingProgress?.manga?.chapterThreadID != "921" {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(model.readingProgress?.manga?.chapterThreadID == "921")
    #expect(model.readingProgress?.manga?.mangaPageIndex == 3)
}

/// Correction flow: renaming the directory through the detail page must
/// persist the rename (name + keywords), migrate the directory-level
/// `.mangaTitle` reading-progress record to the new cleanBookName, and rename
/// the offline-cache owner directory — the same cascade the reader's
/// correction sheet performs.
@MainActor
@Test func forumMangaDetailSaveCorrectionRenamesDirectoryAndMigratesReferences() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-correction")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    let directory = MangaDirectory(
        cleanBookName: "旧名漫画",
        strategy: .tag,
        sourceKey: "77,88",
        chapters: [
            MangaChapter(tid: "930", rawTitle: "第1话", chapterNumber: 1, view: 1)
        ],
        lastUpdatedAt: Date()
    )
    try await mangaDirectoryStore.saveDirectory(directory)
    _ = try await readingProgressStore.saveMangaTitle(
        cleanBookName: directory.cleanBookName,
        chapterThreadID: "930",
        chapterView: 1,
        chapterTitle: "第1话",
        pageIndex: 2,
        mangaID: directory.favoriteIdentity
    )

    let offlineCacheStore = RenameRecordingMangaOfflineCacheStore()
    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "930": makeTestMangaReaderProjection(tid: "930", chapterTitle: "第1话")
        ]),
        mangaOfflineCacheStore: offlineCacheStore
    )
    let model = makeForumMangaDetailViewModel(dependencies: dependencies, threadTID: "930")

    await model.reload()
    #expect(model.directory?.cleanBookName == "旧名漫画")

    await model.saveCorrection(MangaDirectoryEditDraft(
        cleanBookName: "新名漫画",
        primaryKeyword: "作者X",
        secondaryKeyword: "新名漫画"
    ))

    #expect(model.directoryActionErrorMessage == nil)
    #expect(model.directory?.cleanBookName == "新名漫画")
    #expect(model.directory?.searchKeyword == "作者X 新名漫画")
    #expect(try await mangaDirectoryStore.directory(named: "旧名漫画") == nil)
    #expect(try await mangaDirectoryStore.directory(named: "新名漫画") != nil)
    #expect(offlineCacheStore.recordedRenames.count == 1)
    #expect(offlineCacheStore.recordedRenames.first?.from == "旧名漫画")
    #expect(offlineCacheStore.recordedRenames.first?.to == "新名漫画")

    let migratedTargets = await readingProgressStore.loadAll().compactMap(\.contentTarget)
    #expect(migratedTargets.contains { $0.mangaCleanBookName == "新名漫画" })
    #expect(!migratedTargets.contains { $0.mangaCleanBookName == "旧名漫画" })
    // The migrated directory-level record stays reachable through the
    // detail page's own precise progress query.
    #expect(model.readingProgress?.manga?.chapterThreadID == "930")
}

/// Update button (search feature relocated from the reader directory sheet):
/// a non-tag directory update performs a forum search, merges the found
/// chapters, and arms the shared search cooldown countdown.
@MainActor
@Test func forumMangaDetailUpdateDirectoryMergesSearchedChaptersAndStartsCooldown() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-update-search")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    let directory = MangaDirectory(
        cleanBookName: "测试漫画三",
        strategy: .searched,
        sourceKey: "测试漫画三",
        chapters: [
            MangaChapter(tid: "940", rawTitle: "第1话", chapterNumber: 1, view: 1)
        ],
        lastUpdatedAt: Date()
    )
    try await mangaDirectoryStore.saveDirectory(directory)

    let repository = ConfigurableMangaDirectoryRepository(
        searchResults: [
            MangaChapter(tid: "941", rawTitle: "测试漫画三 第2话", chapterNumber: 2, view: 1)
        ]
    )
    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "940": makeTestMangaReaderProjection(tid: "940", chapterTitle: "第1话")
        ]),
        directoryRepository: repository
    )
    let fixedNow = Date()
    let model = makeForumMangaDetailViewModel(
        dependencies: dependencies,
        threadTID: "940",
        workflowConfiguration: MangaDirectoryWorkflowConfiguration(now: { fixedNow })
    )

    await model.reload()
    #expect(model.directory?.chapters.count == 1)
    #expect(model.isSearchMode)

    await model.updateDirectoryFromDetail()

    #expect(model.directoryActionErrorMessage == nil)
    #expect(repository.searchCallCount == 1)
    #expect(model.directory?.chapters.map(\.tid) == ["940", "941"])
    #expect(model.directoryCooldownRemaining > 0)
    #expect(!model.isUpdateButtonEnabled)
    #expect(model.updateButtonTitle == "\(model.directoryCooldownRemaining)s")

    // A second tap during the cooldown surfaces the cooldown error instead
    // of searching again.
    await model.updateDirectoryFromDetail()
    #expect(repository.searchCallCount == 1)
    #expect(model.directoryActionErrorMessage != nil)
    #expect(model.directoryCooldownRemaining > 0)
}

/// Reset must discard the stored "998" chapter (standing in for a stale or
/// manually-corrected row) and rebuild the directory from a fresh network
/// seed, while keeping the directory's `cleanBookName` identity.
@MainActor
@Test func forumMangaDetailResetDirectoryReseedsFromNetworkDiscardingStaleChapters() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-reset")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    let directory = MangaDirectory(
        cleanBookName: "测试漫画四",
        strategy: .searched,
        sourceKey: "旧来源",
        chapters: [
            MangaChapter(tid: "950", rawTitle: "第1话", chapterNumber: 1, view: 1),
            MangaChapter(tid: "998", rawTitle: "手动新增的章节", chapterNumber: 98, view: 1),
        ],
        lastUpdatedAt: Date()
    )
    try await mangaDirectoryStore.saveDirectory(directory)

    let repository = ConfigurableMangaDirectoryRepository(
        seed: MangaDirectorySeed(
            currentChapter: MangaChapter(tid: "950", rawTitle: "第1话", chapterNumber: 1, view: 1),
            tagIDs: ["77"],
            cleanBookName: "测试漫画四"
        ),
        tagDirectoryResults: [
            MangaChapter(tid: "951", rawTitle: "测试漫画四 第2话", chapterNumber: 2, view: 1)
        ]
    )
    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "950": makeTestMangaReaderProjection(tid: "950", chapterTitle: "第1话")
        ]),
        directoryRepository: repository
    )
    let model = makeForumMangaDetailViewModel(
        dependencies: dependencies,
        threadTID: "950"
    )

    await model.reload()
    #expect(model.directory?.chapters.map(\.tid) == ["950", "998"])

    await model.resetDirectoryFromDetail()

    #expect(model.directoryActionErrorMessage == nil)
    #expect(model.directory?.cleanBookName == "测试漫画四")
    #expect(model.directory?.chapters.map(\.tid) == ["950", "951"])
    #expect(repository.tagDirectoryCallCount == 1)
    #expect(repository.seedCallCount == 1)
}

/// Tag-directory update path: a successful tag refresh that performed no
/// search offers the 5-second forced-search shortcut, and tapping the button
/// inside that window escalates to a real global search.
@MainActor
@Test func forumMangaDetailTagUpdateOffersForcedSearchShortcutThenRunsGlobalSearch() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-forced-search")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    let directory = MangaDirectory(
        cleanBookName: "测试漫画四",
        strategy: .tag,
        sourceKey: "12,34",
        chapters: [
            MangaChapter(tid: "950", rawTitle: "第1话", chapterNumber: 1, view: 1)
        ],
        lastUpdatedAt: Date()
    )
    try await mangaDirectoryStore.saveDirectory(directory)

    let repository = ConfigurableMangaDirectoryRepository(
        tagDirectoryResults: [
            MangaChapter(tid: "950", rawTitle: "第1话", chapterNumber: 1, view: 1)
        ],
        searchResults: [
            MangaChapter(tid: "951", rawTitle: "测试漫画四 第2话", chapterNumber: 2, view: 1)
        ]
    )
    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "950": makeTestMangaReaderProjection(tid: "950", chapterTitle: "第1话")
        ]),
        directoryRepository: repository
    )
    let fixedNow = Date()
    let model = makeForumMangaDetailViewModel(
        dependencies: dependencies,
        threadTID: "950",
        workflowConfiguration: MangaDirectoryWorkflowConfiguration(now: { fixedNow })
    )

    await model.reload()
    #expect(!model.isSearchMode)

    await model.updateDirectoryFromDetail()

    #expect(repository.tagDirectoryCallCount == 1)
    #expect(repository.searchCallCount == 0)
    let shortcutRemaining = try #require(model.forcedSearchShortcutRemaining)
    #expect(shortcutRemaining > 0)
    #expect(model.isSearchMode)
    #expect(model.updateButtonTitle == L10n.string("manga.global_search_countdown", shortcutRemaining))

    await model.updateDirectoryFromDetail()

    #expect(repository.searchCallCount == 1)
    #expect(model.directory?.chapters.map(\.tid) == ["950", "951"])
    #expect(model.directoryCooldownRemaining > 0)
    #expect(model.forcedSearchShortcutRemaining == nil)
}

/// A freshly created tag directory (`lastUpdatedAt == nil`) auto-updates once
/// right after the initial load, matching the reader's behavior.
@MainActor
@Test func forumMangaDetailAutoUpdatesFreshTagDirectoryAfterInitialLoad() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-auto-update")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    let directory = MangaDirectory(
        cleanBookName: "测试漫画五",
        strategy: .tag,
        sourceKey: "56",
        chapters: [
            MangaChapter(tid: "960", rawTitle: "第1话", chapterNumber: 1, view: 1)
        ]
    )
    try await mangaDirectoryStore.saveDirectory(directory)

    let repository = ConfigurableMangaDirectoryRepository(
        tagDirectoryResults: [
            MangaChapter(tid: "960", rawTitle: "第1话", chapterNumber: 1, view: 1),
            MangaChapter(tid: "961", rawTitle: "第2话", chapterNumber: 2, view: 1)
        ]
    )
    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "960": makeTestMangaReaderProjection(tid: "960", chapterTitle: "第1话")
        ]),
        directoryRepository: repository
    )
    let model = makeForumMangaDetailViewModel(dependencies: dependencies, threadTID: "960")

    await model.reload()

    for _ in 0..<50 where model.directory?.chapters.count != 2 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(repository.tagDirectoryCallCount == 1)
    #expect(model.directory?.chapters.map(\.tid) == ["960", "961"])
}

/// Cover regression: the favorites organizer's `.smartManga` cover backfill
/// only runs over favorited directories, so the detail page must resolve its
/// own automatic cover when the store has none — otherwise an unfavorited
/// manga's detail page shows the placeholder forever.
@MainActor
@Test func forumMangaDetailResolvesMissingSmartMangaCoverAfterReload() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-cover-backfill")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    // `lastUpdatedAt` keeps `reload()` from scheduling the fresh-tag
    // automatic update, so cover resolution starts directly from `reload()`.
    let directory = MangaDirectory(
        cleanBookName: "测试漫画六",
        strategy: .tag,
        sourceKey: "测试漫画六",
        chapters: [
            MangaChapter(tid: "970", rawTitle: "第一话", chapterNumber: 1, view: 1),
            MangaChapter(tid: "971", rawTitle: "第二话", chapterNumber: 2, view: 2)
        ],
        lastUpdatedAt: Date()
    )
    try await mangaDirectoryStore.saveDirectory(directory)

    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "971": makeTestMangaReaderProjection(tid: "971", chapterTitle: "第二话")
        ])
    )
    // The resolvable page is served for the directory's FIRST chapter (970),
    // while the detail page itself is opened for chapter 971 — the cover
    // must come from the earliest chapter, matching the favorites backfill.
    let owner = BlogReaderUser(uid: "42", name: "作者")
    let coverPage = ForumThreadPage(
        thread: ThreadIdentity(tid: "970", fid: "30"),
        title: "第一话",
        posts: [
            ForumThreadPost(
                postID: "p1",
                floorText: "1#",
                author: owner,
                contentHTML: "",
                contentText: "",
                images: [ForumThreadPostImage(url: "https://img.example.com/cover-970.jpg")]
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1)
    )
    let model = makeForumMangaDetailViewModel(
        dependencies: dependencies,
        threadTID: "971",
        threadCoverPageRepository: FixedPageThreadCoverPageRepository(firstPage: coverPage)
    )

    await model.reload()
    #expect(model.errorMessage == nil)
    #expect(model.coverURL == nil)

    for _ in 0..<50 where model.coverURL == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(model.coverURL?.absoluteString == "https://img.example.com/cover-970.jpg")
    let stored = await dependencies.contentCoverStore.cover(for: .smartManga(cleanBookName: "测试漫画六"))
    #expect(stored?.automaticCoverURL?.absoluteString == "https://img.example.com/cover-970.jpg")
    #expect(stored?.manualCoverURL == nil)
}

/// A manually-chosen or text-forced cover must survive the detail page's
/// automatic resolution untouched: resolution only fills genuinely missing
/// covers.
@MainActor
@Test func forumMangaDetailDoesNotOverrideExistingSmartMangaCover() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-cover-existing")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    let directory = MangaDirectory(
        cleanBookName: "测试漫画七",
        strategy: .tag,
        sourceKey: "测试漫画七",
        chapters: [
            MangaChapter(tid: "980", rawTitle: "第一话", chapterNumber: 1, view: 1)
        ],
        lastUpdatedAt: Date()
    )
    try await mangaDirectoryStore.saveDirectory(directory)

    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "980": makeTestMangaReaderProjection(tid: "980", chapterTitle: "第一话")
        ])
    )
    let manualURL = try #require(URL(string: "https://img.example.com/manual-980.jpg"))
    _ = try await dependencies.contentCoverStore.setManualCover(
        manualURL,
        for: .smartManga(cleanBookName: "测试漫画七")
    )

    let owner = BlogReaderUser(uid: "42", name: "作者")
    let coverPage = ForumThreadPage(
        thread: ThreadIdentity(tid: "980", fid: "30"),
        title: "第一话",
        posts: [
            ForumThreadPost(
                postID: "p1",
                floorText: "1#",
                author: owner,
                contentHTML: "",
                contentText: "",
                images: [ForumThreadPostImage(url: "https://img.example.com/auto-980.jpg")]
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1)
    )
    let model = makeForumMangaDetailViewModel(
        dependencies: dependencies,
        threadTID: "980",
        threadCoverPageRepository: FixedPageThreadCoverPageRepository(firstPage: coverPage)
    )

    await model.reload()
    #expect(model.coverURL == manualURL)

    // Give any (incorrectly started) resolution a chance to run before
    // asserting the stored row still has no automatic URL.
    try await Task.sleep(nanoseconds: 100_000_000)
    let stored = await dependencies.contentCoverStore.cover(for: .smartManga(cleanBookName: "测试漫画七"))
    #expect(stored?.manualCoverURL == manualURL)
    #expect(stored?.automaticCoverURL == nil)
    #expect(model.coverURL == manualURL)
}

/// Live-update regression test: renaming this manga's directory from
/// elsewhere (e.g. the manga reader's own directory sheet, reachable while
/// this detail page stays open underneath it) must refresh both `directory`
/// and its derived `.smartManga` cover here too — not just on the Favorites
/// tab (`FavoriteLibraryOrganizer`'s own `MangaDirectoryStore
/// .didChangeNotification` listener). Before this listener existed, the
/// stale `cleanBookName` left `loadContentCover()` querying a cover key the
/// rename had already moved away from, so the cover (and everything else
/// derived from `directory`) never updated until some unrelated action
/// forced a full `reload()`.
@MainActor
@Test func forumMangaDetailLiveUpdatesDirectoryAndCoverWhenMangaDirectoryStoreChangesExternally() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-external-directory-change")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )

    // `lastUpdatedAt` keeps `reload()` from scheduling the fresh-tag
    // automatic update, isolating this test to the external-rename path.
    let directory = MangaDirectory(
        cleanBookName: "旧名漫画二",
        strategy: .tag,
        sourceKey: "旧名漫画二",
        chapters: [
            MangaChapter(tid: "990", rawTitle: "第一话", chapterNumber: 1, view: 1)
        ],
        lastUpdatedAt: Date()
    )
    try await mangaDirectoryStore.saveDirectory(directory)

    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [
            "990": makeTestMangaReaderProjection(tid: "990", chapterTitle: "第一话")
        ])
    )
    let model = makeForumMangaDetailViewModel(dependencies: dependencies, threadTID: "990")

    await model.reload()
    #expect(model.directory?.cleanBookName == "旧名漫画二")
    #expect(model.coverURL == nil)

    // Simulate the rename happening on a completely separate surface (the
    // reader's own directory correction sheet, or a second detail-page
    // instance), never routing through this view model's own
    // `saveCorrection`.
    var renamed = directory
    renamed.cleanBookName = "新名漫画二"
    try await mangaDirectoryStore.renameDirectory(from: directory.cleanBookName, to: renamed)
    let newCoverURL = try #require(URL(string: "https://img.example.com/renamed-cover.jpg"))
    _ = try await dependencies.contentCoverStore.setAutomaticCover(
        newCoverURL,
        for: .smartManga(cleanBookName: "新名漫画二")
    )

    // The handler updates `directory` first and resolves the cover in a
    // second await — wait on both, or a loaded machine can observe the
    // renamed directory while the cover fetch is still in flight.
    for _ in 0..<50 where model.directory?.cleanBookName != "新名漫画二" || model.coverURL != newCoverURL {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(model.directory?.cleanBookName == "新名漫画二")
    #expect(model.coverURL == newCoverURL)
}

/// Long-press "choose favorite location" feature: not-yet-favorited creates
/// with exactly the picked locations (not the default category), and the
/// add-sync prompt still applies afterward — this test disables it so the
/// add completes silently and `favorite` ends up set.
@MainActor
@Test func forumMangaDetailLocationPickerCreatesNewFavoriteWithPickedLocations() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-location-picker-add")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )
    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [:])
    )
    _ = try await dependencies.settingsStore.update { settings in
        settings.favorites.addSyncPromptEnabled = false
        settings.favorites.addSyncDefault = false
    }
    var document = try await dependencies.localFavoriteLibraryStore.load()
    let category = document.createCategory(name: "长按新建分类")
    try await dependencies.localFavoriteLibraryStore.save(document)

    let model = makeForumMangaDetailViewModel(dependencies: dependencies, threadTID: "920")

    await model.favoriteActions.presentLocationPicker()
    let context = try #require(model.favoriteActions.locationPickerContext)
    #expect(context.initialSelection.isEmpty)
    #expect(context.isFavorited == false)

    await model.favoriteActions.confirmLocationSelection([.category(category.id)])

    #expect(model.favoriteActions.locationPickerContext == nil)
    let favorite = try #require(model.favoriteActions.favorite)
    #expect(favorite.threadID == "920")
    let storedDocument = try await dependencies.localFavoriteLibraryStore.load()
    let storedItem = try #require(storedDocument.items.first { $0.target.threadID == "920" })
    #expect(storedItem.locations == [.category(category.id)])
}

/// Already-favorited: a non-empty selection re-pins locations locally (diff
/// replace, not additive) without touching Yamibo — no add/remove prompt,
/// just the "已更新收藏位置" toast.
@MainActor
@Test func forumMangaDetailLocationPickerRelocatesAlreadyFavoritedItem() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-location-picker-relocate")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )
    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [:])
    )
    let target = FavoriteItemTarget(kind: .mangaThread, threadID: "921")
    var document = try await dependencies.localFavoriteLibraryStore.load()
    let categoryA = document.createCategory(name: "分类A")
    let categoryB = document.createCategory(name: "分类B")
    document.upsertItem(try FavoriteItem(
        target: target,
        title: "已收藏漫画",
        locations: [.category(categoryA.id)]
    ))
    try await dependencies.localFavoriteLibraryStore.save(document)

    let model = makeForumMangaDetailViewModel(dependencies: dependencies, threadTID: "921")
    model.favoriteActions.favorite = Favorite(title: "已收藏漫画", threadID: "921", type: .manga)

    await model.favoriteActions.presentLocationPicker()
    let context = try #require(model.favoriteActions.locationPickerContext)
    #expect(context.initialSelection == [.category(categoryA.id)])
    #expect(context.isFavorited == true)

    await model.favoriteActions.confirmLocationSelection([.category(categoryB.id)])

    #expect(model.favoriteActions.locationPickerContext == nil)
    let storedDocument = try await dependencies.localFavoriteLibraryStore.load()
    let storedItem = try #require(storedDocument.items.first { $0.target.id == target.id })
    #expect(storedItem.locations == [.category(categoryB.id)])
    #expect(model.favoriteActions.transientMessage == L10n.string("favorites.quick.relocated"))
    #expect(model.favoriteActions.favorite != nil)
}

/// Already-favorited: clearing every checkbox is a deliberate unfavorite —
/// routed through the normal remove-sync decision, not a silent relocate to
/// an empty location set (which the domain model forbids anyway).
@MainActor
@Test func forumMangaDetailLocationPickerWithEmptySelectionRemovesFavorite() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-location-picker-remove")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let mangaDirectoryStore = try makeForumMangaDetailTestDirectoryStore(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )
    let dependencies = try makeForumMangaDetailDependencies(
        readingProgressStore: readingProgressStore,
        mangaDirectoryStore: mangaDirectoryStore,
        projectionLoader: FakeMangaReaderProjectionLoader(projectionsByTID: [:])
    )
    _ = try await dependencies.settingsStore.update { settings in
        settings.favorites.removeRemotePromptEnabled = false
        settings.favorites.removeRemoteDefault = false
    }
    let target = FavoriteItemTarget(kind: .mangaThread, threadID: "922")
    var document = try await dependencies.localFavoriteLibraryStore.load()
    let category = document.createCategory(name: "待清空分类")
    document.upsertItem(try FavoriteItem(
        target: target,
        title: "待取消收藏的漫画",
        locations: [.category(category.id)]
    ))
    try await dependencies.localFavoriteLibraryStore.save(document)

    let model = makeForumMangaDetailViewModel(dependencies: dependencies, threadTID: "922")
    model.favoriteActions.favorite = Favorite(title: "待取消收藏的漫画", threadID: "922", type: .manga)

    await model.favoriteActions.presentLocationPicker()
    #expect(model.favoriteActions.locationPickerContext != nil)

    await model.favoriteActions.confirmLocationSelection([])

    #expect(model.favoriteActions.locationPickerContext == nil)
    #expect(model.favoriteActions.removePrompt == nil)
    #expect(model.favoriteActions.favorite == nil)
    let storedItem = try await dependencies.localFavoriteLibraryStore.load().items.first { $0.target.id == target.id }
    #expect(storedItem == nil)
}

/// `MangaStoreTestSupport.swift`'s `makeTestMangaDirectoryStore` lives in the
/// `YamiboXCoreTests` target only, so this file builds its own GRDB pool
/// directly — mirroring `LocalFavoriteOpenTargetResolverTests
/// .makeMangaDirectoryStore(suiteName:)`.
private func makeForumMangaDetailTestDirectoryStore(suiteName: String) throws -> MangaDirectoryStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("forum-manga-detail-view-model-tests", isDirectory: true)
        .appendingPathComponent(suiteName, isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: root)
    return MangaDirectoryStore(databasePool: database)
}

/// Builds a `ForumDependencies` package backed by isolated per-test stores.
/// Factories for repositories this file never exercises trap loudly — the
/// manga directory is always pre-seeded so `MangaDirectoryWorkflow
/// .resolveInitialDirectory` resolves it via `store.directory(containingTID:)`
/// without ever reaching `makeMangaDirectoryRepository`. Unlike
/// `ForumNovelDetailViewModel`, `ForumMangaDetailViewModel` has no injectable
/// provider for its projection loader — it calls
/// `dependencies.makeMangaReaderProjectionLoader()` directly — so the fake
/// loader is threaded straight into that factory closure here.
@MainActor
private func makeForumMangaDetailDependencies(
    readingProgressStore: ReadingProgressStore,
    mangaDirectoryStore: MangaDirectoryStore,
    projectionLoader: FakeMangaReaderProjectionLoader,
    directoryRepository: (any MangaDirectoryRepository)? = nil,
    mangaOfflineCacheStore: (any MangaOfflineCacheStoring)? = nil
) throws -> ForumDependencies {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-detail-deps")
    let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
    let sessionStore = SessionStore(defaults: defaults, key: "session")
    let session = YamiboNetworkConfiguration.makeSession()
    @Sendable func makeClient() async -> YamiboClient {
        let sessionState = await sessionStore.load()
        return YamiboClient(
            session: session,
            cookie: sessionState.cookie,
            userAgent: sessionState.userAgent
        )
    }
    let forumCacheStore = ForumCacheStore(
        baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    )
    return ForumDependencies(
        sessionStore: sessionStore,
        profileStore: YamiboProfileStore(defaults: defaults, key: "profile"),
        localFavoriteLibraryStore: FavoriteLibraryStore(defaults: defaults, key: "local-favorites"),
        readingProgressStore: readingProgressStore,
        settingsStore: SettingsStore(defaults: defaults, key: "settings"),
        contentCoverStore: ContentCoverStore(defaults: defaults, key: "content-covers"),
        mangaDirectoryStore: mangaDirectoryStore,
        mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState(),
        mangaOfflineCacheStore: mangaOfflineCacheStore,
        makeForumRepository: { ForumRepository(client: await makeClient(), cacheStore: forumCacheStore) },
        makeForumThreadReaderRepository: { ForumThreadReaderRepository(client: await makeClient(), cacheStore: forumCacheStore) },
        makeUserSpaceRepository: { UserSpaceRepository(client: await makeClient()) },
        makeBlogReaderRepository: { BlogReaderRepository(client: await makeClient()) },
        makeFavoriteRepository: { FavoriteRepository(client: await makeClient()) },
        makeNovelReaderRepository: { fatalError("makeNovelReaderRepository is not exercised by ForumMangaDetailViewModelTests") },
        makeMangaReaderProjectionLoader: { projectionLoader },
        makeMangaDirectoryRepository: { directoryRepository ?? UnusedMangaDirectoryRepository() },
        makeThreadRouteResolver: { YamiboThreadRouteResolver(client: await makeClient()) }
    )
}

/// Always injects a thread-cover-page repository stub: the view model's
/// automatic `.smartManga` cover resolution otherwise reaches the fixture's
/// real network-backed `ForumThreadReaderRepository` in the background on
/// every `reload()`. The default stub simply resolves nothing.
@MainActor
private func makeForumMangaDetailViewModel(
    dependencies: ForumDependencies,
    threadTID: String,
    workflowConfiguration: MangaDirectoryWorkflowConfiguration = MangaDirectoryWorkflowConfiguration(),
    threadCoverPageRepository: (any ThreadCoverPageResolving)? = nil
) -> ForumMangaDetailViewModel {
    let coverPageRepository = threadCoverPageRepository ?? FixedPageThreadCoverPageRepository(firstPage: nil)
    return ForumMangaDetailViewModel(
        context: MangaDetailLaunchContext(
            thread: ThreadIdentity(tid: threadTID, fid: "30"),
            title: "测试漫画"
        ),
        dependencies: dependencies,
        workflowConfiguration: workflowConfiguration,
        makeThreadCoverPageRepository: { coverPageRepository }
    )
}

/// Serves one fixed first page (or nothing) to the automatic cover
/// resolution, standing in for the network-backed thread reader repository.
private struct FixedPageThreadCoverPageRepository: ThreadCoverPageResolving {
    let firstPage: ForumThreadPage?

    func cachedThreadPage(
        thread _: ThreadIdentity,
        title _: String,
        authorID _: String?,
        page: Int
    ) async -> ForumThreadPage? {
        page == 1 ? firstPage : nil
    }

    func fetchThreadPage(
        thread _: ThreadIdentity,
        title _: String,
        authorID _: String?,
        page _: Int
    ) async throws -> ForumThreadPage {
        throw YamiboError.parsingFailed(context: "thread cover page fetch is not exercised by ForumMangaDetailViewModelTests")
    }
}

/// Configurable stand-in for the tag/search network repository, recording
/// call counts so tests can assert which update path ran.
private final class ConfigurableMangaDirectoryRepository: MangaDirectoryRepository, @unchecked Sendable {
    private let lock = NSLock()
    private let seed: MangaDirectorySeed?
    private let tagDirectoryResults: [MangaChapter]
    private let searchResults: [MangaChapter]
    private var _tagDirectoryCallCount = 0
    private var _searchCallCount = 0
    private var _seedCallCount = 0

    init(seed: MangaDirectorySeed? = nil, tagDirectoryResults: [MangaChapter] = [], searchResults: [MangaChapter] = []) {
        self.seed = seed
        self.tagDirectoryResults = tagDirectoryResults
        self.searchResults = searchResults
    }

    var tagDirectoryCallCount: Int {
        lock.withLock { _tagDirectoryCallCount }
    }

    var searchCallCount: Int {
        lock.withLock { _searchCallCount }
    }

    var seedCallCount: Int {
        lock.withLock { _seedCallCount }
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        guard let seed else {
            fatalError("loadDirectorySeed is not exercised by ForumMangaDetailViewModelTests")
        }
        lock.withLock { _seedCallCount += 1 }
        return seed
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        lock.withLock { _tagDirectoryCallCount += 1 }
        return tagDirectoryResults
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        lock.withLock { _searchCallCount += 1 }
        return searchResults
    }
}

/// Records offline-cache owner renames issued by the correction flow; every
/// other requirement either returns an empty value or traps because the flow
/// under test never reaches it.
private final class RenameRecordingMangaOfflineCacheStore: MangaOfflineCacheStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _recordedRenames: [(from: String, to: String)] = []

    var recordedRenames: [(from: String, to: String)] {
        lock.withLock { _recordedRenames }
    }

    func renameMangaOfflineCacheOwner(from oldOwnerName: String, to newOwnerName: String) async throws {
        lock.withLock { _recordedRenames.append((from: oldOwnerName, to: newOwnerName)) }
    }

    func offlineCacheUpdates() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }

    func offlineImageData(for imageURL: URL) async -> Data? { nil }

    func saveOfflineImageData(_ data: Data, for imageURL: URL) async throws {}

    func mangaOfflineCacheMembership(ownerName: String, tid: String) async -> MangaOfflineCacheMembership? { nil }

    func mangaOfflineCacheMemberships(forOwnerName ownerName: String) async -> [MangaOfflineCacheMembership] { [] }

    func allMangaOfflineCacheMemberships() async -> [MangaOfflineCacheMembership] { [] }

    func saveMangaOfflineCacheMembership(_ membership: MangaOfflineCacheMembership) async throws {}

    func removeMangaOfflineCacheMembership(ownerName: String, tid: String) async throws {}

    func removeMangaOfflineCacheMemberships(forOwnerName ownerName: String) async throws {}

    func mangaOfflineCacheDiskUsageByOwner() async -> [MangaOfflineCacheOwnerUsage] { [] }

    func enqueueMangaOfflineCacheWork(_ request: MangaOfflineCacheWorkRequest) async throws -> MangaOfflineCacheEnqueueResult {
        fatalError("enqueueMangaOfflineCacheWork is not exercised by ForumMangaDetailViewModelTests")
    }

    func mangaOfflineCacheState(ownerName: String, tid: String) async -> MangaOfflineCacheState {
        fatalError("mangaOfflineCacheState is not exercised by ForumMangaDetailViewModelTests")
    }
}

private func makeTestMangaReaderProjection(tid: String, chapterTitle: String) -> MangaReaderProjection {
    MangaReaderProjection(
        tid: tid,
        ownerAuthorID: "42",
        chapterTitle: chapterTitle,
        imageURLs: [URL(string: "https://img.example.com/\(tid)/1.jpg")!]
    )
}

/// Never actually invoked: every test here pre-seeds a real `MangaDirectory`
/// covering the tid it uses, so `MangaDirectoryWorkflow.resolveInitialDirectory`
/// always resolves via `store.directory(containingTID:)` before it would ever
/// fall back to a repository call. Tests using this stub must also seed
/// `lastUpdatedAt` on tag directories — a fresh tag directory (`nil`) makes
/// `reload()` schedule an automatic update that would reach
/// `loadTagDirectory` and trap.
private struct UnusedMangaDirectoryRepository: MangaDirectoryRepository {
    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        fatalError("loadDirectorySeed is not exercised by ForumMangaDetailViewModelTests")
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        fatalError("loadTagDirectory is not exercised by ForumMangaDetailViewModelTests")
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        fatalError("searchDirectory is not exercised by ForumMangaDetailViewModelTests")
    }
}

private final class FakeMangaReaderProjectionLoader: MangaReaderProjectionSnapshotLoading, @unchecked Sendable {
    private let projectionsByTID: [String: MangaReaderProjection]

    init(projectionsByTID: [String: MangaReaderProjection]) {
        self.projectionsByTID = projectionsByTID
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        guard let projection = projectionsByTID[request.threadID] else {
            throw FakeMangaReaderProjectionLoaderError.missingProjection(tid: request.threadID)
        }
        return projection
    }

    func loadReaderProjectionSnapshot(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjectionSnapshot {
        fatalError("loadReaderProjectionSnapshot is not exercised by ForumMangaDetailViewModelTests")
    }
}

private enum FakeMangaReaderProjectionLoaderError: Error {
    case missingProjection(tid: String)
}

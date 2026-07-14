import Foundation
import Testing
@testable import YamiboXCore

@Test func localFavoriteProjectionFiltersBySourceGroupForThreadNovelAndUnknown() throws {
    let (document, items) = try makeProjectionDocument()

    let forumCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(selectedSourceFilters: [.forumBoard(id: "fid-1", label: "版块A")])
    )
    let unknownCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(selectedSourceFilters: [.unknown])
    )

    #expect(Set(forumCards.map(\.id)) == [items.normal.id, items.novel.id])
    // No dedicated "智能漫画" filter bucket anymore (the filter chip was
    // removed): `items.manga` carries no forumID/forumName (only a
    // `.smartManga` sourceGroup label), so it now falls back to `.unknown`
    // like any other item with no real forum board.
    #expect(Set(unknownCards.map(\.id)) == [items.manga.id, items.unknown.id])
}

@Test func localFavoriteProjectionSortsForumGroupsByExplicitForumName() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id
    let first = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "711"),
        title: "第一条",
        sourceGroup: .forumBoard(id: "10", label: "旧标签Z"),
        forumName: "版块A",
        locations: [.category(categoryID)]
    )
    let second = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "712"),
        title: "第二条",
        sourceGroup: .forumBoard(id: "20", label: "旧标签A"),
        forumName: "版块B",
        locations: [.category(categoryID)]
    )
    document.upsertItem(second)
    document.upsertItem(first)

    let cards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(sortOrder: .sourceGroup)
    )

    #expect(cards.map(\.id) == [first.id, second.id])
    #expect(cards.map(\.item.forumName) == ["版块A", "版块B"])
}

@Test func localFavoriteProjectionMatchesForumSourceFilterByForumID() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id
    let current = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "713"),
        title: "当前版名",
        sourceGroup: .forumBoard(id: "30", label: "新版名"),
        locations: [.category(categoryID)]
    )
    let legacy = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "714"),
        title: "旧版名",
        sourceGroup: .forumBoard(id: "30", label: "旧版名"),
        locations: [.category(categoryID)]
    )
    document.upsertItem(current)
    document.upsertItem(legacy)

    let cards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(selectedSourceFilters: [.forumBoard(id: "30", label: "新版名")])
    )

    #expect(Set(cards.map(\.id)) == [current.id, legacy.id])
}

@Test func localFavoriteSourceFilterKeyBucketsMangaThreadFavoritesByForumBoard() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id
    let item = try FavoriteItem(
        target: .mangaThread(threadID: "821"),
        title: "第1话",
        sourceGroup: .forumBoard(id: "46", label: "闭板漫画区"),
        forumID: "46",
        forumName: "闭板漫画区",
        locations: [.category(categoryID)]
    )
    document.upsertItem(item)

    // No dedicated "智能漫画" filter bucket anymore — a `.mangaThread`
    // favorite always buckets by its real forum board, regardless of that
    // board's Smart Comic Mode state.
    #expect(LocalFavoriteSourceFilter.key(for: item) == .forumBoard(id: "46", label: "闭板漫画区"))
}

// 兜底一条规则 (pluggable-reader-config decision #4): a `.mangaThread`
// favorite with no forumID at all can never match a smart-enabled board, so
// it behaves exactly like a plain unknown-source favorite — it never joins a
// merged group (even when a locally resolved directory covers its tid), its
// source-filter bucket is `.unknown`, and its card gets no smart treatment.
@Test func localFavoriteProjectionTreatsMissingForumIDMangaThreadFavoritesAsPlainUnknownFavorites() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id

    let directory = MangaDirectory(
        cleanBookName: "无板块漫画",
        strategy: .links,
        sourceKey: "chapter:861",
        chapters: [
            MangaChapter(tid: "861", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "862", rawTitle: "第2话", chapterNumber: 2),
        ]
    )
    let firstRawTitle = "【作者】无板块漫画 第1话"
    let first = try FavoriteItem(
        target: .mangaThread(threadID: "861"),
        title: firstRawTitle,
        locations: [.category(categoryID)]
    )
    let second = try FavoriteItem(
        target: .mangaThread(threadID: "862"),
        title: "【作者】无板块漫画 第2话",
        locations: [.category(categoryID)]
    )
    document.upsertItem(first)
    document.upsertItem(second)

    let settings = BoardReaderSettings()

    #expect(LocalFavoriteSourceFilter.key(for: first) == .unknown)
    #expect(LocalFavoriteSourceFilter.key(for: second) == .unknown)

    let cards = LocalFavoriteLibraryProjection.cards(
        in: document,
        mangaDirectoriesByTID: ["861": directory, "862": directory],
        boardReaderSettings: settings
    )

    #expect(Set(cards.map(\.id)) == [first.id, second.id])
    #expect(cards.allSatisfy { $0.mangaDirectory == nil && !$0.isMergedGroup })
    #expect(cards.allSatisfy { !$0.isModeOnMangaThread })
    // Raw post title, no local `MangaTitleCleaner` cleanup — the smart-card
    // title fallback only ever applies to mode-on favorites.
    let firstCard = try #require(cards.first { $0.id == first.id })
    #expect(firstCard.resolvedTitle == firstRawTitle)
}

// Progress keys are kind-prefixed while the reader a favorite opens with
// follows the board's current configuration (R11) — the card's progress
// display must look up the effective kind's record first (a stored-normal
// favorite read via the novel reader records under `thread:novel:<tid>`),
// falling back to the stored identity's own record for reads that predate
// the configuration change.
@Test func localFavoriteProjectionResolvesProgressByEffectiveKindWithStoredFallback() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id
    let item = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "801"),
        title: "配置前收藏的小说",
        sourceGroup: .forumBoard(id: "40", label: "小说板块"),
        forumID: "40",
        locations: [.category(categoryID)]
    )
    document.upsertItem(item)

    var boardReader = BoardReaderSettings(entries: [:])
    boardReader.setEntry(.init(mode: .novel), forumID: "40")

    let novelProgress = ReadingProgressRecord(
        contentTarget: .novelThread(threadID: "801"),
        threadID: "801",
        kind: .novel,
        updatedAt: Date(timeIntervalSince1970: 100),
        lastReadAt: Date(timeIntervalSince1970: 200),
        novel: NovelReadingProgressRecord(novelDocumentSurfaceProgressPercent: 40)
    )
    let effectiveCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        readingProgress: [novelProgress],
        boardReaderSettings: boardReader
    )
    let effectiveCard = try #require(effectiveCards.first { $0.id == item.id })
    #expect(effectiveCard.recentReadingAt == Date(timeIntervalSince1970: 200))
    #expect(effectiveCard.progressPercent == 40)

    // Only a pre-change record under the stored identity: still shown.
    let storedProgress = ReadingProgressRecord(
        contentTarget: .normalThread(threadID: "801"),
        threadID: "801",
        kind: .novel,
        updatedAt: Date(timeIntervalSince1970: 50),
        lastReadAt: Date(timeIntervalSince1970: 60),
        novel: NovelReadingProgressRecord(novelDocumentSurfaceProgressPercent: 10)
    )
    let fallbackCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        readingProgress: [storedProgress],
        boardReaderSettings: boardReader
    )
    let fallbackCard = try #require(fallbackCards.first { $0.id == item.id })
    #expect(fallbackCard.recentReadingAt == Date(timeIntervalSince1970: 60))

    // Both present: the effective kind's record wins.
    let bothCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        readingProgress: [storedProgress, novelProgress],
        boardReaderSettings: boardReader
    )
    let bothCard = try #require(bothCards.first { $0.id == item.id })
    #expect(bothCard.recentReadingAt == Date(timeIntervalSince1970: 200))
}

@Test func localFavoriteProjectionSearchesAllowedFieldsOnly() throws {
    let (document, items) = try makeProjectionDocument()

    let displayName = LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(searchText: "本地名"))
    let title = LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(searchText: "小说"))
    let sourceGroup = LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(searchText: "版块A"))
    let collection = LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(searchText: "合集A"))
    let rawURL = LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(searchText: "tid=701"))
    let remoteID = LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(searchText: "remote-701"))

    #expect(displayName.map(\.id) == [items.normal.id])
    #expect(title.map(\.id) == [items.novel.id])
    #expect(Set(sourceGroup.map(\.id)) == [items.normal.id, items.novel.id])
    #expect(collection.isEmpty)
    #expect(rawURL.isEmpty)
    #expect(remoteID.isEmpty)
}

@Test func localFavoriteProjectionSupportsExpectedSortModesWithoutProgressSort() throws {
    let (document, items) = try makeProjectionDocument()
    // `items.normal.target`/`items.novel.target` are `FavoriteItemTarget`
    // values now (favorites-side type); `ReadingProgressRecord.contentTarget`
    // is the separate reading-progress-side `FavoriteContentTarget` type
    // (smart-comic-mode design decision #9's second correction), so these
    // are rebuilt directly rather than reused — the id format is identical
    // for `.normalThread`/`.novelThread` on both types.
    let progress = [
        ReadingProgressRecord(
            contentTarget: .normalThread(threadID: "701"),
            threadID: "701",
            kind: .novel,
            updatedAt: Date(timeIntervalSince1970: 10),
            lastReadAt: Date(timeIntervalSince1970: 30),
            novel: NovelReadingProgressRecord(novelDocumentSurfaceProgressPercent: 30)
        ),
        ReadingProgressRecord(
            contentTarget: .novelThread(threadID: "702"),
            threadID: "702",
            kind: .novel,
            updatedAt: Date(timeIntervalSince1970: 20),
            lastReadAt: Date(timeIntervalSince1970: 20),
            novel: NovelReadingProgressRecord(novelDocumentSurfaceProgressPercent: 80)
        )
    ]

    #expect(LocalFavoriteLibraryProjection.supportedSortOrders == [.organization, .contentUpdatedAt, .yamiboRemoteOrder, .displayTitle, .sourceGroup, .lastReadAt])
    #expect(LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(sortOrder: .organization)).map(\.id).prefix(2) == [items.novel.id, items.normal.id])
    // .contentUpdatedAt's default (ascending/not-descending) direction is
    // newest-first — see the `compareDates` doc comment — so 300/200/100
    // orders as manga/novel/normal, not the calendar-ascending 100/200/300.
    #expect(LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(sortOrder: .contentUpdatedAt)).map(\.id).prefix(3) == [items.manga.id, items.novel.id, items.normal.id])
    #expect(LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(sortOrder: .yamiboRemoteOrder)).map(\.id).prefix(2) == [items.novel.id, items.normal.id])
    #expect(LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(sortOrder: .displayTitle, sortsDescending: true)).map(\.id).first == items.novel.id)
    // Same inverted direction for .lastReadAt: default (not descending) is
    // newest-first, so normal@30 sorts ahead of novel@20.
    #expect(LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(sortOrder: .lastReadAt), readingProgress: progress).map(\.id).prefix(2) == [items.normal.id, items.novel.id])
    // Undated items (manga/unknown, no progress record) stay last even in
    // descending order; the two read items keep the correct oldest-first
    // relative order (novel@20 before normal@30) at the front, since
    // descending now means oldest-first for this recency key.
    #expect(LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(sortOrder: .lastReadAt, sortsDescending: true), readingProgress: progress).map(\.id).prefix(2) == [items.novel.id, items.normal.id])
}

@Test func localFavoriteProjectionBuildsCardMetadataFromReadingProgressWithoutMutatingItems() throws {
    let (document, items) = try makeProjectionDocument()
    // `.mangaThread(threadID:)` is deliberately formatted with the same id
    // on both the favorites-side `FavoriteItemTarget` (items.manga.target)
    // and this reading-progress-side `FavoriteContentTarget`, so the direct
    // id lookup (`progressKey(for:)`) finds this record without any
    // cleanBookName fallback (smart-comic-mode design decision #15).
    let mangaProgress = ReadingProgressRecord(
        contentTarget: .mangaThread(threadID: "703"),
        threadID: "703",
        kind: .manga,
        updatedAt: Date(timeIntervalSince1970: 50),
        lastReadAt: Date(timeIntervalSince1970: 60),
        manga: MangaReadingProgressRecord(
            chapterThreadID: "703",
            lastChapter: "第3话",
            mangaPageIndex: 4,
            mangaPageCount: 10
        )
    )

    let cards = LocalFavoriteLibraryProjection.cards(in: document, readingProgress: [mangaProgress])
    let mangaCard = try #require(cards.first { $0.id == items.manga.id })

    #expect(mangaCard.recentReadingAt == Date(timeIntervalSince1970: 60))
    #expect(mangaCard.lastUpdatedAt == Date(timeIntervalSince1970: 300))
    #expect(mangaCard.progressPercent == 50)
    #expect(mangaCard.chapterPageProgress == L10n.string("favorites.progress.manga_page_total", "第3话", 5, 10))
    #expect(mangaCard.chapterPageProgress != nil)
    // Items carry no cover of their own; the library derivation fills card
    // covers from ContentCoverStore.
    #expect(mangaCard.coverURL == nil)
}

@Test func localFavoriteProjectionMergesModeOnMangaThreadFavoritesSharingADirectory() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id
    let collection = document.createCollection(categoryID: categoryID, name: "追番")

    let directory = MangaDirectory(
        cleanBookName: "测试漫画",
        strategy: .links,
        sourceKey: "chapter:801",
        chapters: [
            MangaChapter(tid: "801", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "802", rawTitle: "第2话", chapterNumber: 2),
        ]
    )

    let firstChapterFavorite = try FavoriteItem(
        target: .mangaThread(threadID: "801"),
        title: "第1话",
        forumID: "30",
        locations: [.category(categoryID)]
    )
    let secondChapterFavorite = try FavoriteItem(
        target: .mangaThread(threadID: "802"),
        title: "第2话",
        forumID: "30",
        locations: [.collection(categoryID: categoryID, collectionID: collection.id)]
    )
    document.upsertItem(firstChapterFavorite)
    document.upsertItem(secondChapterFavorite)

    let mangaDirectoriesByTID = ["801": directory, "802": directory]
    // Board 30 is mode-on by `BoardReaderSettings`'s own default.
    let settings = BoardReaderSettings()

    let categoryCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(categoryID: categoryID),
        mangaDirectoriesByTID: mangaDirectoriesByTID,
        boardReaderSettings: settings
    )
    // Decision #5: the merged card appears in the category view even though
    // only one of its two members has that location directly — the union.
    #expect(categoryCards.count == 1)
    let mergedCard = try #require(categoryCards.first)
    #expect(mergedCard.mangaDirectory?.cleanBookName == "测试漫画")
    #expect(mergedCard.isMergedGroup)
    #expect(mergedCard.mergedMembers?.map(\.target.threadID) == ["801", "802"])
    // Earliest chapter (801) is the representative.
    #expect(mergedCard.item.target.threadID == "801")
    // The card's id is deliberately still the representative (earliest-
    // chapter) member's own real id, not a synthetic directory-based one —
    // see `FavoriteCardProjection.id`'s doc comment for why.
    #expect(mergedCard.id == firstChapterFavorite.id)

    let collectionCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(categoryID: categoryID, collectionID: collection.id),
        mangaDirectoriesByTID: mangaDirectoriesByTID,
        boardReaderSettings: settings
    )
    // Same merged card also surfaces in the collection view (the other
    // member's own location) — same stable id as the category view's card.
    #expect(collectionCards.map(\.id) == [mergedCard.id])
}

/// `LocalFavoriteLibraryQuery.memberScopeCleanBookName` must replace, not
/// combine with, the normal category/collection membership filter — a
/// member resolved to the scoped directory has to show up on the "查看归档
/// 收藏" detail page even when its own location doesn't match the query's
/// `categoryID` at all. Regular (non-merged) category filtering can't stand
/// in for this: once merged, a card's representative location is already
/// the *union* of every member's own locations (proven above), so a naive
/// reimplementation that forgot to actually bypass the category filter for
/// member-scoped entries (which are standalone, each keeping only its own
/// location — see `cards(in:query:...)`'s `isMemberScoped` branch) could
/// still pass a same-category fixture by accident. This test only proves
/// the bypass by putting one member in a category the query never selects.
@Test func localFavoriteMemberScopeQueryBypassesCategoryFilterToShowEveryResolvedMember() throws {
    var document = FavoriteLibraryDocument()
    let defaultCategoryID = document.defaultCategory.id
    let otherCategory = document.createCategory(name: "其他分类")

    let directory = MangaDirectory(
        cleanBookName: "范围测试漫画",
        strategy: .links,
        sourceKey: "chapter:811",
        chapters: [
            MangaChapter(tid: "811", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "812", rawTitle: "第2话", chapterNumber: 2),
        ]
    )

    let firstChapterFavorite = try FavoriteItem(
        target: .mangaThread(threadID: "811"),
        title: "第1话",
        forumID: "30",
        locations: [.category(defaultCategoryID)]
    )
    // Deliberately *not* in `defaultCategoryID` at all — only a plain
    // category filter (no member scoping) would drop this one.
    let secondChapterFavorite = try FavoriteItem(
        target: .mangaThread(threadID: "812"),
        title: "第2话",
        forumID: "30",
        locations: [.category(otherCategory.id)]
    )
    document.upsertItem(firstChapterFavorite)
    document.upsertItem(secondChapterFavorite)

    let mangaDirectoriesByTID = ["811": directory, "812": directory]
    // Board 30 is mode-on by `BoardReaderSettings`'s own default.
    let settings = BoardReaderSettings()

    // Sanity check: without member scoping, the merged card still only
    // resolves under the query's `categoryID` via the representative's own
    // *unioned* location (decision #5) — this alone wouldn't catch a
    // member-scope regression, which is exactly why the assertions below
    // key off two genuinely standalone cards instead.
    let mergedCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(categoryID: defaultCategoryID),
        mangaDirectoriesByTID: mangaDirectoriesByTID,
        boardReaderSettings: settings
    )
    #expect(mergedCards.count == 1)
    #expect(mergedCards.first?.isMergedGroup == true)

    let memberScopedCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(categoryID: defaultCategoryID, memberScopeCleanBookName: directory.cleanBookName),
        mangaDirectoriesByTID: mangaDirectoriesByTID,
        boardReaderSettings: settings
    )
    // Both members show up — including the one whose own location is
    // `otherCategory`, not the query's `categoryID` — because member
    // scoping bypasses category/collection filtering entirely.
    #expect(Set(memberScopedCards.map(\.item.target.threadID)) == ["811", "812"])
    #expect(memberScopedCards.allSatisfy { !$0.isMergedGroup })
    #expect(memberScopedCards.allSatisfy { $0.mangaDirectory == nil })
    #expect(memberScopedCards.allSatisfy { $0.mergedMembers == nil })
}

/// The actual fix: `memberScopeCleanBookName` matching must key off
/// `FavoriteCardProjection.resolvedTitle` — the SAME effective title used
/// for display and smart-card gating — not require an actually-resolved
/// `MangaDirectory`. Two mode-on favorites that have never been opened in
/// the reader (so neither has a `mangaDirectoriesByTID` entry) must still
/// group together on the "查看归档收藏" detail page whenever their
/// independently-computed local-clean guesses happen to match, and a
/// solitary favorite whose guess matches no one else's must still open its
/// own single-item "singleton archive" page with no special-casing.
@Test func localFavoriteMemberScopeQueryMatchesUnresolvedModeOnFavoritesSharingTheSameLocalCleanGuess() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id

    let firstChapter = try FavoriteItem(
        target: .mangaThread(threadID: "841"),
        title: "【作者】作品 第1话",
        forumID: "30",
        locations: [.category(categoryID)]
    )
    let secondChapter = try FavoriteItem(
        target: .mangaThread(threadID: "842"),
        title: "【作者】作品 第2话",
        forumID: "30",
        locations: [.category(categoryID)]
    )
    let solitaryFavorite = try FavoriteItem(
        target: .mangaThread(threadID: "843"),
        title: "【作者】孤本 第1话",
        forumID: "30",
        locations: [.category(categoryID)]
    )
    document.upsertItem(firstChapter)
    document.upsertItem(secondChapter)
    document.upsertItem(solitaryFavorite)

    // Board 30 is mode-on by `BoardReaderSettings`'s own default; none of
    // these tids have ever been resolved to a `MangaDirectory` yet (empty
    // `mangaDirectoriesByTID`), mirroring synced-but-never-opened favorites.
    let settings = BoardReaderSettings()

    let sharedGuessCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(categoryID: categoryID, memberScopeCleanBookName: "作品"),
        boardReaderSettings: settings
    )
    #expect(Set(sharedGuessCards.map(\.item.target.threadID)) == ["841", "842"])
    #expect(sharedGuessCards.allSatisfy { $0.mangaDirectory == nil })
    #expect(sharedGuessCards.allSatisfy { $0.mergedMembers == nil })
    // The *matching* that put these two cards in this scope still keys off
    // the shared local-clean guess ("作品") — that's `Set(...threadID) ==
    // ["841", "842"]` above. But once matched, each resulting card is
    // deliberately de-smart-ified (`isModeOnMangaThread` forced `false` —
    // see `cards(in:query:...)`'s member-scope card-building comment): it
    // must show ITS OWN raw title, not the shared cleaned guess, so the
    // archive page displays two distinguishable posts rather than two
    // copies of the same collapsed "作品" card (the actual regression this
    // fix addresses).
    #expect(sharedGuessCards.allSatisfy { !$0.isModeOnMangaThread })
    #expect(sharedGuessCards.allSatisfy { $0.resolvedTitle != "作品" })
    let firstCard = try #require(sharedGuessCards.first { $0.item.target.threadID == "841" })
    let secondCard = try #require(sharedGuessCards.first { $0.item.target.threadID == "842" })
    #expect(firstCard.resolvedTitle == "【作者】作品 第1话")
    #expect(secondCard.resolvedTitle == "【作者】作品 第2话")
    #expect(firstCard.resolvedTitle != secondCard.resolvedTitle)

    let solitaryCards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(categoryID: categoryID, memberScopeCleanBookName: "孤本"),
        boardReaderSettings: settings
    )
    #expect(solitaryCards.map(\.item.target.threadID) == ["843"])
}

@Test func localFavoriteProjectionKeepsModeOffMangaThreadFavoritesStandaloneEvenWithAResolvedDirectory() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id

    let directory = MangaDirectory(
        cleanBookName: "关闭板块漫画",
        strategy: .links,
        sourceKey: "chapter:811",
        chapters: [
            MangaChapter(tid: "811", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "812", rawTitle: "第2话", chapterNumber: 2),
        ]
    )
    let first = try FavoriteItem(
        target: .mangaThread(threadID: "811"),
        title: "第1话",
        forumID: "46",
        locations: [.category(categoryID)]
    )
    let second = try FavoriteItem(
        target: .mangaThread(threadID: "812"),
        title: "第2话",
        forumID: "46",
        locations: [.category(categoryID)]
    )
    document.upsertItem(first)
    document.upsertItem(second)

    // fid 46 is off by `BoardReaderSettings`'s own default — the
    // directory resolves locally (e.g. leftover from when the board used to
    // be on), but decision #5's addendum says mode-off favorites never merge.
    let cards = LocalFavoriteLibraryProjection.cards(
        in: document,
        mangaDirectoriesByTID: ["811": directory, "812": directory],
        boardReaderSettings: BoardReaderSettings()
    )

    #expect(Set(cards.map(\.id)) == [first.id, second.id])
    #expect(cards.allSatisfy { $0.mangaDirectory == nil && !$0.isMergedGroup })
}

@Test func localFavoriteProjectionUsesDirectoryLevelProgressForMergedAndLoneResolvedCards() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id

    let mergedDirectory = MangaDirectory(
        cleanBookName: "合并进度漫画",
        strategy: .links,
        sourceKey: "chapter:821",
        chapters: [
            MangaChapter(tid: "821", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "822", rawTitle: "第2话", chapterNumber: 2),
        ]
    )
    let firstMember = try FavoriteItem(target: .mangaThread(threadID: "821"), title: "第1话", forumID: "30", locations: [.category(categoryID)])
    let secondMember = try FavoriteItem(target: .mangaThread(threadID: "822"), title: "第2话", forumID: "30", locations: [.category(categoryID)])
    document.upsertItem(firstMember)
    document.upsertItem(secondMember)

    let loneDirectory = MangaDirectory(
        cleanBookName: "单独进度漫画",
        strategy: .links,
        sourceKey: "chapter:831",
        chapters: [MangaChapter(tid: "831", rawTitle: "第1话", chapterNumber: 1)]
    )
    let loneMember = try FavoriteItem(target: .mangaThread(threadID: "831"), title: "第1话", forumID: "30", locations: [.category(categoryID)])
    document.upsertItem(loneMember)

    // The merged card's own representative (821)'s per-thread progress is a
    // stale earlier page; the directory-level record is the manga's actual
    // current position and must win.
    let staleOwnThreadProgress = ReadingProgressRecord(
        contentTarget: .mangaThread(threadID: "821"),
        threadID: "821",
        kind: .manga,
        updatedAt: Date(timeIntervalSince1970: 10),
        manga: MangaReadingProgressRecord(chapterThreadID: "821", lastChapter: "第1话", mangaPageIndex: 0, mangaPageCount: 10)
    )
    let directoryLevelProgress = ReadingProgressRecord(
        contentTarget: FavoriteContentTarget(mangaID: mergedDirectory.favoriteIdentity, mangaCleanBookName: mergedDirectory.cleanBookName),
        threadID: "822",
        kind: .manga,
        updatedAt: Date(timeIntervalSince1970: 20),
        manga: MangaReadingProgressRecord(chapterThreadID: "822", lastChapter: "第2话", mangaPageIndex: 9, mangaPageCount: 10)
    )
    let loneDirectoryLevelProgress = ReadingProgressRecord(
        contentTarget: FavoriteContentTarget(mangaID: loneDirectory.favoriteIdentity, mangaCleanBookName: loneDirectory.cleanBookName),
        threadID: "831",
        kind: .manga,
        updatedAt: Date(timeIntervalSince1970: 30),
        manga: MangaReadingProgressRecord(chapterThreadID: "831", lastChapter: "第1话", mangaPageIndex: 4, mangaPageCount: 5)
    )

    let cards = LocalFavoriteLibraryProjection.cards(
        in: document,
        readingProgress: [staleOwnThreadProgress, directoryLevelProgress, loneDirectoryLevelProgress],
        mangaDirectoriesByTID: [
            "821": mergedDirectory, "822": mergedDirectory,
            "831": loneDirectory,
        ],
        boardReaderSettings: BoardReaderSettings()
    )

    let mergedCard = try #require(cards.first { $0.mangaDirectory?.cleanBookName == "合并进度漫画" })
    #expect(mergedCard.progressPercent == 100)
    #expect(mergedCard.chapterPageProgress == L10n.string("favorites.progress.manga_page_total", "第2话", 10, 10))

    // A lone resolved-directory favorite (no sibling yet) still prefers its
    // directory-level record over its own per-thread progress.
    let loneCard = try #require(cards.first { $0.mangaDirectory?.cleanBookName == "单独进度漫画" })
    #expect(loneCard.mergedMembers == nil)
    #expect(loneCard.progressPercent == 100)
    #expect(loneCard.chapterPageProgress == L10n.string("favorites.progress.manga_page_total", "第1话", 5, 5))
}

@Test func localFavoriteCardResolvedTitlePrefersDirectoryCleanBookNameOverItemTitle() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id

    let directory = MangaDirectory(
        cleanBookName: "标题解析漫画",
        strategy: .links,
        sourceKey: "chapter:901",
        chapters: [MangaChapter(tid: "901", rawTitle: "第1话", chapterNumber: 1)]
    )
    let mangaFavorite = try FavoriteItem(
        target: .mangaThread(threadID: "901"),
        title: "第1话",
        forumID: "30",
        locations: [.category(categoryID)]
    )
    let plainFavorite = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "902"),
        title: "普通主题标题",
        locations: [.category(categoryID)]
    )
    document.upsertItem(mangaFavorite)
    document.upsertItem(plainFavorite)

    let cards = LocalFavoriteLibraryProjection.cards(
        in: document,
        mangaDirectoriesByTID: ["901": directory],
        boardReaderSettings: BoardReaderSettings()
    )

    // A resolved directory (even a lone one, not yet merged with any
    // sibling) wins over the representative member's own post title.
    let resolvedCard = try #require(cards.first { $0.id == mangaFavorite.id })
    #expect(resolvedCard.mangaDirectory?.cleanBookName == "标题解析漫画")
    #expect(resolvedCard.resolvedTitle == "标题解析漫画")
    #expect(resolvedCard.resolvedTitle != mangaFavorite.resolvedDisplayTitle)

    // No resolved directory: falls back to the item's own title, unchanged.
    let unresolvedCard = try #require(cards.first { $0.id == plainFavorite.id })
    #expect(unresolvedCard.mangaDirectory == nil)
    #expect(unresolvedCard.resolvedTitle == plainFavorite.resolvedDisplayTitle)
}

@Test func localFavoriteCardResolvedTitleLocallyCleansUnresolvedModeOnMangaThreadFavoriteTitle() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id

    // Mode-on board (fid 30 is on by `BoardReaderSettings`'s own
    // default) that has never actually been opened in the reader yet, so
    // it has no resolved `MangaDirectory` of its own -- `mangaDirectoriesByTID`
    // below only has an entry for an unrelated tid, mirroring a real
    // library where some *other* manga favorite has already been read
    // while this one has only been synced/starred.
    let rawTitle = "【作者】作品 第12话"
    let unresolvedModeOnFavorite = try FavoriteItem(
        target: .mangaThread(threadID: "930"),
        title: rawTitle,
        forumID: "30",
        locations: [.category(categoryID)]
    )
    // Mode-off board (fid 46 is off by default): must keep showing its raw,
    // unclean title even though it's also an unresolved `.mangaThread`
    // favorite -- regression guard for the earlier mode-off fix.
    let unresolvedModeOffFavorite = try FavoriteItem(
        target: .mangaThread(threadID: "931"),
        title: rawTitle,
        forumID: "46",
        locations: [.category(categoryID)]
    )
    document.upsertItem(unresolvedModeOnFavorite)
    document.upsertItem(unresolvedModeOffFavorite)

    let unrelatedDirectory = MangaDirectory(
        cleanBookName: "无关漫画",
        strategy: .links,
        sourceKey: "chapter:999",
        chapters: [MangaChapter(tid: "999", rawTitle: "第1话", chapterNumber: 1)]
    )

    let cards = LocalFavoriteLibraryProjection.cards(
        in: document,
        mangaDirectoriesByTID: ["999": unrelatedDirectory],
        boardReaderSettings: BoardReaderSettings()
    )

    // Mode-on, unresolved: falls back to a local `MangaTitleCleaner`
    // cleanup of the item's own title, not the raw post title and not
    // some unrelated directory's book name.
    let modeOnCard = try #require(cards.first { $0.id == unresolvedModeOnFavorite.id })
    #expect(modeOnCard.mangaDirectory == nil)
    #expect(modeOnCard.resolvedTitle == MangaTitleCleaner.cleanBookName(rawTitle))
    #expect(modeOnCard.resolvedTitle == "作品")
    #expect(modeOnCard.resolvedTitle != rawTitle)
    #expect(modeOnCard.resolvedTitle != "无关漫画")

    // Mode-off, unresolved: still the raw, unclean title.
    let modeOffCard = try #require(cards.first { $0.id == unresolvedModeOffFavorite.id })
    #expect(modeOffCard.mangaDirectory == nil)
    #expect(modeOffCard.resolvedTitle == rawTitle)
    #expect(modeOffCard.resolvedTitle == modeOffCard.item.resolvedDisplayTitle)
}

@Test func localFavoriteMixedEntriesKeepsCollectionsPinnedInOrganizationOrder() throws {
    let (document, _, collection) = try makeMixedEntryDocument()
    let cards = LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(sortOrder: .organization))

    let entries = LocalFavoriteLibraryProjection.mixedEntries(
        cards: cards,
        collections: [collection],
        // A summary that would sort the collection dead last under any of
        // the auto criteria — proves organization mode ignores it entirely.
        collectionSummaries: [collection.id: FavoriteCollectionSortSummary(minRemoteOrder: 999)],
        sortOrder: .organization,
        descending: false
    )

    #expect(entries.first?.id == "collection-\(collection.id)")
    #expect(Array(entries.dropFirst()).map(\.id) == cards.map { "item-\($0.id)" })
}

@Test func localFavoriteMixedEntriesInterleavesCollectionsWithCardsOutsideOrganizationOrder() throws {
    let (document, items, collection) = try makeMixedEntryDocument()
    let cards = LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(sortOrder: .displayTitle))

    let entries = LocalFavoriteLibraryProjection.mixedEntries(
        cards: cards,
        collections: [collection],
        collectionSummaries: [:],
        sortOrder: .displayTitle,
        descending: false
    )

    // Collection name "条目M" sorts between item titles "条目A" and "条目Z" —
    // it is not pinned ahead of every card.
    #expect(entries.map(\.id) == ["item-\(items.first.id)", "collection-\(collection.id)", "item-\(items.second.id)"])
}

@Test func localFavoriteMixedEntriesUsesLatestMemberUpdateAsCollectionProxyForUpdatedAtSort() throws {
    let (document, items, collection) = try makeMixedEntryDocument()
    let cards = LocalFavoriteLibraryProjection.cards(in: document, query: LocalFavoriteLibraryQuery(sortOrder: .contentUpdatedAt))

    // Collection's proxy update time (150) sits strictly between the two
    // cards' (100 and 200); default (not descending) direction is
    // newest-first, so second(200) sorts ahead of the collection ahead of
    // first(100).
    let entries = LocalFavoriteLibraryProjection.mixedEntries(
        cards: cards,
        collections: [collection],
        collectionSummaries: [collection.id: FavoriteCollectionSortSummary(latestUpdatedAt: Date(timeIntervalSince1970: 150))],
        sortOrder: .contentUpdatedAt,
        descending: false
    )

    #expect(entries.map(\.id) == ["item-\(items.second.id)", "collection-\(collection.id)", "item-\(items.first.id)"])
}

@Test func localFavoriteMixedEntriesUsesLatestMemberReadAsCollectionProxyForLastReadAtSort() throws {
    let (document, items, collection) = try makeMixedEntryDocument()
    let progress = [
        ReadingProgressRecord(
            contentTarget: .normalThread(threadID: "801"),
            threadID: "801",
            kind: .novel,
            updatedAt: Date(timeIntervalSince1970: 10),
            lastReadAt: Date(timeIntervalSince1970: 50),
            novel: NovelReadingProgressRecord(novelDocumentSurfaceProgressPercent: 10)
        ),
        ReadingProgressRecord(
            contentTarget: .normalThread(threadID: "802"),
            threadID: "802",
            kind: .novel,
            updatedAt: Date(timeIntervalSince1970: 20),
            lastReadAt: Date(timeIntervalSince1970: 250),
            novel: NovelReadingProgressRecord(novelDocumentSurfaceProgressPercent: 20)
        )
    ]
    let cards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(sortOrder: .lastReadAt),
        readingProgress: progress
    )

    // Collection's proxy read time (150) sits strictly between the two
    // cards' recentReadingAt (50 and 250); default (not descending)
    // direction is newest-first, so second(250) sorts ahead of the
    // collection ahead of first(50).
    let entries = LocalFavoriteLibraryProjection.mixedEntries(
        cards: cards,
        collections: [collection],
        collectionSummaries: [collection.id: FavoriteCollectionSortSummary(latestReadAt: Date(timeIntervalSince1970: 150))],
        sortOrder: .lastReadAt,
        descending: false
    )

    #expect(entries.map(\.id) == ["item-\(items.second.id)", "collection-\(collection.id)", "item-\(items.first.id)"])
}

@Test func localFavoriteMixedEntriesPutsNeverReadEntriesLastRegardlessOfSortDirection() throws {
    let (document, items, collection) = try makeMixedEntryDocument()
    // Only the first item has ever been read; the second item and the
    // collection (no collectionSummaries entry) have no read history.
    let progress = [
        ReadingProgressRecord(
            contentTarget: .normalThread(threadID: "801"),
            threadID: "801",
            kind: .novel,
            updatedAt: Date(timeIntervalSince1970: 10),
            lastReadAt: Date(timeIntervalSince1970: 50),
            novel: NovelReadingProgressRecord(novelDocumentSurfaceProgressPercent: 10)
        )
    ]
    let cards = LocalFavoriteLibraryProjection.cards(
        in: document,
        query: LocalFavoriteLibraryQuery(sortOrder: .lastReadAt),
        readingProgress: progress
    )

    let entries = LocalFavoriteLibraryProjection.mixedEntries(
        cards: cards,
        collections: [collection],
        collectionSummaries: [:],
        sortOrder: .lastReadAt,
        descending: true
    )

    // The never-read collection and never-read card stay behind the card
    // that was actually read even in descending (oldest-first, per the
    // swapped direction for this recency key) order — switching direction
    // no longer fast-forwards undated entries to the top ahead of real
    // read history. Only one entry has a real date here, so the
    // ascending/descending swap itself doesn't change this assertion.
    #expect(entries.map(\.id) == ["item-\(items.first.id)", "collection-\(collection.id)", "item-\(items.second.id)"])
}

private func makeMixedEntryDocument() throws -> (FavoriteLibraryDocument, MixedEntryItems, LocalFavoriteCollection) {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id
    let collection = document.createCollection(categoryID: categoryID, name: "条目M")
    let first = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "801"),
        title: "条目A",
        contentUpdatedAt: Date(timeIntervalSince1970: 100),
        locations: [.category(categoryID)]
    )
    let second = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "802"),
        title: "条目Z",
        contentUpdatedAt: Date(timeIntervalSince1970: 200),
        locations: [.category(categoryID)]
    )
    document.upsertItem(first)
    document.upsertItem(second)
    return (document, MixedEntryItems(first: first, second: second), collection)
}

private struct MixedEntryItems {
    var first: FavoriteItem
    var second: FavoriteItem
}

private func makeProjectionDocument() throws -> (FavoriteLibraryDocument, ProjectionItems) {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id
    let collection = document.createCollection(categoryID: categoryID, name: "合集A")
    let normal = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "701"),
        title: "普通主题",
        displayName: "本地名",
        sourceGroup: .forumBoard(id: "fid-1", label: "版块A"),
        contentUpdatedAt: Date(timeIntervalSince1970: 100),
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-701", yamiboRemoteOrder: 2),
        locations: [.category(categoryID), .collection(categoryID: categoryID, collectionID: collection.id)],
        updatedAt: Date(timeIntervalSince1970: 10)
    )
    let novel = try FavoriteItem(
        target: FavoriteItemTarget(kind: .novelThread, threadID: "702"),
        title: "小说主题",
        sourceGroup: .forumBoard(id: "fid-1", label: "版块A"),
        contentUpdatedAt: Date(timeIntervalSince1970: 200),
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-702", yamiboRemoteOrder: 1),
        locations: [.category(categoryID)],
        updatedAt: Date(timeIntervalSince1970: 20)
    )
    // No forumID/forumName — `normalizedForumMetadata` nils out `forumID`
    // for a `.smartManga` source group — so with the "智能漫画" filter bucket
    // gone this item buckets `.unknown` like any other board-less favorite.
    let manga = try FavoriteItem(
        target: .mangaThread(threadID: "703"),
        title: "漫画A",
        sourceGroup: .smartManga(cleanBookName: "漫画A"),
        contentUpdatedAt: Date(timeIntervalSince1970: 300),
        locations: [.category(categoryID)],
        updatedAt: Date(timeIntervalSince1970: 30)
    )
    let unknown = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "704"),
        title: "未知来源",
        sourceGroup: .unknown,
        locations: [.category(categoryID)],
        updatedAt: Date(timeIntervalSince1970: 40)
    )
    document.upsertItem(normal)
    document.upsertItem(novel)
    document.upsertItem(manga)
    document.upsertItem(unknown)
    return (document, ProjectionItems(normal: normal, novel: novel, manga: manga, unknown: unknown))
}

private struct ProjectionItems {
    var normal: FavoriteItem
    var novel: FavoriteItem
    var manga: FavoriteItem
    var unknown: FavoriteItem
}

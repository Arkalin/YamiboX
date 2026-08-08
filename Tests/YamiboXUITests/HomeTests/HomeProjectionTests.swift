import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class HomeProjectionTests: XCTestCase {
    func testAppModelDefaultsToHomeAndSettingsHaveNoGeneralCategory() {
        let appModel = YamiboAppModel(appContext: YamiboAppContext())

        XCTAssertEqual(appModel.selectedTab, .home)
        XCTAssertFalse(SettingsCategory.allCases.map(\.rawValue).contains("general"))
        XCTAssertFalse(SettingsSearchRegistry.entries.contains { $0.id == "general.home_page" })
    }

    func testHomeLoadsSmartMangaBadgeSetting() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings(
            favorites: FavoriteLibrarySettings(smartMangaBadgeEnabled: false)
        ))
        let model = HomeViewModel(
            accountDependencies: fixture.appContext.accountDependencies,
            libraryDependencies: fixture.appContext.libraryDependencies
        )

        await model.load()

        XCTAssertFalse(model.smartMangaBadgeEnabled)
    }

    func testPreviousReadingFiltersThreadsSortsByEffectiveReadDateAndKeepsLegacyRecords() {
        let newestNovel = ReadingProgressRecord(
            contentTarget: .novelThread(threadID: "novel-new"),
            kind: .novel,
            updatedAt: Date(timeIntervalSince1970: 10),
            lastReadAt: Date(timeIntervalSince1970: 30),
            novel: NovelReadingProgressRecord(lastView: 3, lastChapter: "第三章")
        )
        let legacyManga = ReadingProgressRecord(
            contentTarget: .mangaTitle(mangaID: "smart-book", cleanBookName: "智能漫画"),
            kind: .manga,
            updatedAt: Date(timeIntervalSince1970: 20),
            manga: MangaReadingProgressRecord(
                chapterThreadID: "manga-legacy",
                lastChapter: "第二话",
                mangaPageIndex: 4,
                mangaPageCount: 10
            )
        )
        let normalThread = ReadingProgressRecord(
            contentTarget: .normalThread(threadID: "thread"),
            kind: .thread,
            updatedAt: Date(timeIntervalSince1970: 99)
        )

        let result = [newestNovel, legacyManga, normalThread]
            .filter { $0.kind == .novel || $0.kind == .manga }
            .sorted(by: HomeViewModel.isMoreRecent)

        XCTAssertEqual(result.map(\.id), [newestNovel.id, legacyManga.id])
        XCTAssertEqual(result.count, 2)
    }

    func testPreviousReadingOmitsTheContinueReadingItem() {
        let records = [
            ReadingProgressRecord(
                contentTarget: .novelThread(threadID: "current"),
                kind: .novel,
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            ReadingProgressRecord(
                contentTarget: .novelThread(threadID: "previous"),
                kind: .novel,
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        ]
        let items = records.map {
            HomeViewModel.progressItem(
                record: $0,
                history: nil,
                cachedWork: nil,
                boardReader: BoardReaderSettings(entries: [:])
            )
        }

        XCTAssertEqual(
            HomeViewModel.previouslyReadItems(from: items).map(\.id),
            [records[1].id]
        )
    }

    func testProgressProjectionUsesHistoryThenCacheThenRecordAndStableFallback() {
        let record = ReadingProgressRecord(
            threadID: "1001",
            kind: .novel,
            updatedAt: Date(timeIntervalSince1970: 10),
            novel: NovelReadingProgressRecord(lastView: 2, lastChapter: "记录章节")
        )
        let cachedWork = OfflineCachedWork(
            id: OfflineCacheGroupID(readerKind: .novel, ownerKey: "1001"),
            title: "缓存作品名",
            cachedEntryCount: 1,
            updatedAt: Date(timeIntervalSince1970: 8),
            launchTarget: .novel(threadID: "1001", authorID: "42", cachedView: 2)
        )
        let history = BrowsingHistoryEntry(
            target: .novelThread(threadID: "1001"),
            title: "历史作品名",
            forumID: "49",
            authorID: "42",
            chapterTitle: "历史章节"
        )

        let historyItem = HomeViewModel.progressItem(
            record: record,
            history: history,
            cachedWork: cachedWork,
            boardReader: BoardReaderSettings(entries: [:])
        )
        XCTAssertEqual(historyItem.title, "历史作品名")
        XCTAssertEqual(historyItem.entry?.forumID, "49")
        XCTAssertEqual(historyItem.fallbackNovelView, 2)

        let cachedTitleItem = HomeViewModel.progressItem(
            record: record,
            history: nil,
            cachedWork: cachedWork,
            boardReader: BoardReaderSettings(entries: [:])
        )
        XCTAssertEqual(cachedTitleItem.title, "缓存作品名")

        let stableFallback = ReadingProgressRecord(kind: .novel, updatedAt: .distantPast)
        let fallbackItem = HomeViewModel.progressItem(
            record: stableFallback,
            history: nil,
            cachedWork: nil,
            boardReader: BoardReaderSettings(entries: [:])
        )
        XCTAssertEqual(fallbackItem.title, stableFallback.id)
        XCTAssertNil(fallbackItem.entry)
    }

    func testSmartMangaProjectionUsesSmartCoverAndSharedProgressPresentation() {
        let record = ReadingProgressRecord(
            contentTarget: .mangaTitle(mangaID: "book-id", cleanBookName: "书名"),
            kind: .manga,
            updatedAt: .now,
            manga: MangaReadingProgressRecord(
                chapterThreadID: "2001",
                lastChapter: "第六话",
                mangaPageIndex: 2,
                mangaPageCount: 8
            )
        )

        let item = HomeViewModel.progressItem(
            record: record,
            history: nil,
            cachedWork: nil,
            boardReader: BoardReaderSettings(entries: [:])
        )

        XCTAssertEqual(item.kind, .smartManga)
        XCTAssertEqual(item.coverKey, .smartManga(cleanBookName: "书名"))
        XCTAssertEqual(item.progressPercent, ReadingProgressPresentation.percent(for: record))
        XCTAssertTrue(item.detail?.contains(ReadingProgressPresentation.positionText(for: record) ?? "") == true)
    }
}

import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class ReadingHomeShelfTests: XCTestCase {
    func testSelectsOneNovelAndOneMangaAcrossBothMangaIdentities() {
        let novel = entry(.novelThread(threadID: "1"), time: 10)
        let oldNovel = entry(.novelThread(threadID: "2"), time: 8)
        let smart = entry(.mangaTitle(mangaID: "book", cleanBookName: "Book"), time: 9)
        let manga = entry(.mangaThread(threadID: "3"), time: 7)
        let normal = entry(.normalThread(threadID: "4"), time: 11)

        let shelf = ReadingHomeShelf(
            entries: [manga, oldNovel, normal, smart, novel],
            boardReader: BoardReaderSettings(entries: [:])
        )

        XCTAssertEqual(shelf.continuing.map(\.id), [novel.id, smart.id])
        XCTAssertEqual(shelf.previous.map(\.id), [oldNovel.id, manga.id])
        XCTAssertTrue(Set(shelf.continuing.map(\.id)).isDisjoint(with: shelf.previous.map(\.id)))
    }

    func testPlainMangaCanBeMoreRecentThanSmartManga() {
        let smart = entry(.mangaTitle(mangaID: "book", cleanBookName: "Book"), time: 1)
        let manga = entry(.mangaThread(threadID: "2"), time: 2)
        let shelf = ReadingHomeShelf(entries: [smart, manga], boardReader: .init(entries: [:]))
        XCTAssertEqual(shelf.continuing, [manga])
        XCTAssertEqual(shelf.previous, [smart])
    }

    func testEmptyAndSingleCategoryNeverCreatePlaceholderBooks() {
        let empty = ReadingHomeShelf(entries: [], boardReader: .init())
        XCTAssertTrue(empty.continuing.isEmpty)
        XCTAssertTrue(empty.previous.isEmpty)
        let novel = entry(.novelThread(threadID: "1"), time: 1)
        let onlyNovel = ReadingHomeShelf(entries: [novel], boardReader: .init())
        XCTAssertEqual(onlyNovel.continuing, [novel])
        XCTAssertTrue(onlyNovel.previous.isEmpty)
    }

    func testCurrentBoardModeControlsInclusionAndGrouping() {
        var settings = BoardReaderSettings(entries: [:])
        settings.setEntry(.init(mode: .normal), forumID: "10")
        settings.setEntry(.init(mode: .novel), forumID: "20")
        let hiddenNovel = entry(.novelThread(threadID: "1"), time: 3, forumID: "10")
        let newNovel = entry(.normalThread(threadID: "2"), time: 2, forumID: "20")
        let shelf = ReadingHomeShelf(entries: [hiddenNovel, newNovel], boardReader: settings)
        XCTAssertEqual(shelf.continuing, [newNovel])
        XCTAssertTrue(shelf.previous.isEmpty)
    }

    func testEqualTimestampsHaveStableOrder() {
        let first = entry(.novelThread(threadID: "1"), time: 1)
        let second = entry(.novelThread(threadID: "2"), time: 1)
        let forward = ReadingHomeShelf(entries: [first, second], boardReader: .init())
        let reversed = ReadingHomeShelf(entries: [second, first], boardReader: .init())
        XCTAssertEqual(forward, reversed)
    }

    func testMangaPositionIsOneBasedAndDoesNotInventWholeBookPercentage() {
        var manga = entry(.mangaThread(threadID: "1"), time: 1)
        manga.pageIndex = 0
        manga.pageCount = 20
        let book = ReadingHomeBook(entry: manga, category: .manga, isSmartManga: false, coverURL: nil)
        XCTAssertEqual(book.positionText, L10n.string("history.progress.page_of_total", "1", "20"))
        XCTAssertFalse(book.positionText?.contains("%") ?? true)
    }

    private func entry(_ target: FavoriteContentTarget, time: TimeInterval, forumID: String? = nil) -> BrowsingHistoryEntry {
        BrowsingHistoryEntry(target: target, title: target.id, forumID: forumID, lastVisitTime: Date(timeIntervalSince1970: time))
    }
}

@MainActor
final class ReadingHomeViewModelTests: XCTestCase {
    func testCanonicalSnapshotUpdatesHomeHistoryAndOpenTargetTogether() async throws {
        let context = try makeContext()
        try await context.settingsStore.update { $0.boardReader.setEntry(.init(mode: .novel), forumID: "40") }
        try await context.readingProgressStore.saveNormalThread(threadID: "900", page: 4)
        try await context.readingProgressStore.saveNovel(NovelReadingPosition(threadID: "900", view: 2, chapterTitle: "Novel chapter"))
        let visit = BrowsingHistoryVisit(threadID: "900", title: "Book", forumID: "40", reader: .normal)
        try await context.browsingHistoryWorkflow.recordVisit(visit)
        let home = ReadingHomeViewModel(dependencies: context.libraryDependencies)
        let history = BrowsingHistoryViewModel(dependencies: context.libraryDependencies)
        await home.reload()
        await history.reload()
        let original = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(home.continuing.first?.entry, original)
        XCTAssertEqual(home.continuing.first?.positionText, "Novel chapter")
        let resolver = ReadingOpenTargetResolver(
            readingProgressStore: context.readingProgressStore,
            mangaDirectoryStore: context.libraryDependencies.mangaDirectoryStore,
            settingsStore: context.settingsStore,
            historyWorkflow: context.browsingHistoryWorkflow
        )
        try await context.settingsStore.update { $0.boardReader.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "40") }
        await home.reload()
        await history.reload()
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(home.continuing.first?.entry, history.entries.first)
        XCTAssertNil(home.continuing.first?.positionText)
        XCTAssertEqual(history.entries.first?.lastVisitTime, visit.date)
        guard case let .mangaReader(manga)? = await resolver.openTarget(for: original) else {
            return XCTFail("Expected the current board's manga reader")
        }
        XCTAssertEqual(manga.chapterTID, "900")
        try await context.settingsStore.update { $0.boardReader.setEntry(.init(mode: .normal), forumID: "40") }
        await home.reload()
        await history.reload()
        XCTAssertTrue(home.continuing.isEmpty)
        XCTAssertEqual(history.entries.first?.pageIndex, 4)
        XCTAssertEqual(history.entries.first?.category, .normal)
        XCTAssertNil(history.entries.first?.chapterTitle)
        XCTAssertEqual(history.entries.first?.lastVisitTime, visit.date)
        guard case .nativeThread? = await resolver.openTarget(for: original) else {
            return XCTFail("Expected the current board's plain reader")
        }
    }

    func testReloadUsesSharedCoversAndUpdatesAfterDeletionAndClear() async throws {
        let context = try makeContext()
        let novel = BrowsingHistoryEntry(target: .novelThread(threadID: "1"), title: "Novel", lastVisitTime: Date(timeIntervalSince1970: 3))
        let older = BrowsingHistoryEntry(target: .novelThread(threadID: "2"), title: "Older", lastVisitTime: Date(timeIntervalSince1970: 1))
        let manga = BrowsingHistoryEntry(target: .mangaTitle(mangaID: "book", cleanBookName: "Book"), title: "Book", lastVisitTime: Date(timeIntervalSince1970: 2))
        for entry in [novel, older, manga] { try await context.browsingHistoryStore.record(entry) }
        let coverURL = try XCTUnwrap(URL(string: "https://example.com/cover.jpg"))
        try await context.contentCoverStore.setManualCover(coverURL, for: .smartManga(cleanBookName: "Book"))
        let model = ReadingHomeViewModel(dependencies: context.libraryDependencies)

        await model.reload()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.continuing.map(\.id), [novel.id, manga.id])
        XCTAssertEqual(model.continuing.last?.coverURL, coverURL)
        XCTAssertEqual(model.previous.map(\.id), [older.id])

        try await context.contentCoverStore.setTextCoverForced(true, for: .smartManga(cleanBookName: "Book"))
        await model.reload()
        XCTAssertNil(model.continuing.last?.coverURL)

        try await context.browsingHistoryStore.delete(id: novel.id)
        await model.reload()
        XCTAssertEqual(model.continuing.map(\.id), [manga.id, older.id])
        XCTAssertTrue(model.previous.isEmpty)

        try await context.browsingHistoryStore.clearAll()
        await model.reload()
        XCTAssertTrue(model.continuing.isEmpty)
        XCTAssertTrue(model.previous.isEmpty)
    }

    func testPreviousListExcludesContinueBeforeApplyingSearch() async throws {
        let context = try makeContext()
        let latest = BrowsingHistoryEntry(target: .novelThread(threadID: "1"), title: "Latest", lastVisitTime: Date(timeIntervalSince1970: 3))
        let older = BrowsingHistoryEntry(target: .novelThread(threadID: "2"), title: "Older", lastVisitTime: Date(timeIntervalSince1970: 1))
        let normal = BrowsingHistoryEntry(target: .normalThread(threadID: "3"), title: "Older forum post")
        for entry in [latest, older, normal] { try await context.browsingHistoryStore.record(entry) }
        let model = BrowsingHistoryViewModel(dependencies: context.libraryDependencies, showsPreviousReading: true)
        model.searchText = "Older"
        await model.load()
        XCTAssertEqual(model.entries, [older])
        model.searchText = "Latest"
        await model.reload()
        XCTAssertTrue(model.entries.isEmpty)

        let allHistory = BrowsingHistoryViewModel(dependencies: context.libraryDependencies)
        await allHistory.load()
        XCTAssertEqual(Set(allHistory.entries.map(\.id)), Set([latest.id, older.id, normal.id]))
    }

    func testObservesHistoryChanges() async throws {
        let context = try makeContext()
        let model = ReadingHomeViewModel(dependencies: context.libraryDependencies)
        let changes = context.browsingHistoryStore.changes()
        let observer = Task { await model.observe(changes) }
        defer { observer.cancel() }
        let novel = BrowsingHistoryEntry(target: .novelThread(threadID: "1"), title: "Novel")
        try await context.browsingHistoryStore.record(novel)
        for _ in 0..<100 where model.continuing.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.continuing.map(\.id), [novel.id])
    }

    private func makeContext() throws -> YamiboAppContext {
        let name = "reading-home-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        addTeardownBlock {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        return YamiboAppContext(
            sessionStore: SessionStore(defaults: defaults, key: "session"),
            profileStore: YamiboProfileStore(defaults: defaults, key: "profile"),
            settingsStore: SettingsStore(defaults: defaults, key: "settings"),
            databasePool: try YamiboDatabase.openPool(rootDirectory: root.appendingPathComponent("database")),
            grdbRootDirectory: root,
            cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: defaults,
            clearsWebDataOnReset: false
        )
    }
}

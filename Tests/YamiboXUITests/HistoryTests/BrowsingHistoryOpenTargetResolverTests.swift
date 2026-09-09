import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

/// Open-time reader-mode dispatch for history rows (pluggable-reader-config
/// R13, mirroring the favorites resolver's R11/R12): a configured board entry
/// dictates the reader; boards with no entry keep the row's recorded
/// identity.
@MainActor
final class BrowsingHistoryOpenTargetResolverTests: XCTestCase {
    func testNovelConfiguredBoardOpensNormalRecordedRowInNovelReader() async throws {
        let fixture = try makeFixture(prefix: "history-open-config-novel")
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .novel), forumID: "40")
        try await fixture.settingsStore.save(AppSettings(boardReader: boardReader))

        let entry = BrowsingHistoryEntry(
            target: .normalThread(threadID: "6001"),
            title: "配置前读过的帖子",
            forumID: "40"
        )
        let opened = await fixture.resolver.openTarget(for: entry)

        guard case let .novelReader(context)? = opened else {
            return XCTFail("Expected a novel reader open target")
        }
        XCTAssertEqual(context.threadID, "6001")
        XCTAssertEqual(context.forumID, "40")
        XCTAssertEqual(context.threadTitle, "配置前读过的帖子")
    }

    func testExplicitNormalEntryOpensNovelRecordedRowAsNativeThread() async throws {
        let fixture = try makeFixture(prefix: "history-open-config-normal")
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .normal), forumID: "40")
        try await fixture.settingsStore.save(AppSettings(boardReader: boardReader))

        let entry = BrowsingHistoryEntry(
            target: .novelThread(threadID: "6002"),
            title: "改回普通板块的小说行",
            forumID: "40"
        )
        let opened = await fixture.resolver.openTarget(for: entry)

        guard case let .nativeThread(url, title)? = opened else {
            return XCTFail("Expected a native thread open target")
        }
        XCTAssertEqual(url, YamiboRoute.threadByID(tid: "6002", page: 1, authorID: nil, reverse: false).url)
        XCTAssertEqual(title, "改回普通板块的小说行")
    }

    // A directory-level row on a board switched back to 普通 opens its
    // *current chapter* as a plain thread — the same thread the row's heart
    // acts on (browsing-history decision #11).
    func testExplicitNormalEntryOpensMangaTitleRowChapterAsNativeThread() async throws {
        let fixture = try makeFixture(prefix: "history-open-config-normal-manga-title")
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .normal), forumID: "46")
        try await fixture.settingsStore.save(AppSettings(boardReader: boardReader))

        let entry = BrowsingHistoryEntry(
            target: .mangaTitle(mangaID: "m1", cleanBookName: "改回普通的漫画"),
            title: "改回普通的漫画",
            forumID: "46",
            chapterTitle: "第三话",
            chapterThreadID: "6003"
        )
        let opened = await fixture.resolver.openTarget(for: entry)

        guard case let .nativeThread(url, _)? = opened else {
            return XCTFail("Expected a native thread open target")
        }
        XCTAssertEqual(url, YamiboRoute.threadByID(tid: "6003", page: 1, authorID: nil, reverse: false).url)
    }

    // The manga dispatch keeps its live smart-bit semantics: a normal-recorded
    // row on a now-smart-manga board resumes at the directory level when a
    // resolved directory covers the thread (decision #13's absorption
    // semantics applied at open time).
    func testSmartMangaConfiguredBoardOpensNormalRecordedRowViaDirectory() async throws {
        let fixture = try makeFixture(prefix: "history-open-config-smart-manga")
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "40")
        try await fixture.settingsStore.save(AppSettings(boardReader: boardReader))

        let directory = MangaDirectory(
            cleanBookName: "改配漫画",
            strategy: .links,
            sourceKey: "chapter:6004",
            chapters: [
                MangaChapter(tid: "6004", rawTitle: "第一话", chapterNumber: 1, view: 1),
                MangaChapter(tid: "6005", rawTitle: "第二话", chapterNumber: 2, view: 1),
            ]
        )
        try await fixture.mangaDirectoryStore.saveDirectory(directory)

        let entry = BrowsingHistoryEntry(
            target: .normalThread(threadID: "6004"),
            title: "改配漫画 第一话",
            forumID: "40"
        )
        let opened = await fixture.resolver.openTarget(for: entry)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertTrue(context.isSmartModeEnabled)
        XCTAssertEqual(context.directoryName, "改配漫画")
        XCTAssertEqual(context.chapterTID, "6004")
        XCTAssertEqual(context.forumID, "40")
    }

    func testKnownUnconfiguredBoardUsesPlainReader() async throws {
        let fixture = try makeFixture(prefix: "history-open-unconfigured")
        try await fixture.settingsStore.save(AppSettings(boardReader: BoardReaderSettings(entries: [:])))

        let entry = BrowsingHistoryEntry(
            target: .novelThread(threadID: "6006"),
            title: "未配置板块的小说行",
            forumID: "88"
        )
        let opened = await fixture.resolver.openTarget(for: entry)

        guard case let .nativeThread(url, _)? = opened else {
            return XCTFail("Expected a plain thread open target")
        }
        XCTAssertEqual(url, YamiboRoute.threadByID(tid: "6006", page: 1, authorID: nil, reverse: false).url)
    }

    func testHomeOriginUsesCachedMangaChapterWhenNoProgressExists() async throws {
        let fixture = try makeFixture(prefix: "history-open-home-cache")
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "46")
        try await fixture.settingsStore.save(AppSettings(boardReader: boardReader))

        let entry = BrowsingHistoryEntry(
            target: .mangaThread(threadID: "6010"),
            title: "离线漫画",
            forumID: "46",
            chapterTitle: "第七话",
            chapterThreadID: "6010"
        )
        let opened = await fixture.resolver.openTarget(
            for: entry,
            origin: .home,
            fallbackMangaView: 4
        )

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.source, .home)
        XCTAssertEqual(context.chapterTID, "6010")
        XCTAssertEqual(context.chapterView, 4)
    }

    func testSmartThreadWithoutDirectoryProgressStartsAtFirstChapterRealView() async throws {
        let fixture = try makeFixture(prefix: "history-smart-first-view")
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
        try await fixture.settingsStore.save(AppSettings(boardReader: boardReader))
        let directory = MangaDirectory(
            cleanBookName: "Directory",
            strategy: .links,
            sourceKey: "chapter:6102",
            chapters: [
                MangaChapter(tid: "6101", rawTitle: "First", chapterNumber: 1, view: 3),
                MangaChapter(tid: "6102", rawTitle: "Second", chapterNumber: 2, view: 1)
            ]
        )
        try await fixture.mangaDirectoryStore.saveDirectory(directory)
        let entry = BrowsingHistoryEntry(
            target: .mangaThread(threadID: "6102"), title: "Second", forumID: "46"
        )

        guard case let .mangaReader(context)? = await fixture.resolver.openTarget(
            for: entry, origin: .home, fallbackMangaView: 9
        ) else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.originalThreadID, "6102")
        XCTAssertEqual(context.chapterTID, "6101")
        XCTAssertEqual(context.chapterView, 3)
        XCTAssertEqual(context.initialPage, 0)
        XCTAssertEqual(context.displayTitle, "Directory")
        XCTAssertEqual(context.source, .home)
        XCTAssertEqual(context.forumID, "46")
    }

    func testPlainThreadIgnoresDirectoryProgressWithSameChapter() async throws {
        let fixture = try makeFixture(prefix: "history-plain-exact-progress")
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "46")
        try await fixture.settingsStore.save(AppSettings(boardReader: boardReader))
        _ = try await fixture.resolver.readingProgressStore.saveMangaTitle(
            cleanBookName: "Directory", chapterThreadID: "6201",
            chapterTitle: "First", pageIndex: 7, mangaID: "directory-id"
        )
        let entry = BrowsingHistoryEntry(
            target: .mangaThread(threadID: "6201"), title: "First", forumID: "46"
        )

        guard case let .mangaReader(context)? = await fixture.resolver.openTarget(
            for: entry, fallbackMangaView: 4
        ) else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.chapterTID, "6201")
        XCTAssertEqual(context.chapterView, 4)
        XCTAssertEqual(context.initialPage, 0)
        XCTAssertNil(context.directoryName)
        XCTAssertFalse(context.isSmartModeEnabled)
    }

    func testDirectoryRowWithoutProgressRetainsRecordedChapterInsteadOfFirst() async throws {
        let fixture = try makeFixture(prefix: "history-directory-recorded-chapter")
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
        try await fixture.settingsStore.save(AppSettings(boardReader: boardReader))
        let directory = MangaDirectory(
            cleanBookName: "Directory", strategy: .links, sourceKey: "chapter:6301",
            chapters: [
                MangaChapter(tid: "6301", rawTitle: "First", chapterNumber: 1, view: 1),
                MangaChapter(tid: "6302", rawTitle: "Second", chapterNumber: 2, view: 5)
            ]
        )
        try await fixture.mangaDirectoryStore.saveDirectory(directory)
        let entry = BrowsingHistoryEntry(
            target: .mangaTitle(mangaID: directory.favoriteIdentity, cleanBookName: "Directory"),
            title: "Directory", forumID: "46", chapterTitle: "Second", chapterThreadID: "6302"
        )

        guard case let .mangaReader(context)? = await fixture.resolver.openTarget(for: entry) else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.chapterTID, "6302")
        XCTAssertEqual(context.chapterView, 5)
        XCTAssertEqual(context.initialPage, 0)
        XCTAssertEqual(context.directoryName, "Directory")
    }

    // The heart stamps the row's effective category (R13): the mapping from
    // effective category to favorite target kind is what keeps "what the row
    // shows/opens as" and "what gets favorited" in lockstep.
    func testEffectiveCategoryMapsToFavoriteTargetKind() {
        XCTAssertEqual(BrowsingHistoryCategory.normal.favoriteTargetKind, .normalThread)
        XCTAssertEqual(BrowsingHistoryCategory.novel.favoriteTargetKind, .novelThread)
        XCTAssertEqual(BrowsingHistoryCategory.manga.favoriteTargetKind, .mangaThread)
    }

    // MARK: - Fixture

    private struct Fixture {
        let settingsStore: SettingsStore
        let mangaDirectoryStore: MangaDirectoryStore
        let resolver: BrowsingHistoryOpenTargetResolver
    }

    private func makeFixture(prefix: String) throws -> Fixture {
        let suiteName = YamiboTestDefaults.suiteName(prefix: prefix)
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsing-history-open-target-resolver-tests", isDirectory: true)
            .appendingPathComponent(suiteName, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let mangaDirectoryStore = MangaDirectoryStore(databasePool: try YamiboDatabase.openPool(rootDirectory: root))
        return Fixture(
            settingsStore: settingsStore,
            mangaDirectoryStore: mangaDirectoryStore,
            resolver: BrowsingHistoryOpenTargetResolver(
                readingProgressStore: readingProgressStore,
                mangaDirectoryStore: mangaDirectoryStore,
                settingsStore: settingsStore
            )
        )
    }
}

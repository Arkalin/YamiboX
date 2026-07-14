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

    func testUnconfiguredBoardKeepsRecordedNovelIdentity() async throws {
        let fixture = try makeFixture(prefix: "history-open-unconfigured")
        try await fixture.settingsStore.save(AppSettings(boardReader: BoardReaderSettings(entries: [:])))

        let entry = BrowsingHistoryEntry(
            target: .novelThread(threadID: "6006"),
            title: "未配置板块的小说行",
            forumID: "88"
        )
        let opened = await fixture.resolver.openTarget(for: entry)

        guard case let .novelReader(context)? = opened else {
            return XCTFail("Expected a novel reader open target")
        }
        XCTAssertEqual(context.threadID, "6006")
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

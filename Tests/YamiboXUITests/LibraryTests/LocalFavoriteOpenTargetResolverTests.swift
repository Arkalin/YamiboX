import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class LocalFavoriteOpenTargetResolverTests: XCTestCase {
    func testNormalThreadOpenTargetUsesNativeReaderWithoutMutatingFavoriteUpdatedAt() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let originalUpdatedAt = Date(timeIntervalSince1970: 1_000)
        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "901"),
            title: "普通主题",
            locations: [.category(document.defaultCategory.id)],
            updatedAt: originalUpdatedAt
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName)
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .nativeThread(openedURL, title)? = opened else {
            return XCTFail("Expected a native thread open target")
        }
        XCTAssertEqual(openedURL, YamiboRoute.threadByID(tid: "901", page: 1, authorID: nil, reverse: false).url)
        XCTAssertEqual(title, "普通主题")
        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.id == item.id }
        XCTAssertEqual(storedItem?.updatedAt, originalUpdatedAt)
    }

    // `.mangaThread` favorites always resolve straight to the manga reader
    // (smart-comic-mode design decision #7) and, unlike the old `.mangaTitle`
    // merged identity, always have a real chapter tid to fall back to when
    // there is no reading-progress record yet — the old `mangaTitleUnresolved`
    // failure mode can no longer occur (see LocalFavoriteOpenTargetResolver).
    //
    // This item has no `forumID`, which reports mode-off under the strict
    // rule (only a board currently configured as `.manga(smartEnabled:
    // true)` is on — a missing fid can never match), so this exercises the
    // mode-off single-thread resume branch: the favorite's own
    // `.mangaThread` progress (here, none at all), never a merged
    // directory.
    func testMangaThreadOpenTargetFallsBackToOwnThreadWithoutReadingProgress() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "902"),
            title: "漫画章节",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName)
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.originalThreadID, "902")
        XCTAssertEqual(context.chapterTID, "902")
        XCTAssertEqual(context.initialPage, 0)
        XCTAssertNil(context.directoryName)
        XCTAssertFalse(context.isSmartModeEnabled)
    }

    // Mode-on resume (smart-comic-mode design decision #15/#7): the favorite
    // is a single chapter thread, but its `MangaDirectory` is already
    // resolved locally with an upserted directory-level `.mangaTitle`
    // progress record pointing at a *different* chapter than the one the
    // favorite itself was created from. Resuming must follow the
    // directory-level record (not the favorited thread's own tid).
    func testMangaThreadOpenTargetOnModeOnBoardResumesViaDirectoryLevelProgress() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-mode-on")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "测试漫画",
            strategy: .tag,
            sourceKey: "测试漫画",
            chapters: [
                MangaChapter(tid: "1001", rawTitle: "第一话", chapterNumber: 1, view: 1),
                MangaChapter(tid: "1002", rawTitle: "第二话", chapterNumber: 2, view: 1),
                MangaChapter(tid: "1003", rawTitle: "第三话", chapterNumber: 3, view: 1)
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)
        _ = try await readingProgressStore.saveMangaTitle(
            cleanBookName: directory.cleanBookName,
            chapterThreadID: "1002",
            chapterTitle: "第二话",
            pageIndex: 4,
            mangaID: directory.favoriteIdentity
        )

        var document = FavoriteLibraryDocument()
        // The favorite itself points at chapter 1's thread — the merged
        // board (fid "30" is on by default) should still resume at chapter
        // 2, following the directory-level record, not this thread's own id.
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "1001"),
            title: "测试漫画 第一话",
            sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.originalThreadID, "1001")
        XCTAssertEqual(context.chapterTID, "1002")
        XCTAssertEqual(context.initialPage, 4)
        XCTAssertEqual(context.directoryName, "测试漫画")
        XCTAssertTrue(context.isSmartModeEnabled)
    }

    // Same directory/progress setup as above, but the resolved directory has
    // no progress record at all yet — resume should fall back to the
    // directory's earliest chapter (smart-comic-mode design decision #7).
    func testMangaThreadOpenTargetOnModeOnBoardFallsBackToEarliestChapterWithoutProgress() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-mode-on-fallback")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "无进度漫画",
            strategy: .tag,
            sourceKey: "无进度漫画",
            chapters: [
                MangaChapter(tid: "2001", rawTitle: "第一话", chapterNumber: 1, view: 1),
                MangaChapter(tid: "2002", rawTitle: "第二话", chapterNumber: 2, view: 1)
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "2002"),
            title: "无进度漫画 第二话",
            sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.chapterTID, "2001")
        XCTAssertEqual(context.initialPage, 0)
        XCTAssertEqual(context.directoryName, "无进度漫画")
    }

    // Long-pressing an already-parsed smart-comic favorite card and choosing
    // "从头打开" (`.start`) must jump to the directory's actual first
    // chapter, not just reset the tapped/representative member's own tid to
    // page 0 — the representative item is whichever member was favorited
    // earliest, which is frequently a *different* chapter than #1 once a
    // directory has multiple favorited members. It must also ignore any
    // existing directory-level progress (unlike plain resume).
    func testMangaThreadOpenTargetOnModeOnBoardWithStartModeOpensDirectoryFirstChapter() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-mode-on-start")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "从头打开漫画",
            strategy: .tag,
            sourceKey: "从头打开漫画",
            chapters: [
                MangaChapter(tid: "6001", rawTitle: "第一话", chapterNumber: 1, view: 1),
                MangaChapter(tid: "6002", rawTitle: "第二话", chapterNumber: 2, view: 1),
                MangaChapter(tid: "6003", rawTitle: "第三话", chapterNumber: 3, view: 1)
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)
        // Existing progress sits at chapter 3 — "从头打开" must ignore this
        // entirely and still land on chapter 1.
        _ = try await readingProgressStore.saveMangaTitle(
            cleanBookName: directory.cleanBookName,
            chapterThreadID: "6003",
            chapterTitle: "第三话",
            pageIndex: 5,
            mangaID: directory.favoriteIdentity
        )

        var document = FavoriteLibraryDocument()
        // The favorite/representative item points at chapter 2's thread —
        // this must NOT be what "从头打开" opens.
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "6002"),
            title: "从头打开漫画 第二话",
            sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        let opened = try await resolver.openTarget(for: item, mode: .start)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.originalThreadID, "6002")
        XCTAssertEqual(context.chapterTID, "6001")
        XCTAssertEqual(context.initialPage, 0)
        XCTAssertEqual(context.directoryName, "从头打开漫画")
        XCTAssertTrue(context.isSmartModeEnabled)
    }

    // If the directory has never been resolved locally at all (e.g. a
    // favorite synced in from another device that was never opened here),
    // "从头打开" on a mode-on board falls back to the favorite's own thread
    // at page 0, still launching with Smart Comic Mode on so the reader
    // resolves a real directory on this open — mirroring the equivalent
    // resume-path fallback.
    func testMangaThreadOpenTargetOnModeOnBoardWithStartModeFallsBackWhenDirectoryNeverResolved() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-mode-on-start-unresolved")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )

        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "6101"),
            title: "未解析漫画 第一话",
            sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName)
        )
        let opened = try await resolver.openTarget(for: item, mode: .start)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.chapterTID, "6101")
        XCTAssertEqual(context.initialPage, 0)
        XCTAssertNil(context.directoryName)
        XCTAssertTrue(context.isSmartModeEnabled)
    }

    // Mode-off (smart-comic-mode design decision #15): resume must use only
    // this thread's own `.mangaThread` progress record, never the
    // directory-level one, even when a resolved directory with progress
    // exists for the same tid (e.g. left over from before the board was
    // switched off).
    func testMangaThreadOpenTargetOnModeOffBoardResumesViaOwnThreadProgressOnly() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-mode-off")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "已关闭板块漫画",
            strategy: .tag,
            sourceKey: "已关闭板块漫画",
            chapters: [
                MangaChapter(tid: "3001", rawTitle: "第一话", chapterNumber: 1, view: 1)
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)
        // Stale directory-level record from before the board was switched
        // off — must be ignored entirely by the mode-off resume path.
        _ = try await readingProgressStore.saveMangaTitle(
            cleanBookName: directory.cleanBookName,
            chapterThreadID: "3001",
            chapterTitle: "第一话",
            pageIndex: 9,
            mangaID: directory.favoriteIdentity
        )
        _ = try await readingProgressStore.saveMangaThread(MangaProgressReadingPosition(
            chapterThreadID: "3001",
            chapterTitle: "第一话",
            pageIndex: 2
        ))

        var document = FavoriteLibraryDocument()
        // fid "46" is off by default (smart-comic-mode design decision #1).
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "3001"),
            title: "已关闭板块漫画 第一话",
            sourceGroup: .forumBoard(id: "46", label: "关闭板块"),
            forumID: "46",
            forumName: "关闭板块",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.originalThreadID, "3001")
        XCTAssertEqual(context.chapterTID, "3001")
        XCTAssertEqual(context.initialPage, 2)
        XCTAssertNil(context.directoryName)
        XCTAssertFalse(context.isSmartModeEnabled)
    }

    // A `.mangaThread` favorite whose board has NO configuration entry at
    // all (fid "88" — not in the factory default, unlike the mode-off manga
    // board above) reports mode-off under the one rule (pluggable-reader-
    // config decision #4), so resume stays on the single-thread track: its
    // own `.mangaThread` progress record, never the directory-level one,
    // even when a resolved directory with fresher progress covers the tid.
    func testMangaThreadOpenTargetOnUnconfiguredBoardResumesViaOwnThreadProgressOnly() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-unconfigured")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "未配置板块漫画",
            strategy: .tag,
            sourceKey: "未配置板块漫画",
            chapters: [
                MangaChapter(tid: "5001", rawTitle: "第一话", chapterNumber: 1, view: 1),
                MangaChapter(tid: "5002", rawTitle: "第二话", chapterNumber: 2, view: 1)
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)
        // Fresher directory-level record pointing at a different chapter —
        // must be ignored entirely on the unconfigured board's resume path.
        _ = try await readingProgressStore.saveMangaTitle(
            cleanBookName: directory.cleanBookName,
            chapterThreadID: "5002",
            chapterTitle: "第二话",
            pageIndex: 8,
            mangaID: directory.favoriteIdentity
        )
        _ = try await readingProgressStore.saveMangaThread(MangaProgressReadingPosition(
            chapterThreadID: "5001",
            chapterTitle: "第一话",
            pageIndex: 1
        ))

        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "5001"),
            title: "未配置板块漫画 第一话",
            sourceGroup: .forumBoard(id: "88", label: "未配置板块"),
            forumID: "88",
            forumName: "未配置板块",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore,
            settingsStore: settingsStore
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.originalThreadID, "5001")
        XCTAssertEqual(context.chapterTID, "5001")
        XCTAssertEqual(context.initialPage, 1)
        XCTAssertNil(context.directoryName)
        XCTAssertFalse(context.isSmartModeEnabled)
    }

    // The "查看归档收藏" archive page opens its members with
    // `mangaScope: .singleThread`: even on a mode-ON board with a resolved
    // directory and a directory-level progress record pointing at a
    // different chapter, the tapped member must open as exactly its own
    // thread (single-thread reading, own `.mangaThread` progress) — matching
    // the ordinary non-smart card the page renders it as.
    func testMangaThreadOpenTargetWithSingleThreadScopeIgnoresModeOnBoard() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-single-thread-scope")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "归档页漫画",
            strategy: .tag,
            sourceKey: "归档页漫画",
            chapters: [
                MangaChapter(tid: "4001", rawTitle: "第一话", chapterNumber: 1, view: 1),
                MangaChapter(tid: "4002", rawTitle: "第二话", chapterNumber: 2, view: 1)
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)
        // A merged-reading session left the directory-level record at
        // chapter 2 — the boardDefault scope would resume there, but the
        // archive page's single-thread scope must not.
        _ = try await readingProgressStore.saveMangaTitle(
            cleanBookName: directory.cleanBookName,
            chapterThreadID: "4002",
            chapterTitle: "第二话",
            pageIndex: 7,
            mangaID: directory.favoriteIdentity
        )
        _ = try await readingProgressStore.saveMangaThread(MangaProgressReadingPosition(
            chapterThreadID: "4001",
            chapterTitle: "第一话",
            pageIndex: 3
        ))

        var document = FavoriteLibraryDocument()
        // fid "30" is on by default (smart-comic-mode design decision #1).
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "4001"),
            title: "归档页漫画 第一话",
            sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        let opened = try await resolver.openTarget(for: item, mangaScope: .singleThread)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.originalThreadID, "4001")
        XCTAssertEqual(context.chapterTID, "4001")
        XCTAssertEqual(context.initialPage, 3)
        XCTAssertNil(context.directoryName)
        XCTAssertFalse(context.isSmartModeEnabled)
    }

    // Same single-thread scope, launched from the context menu's "从头阅读"
    // (`.start`): opens the member's own thread at page 0 with Smart Comic
    // Mode off, never the merged directory.
    func testMangaThreadOpenTargetWithSingleThreadScopeStartsOwnThreadFromPageZero() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-single-thread-start")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "4101"),
            title: "归档页漫画 第一话",
            sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName)
        )
        let opened = try await resolver.openTarget(for: item, mode: .start, mangaScope: .singleThread)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.chapterTID, "4101")
        XCTAssertEqual(context.initialPage, 0)
        XCTAssertNil(context.directoryName)
        XCTAssertFalse(context.isSmartModeEnabled)
    }

    // MARK: - Open-time reader-mode dispatch (pluggable-reader-config R11)

    // A favorite stored as `.normalThread` (e.g. synced in before its board
    // was ever configured) must open with the reader the board is configured
    // for NOW — the stored kind is an add-time classification, not an open
    // contract. The stored kind itself must survive untouched (decision #5).
    func testNovelConfiguredBoardOpensStoredNormalThreadFavoriteInNovelReader() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-config-novel")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        var boardReader = BoardReaderSettings()
        boardReader.setEntry(.init(mode: .novel), forumID: "40")
        try await settingsStore.save(AppSettings(boardReader: boardReader))

        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "5001"),
            title: "配置前收藏的小说",
            sourceGroup: .forumBoard(id: "40", label: "小说板块"),
            forumID: "40",
            forumName: "小说板块",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName),
            settingsStore: settingsStore
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .novelReader(context)? = opened else {
            return XCTFail("Expected a novel reader open target")
        }
        XCTAssertEqual(context.threadID, "5001")
        XCTAssertEqual(context.threadTitle, "配置前收藏的小说")
        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.id == item.id }
        XCTAssertEqual(storedItem?.target.kind, .normalThread)
    }

    // The reverse flip: a board reconfigured 漫画 (smart off) opens even a
    // stored `.normalThread` favorite in the manga reader's single-thread
    // track, exactly like tapping the same thread on the board page would.
    func testMangaConfiguredBoardOpensStoredNormalThreadFavoriteInMangaReader() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-config-manga")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        var boardReader = BoardReaderSettings()
        boardReader.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "40")
        try await settingsStore.save(AppSettings(boardReader: boardReader))

        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "5002"),
            title: "改配漫画板块的旧收藏",
            sourceGroup: .forumBoard(id: "40", label: "漫画板块"),
            forumID: "40",
            forumName: "漫画板块",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName),
            settingsStore: settingsStore
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.originalThreadID, "5002")
        XCTAssertEqual(context.chapterTID, "5002")
        XCTAssertNil(context.directoryName)
        XCTAssertFalse(context.isSmartModeEnabled)
    }

    // A `.mangaThread` favorite whose board is reconfigured 小说 follows the
    // configuration too — the manga-flavored stored kind grants nothing once
    // the board says novel.
    func testNovelConfiguredBoardOpensStoredMangaThreadFavoriteInNovelReader() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-config-novel-from-manga")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        var boardReader = BoardReaderSettings()
        boardReader.setEntry(.init(mode: .novel), forumID: "46")
        try await settingsStore.save(AppSettings(boardReader: boardReader))

        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "5003"),
            title: "改配小说板块的漫画收藏",
            sourceGroup: .forumBoard(id: "46", label: "改配小说"),
            forumID: "46",
            forumName: "改配小说",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName),
            settingsStore: settingsStore
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .novelReader(context)? = opened else {
            return XCTFail("Expected a novel reader open target")
        }
        XCTAssertEqual(context.threadID, "5003")
    }

    // No entry for the board (普通/never configured/no fid) → the stored kind
    // still decides, so a novel-TYPE favorite keeps opening as a novel even
    // though the strict classification rule would call new adds on this
    // board `.normalThread`. Open-time dispatch must not "downgrade" kinds
    // that came from the content type rather than board configuration.
    func testUnconfiguredBoardKeepsStoredNovelThreadFavoriteInNovelReader() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-unconfigured-novel")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        try await settingsStore.save(AppSettings(boardReader: BoardReaderSettings(entries: [:])))

        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: FavoriteItemTarget(kind: .novelThread, threadID: "5004"),
            title: "未配置板块的小说收藏",
            sourceGroup: .forumBoard(id: "88", label: "未配置板块"),
            forumID: "88",
            forumName: "未配置板块",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName),
            settingsStore: settingsStore
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .novelReader(context)? = opened else {
            return XCTFail("Expected a novel reader open target")
        }
        XCTAssertEqual(context.threadID, "5004")
    }

    // The counterpart to the unconfigured-fallback test above: a board
    // switched BACK to 普通 writes an explicit `.normal` entry (R12), and
    // that entry — unlike the absence of one — forces the plain thread
    // reader even for a favorite whose stored kind is novel.
    func testExplicitNormalEntryOpensStoredNovelThreadFavoriteAsNativeThread() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-explicit-normal")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .normal, boardName: "改回普通的板块"), forumID: "88")
        try await settingsStore.save(AppSettings(boardReader: boardReader))

        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: FavoriteItemTarget(kind: .novelThread, threadID: "5005"),
            title: "改回普通板块的小说收藏",
            sourceGroup: .forumBoard(id: "88", label: "改回普通的板块"),
            forumID: "88",
            forumName: "改回普通的板块",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName),
            settingsStore: settingsStore
        )
        let opened = try await resolver.openTarget(for: item)

        guard case let .nativeThread(openedURL, title)? = opened else {
            return XCTFail("Expected a native thread open target")
        }
        XCTAssertEqual(openedURL, YamiboRoute.threadByID(tid: "5005", page: 1, authorID: nil, reverse: false).url)
        XCTAssertEqual(title, "改回普通板块的小说收藏")
    }

    // MARK: - Smart-manga directory update-event re-derivation

    // A directory-mode update event carries only a `cleanBookName`, never a
    // pointer to one specific favorite (detection is per-directory). Tap
    // routing must find ANY currently-favorited `.mangaThread` chapter whose
    // tid resolves into that directory and route it through the same
    // mode-on resume path a merged smart-manga card's tap already uses.
    func testMangaDirectoryCleanBookNameOpenTargetFindsAnyFavoritedChapterInDirectory() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-directory-event")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "更新事件测试漫画",
            strategy: .tag,
            sourceKey: "更新事件测试漫画",
            chapters: [
                MangaChapter(tid: "9001", rawTitle: "第一话", chapterNumber: 1, view: 1),
                MangaChapter(tid: "9002", rawTitle: "第二话", chapterNumber: 2, view: 1)
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: .mangaThread(threadID: "9002"),
            title: "更新事件测试漫画 第二话",
            sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        let opened = try await resolver.openTarget(forMangaDirectoryCleanBookName: "更新事件测试漫画")

        guard case let .mangaReader(context)? = opened else {
            return XCTFail("Expected a manga reader open target")
        }
        XCTAssertEqual(context.directoryName, "更新事件测试漫画")
        XCTAssertTrue(context.isSmartModeEnabled)
    }

    // Every favorited chapter in the directory was removed since the update
    // was detected — the caller (in-app tap or notification tap) must fall
    // back to its existing "favorite already deleted" handling instead of
    // crashing or opening something stale.
    func testMangaDirectoryCleanBookNameOpenTargetReturnsNilWhenNoFavoriteRemainsInDirectory() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-directory-event-missing")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "已取消收藏的漫画",
            strategy: .tag,
            sourceKey: "已取消收藏的漫画",
            chapters: [MangaChapter(tid: "9101", rawTitle: "第一话", chapterNumber: 1, view: 1)]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        let opened = try await resolver.openTarget(forMangaDirectoryCleanBookName: "已取消收藏的漫画")

        XCTAssertNil(opened)
    }

    func testMangaDirectoryCleanBookNameOpenTargetReturnsNilForUnknownDirectory() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-target-manga-directory-event-unknown")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: try makeMangaDirectoryStore(suiteName: suiteName)
        )
        let opened = try await resolver.openTarget(forMangaDirectoryCleanBookName: "不存在的漫画")

        XCTAssertNil(opened)
    }

    private func makeMangaDirectoryStore(suiteName: String) throws -> MangaDirectoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-favorite-open-target-resolver-tests", isDirectory: true)
            .appendingPathComponent(suiteName, isDirectory: true)
        let database = try YamiboDatabase.openPool(rootDirectory: root)
        return MangaDirectoryStore(databasePool: database)
    }
}

import Foundation
@preconcurrency import GRDB
import Testing
@testable import YamiboXCore

@Test func forumCacheStoreReturnsHomeWithinTTL() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 100)
    let store = ForumCacheStore(baseDirectory: directory, now: { now })
    let home = ForumHomePage(
        categories: [
            ForumCategory(
                id: "main",
                title: "分区",
                boards: [
                    ForumBoardSummary(
                        fid: "5",
                        name: "動漫區",
                        url: ForumRouteResolver.boardURL(fid: "5")
                    )
                ]
            )
        ],
        fetchedAt: now
    )

    try await store.saveHome(home)
    now = Date(timeIntervalSince1970: 100 + ForumCacheStore.homeTTL - 1)

    let loaded = await ForumCacheStore(baseDirectory: directory, now: { now }).loadHome()
    #expect(loaded?.categories.first?.boards.first?.fid == "5")
    #expect(FileManager.default.fileExists(
        atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: directory)
            .appendingPathComponent("forum-home", isDirectory: true)
            .appendingPathComponent("home.json", isDirectory: false)
            .path
    ))
}

@Test func forumCacheStoreExpiresHomeAfterTTL() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 100)
    let store = ForumCacheStore(baseDirectory: directory, now: { now })
    let home = ForumHomePage(categories: [], fetchedAt: now)

    try await store.saveHome(home)
    now = Date(timeIntervalSince1970: 100 + ForumCacheStore.homeTTL + 1)

    #expect(await store.loadHome(allowExpired: true) != nil)
    #expect(await store.loadHome() == nil)
}

@Test func forumCacheStoreWritesBoardPagesIntoDiskCacheNamespace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let pool = try YamiboDatabase.openPool(rootDirectory: root)
    let diskCache = DiskCacheStore(writer: pool, rootDirectory: root)
    let store = ForumCacheStore(diskCacheStore: diskCache)
    let board = ForumBoardPage(
        board: ForumBoardSummary(
            fid: "49",
            name: "百合小说",
            url: ForumRouteResolver.boardURL(fid: "49")
        ),
        threads: [
            ForumThreadSummary(
                tid: "991",
                title: "缓存帖子",
                url: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=991&mobile=2"))
            )
        ],
        fetchedAt: Date(timeIntervalSince1970: 100)
    )

    try await store.saveBoard(
        board,
        fid: "49",
        pageNumber: 2,
        filterID: "type-1",
        orderFilter: "dateline",
        orderBy: "desc"
    )

    #expect(await store.loadBoard(
        fid: "49",
        page: 2,
        filterID: "type-1",
        orderFilter: "dateline",
        orderBy: "desc"
    )?.threads.first?.title == "缓存帖子")

    let rows = try await pool.read { db in
        try Row.fetchAll(
            db,
            sql: "SELECT namespace, cache_key FROM cache_entries ORDER BY cache_key"
        ).map { row in
            let namespace: String = row["namespace"]
            let key: String = row["cache_key"]
            return (namespace: namespace, key: key)
        }
    }
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.namespace == "forum-boards")
    #expect(row.key.hasPrefix("board_"))
    #expect(FileManager.default.fileExists(
        atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: root)
            .appendingPathComponent("forum-boards", isDirectory: true)
            .appendingPathComponent("\(row.key).json", isDirectory: false)
            .path
    ))
}

@Test func forumCacheStorePrunesBoardsToMostRecentFiftyEntries() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 100)
    let store = ForumCacheStore(baseDirectory: directory, now: { now })
    let board = ForumBoardSummary(
        fid: "49",
        name: "百合小说",
        url: ForumRouteResolver.boardURL(fid: "49")
    )

    for page in 1...51 {
        now = Date(timeIntervalSince1970: 100 + TimeInterval(page))
        try await store.saveBoard(
            ForumBoardPage(
                board: board,
                pageNavigation: ForumPageNavigation(currentPage: page, totalPages: nil),
                fetchedAt: now
            ),
            fid: "49",
            pageNumber: page
        )
    }

    #expect(await store.loadBoard(fid: "49", page: 1, allowExpired: true) == nil)
    #expect(await store.loadBoard(fid: "49", page: 2, allowExpired: true)?.pageNavigation?.currentPage == 2)
    #expect(await store.loadBoard(fid: "49", page: 51, allowExpired: true)?.pageNavigation?.currentPage == 51)
}

@Test func forumCacheStoreCachesThreadPagesByThreadPageAndAuthor() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 100)
    let store = ForumCacheStore(baseDirectory: directory, now: { now })
    let thread = try makeCacheTestThread(tid: "900")

    try await store.saveThreadPage(
        makeCacheTestThreadPage(thread: thread, title: "全部第一页"),
        thread: thread,
        pageNumber: 1,
        authorID: nil
    )
    try await store.saveThreadPage(
        makeCacheTestThreadPage(thread: thread, title: "全部第二页"),
        thread: thread,
        pageNumber: 2,
        authorID: nil
    )
    try await store.saveThreadPage(
        makeCacheTestThreadPage(thread: thread, title: "作者第一页"),
        thread: thread,
        pageNumber: 1,
        authorID: "42"
    )

    now = Date(timeIntervalSince1970: 100 + ForumCacheStore.threadPageTTL - 1)

    #expect(await store.loadThreadPage(thread: thread, page: 1, authorID: nil)?.title == "全部第一页")
    #expect(await store.loadThreadPage(thread: thread, page: 2, authorID: nil)?.title == "全部第二页")
    #expect(await store.loadThreadPage(thread: thread, page: 1, authorID: "42")?.title == "作者第一页")
}

@Test func forumCacheStoreReportsAndDeletesCachedThreadPageViewsByAuthor() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ForumCacheStore(baseDirectory: directory)
    let thread = try makeCacheTestThread(tid: "905")

    try await store.saveThreadPage(
        makeCacheTestThreadPage(thread: thread, title: "作者第一页"),
        thread: thread,
        pageNumber: 1,
        authorID: "42"
    )
    try await store.saveThreadPage(
        makeCacheTestThreadPage(thread: thread, title: "作者第三页"),
        thread: thread,
        pageNumber: 3,
        authorID: "42"
    )

    #expect(await store.cachedThreadPageViews(thread: thread, authorID: "42") == [1, 3])

    try await store.deleteThreadPages([1], thread: thread, authorID: "42")

    #expect(await store.cachedThreadPageViews(thread: thread, authorID: "42") == [3])
    #expect(await store.loadThreadPage(thread: thread, page: 1, authorID: "42", allowExpired: true) == nil)
    #expect(await store.loadThreadPage(thread: thread, page: 3, authorID: "42", allowExpired: true)?.title == "作者第三页")
}

@Test func forumCacheStoreExpiresThreadPagesAfterTTL() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 100)
    let store = ForumCacheStore(baseDirectory: directory, now: { now })
    let thread = try makeCacheTestThread(tid: "901")

    try await store.saveThreadPage(
        makeCacheTestThreadPage(thread: thread, title: "缓存页"),
        thread: thread,
        pageNumber: 1,
        authorID: nil
    )
    now = Date(timeIntervalSince1970: 100 + ForumCacheStore.threadPageTTL + 1)

    #expect(await store.loadThreadPage(thread: thread, page: 1, authorID: nil, allowExpired: true)?.title == "缓存页")
    #expect(await store.loadThreadPage(thread: thread, page: 1, authorID: nil) == nil)
}

@Test func forumCacheStorePrunesThreadPagesToMostRecentFiftyEntries() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 100)
    let store = ForumCacheStore(baseDirectory: directory, now: { now })
    let thread = try makeCacheTestThread(tid: "902")

    for page in 1...51 {
        now = Date(timeIntervalSince1970: 100 + TimeInterval(page))
        try await store.saveThreadPage(
            makeCacheTestThreadPage(thread: thread, title: "第\(page)页"),
            thread: thread,
            pageNumber: page,
            authorID: nil
        )
    }

    #expect(await store.loadThreadPage(thread: thread, page: 1, authorID: nil, allowExpired: true) == nil)
    #expect(await store.loadThreadPage(thread: thread, page: 2, authorID: nil)?.title == "第2页")
    #expect(await store.loadThreadPage(thread: thread, page: 51, authorID: nil)?.title == "第51页")
}

@Test func forumCacheStoreClearThreadPagesPreservesOtherForumCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ForumCacheStore(baseDirectory: directory)
    let firstThread = try makeCacheTestThread(tid: "903")
    let secondThread = try makeCacheTestThread(tid: "904")
    let home = ForumHomePage(categories: [], fetchedAt: Date(timeIntervalSince1970: 100))
    let board = ForumBoardPage(
        board: ForumBoardSummary(
            fid: "49",
            name: "百合小说",
            url: ForumRouteResolver.boardURL(fid: "49")
        ),
        fetchedAt: Date(timeIntervalSince1970: 100)
    )

    try await store.saveHome(home)
    try await store.saveBoard(board, fid: "49")
    try await store.saveThreadPage(
        makeCacheTestThreadPage(thread: firstThread, title: "目标线程"),
        thread: firstThread,
        pageNumber: 1,
        authorID: nil
    )
    try await store.saveThreadPage(
        makeCacheTestThreadPage(thread: secondThread, title: "其他线程"),
        thread: secondThread,
        pageNumber: 1,
        authorID: nil
    )

    try await store.clearThreadPages(thread: firstThread)

    #expect(await store.loadThreadPage(thread: firstThread, page: 1, authorID: nil, allowExpired: true) == nil)
    #expect(await store.loadThreadPage(thread: secondThread, page: 1, authorID: nil, allowExpired: true)?.title == "其他线程")
    #expect(await store.loadHome(allowExpired: true) != nil)
    #expect(await store.loadBoard(fid: "49", allowExpired: true)?.board.fid == "49")
}

@Test func forumCacheStoreUsesDiskCacheNamespacesAndTidFirstKeys() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let pool = try YamiboDatabase.openPool(rootDirectory: root)
    let diskCache = DiskCacheStore(writer: pool, rootDirectory: root)
    let store = ForumCacheStore(diskCacheStore: diskCache)
    let thread = ThreadIdentity(tid: "990")
    try await store.saveHome(ForumHomePage(categories: [], fetchedAt: Date(timeIntervalSince1970: 100)))

    try await store.saveThreadPage(
        makeCacheTestThreadPage(thread: thread, title: "GRDB线程页"),
        thread: thread,
        pageNumber: 4,
        authorID: "42"
    )

    #expect(await store.loadThreadPage(thread: thread, page: 4, authorID: "42")?.title == "GRDB线程页")
    #expect(await store.cachedThreadPageViews(thread: thread, authorID: "42") == [4])

    let rows = try await pool.read { db in
        try Row.fetchAll(
            db,
            sql: "SELECT namespace, cache_key FROM cache_entries ORDER BY cache_key"
        ).map { row in
            let namespace: String = row["namespace"]
            let key: String = row["cache_key"]
            return (namespace: namespace, key: key)
        }
    }
    #expect(rows.count == 2)
    #expect(rows.map(\.namespace) == ["forum-home", "forum-thread-pages"])
    #expect(rows.first(where: { $0.namespace == "forum-home" })?.key == "home")
    #expect(rows.first(where: { $0.namespace == "forum-thread-pages" })?.key == "tid_990_page_4_author_42")
    #expect(rows.first(where: { $0.namespace == "forum-thread-pages" })?.key.contains("https://") == false)

    let cacheFile = YamiboDatabase.cacheDirectoryURL(rootDirectory: root)
        .appendingPathComponent("forum-thread-pages", isDirectory: true)
        .appendingPathComponent("tid_990_page_4_author_42.json", isDirectory: false)
    #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("legacy-forum-cache", isDirectory: true).path
    ))

    try await store.deleteThreadPages([4], thread: thread, authorID: "42")
    #expect(await store.loadThreadPage(thread: thread, page: 4, authorID: "42", allowExpired: true) == nil)
}

private func makeCacheTestThread(tid: String) throws -> ThreadIdentity {
    ThreadIdentity(tid: tid)
}

private func makeCacheTestThreadPage(thread: ThreadIdentity, title: String) -> ForumThreadPage {
    ForumThreadPage(
        thread: thread,
        title: title,
        posts: [
            ForumThreadPost(
                postID: "p-\(title)",
                author: BlogReaderUser(uid: "42", name: "楼主"),
                contentHTML: "",
                contentText: title
            )
        ]
    )
}

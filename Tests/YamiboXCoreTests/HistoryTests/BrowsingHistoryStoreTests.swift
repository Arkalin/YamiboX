import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

private func makeBrowsingHistoryStore(prefix: String) throws -> BrowsingHistoryStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pool = try YamiboDatabase.openPool(rootDirectory: root)
    return BrowsingHistoryStore(databasePool: pool)
}

@Test func browsingHistoryStoreUpsertsSameTargetIntoOneRow() async throws {
    let store = try makeBrowsingHistoryStore(prefix: "history-upsert")

    try await store.record(
        BrowsingHistoryEntry(
            target: .normalThread(threadID: "100"),
            title: "First title",
            pageIndex: 1,
            lastVisitTime: Date(timeIntervalSince1970: 1_000)
        )
    )
    try await store.record(
        BrowsingHistoryEntry(
            target: .normalThread(threadID: "100"),
            title: "Renamed title",
            pageIndex: 3,
            lastVisitTime: Date(timeIntervalSince1970: 2_000)
        )
    )

    let entries = await store.entries()
    #expect(entries.count == 1)
    #expect(entries.first?.title == "Renamed title")
    #expect(entries.first?.pageIndex == 3)
    #expect(entries.first?.lastVisitTime == Date(timeIntervalSince1970: 2_000))
}

@Test func browsingHistoryStoreOrdersByLastVisitDescending() async throws {
    let store = try makeBrowsingHistoryStore(prefix: "history-order")

    try await store.record(
        BrowsingHistoryEntry(target: .normalThread(threadID: "1"), title: "Old", lastVisitTime: Date(timeIntervalSince1970: 1_000))
    )
    try await store.record(
        BrowsingHistoryEntry(target: .novelThread(threadID: "2"), title: "New", lastVisitTime: Date(timeIntervalSince1970: 3_000))
    )
    try await store.record(
        BrowsingHistoryEntry(target: .mangaThread(threadID: "3"), title: "Middle", lastVisitTime: Date(timeIntervalSince1970: 2_000))
    )

    let entries = await store.entries()
    #expect(entries.map(\.title) == ["New", "Middle", "Old"])
}

@Test func browsingHistoryStoreSingleThreadRecordAbsorbsDifferentKindRowForSameTID() async throws {
    let store = try makeBrowsingHistoryStore(prefix: "history-absorb-kind")

    // Board reconfigured between visits: the same tid was once recorded as a
    // normal thread and is now read as a novel — only the newest form stays.
    try await store.record(
        BrowsingHistoryEntry(target: .normalThread(threadID: "42"), title: "As normal", lastVisitTime: Date(timeIntervalSince1970: 1_000))
    )
    try await store.record(
        BrowsingHistoryEntry(target: .novelThread(threadID: "42"), title: "As novel", lastVisitTime: Date(timeIntervalSince1970: 2_000))
    )

    let entries = await store.entries()
    #expect(entries.count == 1)
    #expect(entries.first?.target == .novelThread(threadID: "42"))
}

@Test func browsingHistoryStoreDirectoryRecordAbsorbsMemberThreadRows() async throws {
    let store = try makeBrowsingHistoryStore(prefix: "history-absorb-members")

    try await store.record(
        BrowsingHistoryEntry(target: .mangaThread(threadID: "201"), title: "Chapter 1", lastVisitTime: Date(timeIntervalSince1970: 1_000))
    )
    try await store.record(
        BrowsingHistoryEntry(target: .mangaThread(threadID: "202"), title: "Chapter 2", lastVisitTime: Date(timeIntervalSince1970: 1_100))
    )
    try await store.record(
        BrowsingHistoryEntry(target: .normalThread(threadID: "999"), title: "Unrelated", lastVisitTime: Date(timeIntervalSince1970: 1_200))
    )

    try await store.record(
        BrowsingHistoryEntry(
            target: .mangaTitle(mangaID: "book", cleanBookName: "Book"),
            title: "Book",
            chapterThreadID: "202",
            lastVisitTime: Date(timeIntervalSince1970: 2_000)
        ),
        absorbingThreadIDs: ["201", "202", "203"]
    )

    let entries = await store.entries()
    #expect(entries.count == 2)
    #expect(entries.first?.target.kind == .mangaTitle)
    #expect(entries.contains { $0.target == .normalThread(threadID: "999") })
    #expect(!entries.contains { $0.target.kind == .mangaThread })
}

@Test func browsingHistoryStoreUpdatePositionNeverResurrectsDeletedRow() async throws {
    let store = try makeBrowsingHistoryStore(prefix: "history-update")

    let target = FavoriteContentTarget.novelThread(threadID: "77")
    try await store.record(
        BrowsingHistoryEntry(target: target, title: "Novel", lastVisitTime: Date(timeIntervalSince1970: 1_000))
    )

    await store.updatePosition(
        targetID: target.id,
        chapterTitle: "Chapter 5",
        date: Date(timeIntervalSince1970: 2_000)
    )
    var entries = await store.entries()
    #expect(entries.first?.chapterTitle == "Chapter 5")
    #expect(entries.first?.lastVisitTime == Date(timeIntervalSince1970: 2_000))
    // Fields not provided keep their previous values.
    #expect(entries.first?.title == "Novel")

    try await store.delete(id: target.id)
    await store.updatePosition(targetID: target.id, chapterTitle: "Chapter 6")
    entries = await store.entries()
    #expect(entries.isEmpty)
}

@Test func browsingHistoryStoreTrimsToMaxEntryCountByLastVisit() async throws {
    let store = try makeBrowsingHistoryStore(prefix: "history-trim")

    for index in 0..<(BrowsingHistoryStore.maxEntryCount + 5) {
        try await store.record(
            BrowsingHistoryEntry(
                target: .normalThread(threadID: "t\(index)"),
                title: "Thread \(index)",
                lastVisitTime: Date(timeIntervalSince1970: Double(index))
            )
        )
    }

    let entries = await store.entries()
    #expect(entries.count == BrowsingHistoryStore.maxEntryCount)
    // The oldest rows fell off; the newest survive.
    #expect(entries.first?.title == "Thread \(BrowsingHistoryStore.maxEntryCount + 4)")
    #expect(!entries.contains { $0.title == "Thread 0" })
}

@Test func browsingHistoryStoreFiltersByCategoryAndSearch() async throws {
    let store = try makeBrowsingHistoryStore(prefix: "history-filter")

    try await store.record(
        BrowsingHistoryEntry(target: .normalThread(threadID: "1"), title: "百合讨论帖", lastVisitTime: Date(timeIntervalSince1970: 1_000))
    )
    try await store.record(
        BrowsingHistoryEntry(target: .novelThread(threadID: "2"), title: "百合小说连载", lastVisitTime: Date(timeIntervalSince1970: 2_000))
    )
    try await store.record(
        BrowsingHistoryEntry(target: .mangaTitle(mangaID: "m", cleanBookName: "漫画作品"), title: "漫画作品", chapterThreadID: "3", lastVisitTime: Date(timeIntervalSince1970: 3_000))
    )

    let novels = await store.entries(category: .novel)
    #expect(novels.map(\.title) == ["百合小说连载"])

    let manga = await store.entries(category: .manga)
    #expect(manga.map(\.title) == ["漫画作品"])

    let searched = await store.entries(searchText: "百合")
    #expect(searched.count == 2)

    let searchedNovel = await store.entries(category: .novel, searchText: "百合")
    #expect(searchedNovel.count == 1)

    // LIKE metacharacters are escaped, not interpreted.
    let literalPercent = await store.entries(searchText: "%")
    #expect(literalPercent.isEmpty)
}

@Test func browsingHistoryStoreClearAllRemovesEverything() async throws {
    let store = try makeBrowsingHistoryStore(prefix: "history-clear")

    try await store.record(
        BrowsingHistoryEntry(target: .normalThread(threadID: "1"), title: "One")
    )
    try await store.record(
        BrowsingHistoryEntry(target: .novelThread(threadID: "2"), title: "Two")
    )
    try await store.clearAll()

    let entries = await store.entries()
    #expect(entries.isEmpty)
}

@Test func browsingHistoryStoreRecordAbsorbsSupersededEntryIDs() async throws {
    let store = try makeBrowsingHistoryStore(prefix: "history-absorb-entry-ids")

    // A directory-level row recorded under a synthetic pre-resolution
    // identity; resolution later re-records under the real identity, which
    // must absorb the old row by its exact id (directory rows have no
    // thread_id for the tid-based absorption to find).
    let syntheticTarget = FavoriteContentTarget(mangaID: "chapter:201", mangaCleanBookName: "Book")
    try await store.record(
        BrowsingHistoryEntry(target: syntheticTarget, title: "Book", chapterThreadID: "201", lastVisitTime: Date(timeIntervalSince1970: 1_000))
    )

    let resolvedTarget = FavoriteContentTarget(mangaID: "searched:book", mangaCleanBookName: "Book")
    try await store.record(
        BrowsingHistoryEntry(target: resolvedTarget, title: "Book", chapterThreadID: "201", lastVisitTime: Date(timeIntervalSince1970: 2_000)),
        absorbingEntryIDs: [syntheticTarget.id]
    )

    let entries = await store.entries()
    #expect(entries.count == 1)
    #expect(entries.first?.target == resolvedTarget)
}

@Test func readingProgressFuzzyThreadLookupIsNotShadowedByNormalThreadAnchorRow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("thread-shadow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pool = try YamiboDatabase.openPool(rootDirectory: root)
    let store = ReadingProgressStore(databasePool: pool)

    let novelPosition = NovelReadingPosition(threadID: "888", view: 3, chapterTitle: "第三章")
    _ = try await store.saveNovel(novelPosition, date: Date(timeIntervalSince1970: 1_000))
    // A discussion companion view later writes a fresher normal-thread
    // anchor row for the same tid; the fuzzy lookup novel/manga consumers
    // use must keep returning the novel record, not the anchor row.
    _ = try await store.saveNormalThread(threadID: "888", page: 2, date: Date(timeIntervalSince1970: 2_000))

    let fuzzy = await store.load(threadID: "888")
    #expect(fuzzy?.kind == .novel)
    #expect(fuzzy?.novel?.lastView == 3)

    let precise = await store.load(for: .normalThread(threadID: "888"))
    #expect(precise?.thread?.lastPage == 2)
}

@Test func readingProgressStorePersistsNormalThreadAnchor() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("normal-thread-progress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pool = try YamiboDatabase.openPool(rootDirectory: root)
    let store = ReadingProgressStore(databasePool: pool)

    _ = try await store.saveNormalThread(
        threadID: "555",
        page: 4,
        pageCount: 9,
        anchorPostID: "post-77",
        date: Date(timeIntervalSince1970: 5_000)
    )

    let loaded = await store.load(for: .normalThread(threadID: "555"))
    #expect(loaded?.kind == .thread)
    #expect(loaded?.thread?.lastPage == 4)
    #expect(loaded?.thread?.pageCount == 9)
    #expect(loaded?.thread?.anchorPostID == "post-77")

    // Upsert overwrites the same row rather than adding a second one.
    _ = try await store.saveNormalThread(threadID: "555", page: 6, anchorPostID: nil)
    let updated = await store.load(for: .normalThread(threadID: "555"))
    #expect(updated?.thread?.lastPage == 6)
    #expect(updated?.thread?.anchorPostID == nil)
}

import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

private func novelAnchor(
    chapter: String = "chapter-1",
    segment: String? = "chapter-1#text:0",
    offset: Int,
    view: Int = 1,
    chapterOrdinal: Int = 0,
    chapterTitle: String? = nil
) -> BookmarkAnchorPayload {
    .novel(
        NovelBookmarkAnchor(
            chapterIdentity: NovelChapterIdentity(rawValue: chapter),
            textSegmentIdentity: segment.map { NovelTextSegmentIdentity(rawValue: $0) },
            displayedTextOffset: offset,
            view: view,
            chapterOrdinal: chapterOrdinal,
            chapterTitle: chapterTitle
        )
    )
}

@Test func bookmarkStoreTogglesOnAndOffAtTheSamePlace() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkTestDatabasePool(prefix: "bookmark-toggle"))
    let workKey = LikeWorkKey.novel(threadID: "100")
    let anchor = novelAnchor(offset: 120)

    let added = try await store.toggle(workKey: workKey, anchor: anchor, excerptText: "第一行快照")
    #expect(added.isBookmarked)
    #expect(await store.bookmarks(for: workKey).count == 1)

    let removed = try await store.toggle(workKey: workKey, anchor: anchor)
    #expect(removed.isBookmarked == false)
    #expect(await store.bookmarks(for: workKey).isEmpty)

    // Removal is a tombstone, not a physical delete, so a stale remote
    // snapshot cannot resurrect it later.
    let includingDeleted = await store.allIncludingDeleted()
    #expect(includingDeleted.first?.deletedAt != nil)
}

@Test func bookmarkStoreToggleTreatsNearbyOffsetInSameSegmentAsTheSamePlace() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkTestDatabasePool(prefix: "bookmark-neighborhood"))
    let workKey = LikeWorkKey.novel(threadID: "101")

    try await store.toggle(workKey: workKey, anchor: novelAnchor(offset: 100))
    // Inside the neighborhood radius: this is "the place is already
    // bookmarked", so the toggle removes rather than adding a second row.
    let nearby = try await store.toggle(workKey: workKey, anchor: novelAnchor(offset: 100 + NovelBookmarkAnchor.neighborhoodCharacterRadius))

    #expect(nearby.isBookmarked == false)
    #expect(await store.bookmarks(for: workKey).isEmpty)
}

@Test func bookmarkStoreToggleAddsSecondRowOnceOutsideTheNeighborhood() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkTestDatabasePool(prefix: "bookmark-outside"))
    let workKey = LikeWorkKey.novel(threadID: "102")

    try await store.toggle(workKey: workKey, anchor: novelAnchor(offset: 100))
    // One character past the radius: the agreed rule is "scrolling away flips
    // the button back to unmarked", so this must add rather than delete —
    // duplicates are recoverable, deleting an off-screen bookmark is not.
    let second = try await store.toggle(workKey: workKey, anchor: novelAnchor(offset: 101 + NovelBookmarkAnchor.neighborhoodCharacterRadius))

    #expect(second.isBookmarked)
    #expect(await store.bookmarks(for: workKey).count == 2)
}

@Test func bookmarkStoreToggleTreatsDifferentSegmentsAsDifferentPlaces() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkTestDatabasePool(prefix: "bookmark-segments"))
    let workKey = LikeWorkKey.novel(threadID: "103")

    try await store.toggle(workKey: workKey, anchor: novelAnchor(segment: "chapter-1#text:0", offset: 10))
    try await store.toggle(workKey: workKey, anchor: novelAnchor(segment: "chapter-1#text:1", offset: 10))

    #expect(await store.bookmarks(for: workKey).count == 2)
}

@Test func bookmarkStoreTogglesMangaPagesExactly() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkTestDatabasePool(prefix: "bookmark-manga"))
    let workKey = LikeWorkKey.mangaTitle(cleanBookName: "测试漫画")
    let page3 = BookmarkAnchorPayload.manga(
        MangaBookmarkAnchor(chapterTID: "900", pageLocalIndex: 3, globalPageIndex: 12, forumID: "44")
    )
    let page4 = BookmarkAnchorPayload.manga(
        MangaBookmarkAnchor(chapterTID: "900", pageLocalIndex: 4, globalPageIndex: 13, forumID: "44")
    )

    try await store.toggle(workKey: workKey, anchor: page3)
    try await store.toggle(workKey: workKey, anchor: page4)
    #expect(await store.bookmarks(for: workKey).count == 2)

    // Manga pages are discrete, so "the same place" is exact page equality —
    // no neighborhood radius applies.
    let removed = try await store.toggle(workKey: workKey, anchor: page3)
    #expect(removed.isBookmarked == false)
    #expect(await store.bookmarks(for: workKey).count == 1)
}

@Test func bookmarkStoreOrdersByBookOrderNotCreationTime() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkTestDatabasePool(prefix: "bookmark-order"))
    let workKey = LikeWorkKey.novel(threadID: "104")

    // Created out of order on purpose: the panel sorts by the persisted
    // sortKey so rows follow reading order, not when the user tapped.
    try await store.toggle(workKey: workKey, anchor: novelAnchor(segment: "chapter-3#text:0", offset: 5, view: 3, chapterOrdinal: 2), excerptText: "第三章")
    try await store.toggle(workKey: workKey, anchor: novelAnchor(segment: "chapter-1#text:0", offset: 5, view: 1, chapterOrdinal: 0), excerptText: "第一章")
    try await store.toggle(workKey: workKey, anchor: novelAnchor(segment: "chapter-2#text:0", offset: 5, view: 2, chapterOrdinal: 1), excerptText: "第二章")

    let ordered = await store.bookmarks(for: workKey).compactMap(\.excerptText)
    #expect(ordered == ["第一章", "第二章", "第三章"])
}

@Test func bookmarkStoreCountsOnlyLiveRowsOfOneWork() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkTestDatabasePool(prefix: "bookmark-count"))
    let novel = LikeWorkKey.novel(threadID: "105")
    let other = LikeWorkKey.novel(threadID: "106")

    try await store.toggle(workKey: novel, anchor: novelAnchor(offset: 0))
    try await store.toggle(workKey: novel, anchor: novelAnchor(segment: "chapter-1#text:1", offset: 0))
    try await store.toggle(workKey: other, anchor: novelAnchor(offset: 0))
    let live = await store.bookmarks(for: novel)
    try await store.delete(id: try #require(live.first).id)

    #expect(await store.count(for: novel) == 1)
    #expect(await store.count(for: other) == 1)
}

@Test func bookmarkStoreFindsTheBookmarkMarkingAGivenPlace() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkTestDatabasePool(prefix: "bookmark-marking"))
    let workKey = LikeWorkKey.novel(threadID: "107")
    try await store.toggle(workKey: workKey, anchor: novelAnchor(offset: 500), excerptText: "命中")

    let hit = await store.bookmark(marking: novelAnchor(offset: 510), in: workKey)
    let miss = await store.bookmark(marking: novelAnchor(offset: 5_000), in: workKey)

    #expect(hit?.excerptText == "命中")
    #expect(miss == nil)
}

@Test func bookmarkStoreRenamesMangaTitleBookmarksWithTheDirectory() async throws {
    let pool = try makeBookmarkTestDatabasePool(prefix: "bookmark-rename")
    let store = BookmarkStore(databasePool: pool)
    try await store.toggle(
        workKey: .mangaTitle(cleanBookName: "旧名"),
        anchor: .manga(MangaBookmarkAnchor(chapterTID: "1", pageLocalIndex: 0, globalPageIndex: 0))
    )

    try await pool.write { db in
        try BookmarkStore.renameMangaTitleBookmarks(from: "旧名", to: "新名", in: db)
    }

    #expect(await store.bookmarks(for: .mangaTitle(cleanBookName: "旧名")).isEmpty)
    #expect(await store.bookmarks(for: .mangaTitle(cleanBookName: "新名")).count == 1)
}

private func makeBookmarkTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}

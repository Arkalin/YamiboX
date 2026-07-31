import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

private let regressionChapter = NovelChapterIdentity(rawValue: "post:9#chapter:0")
private func regressionSegment(_ occurrence: Int) -> NovelTextSegmentIdentity {
    NovelTextSegmentIdentity(rawValue: "post:9#chapter:0#text:\(occurrence)")
}

private func regressionAnchor(length: Int = 4) -> NovelTextLikeAnchor {
    NovelTextLikeAnchor(
        chapterIdentity: regressionChapter,
        textSegmentIdentity: regressionSegment(0),
        range: NovelCharacterRange(location: 0, length: length),
        view: 1,
        resolvedAuthorID: nil
    )
}

@Test func downloadingAFlattenedPayloadKeepsStyleAndNote() async throws {
    let store = LikeStore(databasePool: try makeRegressionDatabasePool(prefix: "like-apply-remote"))
    let participant = LikeLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.novel(threadID: "1")
    let writtenAt = Date(timeIntervalSince1970: 1_000)

    let created = try await store.upsertTextLike(
        workKey: workKey,
        anchor: regressionAnchor(),
        excerptText: "重要的一句",
        style: .purple,
        date: writtenAt
    )
    _ = try await store.updateNote(id: created.item.id, note: "重要", date: writtenAt)

    // A client too old to know about style/note re-exports the payload for an
    // unrelated reason: the row survives with the SAME updatedAt but its style
    // is back at the default and its note is gone.
    let flattened = LikeItem(
        id: created.item.id,
        workKey: workKey,
        kind: .text,
        excerptText: "重要的一句",
        anchor: .novelText(regressionAnchor()),
        createdAt: writtenAt,
        updatedAt: writtenAt
    )
    let remoteData = try JSONEncoder().encode(
        LikeLibraryWebDAVPayload(updatedAt: writtenAt, items: [flattened], tombstones: [:])
    )

    // `applyRemote` is a straight overwrite, so without a same-version salvage
    // this permanently wipes every colour and note the user had.
    try await participant.applyRemote(remoteData)

    let reloaded = await store.likes(for: workKey).first
    #expect(reloaded?.style == .purple)
    #expect(reloaded?.note == "重要")
}

@Test func downloadingAGenuineEditStillWins() async throws {
    let store = LikeStore(databasePool: try makeRegressionDatabasePool(prefix: "like-apply-remote-edit"))
    let participant = LikeLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.novel(threadID: "2")
    let writtenAt = Date(timeIntervalSince1970: 1_000)
    let editedAt = Date(timeIntervalSince1970: 2_000)

    let created = try await store.upsertTextLike(
        workKey: workKey,
        anchor: regressionAnchor(),
        excerptText: "文本",
        style: .purple,
        date: writtenAt
    )
    _ = try await store.updateNote(id: created.item.id, note: "旧笔记", date: writtenAt)

    // Another device deliberately recoloured it back to yellow and cleared the
    // note — a real edit, so its updatedAt is newer. The salvage must not undo
    // that.
    let edited = LikeItem(
        id: created.item.id,
        workKey: workKey,
        kind: .text,
        excerptText: "文本",
        anchor: .novelText(regressionAnchor()),
        style: .yellow,
        note: nil,
        createdAt: writtenAt,
        updatedAt: editedAt
    )
    let remoteData = try JSONEncoder().encode(
        LikeLibraryWebDAVPayload(updatedAt: editedAt, items: [edited], tombstones: [:])
    )

    try await participant.applyRemote(remoteData)

    let reloaded = await store.likes(for: workKey).first
    #expect(reloaded?.style == .yellow)
    #expect(reloaded?.note == nil)
}

@Test func spanningAnchorDegradesToARenderableLegacyRange() throws {
    // The two offsets index DIFFERENT segments, so their difference is
    // meaningless and usually negative. A zero-length legacy range decodes back
    // as start == end and the highlight disappears entirely.
    let anchor = NovelTextLikeAnchor(
        chapterIdentity: regressionChapter,
        start: NovelLikeTextEndpoint(segmentIdentity: regressionSegment(0).rawValue, offset: 120),
        end: NovelLikeTextEndpoint(segmentIdentity: regressionSegment(1).rawValue, offset: 30),
        view: 1,
        resolvedAuthorID: nil
    )

    let object = try #require(
        try JSONSerialization.jsonObject(with: try JSONEncoder().encode(anchor)) as? [String: Any]
    )
    let legacyRange = try #require(object["range"] as? [String: Any])

    #expect(legacyRange["location"] as? Int == 120)
    #expect((legacyRange["length"] as? Int ?? 0) >= 1)
}

@Test func bookmarkMergeCollapsesTwoDevicesBookmarkingTheSamePlace() async throws {
    let store = BookmarkStore(databasePool: try makeRegressionDatabasePool(prefix: "bookmark-dedupe"))
    let participant = BookmarkLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.mangaTitle(cleanBookName: "书名")
    let place = BookmarkAnchorPayload.manga(
        MangaBookmarkAnchor(chapterTID: "12", pageLocalIndex: 4, globalPageIndex: 40)
    )

    // This device's row.
    try await store.toggle(
        workKey: workKey,
        anchor: place,
        date: Date(timeIntervalSince1970: 1_000)
    )
    // The other device bookmarked the same page before syncing, so it minted a
    // different id for the same place.
    let remoteTwin = BookmarkItem(
        id: "other-device",
        workKey: workKey,
        anchor: place,
        createdAt: Date(timeIntervalSince1970: 2_000),
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )
    let remoteData = try JSONEncoder().encode(
        BookmarkLibraryWebDAVPayload(updatedAt: .now, items: [remoteTwin], tombstones: [:])
    )

    _ = try await participant.mergeAndExport(remoteData: remoteData, updatedAt: .now, accountUID: "acct")

    // Two rows for one place would make the toggle remove only one, so the
    // button flips straight back to bookmarked and the panel lists a duplicate.
    let live = await store.bookmarks(for: workKey)
    #expect(live.count == 1)
    // The earliest-created row survives, which every device agrees on without
    // coordinating.
    #expect(live.first?.createdAt == Date(timeIntervalSince1970: 1_000))
}

@Test func bookmarkMergeKeepsDistinctPlaces() async throws {
    let store = BookmarkStore(databasePool: try makeRegressionDatabasePool(prefix: "bookmark-dedupe-distinct"))
    let participant = BookmarkLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.mangaTitle(cleanBookName: "书名")

    try await store.toggle(
        workKey: workKey,
        anchor: .manga(MangaBookmarkAnchor(chapterTID: "12", pageLocalIndex: 4, globalPageIndex: 40))
    )
    let remoteOtherPage = BookmarkItem(
        id: "other-page",
        workKey: workKey,
        anchor: .manga(MangaBookmarkAnchor(chapterTID: "12", pageLocalIndex: 5, globalPageIndex: 41))
    )
    let remoteData = try JSONEncoder().encode(
        BookmarkLibraryWebDAVPayload(updatedAt: .now, items: [remoteOtherPage], tombstones: [:])
    )

    _ = try await participant.mergeAndExport(remoteData: remoteData, updatedAt: .now, accountUID: "acct")

    #expect(await store.bookmarks(for: workKey).count == 2)
}

private func makeRegressionDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}

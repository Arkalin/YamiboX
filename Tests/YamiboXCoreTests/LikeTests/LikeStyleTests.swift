import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

private func textAnchor(location: Int = 0, length: Int = 4) -> NovelTextLikeAnchor {
    NovelTextLikeAnchor(
        chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
        range: NovelCharacterRange(location: location, length: length),
        view: 1,
        resolvedAuthorID: nil
    )
}

@Test func likeItemDecodesWithoutAStyleFieldAsYellow() throws {
    // A payload written by a client that predates styles must still decode:
    // the Like Library payload version is deliberately not bumped for additive
    // fields, so old clients keep syncing.
    let json = """
    {
      "id": "legacy",
      "workKey": { "kind": "novel", "id": "1" },
      "kind": "text",
      "excerptText": "旧数据",
      "anchor": { "novelText": { "_0": {
        "chapterIdentity": { "rawValue": "chapter-1" },
        "textSegmentIdentity": { "rawValue": "chapter-1#text:0" },
        "range": { "location": 0, "length": 3 },
        "view": 1
      } } },
      "createdAt": 0,
      "updatedAt": 0
    }
    """
    let data = try #require(json.data(using: .utf8))

    let item = try JSONDecoder().decode(LikeItem.self, from: data)

    #expect(item.style == .yellow)
    #expect(item.excerptText == "旧数据")
}

@Test func likeItemRoundTripsItsStyle() throws {
    let item = LikeItem(
        workKey: .novel(threadID: "1"),
        kind: .text,
        excerptText: "文本",
        anchor: .novelText(textAnchor()),
        style: .purple
    )

    let decoded = try JSONDecoder().decode(LikeItem.self, from: try JSONEncoder().encode(item))

    #expect(decoded.style == .purple)
}

@Test func likeStoreMigratesExistingRowsToYellow() async throws {
    let store = LikeStore(databasePool: try makeLikeStyleTestDatabasePool(prefix: "like-style-default"))
    let workKey = LikeWorkKey.novel(threadID: "1")

    try await store.upsertTextLike(workKey: workKey, anchor: textAnchor(), excerptText: "文本")

    #expect(await store.likes(for: workKey).first?.style == .yellow)
}

@Test func likeStorePersistsAndUpdatesStyle() async throws {
    let store = LikeStore(databasePool: try makeLikeStyleTestDatabasePool(prefix: "like-style-update"))
    let workKey = LikeWorkKey.novel(threadID: "2")
    let created = try await store.upsertTextLike(
        workKey: workKey,
        anchor: textAnchor(),
        excerptText: "文本",
        style: .blue
    )
    #expect(created.item.style == .blue)

    let updated = try await store.updateStyle(id: created.item.id, style: .underline)

    #expect(updated?.style == .underline)
    #expect(await store.likes(for: workKey).first?.style == .underline)
}

@Test func likeStoreUpdateStyleDoesNotMergeNeighbouringRanges() async throws {
    let store = LikeStore(databasePool: try makeLikeStyleTestDatabasePool(prefix: "like-style-nomerge"))
    let workKey = LikeWorkKey.novel(threadID: "3")
    let first = try await store.upsertTextLike(
        id: "first",
        workKey: workKey,
        anchor: textAnchor(location: 0, length: 10),
        excerptText: "AAAAAAAAAA"
    )
    try await store.upsertTextLike(
        id: "second",
        workKey: workKey,
        anchor: textAnchor(location: 40, length: 5),
        excerptText: "BBBBB"
    )

    // Recolouring is not a new selection, so it must not run the overlap merge
    // that `upsertTextLike` does — otherwise changing a colour could silently
    // swallow a neighbouring annotation.
    _ = try await store.updateStyle(id: first.item.id, style: .green)

    let likes = await store.likes(for: workKey)
    #expect(likes.count == 2)
    #expect(likes.first { $0.id == "first" }?.style == .green)
    #expect(likes.first { $0.id == "second" }?.style == .yellow)
}

@Test func likeStoreUpdateStyleBumpsUpdatedAtSoTheDatasetSyncs() async throws {
    let store = LikeStore(databasePool: try makeLikeStyleTestDatabasePool(prefix: "like-style-updatedat"))
    let workKey = LikeWorkKey.novel(threadID: "4")
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let recoloredAt = Date(timeIntervalSince1970: 2_000)
    let created = try await store.upsertTextLike(
        workKey: workKey,
        anchor: textAnchor(),
        excerptText: "文本",
        date: createdAt
    )

    let updated = try await store.updateStyle(id: created.item.id, style: .pink, date: recoloredAt)

    #expect(updated?.updatedAt == recoloredAt)
    // The creation timestamp must survive, or "book order" and "recently
    // added" listings would reshuffle every time a colour changes.
    #expect(updated?.createdAt == createdAt)
}

@Test func likeStoreUpdateStyleIgnoresAnUnknownID() async throws {
    let store = LikeStore(databasePool: try makeLikeStyleTestDatabasePool(prefix: "like-style-missing"))

    let updated = try await store.updateStyle(id: "does-not-exist", style: .green)

    #expect(updated == nil)
}

@Test func mergingCaptureAdoptsTheNewStyleForTheWholeRange() async throws {
    let store = LikeStore(databasePool: try makeLikeStyleTestDatabasePool(prefix: "like-style-merge"))
    let workKey = LikeWorkKey.novel(threadID: "5")
    try await store.upsertTextLike(
        id: "old",
        workKey: workKey,
        anchor: textAnchor(location: 0, length: 10),
        excerptText: "AAAAAAAAAA",
        style: .green
    )

    // The union range is one annotation, so it can only carry one style — the
    // one the user just picked.
    let merged = try await store.upsertTextLike(
        id: "old",
        workKey: workKey,
        anchor: textAnchor(location: 0, length: 15),
        excerptText: "AAAAAAAAAABBBBB",
        style: .blue
    )

    #expect(merged.item.style == .blue)
}

private func makeLikeStyleTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}

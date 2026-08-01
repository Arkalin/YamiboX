import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

private let chapter = NovelChapterIdentity(rawValue: "post:9#chapter:0")
private func segment(_ occurrence: Int) -> NovelTextSegmentIdentity {
    NovelTextSegmentIdentity(rawValue: "post:9#chapter:0#text:\(occurrence)")
}

private func spanningAnchor(
    fromSegment: Int,
    fromOffset: Int,
    toSegment: Int,
    toOffset: Int
) -> NovelTextLikeAnchor {
    NovelTextLikeAnchor(
        chapterIdentity: chapter,
        start: NovelLikeTextEndpoint(segmentIdentity: segment(fromSegment).rawValue, offset: fromOffset),
        end: NovelLikeTextEndpoint(segmentIdentity: segment(toSegment).rawValue, offset: toOffset),
        view: 1,
        resolvedAuthorID: nil
    )
}

@Test func novelTextLikeAnchorDecodesTheLegacySingleSegmentShape() throws {
    // Every row written before the anchor gained a second endpoint has this
    // shape, and an old client re-exporting a payload still produces it.
    let json = """
    {
      "chapterIdentity": { "rawValue": "post:9#chapter:0" },
      "textSegmentIdentity": { "rawValue": "post:9#chapter:0#text:2" },
      "range": { "location": 10, "length": 5 },
      "view": 3
    }
    """
    let data = try #require(json.data(using: .utf8))

    let anchor = try JSONDecoder().decode(NovelTextLikeAnchor.self, from: data)

    #expect(anchor.spansMultipleSegments == false)
    #expect(anchor.start == NovelLikeTextEndpoint(segmentIdentity: "post:9#chapter:0#text:2", offset: 10))
    #expect(anchor.end == NovelLikeTextEndpoint(segmentIdentity: "post:9#chapter:0#text:2", offset: 15))
    #expect(anchor.singleSegmentRange == NovelCharacterRange(location: 10, length: 5))
    #expect(anchor.view == 3)
}

@Test func novelTextLikeAnchorRoundTripsASpanningRange() throws {
    let anchor = spanningAnchor(fromSegment: 0, fromOffset: 4, toSegment: 1, toOffset: 6)

    let decoded = try JSONDecoder().decode(
        NovelTextLikeAnchor.self,
        from: try JSONEncoder().encode(anchor)
    )

    #expect(decoded == anchor)
    #expect(decoded.spansMultipleSegments)
    // A spanning anchor has no single range by definition.
    #expect(decoded.singleSegmentRange == nil)
}

@Test func novelTextLikeAnchorStillEncodesTheLegacyKeysForOldClients() throws {
    let anchor = spanningAnchor(fromSegment: 0, fromOffset: 4, toSegment: 1, toOffset: 6)

    let data = try JSONEncoder().encode(anchor)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    // A client that predates endpoints reads only these; without them it would
    // fail to decode the payload entirely rather than merely degrading.
    let legacySegment = try #require(object["textSegmentIdentity"] as? [String: Any])
    #expect(legacySegment["rawValue"] as? String == segment(0).rawValue)
    let legacyRange = try #require(object["range"] as? [String: Any])
    #expect(legacyRange["location"] as? Int == 4)
}

@Test func endpointOrderingTreatsAdjacentSegmentsInOneChapterAsTouching() {
    // The illustration that splits a chapter's text into two segments is a
    // layout break, not a semantic one, so ranges either side of it merge.
    let before = spanningAnchor(fromSegment: 0, fromOffset: 0, toSegment: 0, toOffset: 10)
    let after = spanningAnchor(fromSegment: 1, fromOffset: 0, toSegment: 1, toOffset: 10)
    let spanning = spanningAnchor(fromSegment: 0, fromOffset: 5, toSegment: 1, toOffset: 5)

    #expect(NovelLikeTextEndpointOrdering.overlapsOrTouches(before, spanning))
    #expect(NovelLikeTextEndpointOrdering.overlapsOrTouches(after, spanning))

    // Different chapters never touch, whatever their offsets.
    let otherChapter = NovelTextLikeAnchor(
        chapterIdentity: NovelChapterIdentity(rawValue: "post:10#chapter:0"),
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "post:10#chapter:0#text:0"),
        range: NovelCharacterRange(location: 0, length: 10),
        view: 1,
        resolvedAuthorID: nil
    )
    #expect(NovelLikeTextEndpointOrdering.overlapsOrTouches(otherChapter, spanning) == false)
}

@Test func captureRejectsASelectionThatCrossesPosts() async throws {
    let store = LikeStore(databasePool: try makeSpanTestDatabasePool(prefix: "like-span-crosschapter"))
    let service = NovelTextLikeCaptureService(likeStore: store)

    await #expect(throws: (any Error).self) {
        try await service.like(
            NovelTextLikeCaptureRequest(
                workKey: .novel(threadID: "1"),
                start: NovelTextViewportSemanticTextPosition(
                    chapterIdentity: chapter,
                    textSegmentIdentity: segment(0),
                    displayedTextOffset: 0,
                    progressInTextRange: 0
                ),
                end: NovelTextViewportSemanticTextPosition(
                    chapterIdentity: NovelChapterIdentity(rawValue: "post:10#chapter:0"),
                    textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "post:10#chapter:0#text:0"),
                    displayedTextOffset: 5,
                    progressInTextRange: 0
                ),
                excerptText: "跨楼层",
                view: 1,
                resolvedAuthorID: nil
            )
        )
    }
}

@Test func captureStoresASelectionThatCrossesAnIllustration() async throws {
    let store = LikeStore(databasePool: try makeSpanTestDatabasePool(prefix: "like-span-capture"))
    let service = NovelTextLikeCaptureService(likeStore: store)
    let workKey = LikeWorkKey.novel(threadID: "2")

    let outcome = try await service.like(
        NovelTextLikeCaptureRequest(
            workKey: workKey,
            start: NovelTextViewportSemanticTextPosition(
                chapterIdentity: chapter,
                textSegmentIdentity: segment(0),
                displayedTextOffset: 8,
                progressInTextRange: 0
            ),
            end: NovelTextViewportSemanticTextPosition(
                chapterIdentity: chapter,
                textSegmentIdentity: segment(1),
                displayedTextOffset: 3,
                progressInTextRange: 0
            ),
            excerptText: "图前的话\n\n图后的话",
            view: 1,
            resolvedAuthorID: nil
        )
    )

    guard case let .added(item) = outcome,
          case let .novelText(anchor) = item.anchor else {
        Issue.record("expected an added novelText outcome, got \(outcome)")
        return
    }
    #expect(anchor.spansMultipleSegments)
    #expect(anchor.start.segmentIdentity == segment(0).rawValue)
    #expect(anchor.end.segmentIdentity == segment(1).rawValue)
    // The separator between segments is already "\n\n" in the composed
    // document, so the excerpt reads with the break intact.
    #expect(item.excerptText == "图前的话\n\n图后的话")
}

@Test func captureNormalizesABackwardsDragAcrossSegments() async throws {
    let store = LikeStore(databasePool: try makeSpanTestDatabasePool(prefix: "like-span-backwards"))
    let service = NovelTextLikeCaptureService(likeStore: store)

    let outcome = try await service.like(
        NovelTextLikeCaptureRequest(
            workKey: .novel(threadID: "3"),
            // Dragged right-to-left: the later segment is reported first.
            start: NovelTextViewportSemanticTextPosition(
                chapterIdentity: chapter,
                textSegmentIdentity: segment(1),
                displayedTextOffset: 3,
                progressInTextRange: 0
            ),
            end: NovelTextViewportSemanticTextPosition(
                chapterIdentity: chapter,
                textSegmentIdentity: segment(0),
                displayedTextOffset: 8,
                progressInTextRange: 0
            ),
            excerptText: "文本",
            view: 1,
            resolvedAuthorID: nil
        )
    )

    guard case let .added(item) = outcome, case let .novelText(anchor) = item.anchor else {
        Issue.record("expected an added novelText outcome, got \(outcome)")
        return
    }
    // Document order, not drag order, decides which endpoint is the start.
    #expect(anchor.start.segmentIdentity == segment(0).rawValue)
    #expect(anchor.end.segmentIdentity == segment(1).rawValue)
}

@Test func overlapMergeLeavesATombstoneForEverythingItSubsumes() async throws {
    let store = LikeStore(databasePool: try makeSpanTestDatabasePool(prefix: "like-span-tombstone"))
    let workKey = LikeWorkKey.novel(threadID: "4")
    try await store.upsertTextLike(
        id: "subsumed",
        workKey: workKey,
        anchor: NovelTextLikeAnchor(
            chapterIdentity: chapter,
            textSegmentIdentity: segment(0),
            range: NovelCharacterRange(location: 0, length: 10),
            view: 1,
            resolvedAuthorID: nil
        ),
        excerptText: "AAAAAAAAAA"
    )

    try await store.upsertTextLike(
        id: "survivor",
        workKey: workKey,
        anchor: NovelTextLikeAnchor(
            chapterIdentity: chapter,
            textSegmentIdentity: segment(0),
            range: NovelCharacterRange(location: 0, length: 20),
            view: 1,
            resolvedAuthorID: nil
        ),
        excerptText: "AAAAAAAAAABBBBBBBBBB"
    )

    // Physically deleting the subsumed row would leave it out of BOTH `items`
    // and `tombstones` on the next export, so the remote copy would come back
    // as an unseen new item and the merged-away highlight would reappear.
    let all = await store.allIncludingDeleted()
    #expect(all.first { $0.id == "subsumed" }?.deletedAt != nil)
    #expect(await store.likes(for: workKey).map(\.id) == ["survivor"])
}

@Test func likeStoreOrdersByBookPositionAndSharpensItWithResolvedChapterOrdinals() async throws {
    let store = LikeStore(databasePool: try makeSpanTestDatabasePool(prefix: "like-span-sortkey"))
    let workKey = LikeWorkKey.novel(threadID: "5")
    let firstPost = NovelChapterIdentity(rawValue: "post:100#chapter:0")
    let secondPost = NovelChapterIdentity(rawValue: "post:99#chapter:0")

    // Two posts sharing one forum page. Their segment occurrence counters both
    // start at 0, so before the ordinals are resolved the keys tie.
    try await store.upsertTextLike(
        id: "second-post",
        workKey: workKey,
        anchor: NovelTextLikeAnchor(
            chapterIdentity: secondPost,
            textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "post:99#chapter:0#text:0"),
            range: NovelCharacterRange(location: 0, length: 4),
            view: 1,
            resolvedAuthorID: nil
        ),
        excerptText: "第二楼"
    )
    try await store.upsertTextLike(
        id: "first-post",
        workKey: workKey,
        anchor: NovelTextLikeAnchor(
            chapterIdentity: firstPost,
            textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "post:100#chapter:0#text:0"),
            range: NovelCharacterRange(location: 0, length: 4),
            view: 1,
            resolvedAuthorID: nil
        ),
        excerptText: "第一楼"
    )

    // The reader lays the page out and reports where each post actually sits.
    await store.resolveChapterOrdinals([firstPost: 0, secondPost: 1], for: workKey)

    let ordered = await store.likes(for: workKey).compactMap(\.excerptText)
    #expect(ordered == ["第一楼", "第二楼"])
}

@Test func resolvingChapterOrdinalsDoesNotTouchUpdatedAt() async throws {
    let store = LikeStore(databasePool: try makeSpanTestDatabasePool(prefix: "like-span-sortkey-clean"))
    let workKey = LikeWorkKey.novel(threadID: "6")
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let created = try await store.upsertTextLike(
        workKey: workKey,
        anchor: NovelTextLikeAnchor(
            chapterIdentity: chapter,
            textSegmentIdentity: segment(0),
            range: NovelCharacterRange(location: 0, length: 4),
            view: 1,
            resolvedAuthorID: nil
        ),
        excerptText: "文本",
        date: createdAt
    )

    await store.resolveChapterOrdinals([chapter: 7], for: workKey)

    // The sort key is local derived state; bumping `updatedAt` would mark the
    // whole Like dataset dirty and re-upload it on every reader launch.
    let reloaded = await store.like(id: created.item.id)
    #expect(reloaded?.updatedAt == createdAt)
    #expect(reloaded?.chapterOrdinal == 7)
}

private func makeSpanTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}

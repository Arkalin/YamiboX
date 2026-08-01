import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

private func noteTestAnchor(location: Int, length: Int) -> NovelTextLikeAnchor {
    NovelTextLikeAnchor(
        chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
        range: NovelCharacterRange(location: location, length: length),
        view: 1,
        resolvedAuthorID: nil
    )
}

@Test func likeItemTreatsAWhitespaceOnlyNoteAsAbsent() {
    let base = LikeItem(
        workKey: .novel(threadID: "1"),
        kind: .text,
        anchor: .novelText(noteTestAnchor(location: 0, length: 1))
    )
    var withBlank = base
    withBlank.note = "   \n "
    var withText = base
    withText.note = "有内容"

    #expect(base.hasNote == false)
    #expect(withBlank.hasNote == false)
    #expect(withText.hasNote)
}

@Test func likeItemDecodesWithoutANoteField() throws {
    // Same tolerance contract as `style`: an old client's payload must decode.
    let json = """
    {
      "id": "legacy",
      "workKey": { "kind": "novel", "id": "1" },
      "kind": "text",
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

    #expect(item.note == nil)
}

@Test func likeStorePersistsAndClearsANote() async throws {
    let store = LikeStore(databasePool: try makeLikeNoteTestDatabasePool(prefix: "like-note-update"))
    let workKey = LikeWorkKey.novel(threadID: "1")
    let created = try await store.upsertTextLike(
        workKey: workKey,
        anchor: noteTestAnchor(location: 0, length: 4),
        excerptText: "文本"
    )

    let written = try await store.updateNote(id: created.item.id, note: "这句写得好")
    #expect(written?.note == "这句写得好")

    // Clearing the editor removes the note without removing the annotation —
    // that is the whole difference between "remove note" and "remove like".
    let cleared = try await store.updateNote(id: created.item.id, note: "   ")
    #expect(cleared?.note == nil)
    #expect(await store.likes(for: workKey).count == 1)
}

@Test func likeStoreUpdateNoteDoesNotMergeNeighbouringRanges() async throws {
    let store = LikeStore(databasePool: try makeLikeNoteTestDatabasePool(prefix: "like-note-nomerge"))
    let workKey = LikeWorkKey.novel(threadID: "2")
    let first = try await store.upsertTextLike(
        id: "first",
        workKey: workKey,
        anchor: noteTestAnchor(location: 0, length: 10),
        excerptText: "AAAAAAAAAA"
    )
    try await store.upsertTextLike(
        id: "second",
        workKey: workKey,
        anchor: noteTestAnchor(location: 40, length: 5),
        excerptText: "BBBBB"
    )

    _ = try await store.updateNote(id: first.item.id, note: "笔记")

    #expect(await store.likes(for: workKey).count == 2)
}

@Test func mergingCaptureConcatenatesSubsumedNotesInDocumentOrder() async throws {
    let store = LikeStore(databasePool: try makeLikeNoteTestDatabasePool(prefix: "like-note-merge"))
    let service = NovelTextLikeCaptureService(likeStore: store)
    let workKey = LikeWorkKey.novel(threadID: "3")

    // Two annotated ranges, created out of document order on purpose.
    try await store.upsertTextLike(
        id: "later",
        workKey: workKey,
        anchor: noteTestAnchor(location: 20, length: 10),
        excerptText: "BBBBBBBBBB",
        note: "第二条笔记"
    )
    try await store.upsertTextLike(
        id: "earlier",
        workKey: workKey,
        anchor: noteTestAnchor(location: 0, length: 10),
        excerptText: "AAAAAAAAAA",
        note: "第一条笔记"
    )

    // A new selection spanning both must not silently drop either note —
    // losing text the user typed is not recoverable.
    let outcome = try await service.like(
        NovelTextLikeCaptureRequest(
            workKey: workKey,
            start: NovelTextViewportSemanticTextPosition(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
                displayedTextOffset: 0,
                progressInTextRange: 0
            ),
            end: NovelTextViewportSemanticTextPosition(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
                displayedTextOffset: 30,
                progressInTextRange: 0
            ),
            excerptText: "AAAAAAAAAA          BBBBBBBBBB",
            view: 1,
            resolvedAuthorID: nil,
            style: .blue
        )
    )

    guard case let .merged(item) = outcome else {
        Issue.record("expected a merged outcome, got \(outcome)")
        return
    }
    #expect(item.note == "第一条笔记\n\n第二条笔记")
    #expect(item.style == .blue)
    #expect(await store.likes(for: workKey).count == 1)
}

@Test func mergingCaptureLeavesNoNoteWhenNothingSubsumedHadOne() async throws {
    let store = LikeStore(databasePool: try makeLikeNoteTestDatabasePool(prefix: "like-note-merge-empty"))
    let service = NovelTextLikeCaptureService(likeStore: store)
    let workKey = LikeWorkKey.novel(threadID: "4")
    try await store.upsertTextLike(
        id: "plain",
        workKey: workKey,
        anchor: noteTestAnchor(location: 0, length: 10),
        excerptText: "AAAAAAAAAA"
    )

    let outcome = try await service.like(
        NovelTextLikeCaptureRequest(
            workKey: workKey,
            start: NovelTextViewportSemanticTextPosition(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
                displayedTextOffset: 0,
                progressInTextRange: 0
            ),
            end: NovelTextViewportSemanticTextPosition(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
                displayedTextOffset: 15,
                progressInTextRange: 0
            ),
            excerptText: "AAAAAAAAAABBBBB",
            view: 1,
            resolvedAuthorID: nil
        )
    )

    guard case let .merged(item) = outcome else {
        Issue.record("expected a merged outcome, got \(outcome)")
        return
    }
    #expect(item.note == nil)
}

private func makeLikeNoteTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}

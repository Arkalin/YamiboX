import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

// MARK: - Clause extraction

@Test func prefixIsTheClauseHeadBeforeTheSelection() {
    // Apple Books' first sample row: highlight starts at 有, the clause began
    // at 大概 (the previous sentence ends with 。).
    let context = NovelLikeExcerptContext.make(
        textBefore: "前一句结束了。大概",
        textAfter: ""
    )
    #expect(context.prefix == "大概")
    #expect(context.suffix == nil)
}

@Test func prefixStopsAtACommaBoundary() {
    let context = NovelLikeExcerptContext.make(
        textBefore: "转头望去，崖间",
        textAfter: ""
    )
    #expect(context.prefix == "崖间")
}

@Test func prefixIsNilWhenTheHighlightStartsAtAClauseBoundary() {
    let context = NovelLikeExcerptContext.make(
        textBefore: "盛会，",
        textAfter: ""
    )
    #expect(context.prefix == nil)
}

@Test func prefixDoesNotCrossAParagraphBreak() {
    let context = NovelLikeExcerptContext.make(
        textBefore: "上一段的结尾\n本段开头",
        textAfter: ""
    )
    #expect(context.prefix == "本段开头")
}

@Test func prefixKeepsOnlyTheRunNearestTheHighlightWhenTheClauseIsLong() {
    let head = String(repeating: "长", count: 30)
    let context = NovelLikeExcerptContext.make(textBefore: head, textAfter: "")
    #expect(context.prefix == String(repeating: "长", count: 16))
}

@Test func suffixRunsToTheSentenceEndIncludingThePunctuation() {
    let context = NovelLikeExcerptContext.make(
        textBefore: "",
        textAfter: "要开始了”。下一句在这里。"
    )
    #expect(context.suffix == "要开始了”。")
}

@Test func suffixStopsBeforeAParagraphBreak() {
    let context = NovelLikeExcerptContext.make(
        textBefore: "",
        textAfter: "残句\n下一段"
    )
    #expect(context.suffix == "残句")
}

@Test func suffixContinuesPastACommaToFillTheLine() {
    // The suffix exists to fill the row's line, so a comma must not stop it —
    // "爆发出一大群…" keeps going in Apple Books' row.
    let context = NovelLikeExcerptContext.make(
        textBefore: "",
        textAfter: "爆发出一大群，黑压压的往上冲。"
    )
    #expect(context.suffix == "爆发出一大群，黑压压的往上冲。")
}

@Test func emptySurroundingsYieldNoContext() {
    let context = NovelLikeExcerptContext.make(textBefore: "", textAfter: "")
    #expect(context.prefix == nil)
    #expect(context.suffix == nil)
}

// MARK: - Persistence

private func contextTextAnchor(location: Int = 0, length: Int = 4) -> NovelTextLikeAnchor {
    NovelTextLikeAnchor(
        chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
        range: NovelCharacterRange(location: location, length: length),
        view: 1,
        resolvedAuthorID: nil
    )
}

@Test func likeStoreRoundTripsExcerptContext() async throws {
    let store = LikeStore(databasePool: try makeLikeExcerptContextTestDatabasePool(prefix: "like-context-roundtrip"))
    let workKey = LikeWorkKey.novel(threadID: "1")

    try await store.upsertTextLike(
        workKey: workKey,
        anchor: contextTextAnchor(),
        excerptText: "有一二百人吧",
        excerptPrefix: "大概",
        excerptSuffix: "。"
    )

    let item = try #require(await store.likes(for: workKey).first)
    #expect(item.excerptPrefix == "大概")
    #expect(item.excerptSuffix == "。")
}

@Test func resolveExcerptContextsHealsWithoutTouchingUpdatedAt() async throws {
    let store = LikeStore(databasePool: try makeLikeExcerptContextTestDatabasePool(prefix: "like-context-heal"))
    let workKey = LikeWorkKey.novel(threadID: "2")
    // Whole-second timestamp on purpose: `updated_at` is stored as a Double of
    // seconds, and a fractional `.now` does not always survive the round trip
    // bit-for-bit — which is precision noise, not the regression this test
    // guards against.
    let writtenAt = Date(timeIntervalSince1970: 1_722_000_000)
    let result = try await store.upsertTextLike(
        workKey: workKey,
        anchor: contextTextAnchor(),
        excerptText: "旧条目",
        date: writtenAt
    )
    let originalUpdatedAt = result.item.updatedAt

    await store.resolveExcerptContexts([
        result.item.id: (prefix: "分句头", suffix: "分句尾。")
    ])

    let healed = try #require(await store.likes(for: workKey).first)
    #expect(healed.excerptPrefix == "分句头")
    #expect(healed.excerptSuffix == "分句尾。")
    // Local derived state: healing must not mark the Like dataset dirty, or
    // every reader launch would schedule a WebDAV upload.
    #expect(healed.updatedAt == originalUpdatedAt)
}

@Test func excerptContextNeverEntersTheWirePayload() throws {
    let item = LikeItem(
        workKey: .novel(threadID: "1"),
        kind: .text,
        excerptText: "文本",
        excerptPrefix: "前",
        excerptSuffix: "后",
        anchor: .novelText(contextTextAnchor())
    )

    let data = try JSONEncoder().encode(item)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("excerptPrefix"))
    #expect(!json.contains("excerptSuffix"))

    let decoded = try JSONDecoder().decode(LikeItem.self, from: data)
    #expect(decoded.excerptPrefix == nil)
    #expect(decoded.excerptSuffix == nil)
}

private func makeLikeExcerptContextTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}

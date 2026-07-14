import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Test func novelTextLikeCaptureServiceAddsNewLike() async throws {
    let store = LikeStore(databasePool: try makeCaptureTestDatabasePool(prefix: "capture-add"))
    let service = NovelTextLikeCaptureService(likeStore: store)
    let workKey = LikeWorkKey.novel(threadID: "1")
    let request = makeCaptureRequest(workKey: workKey, chapter: "chapter-1", start: 0, end: 5, excerptText: "01234")

    let outcome = try await service.like(request)

    guard case let .added(item) = outcome else {
        Issue.record("expected .added outcome, got \(outcome)")
        return
    }
    #expect(item.excerptText == "01234")
    guard case let .novelText(anchor) = item.anchor else {
        Issue.record("expected a novelText anchor")
        return
    }
    #expect(anchor.range == NovelCharacterRange(location: 0, length: 5))
    #expect(await store.likes(for: workKey).count == 1)
}

@Test func novelTextLikeCaptureServiceIsIdempotentForSameAnchor() async throws {
    let store = LikeStore(databasePool: try makeCaptureTestDatabasePool(prefix: "capture-idempotent"))
    let service = NovelTextLikeCaptureService(likeStore: store)
    let workKey = LikeWorkKey.novel(threadID: "2")
    let request = makeCaptureRequest(workKey: workKey, chapter: "chapter-1", start: 0, end: 5, excerptText: "01234")

    let first = try await service.like(request)
    guard case let .added(firstItem) = first else {
        Issue.record("expected .added outcome for the first like")
        return
    }

    let second = try await service.like(request)
    guard case let .alreadyLiked(secondItem) = second else {
        Issue.record("expected .alreadyLiked outcome, got \(second)")
        return
    }

    #expect(secondItem.id == firstItem.id)
    #expect(await store.likes(for: workKey).count == 1)
}

@Test func novelTextLikeCaptureServiceMergesPartiallyOverlappingRange() async throws {
    let store = LikeStore(databasePool: try makeCaptureTestDatabasePool(prefix: "capture-merge-overlap"))
    let service = NovelTextLikeCaptureService(likeStore: store)
    let workKey = LikeWorkKey.novel(threadID: "3")

    let first = try await service.like(makeCaptureRequest(workKey: workKey, chapter: "chapter-1", start: 0, end: 10, excerptText: "0123456789"))
    guard case let .added(firstItem) = first else {
        Issue.record("expected .added outcome for the first like")
        return
    }

    let request = makeCaptureRequest(workKey: workKey, chapter: "chapter-1", start: 5, end: 15, excerptText: "unused")
    let outcome = try await service.like(request, excerptTextForRange: { _ in "MERGED" })

    guard case let .merged(mergedItem) = outcome else {
        Issue.record("expected .merged outcome, got \(outcome)")
        return
    }
    #expect(mergedItem.id == firstItem.id)
    #expect(mergedItem.excerptText == "MERGED")
    guard case let .novelText(anchor) = mergedItem.anchor else {
        Issue.record("expected a novelText anchor")
        return
    }
    #expect(anchor.range == NovelCharacterRange(location: 0, length: 15))
    #expect(await store.likes(for: workKey).count == 1)
}

@Test func novelTextLikeCaptureServiceMergesTouchingRangeWithNoGap() async throws {
    let store = LikeStore(databasePool: try makeCaptureTestDatabasePool(prefix: "capture-merge-touch"))
    let service = NovelTextLikeCaptureService(likeStore: store)
    let workKey = LikeWorkKey.novel(threadID: "4")

    try await service.like(makeCaptureRequest(workKey: workKey, chapter: "chapter-1", start: 0, end: 5, excerptText: "01234"))

    let outcome = try await service.like(
        makeCaptureRequest(workKey: workKey, chapter: "chapter-1", start: 5, end: 10, excerptText: "unused"),
        excerptTextForRange: { _ in "0123456789" }
    )

    guard case let .merged(mergedItem) = outcome else {
        Issue.record("expected .merged outcome, got \(outcome)")
        return
    }
    guard case let .novelText(anchor) = mergedItem.anchor else {
        Issue.record("expected a novelText anchor")
        return
    }
    #expect(anchor.range == NovelCharacterRange(location: 0, length: 10))
    #expect(await store.likes(for: workKey).count == 1)
}

@Test func novelTextLikeCaptureServiceAddsSeparateLikeWhenRangesDoNotTouch() async throws {
    let store = LikeStore(databasePool: try makeCaptureTestDatabasePool(prefix: "capture-gap"))
    let service = NovelTextLikeCaptureService(likeStore: store)
    let workKey = LikeWorkKey.novel(threadID: "5")

    try await service.like(makeCaptureRequest(workKey: workKey, chapter: "chapter-1", start: 0, end: 5, excerptText: "01234"))
    let outcome = try await service.like(makeCaptureRequest(workKey: workKey, chapter: "chapter-1", start: 10, end: 15, excerptText: "ABCDE"))

    guard case .added = outcome else {
        Issue.record("expected .added outcome, got \(outcome)")
        return
    }
    #expect(await store.likes(for: workKey).count == 2)
}

@Test func novelTextLikeCaptureServiceNeverMergesAcrossChapters() async throws {
    let store = LikeStore(databasePool: try makeCaptureTestDatabasePool(prefix: "capture-cross-chapter"))
    let service = NovelTextLikeCaptureService(likeStore: store)
    let workKey = LikeWorkKey.novel(threadID: "6")

    try await service.like(makeCaptureRequest(workKey: workKey, chapter: "chapter-1", start: 0, end: 5, excerptText: "01234"))
    let outcome = try await service.like(makeCaptureRequest(workKey: workKey, chapter: "chapter-2", start: 0, end: 5, excerptText: "56789"))

    guard case .added = outcome else {
        Issue.record("expected .added outcome, got \(outcome)")
        return
    }
    #expect(await store.likes(for: workKey).count == 2)
}

private func makeCaptureTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}

private func makeSemanticPosition(chapter: String, offset: Int) -> NovelTextViewportSemanticTextPosition {
    NovelTextViewportSemanticTextPosition(
        chapterIdentity: NovelChapterIdentity(rawValue: chapter),
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "\(chapter)#text:0"),
        displayedTextOffset: offset,
        progressInTextRange: 0
    )
}

private func makeCaptureRequest(
    workKey: LikeWorkKey,
    chapter: String,
    start: Int,
    end: Int,
    excerptText: String
) -> NovelTextLikeCaptureRequest {
    NovelTextLikeCaptureRequest(
        workKey: workKey,
        start: makeSemanticPosition(chapter: chapter, offset: start),
        end: makeSemanticPosition(chapter: chapter, offset: end),
        excerptText: excerptText,
        view: 1,
        resolvedAuthorID: nil
    )
}

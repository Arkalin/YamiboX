import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Test func novelImageLikeCaptureServiceAddsNewLike() async throws {
    let store = LikeStore(databasePool: try makeImageCaptureTestDatabasePool(prefix: "novel-image-add"))
    let imageStore = LikeImageStore(baseDirectory: makeImageCaptureTestDirectory(prefix: "novel-image-add"))
    let service = NovelImageLikeCaptureService(likeStore: store, likeImageStore: imageStore)
    let workKey = LikeWorkKey.novel(threadID: "10")
    let anchor = NovelImageLikeAnchor(
        chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
        imageSegmentIdentity: "chapter-1#image:0",
        view: 1,
        resolvedAuthorID: nil
    )
    let sourceURL = try #require(URL(string: "https://img.example.com/a.jpg"))
    let data = Data([1, 2, 3, 4])

    let outcome = try await service.like(workKey: workKey, anchor: anchor, sourceImageURL: sourceURL, imageData: { data })

    guard case let .added(item) = outcome else {
        Issue.record("expected .added outcome, got \(outcome)")
        return
    }
    #expect(item.kind == .image)
    #expect(item.sourceImageURL == sourceURL)
    #expect(await imageStore.loadData(id: item.id) == data)
    #expect(await store.likes(for: workKey).count == 1)
}

@Test func novelImageLikeCaptureServiceIsIdempotentForSameAnchor() async throws {
    let store = LikeStore(databasePool: try makeImageCaptureTestDatabasePool(prefix: "novel-image-idempotent"))
    let imageStore = LikeImageStore(baseDirectory: makeImageCaptureTestDirectory(prefix: "novel-image-idempotent"))
    let service = NovelImageLikeCaptureService(likeStore: store, likeImageStore: imageStore)
    let workKey = LikeWorkKey.novel(threadID: "11")
    let anchor = NovelImageLikeAnchor(
        chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
        imageSegmentIdentity: "chapter-1#image:0",
        view: 1,
        resolvedAuthorID: nil
    )
    let sourceURL = try #require(URL(string: "https://img.example.com/a.jpg"))

    let first = try await service.like(workKey: workKey, anchor: anchor, sourceImageURL: sourceURL, imageData: { Data([1]) })
    guard case let .added(firstItem) = first else {
        Issue.record("expected .added outcome for the first like")
        return
    }

    let counter = CaptureCallCounter()
    let second = try await service.like(
        workKey: workKey,
        anchor: anchor,
        sourceImageURL: sourceURL,
        imageData: {
            await counter.increment()
            return Data([9, 9, 9])
        }
    )

    guard case let .alreadyLiked(secondItem) = second else {
        Issue.record("expected .alreadyLiked outcome, got \(second)")
        return
    }
    #expect(secondItem.id == firstItem.id)
    #expect(await counter.count == 0)
    #expect(await store.likes(for: workKey).count == 1)
}

private func makeImageCaptureTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}

private func makeImageCaptureTestDirectory(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

private actor CaptureCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

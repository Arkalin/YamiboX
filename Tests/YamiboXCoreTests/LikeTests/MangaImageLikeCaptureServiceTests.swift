import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Test func mangaImageLikeCaptureServiceAddsNewLike() async throws {
    let store = LikeStore(databasePool: try makeImageCaptureTestDatabasePool(prefix: "manga-image-add"))
    let imageStore = LikeImageStore(baseDirectory: makeImageCaptureTestDirectory(prefix: "manga-image-add"))
    let service = MangaImageLikeCaptureService(likeStore: store, likeImageStore: imageStore)
    let workKey = LikeWorkKey.mangaTitle(cleanBookName: "测试漫画")
    let anchor = MangaImageLikeAnchor(chapterTID: "900", pageLocalIndex: 3)
    let sourceURL = try #require(URL(string: "https://img.example.com/page.jpg"))
    let data = Data([5, 6, 7, 8])

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

@Test func mangaImageLikeCaptureServiceIsIdempotentForSameAnchor() async throws {
    let store = LikeStore(databasePool: try makeImageCaptureTestDatabasePool(prefix: "manga-image-idempotent"))
    let imageStore = LikeImageStore(baseDirectory: makeImageCaptureTestDirectory(prefix: "manga-image-idempotent"))
    let service = MangaImageLikeCaptureService(likeStore: store, likeImageStore: imageStore)
    let workKey = LikeWorkKey.mangaTitle(cleanBookName: "测试漫画2")
    let anchor = MangaImageLikeAnchor(chapterTID: "901", pageLocalIndex: 0)
    let sourceURL = try #require(URL(string: "https://img.example.com/page2.jpg"))

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

// Re-liking a page whose stored row predates the anchor's fid field (anchor
// equality differs only by `forumID`, R13) must still report already-liked —
// the dedup matches identity fields (chapterTID + pageLocalIndex), never the
// board snapshot.
@Test func mangaImageLikeCaptureServiceMatchesLegacyRowByIdentityFieldsOnly() async throws {
    let store = LikeStore(databasePool: try makeImageCaptureTestDatabasePool(prefix: "manga-image-legacy-dedup"))
    let imageStore = LikeImageStore(baseDirectory: makeImageCaptureTestDirectory(prefix: "manga-image-legacy-dedup"))
    let workKey = LikeWorkKey.mangaTitle(cleanBookName: "去重漫画")
    let legacy = try await store.upsertImageLike(
        workKey: workKey,
        anchor: .mangaImage(MangaImageLikeAnchor(chapterTID: "700", pageLocalIndex: 3)),
        sourceImageURL: nil
    )

    let service = MangaImageLikeCaptureService(likeStore: store, likeImageStore: imageStore)
    let outcome = try await service.like(
        workKey: workKey,
        anchor: MangaImageLikeAnchor(chapterTID: "700", pageLocalIndex: 3, forumID: "46"),
        sourceImageURL: nil,
        imageData: { Data([0xFF]) }
    )

    guard case let .alreadyLiked(match) = outcome else {
        Issue.record("expected alreadyLiked, got \(outcome)")
        return
    }
    #expect(match.id == legacy.id)
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

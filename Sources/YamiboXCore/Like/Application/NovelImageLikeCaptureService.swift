import Foundation

public struct NovelImageLikeCaptureService: Sendable {
    let likeStore: LikeStore
    let likeImageStore: LikeImageStore

    public init(likeStore: LikeStore, likeImageStore: LikeImageStore) {
        self.likeStore = likeStore
        self.likeImageStore = likeImageStore
    }

    @discardableResult
    public func like(
        workKey: ReadingWorkKey,
        anchor: NovelImageLikeAnchor,
        sourceImageURL: URL?,
        chapterTitle: String? = nil,
        imageData: @Sendable () async throws -> Data,
        date: Date = .now
    ) async throws -> LikeCaptureOutcome {
        try await ImageLikeCaptureService(likeStore: likeStore, likeImageStore: likeImageStore).like(
            workKey: workKey, anchor: .novel(anchor), sourceImageURL: sourceImageURL,
            chapterTitle: chapterTitle, imageData: imageData, date: date
        )
    }
}

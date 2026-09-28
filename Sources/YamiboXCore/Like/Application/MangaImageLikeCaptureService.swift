import Foundation

public struct MangaImageLikeCaptureService: Sendable {
    let likeStore: LikeStore
    let likeImageStore: LikeImageStore

    public init(likeStore: LikeStore, likeImageStore: LikeImageStore) {
        self.likeStore = likeStore
        self.likeImageStore = likeImageStore
    }

    @discardableResult
    public func like(
        workKey: ReadingWorkKey,
        anchor: MangaImageLikeAnchor,
        sourceImageURL: URL?,
        chapterTitle: String? = nil,
        imageData: @Sendable () async throws -> Data,
        date: Date = .now
    ) async throws -> LikeCaptureOutcome {
        try await ImageLikeCaptureService(likeStore: likeStore, likeImageStore: likeImageStore).like(
            workKey: workKey, anchor: .manga(anchor), sourceImageURL: sourceImageURL,
            chapterTitle: chapterTitle, imageData: imageData, date: date
        )
    }
}

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
        workKey: LikeWorkKey,
        anchor: NovelImageLikeAnchor,
        sourceImageURL: URL?,
        imageData: @Sendable () async throws -> Data,
        date: Date = .now
    ) async throws -> LikeCaptureOutcome {
        let payload = LikeAnchorPayload.novelImage(anchor)
        let existing = await likeStore.likes(for: workKey)
        if let match = existing.first(where: { $0.kind == .image && $0.anchor == payload }) {
            return .alreadyLiked(match)
        }

        let data = try await imageData()
        let id = UUID().uuidString
        // Terminal write: bytes + metadata row must land even if the calling
        // Task (a reader long-press gesture) is cancelled mid-download.
        let item = try await Task {
            try await likeImageStore.save(data, id: id, sourceURL: sourceImageURL)
            return try await likeStore.upsertImageLike(
                id: id,
                workKey: workKey,
                anchor: payload,
                sourceImageURL: sourceImageURL,
                date: date
            )
        }.value
        return .added(item)
    }
}

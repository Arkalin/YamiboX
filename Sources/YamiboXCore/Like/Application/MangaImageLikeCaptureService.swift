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
        workKey: LikeWorkKey,
        anchor: MangaImageLikeAnchor,
        sourceImageURL: URL?,
        imageData: @Sendable () async throws -> Data,
        date: Date = .now
    ) async throws -> LikeCaptureOutcome {
        let payload = LikeAnchorPayload.mangaImage(anchor)
        let existing = await likeStore.likes(for: workKey)
        // Match by the anchor's identity fields only — `forumID` is a board
        // snapshot (R13 metadata), not identity, so a row captured before the
        // field existed must still count as "already liked" for the same page.
        if let match = existing.first(where: { item in
            guard item.kind == .image, case let .mangaImage(existingAnchor) = item.anchor else { return false }
            return existingAnchor.chapterTID == anchor.chapterTID
                && existingAnchor.pageLocalIndex == anchor.pageLocalIndex
        }) {
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

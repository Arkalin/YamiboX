import Foundation

public enum ImageLikeCaptureAnchor: Sendable {
    case novel(NovelImageLikeAnchor)
    case manga(MangaImageLikeAnchor)

    var payload: LikeAnchorPayload {
        switch self {
        case let .novel(anchor): .novelImage(anchor)
        case let .manga(anchor): .mangaImage(anchor)
        }
    }

    func matches(_ item: LikeItem) -> Bool {
        item.kind == .image && payload.matchesImage(item.anchor)
    }
}

public struct ImageLikeCaptureService: Sendable {
    private let likeStore: any ImageLikeMetadataPersisting
    private let imageStore: any LikeImageWriting

    public init(likeStore: any ImageLikeMetadataPersisting, likeImageStore: any LikeImageWriting) {
        self.likeStore = likeStore
        imageStore = likeImageStore
    }

    @discardableResult
    public func like(
        workKey: ReadingWorkKey,
        anchor: ImageLikeCaptureAnchor,
        sourceImageURL: URL?,
        chapterTitle: String? = nil,
        imageData: @Sendable () async throws -> Data,
        date: Date = .now
    ) async throws -> LikeCaptureOutcome {
        let existing = try await likeStore.likes(for: workKey)
        if var match = existing.first(where: anchor.matches) {
            if match.chapterTitle == nil {
                match.chapterTitle = LikeItem.normalizedChapterTitle(chapterTitle)
                _ = try await likeStore.resolveChapterTitles([match])
            }
            return .alreadyLiked(match)
        }

        let data = try await imageData()
        let id = UUID().uuidString
        return try await Task {
            try await imageStore.save(data, id: id, sourceURL: sourceImageURL)
            let item: LikeItem
            do {
                item = try await likeStore.upsertImageLike(
                    id: id, workKey: workKey, anchor: anchor.payload,
                    sourceImageURL: sourceImageURL, chapterTitle: chapterTitle, date: date
                )
            } catch {
                do { try await imageStore.delete(id: id) }
                catch { YamiboLog.persistence.error("Failed to clean up uncommitted like image: \(error)") }
                throw error
            }
            guard item.id == id else {
                do { try await imageStore.delete(id: id) }
                catch { YamiboLog.persistence.error("Failed to clean up duplicate like image: \(error)") }
                return LikeCaptureOutcome.alreadyLiked(item)
            }
            return LikeCaptureOutcome.added(item)
        }.value
    }
}

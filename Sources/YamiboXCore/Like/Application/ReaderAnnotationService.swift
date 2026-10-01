import Foundation

/// Owns annotation mutations and the ordering between metadata and retained files.
public struct ReaderAnnotationService: Sendable {
    private let likes: any ReaderLikeMutating
    private let images: any LikeImageWriting
    private let bookmarks: any ReaderBookmarkMutating

    public init(likeStore: any ReaderLikeMutating, likeImageStore: any LikeImageWriting, bookmarkStore: any ReaderBookmarkMutating) {
        likes = likeStore
        images = likeImageStore
        bookmarks = bookmarkStore
    }

    public func removeLikes(_ items: [LikeItem]) async throws {
        guard !items.isEmpty else { return }
        try await Task {
            // Never discard retained bytes before their metadata deletion commits.
            try await likes.delete(ids: items.map(\.id), date: .now)
            try await images.delete(ids: items.filter { $0.kind == .image }.map(\.id))
        }.value
    }

    public func removeLikes(for work: ReadingWorkKey) async throws {
        let items = try await likes.likes(for: work)
        try await removeLikes(items)
    }

    public func toggleImage(
        work: ReadingWorkKey,
        anchor: ImageLikeCaptureAnchor,
        sourceImageURL: URL?,
        chapterTitle: String?,
        imageData: @Sendable () async throws -> Data
    ) async throws {
        let existing = try await likes.likes(for: work)
        if let match = existing.first(where: anchor.matches) {
            try await removeLikes([match])
        } else {
            try await ImageLikeCaptureService(likeStore: likes, likeImageStore: images).like(
                workKey: work, anchor: anchor, sourceImageURL: sourceImageURL,
                chapterTitle: chapterTitle, imageData: imageData
            )
        }
    }

    public func updateNote(id: String, note: String?) async throws {
        _ = try await Task { try await likes.updateNote(id: id, note: note, date: .now) }.value
    }

    public func updateStyle(id: String, style: LikeStyle) async throws {
        _ = try await Task { try await likes.updateStyle(id: id, style: style, date: .now) }.value
    }

    public func toggleBookmark(
        work: ReadingWorkKey, anchor: BookmarkAnchorPayload, excerptText: String? = nil
    ) async throws -> BookmarkToggleOutcome {
        try await Task {
            try await bookmarks.toggle(workKey: work, anchor: anchor, excerptText: excerptText, date: .now)
        }.value
    }

    public func removeBookmarks(ids: [String]) async throws {
        try await Task { try await bookmarks.delete(ids: ids, date: .now) }.value
    }
}

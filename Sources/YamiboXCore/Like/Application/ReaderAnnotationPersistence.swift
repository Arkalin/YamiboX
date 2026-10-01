import Foundation

/// Only the metadata operations needed to capture an image. The upsert must
/// resolve duplicate anchors atomically and return the record that owns the file.
public protocol ImageLikeMetadataPersisting: Sendable {
    func likes(for workKey: ReadingWorkKey) async throws -> [LikeItem]
    func resolveChapterTitles(_ snapshots: [LikeItem]) async throws -> Bool
    func upsertImageLike(
        id: String, workKey: ReadingWorkKey, anchor: LikeAnchorPayload,
        sourceImageURL: URL?, chapterTitle: String?, date: Date
    ) async throws -> LikeItem
}

public protocol ReaderLikeMutating: ImageLikeMetadataPersisting {
    func delete(ids: [String], date: Date) async throws
    func updateNote(id: String, note: String?, date: Date) async throws -> LikeItem?
    func updateStyle(id: String, style: LikeStyle, date: Date) async throws -> LikeItem?
}

/// Retained bytes are a separate failure boundary from metadata transactions.
public protocol LikeImageWriting: Sendable {
    func save(_ data: Data, id: String, sourceURL: URL?) async throws
    func delete(id: String) async throws
    func delete(ids: [String]) async throws
}

public extension LikeImageWriting {
    func delete(ids: [String]) async throws {
        for id in ids { try await delete(id: id) }
    }
}

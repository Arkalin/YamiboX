import Foundation

public protocol ReaderBookmarkMutating: Sendable {
    func toggle(
        workKey: ReadingWorkKey, anchor: BookmarkAnchorPayload,
        excerptText: String?, date: Date
    ) async throws -> BookmarkToggleOutcome
    func delete(ids: [String], date: Date) async throws
}

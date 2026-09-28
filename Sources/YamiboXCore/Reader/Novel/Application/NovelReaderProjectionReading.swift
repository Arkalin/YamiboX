import Foundation

/// Local-only projection lookup. Consumers do not need cache mutation or disk access.
public protocol NovelReaderProjectionReading: Sendable {
    func loadProjection(for request: NovelPageRequest) async -> NovelReaderProjection?
}

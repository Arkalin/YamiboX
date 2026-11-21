import Foundation

public protocol NovelReaderProjectionReading: Sendable {
    func loadProjection(for request: NovelPageRequest) async -> NovelReaderProjection?
}

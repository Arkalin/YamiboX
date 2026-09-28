import Foundation

/// Shared missing-cover policy. Callers own task lifetime and refresh their own
/// presentation; the final store write rechecks user choices in its transaction.
public struct MangaAutomaticCoverService: Sendable {
    private let store: ContentCoverStore

    public init(store: ContentCoverStore) {
        self.store = store
    }

    @discardableResult
    public func fillMissingCover(
        for directory: MangaDirectory,
        makeRepository: @Sendable () async -> any ThreadCoverPageResolving
    ) async throws -> Bool {
        try Task.checkCancellation()
        let title = directory.cleanBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let firstChapter = directory.chapters.first else { return false }
        let key = ContentCoverKey.smartManga(directoryID: directory.id)
        if let cover = try await store.storedCover(for: key), cover.textCoverForced || cover.resolvedURL != nil {
            return false
        }
        let repository = await makeRepository()
        try Task.checkCancellation()
        let url = await ThreadCoverResolver().resolve(
            thread: ThreadIdentity(tid: firstChapter.tid), title: title, repository: repository
        )
        try Task.checkCancellation()
        guard let url else { return false }
        return try await store.setAutomaticCover(url, for: key, onlyIfMissing: true)
    }
}

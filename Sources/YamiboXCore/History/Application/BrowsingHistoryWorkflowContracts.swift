import Foundation

/// Canonical timeline operations, not the store's sync or storage-management API.
public protocol BrowsingHistoryReconciling: Sendable {
    func snapshotEntries() async throws -> [BrowsingHistoryEntry]
    func canRecord(_ visit: BrowsingHistoryVisit, targetID: String) async throws -> Bool
    /// Atomically compare the current timeline with `expected` and recheck visit
    /// deletions before committing. Return false without writing on conflict;
    /// throw on storage failure so the workflow does not retry it as a conflict.
    func applyCanonicalEntries(
        _ entries: [BrowsingHistoryEntry], replacing expected: [BrowsingHistoryEntry],
        visit: BrowsingHistoryVisit?, visitTargetID: String?
    ) async throws -> Bool
    func delete(id: String) async throws
}

public protocol BrowsingHistorySettingsReading: Sendable {
    func loadBoardReaderSettings() async -> BoardReaderSettings
    func changes() -> AsyncStream<String>
}

public protocol BrowsingHistoryProgressReading: Sendable {
    func loadAll() async throws -> [ReadingProgressRecord]
}

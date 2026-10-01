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
    func positionEntries(threadID: String, directoryTargetID: String?) async throws -> [BrowsingHistoryEntry]
    func applyPositionEntry(_ entry: BrowsingHistoryEntry, replacing expected: BrowsingHistoryEntry, visit: BrowsingHistoryVisit) async throws -> Bool
}

public protocol BrowsingHistorySettingsReading: Sendable {
    func loadBoardReaderSettings() async -> BoardReaderSettings
    func changes() -> AsyncStream<String>
}

public protocol BrowsingHistoryProgressReading: Sendable {
    func loadAll() async throws -> [ReadingProgressRecord]
    func load(for target: FavoriteContentTarget) async throws -> ReadingProgressRecord?
}

public extension BrowsingHistoryProgressReading {
    func load(for target: FavoriteContentTarget) async throws -> ReadingProgressRecord? {
        try await loadAll().first { $0.id == target.id }
    }
}

public extension BrowsingHistoryReconciling {
    func positionEntries(threadID: String, directoryTargetID: String?) async throws -> [BrowsingHistoryEntry] {
        try await snapshotEntries().filter { $0.lastVisitedThreadID == threadID || $0.target.threadID == threadID || $0.id == directoryTargetID }
    }

    func applyPositionEntry(_ entry: BrowsingHistoryEntry, replacing expected: BrowsingHistoryEntry, visit: BrowsingHistoryVisit) async throws -> Bool {
        let snapshot = try await snapshotEntries()
        guard snapshot.contains(expected) else { return false }
        let updated = snapshot.map { $0.id == expected.id ? entry : $0 }
        return try await applyCanonicalEntries(updated, replacing: snapshot, visit: visit, visitTargetID: entry.id)
    }
}

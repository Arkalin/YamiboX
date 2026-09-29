import Foundation

/// Persistence used by update checking and its event/filter controls, not a
/// mirror of the store's maintenance, migration or direct-insertion APIs.
public protocol FavoriteUpdateStatePersisting: Sendable {
    var changeID: String { get }
    func changes() -> AsyncStream<String>
    func loadState() async throws -> FavoriteUpdateStoreState
    func latestRun() async throws -> FavoriteUpdateRunSnapshot?
    func saveRun(_ snapshot: FavoriteUpdateRunSnapshot) async throws
    func replaceTrackedTargets(_ targets: [FavoriteUpdateTrackedTarget]) async throws
    /// Merge concurrent read/dismiss decisions and commit the results atomically.
    func applyCheckRunResults(trackedTargets: [FavoriteUpdateTrackedTarget], events: [FavoriteUpdateEvent]) async throws
    func unreadEventCount(mergingRunEvents runEvents: [FavoriteUpdateEvent]) async throws -> Int
    func markEventRead(_ id: String, date: Date) async throws
    func markEventsRead(_ ids: Set<String>, date: Date) async throws
    func dismissEvent(_ id: String, date: Date) async throws
    func dismissAllEvents(date: Date) async throws
    /// Refresh available filters while preserving persisted enable/disable choices.
    func replaceFilters(fidFilters: [FavoriteUpdateFidFilter], categoryFilters: [FavoriteUpdateCategoryFilter]) async throws
    func setFidEnabled(_ fid: String, enabled: Bool, date: Date) async throws
    func setCategoryEnabled(_ categoryID: String, enabled: Bool, date: Date) async throws
}

public protocol FavoriteUpdateLibraryAccessing: Sendable {
    func load() async throws -> FavoriteLibraryDocument
    /// Re-read and patch atomically; never recreate an item deleted during a check.
    func healUnknownSourceGroup(for target: FavoriteItemTarget, forumID: String, forumName: String?) async throws
}

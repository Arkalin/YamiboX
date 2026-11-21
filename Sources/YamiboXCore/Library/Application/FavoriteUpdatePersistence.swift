import Foundation

public protocol FavoriteUpdateStatePersisting: Sendable {
    var changeID: String { get }
    func changes() -> AsyncStream<Void>
    func loadState() async throws -> FavoriteUpdateStoreState
    func latestRun() async throws -> FavoriteUpdateRunSnapshot?
    func saveRun(_ snapshot: FavoriteUpdateRunSnapshot) async throws
    func replaceTrackedTargets(_ targets: [FavoriteUpdateTrackedTarget]) async throws
    func applyCheckRunResults(trackedTargets: [FavoriteUpdateTrackedTarget], events: [FavoriteUpdateEvent]) async throws
    func unreadEventCount(mergingRunEvents runEvents: [FavoriteUpdateEvent]) async throws -> Int
    func unreadEventCount(mergingRunEvents runEvents: [FavoriteUpdateEvent], replacingWith event: FavoriteUpdateEvent, runID: String, sequence: UInt64) async throws -> Int
    func unreadEventCount(
        runEventCount: Int,
        materializeRunEvents: @escaping @Sendable () -> [FavoriteUpdateEvent],
        replacingWith event: FavoriteUpdateEvent,
        runID: String,
        sequence: UInt64
    ) async throws -> Int
    func endNotificationBadgeRun(runID: String) async
    func markEventRead(_ id: String, date: Date) async throws
    func markEventsRead(_ ids: Set<String>, date: Date) async throws
    func dismissEvent(_ id: String, date: Date) async throws
    func dismissAllEvents(date: Date) async throws
    func replaceFilters(fidFilters: [FavoriteUpdateFidFilter], categoryFilters: [FavoriteUpdateCategoryFilter]) async throws
    func setFidEnabled(_ fid: String, enabled: Bool, date: Date) async throws
    func setCategoryEnabled(_ categoryID: String, enabled: Bool, date: Date) async throws
}

public protocol FavoriteUpdateLibraryAccessing: Sendable {
    func load() async throws -> FavoriteLibraryDocument
    func healUnknownSourceGroup(for target: FavoriteItemTarget, forumID: String, forumName: String?) async throws
    func recordContentUpdate(for target: FavoriteItemTarget, contentUpdatedAt: Date) async throws
}

extension FavoriteUpdateStatePersisting {
    public func unreadEventCount(
        runEventCount: Int,
        materializeRunEvents: @escaping @Sendable () -> [FavoriteUpdateEvent],
        replacingWith event: FavoriteUpdateEvent,
        runID: String,
        sequence: UInt64
    ) async throws -> Int {
        try await unreadEventCount(mergingRunEvents: materializeRunEvents(), replacingWith: event, runID: runID, sequence: sequence)
    }

    public func unreadEventCount(mergingRunEvents runEvents: [FavoriteUpdateEvent], replacingWith event: FavoriteUpdateEvent, runID: String, sequence: UInt64) async throws -> Int {
        try await unreadEventCount(mergingRunEvents: runEvents)
    }

    public func endNotificationBadgeRun(runID: String) async {}
}

import Foundation

public struct NovelReaderCacheOperationContext: Equatable, Sendable {
    public var ownerTitle: String
    public var threadID: String
    public var authorID: String?

    public init(ownerTitle: String = "", threadID: String, authorID: String?) {
        self.ownerTitle = ownerTitle
        self.threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authorID = authorID
    }
}

public struct NovelReaderCacheOperationSnapshot: Equatable, Sendable {
    public var cacheableViews: Set<Int>
    public var cachedViews: Set<Int>
    public var cachingViews: Set<Int>
    public var updateTimesByView: [Int: Date]
    public var context: NovelReaderCacheOperationContext

    public init(
        cacheableViews: Set<Int>,
        cachedViews: Set<Int>,
        cachingViews: Set<Int> = [],
        updateTimesByView: [Int: Date] = [:],
        context: NovelReaderCacheOperationContext
    ) {
        self.cacheableViews = cacheableViews
        self.cachedViews = cachedViews
        self.cachingViews = cachingViews
        self.updateTimesByView = updateTimesByView
        self.context = context
    }
}

public struct NovelReaderCacheOperationState: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case idle
        case running
        case completed
        case cancelled
    }

    public var cachedViews: Set<Int>
    public var queuedViews: [Int]
    public var completedViews: [Int]
    public var failedViews: [Int]
    public var totalCount: Int
    public var completedCount: Int
    public var currentView: Int?
    public var isProgressHidden: Bool
    public var status: Status
    public var summaryMessage: String?

    public init(
        cachedViews: Set<Int> = [],
        queuedViews: [Int] = [],
        completedViews: [Int] = [],
        failedViews: [Int] = [],
        totalCount: Int = 0,
        completedCount: Int = 0,
        currentView: Int? = nil,
        isProgressHidden: Bool = false,
        status: Status = .idle,
        summaryMessage: String? = nil
    ) {
        self.cachedViews = cachedViews
        self.queuedViews = queuedViews
        self.completedViews = completedViews
        self.failedViews = failedViews
        self.totalCount = totalCount
        self.completedCount = completedCount
        self.currentView = currentView
        self.isProgressHidden = isProgressHidden
        self.status = status
        self.summaryMessage = summaryMessage
    }

    public var isRunning: Bool {
        status == .running
    }

    public var isFinished: Bool {
        status == .completed || status == .cancelled
    }

    public var hasSession: Bool {
        isRunning || isFinished
    }
}

public struct NovelReaderCacheSelectionState: Equatable, Sendable {
    public var selectedViews: Set<Int>
    public var cachedSelectedViews: Set<Int>
    public var cachingSelectedViews: Set<Int>
    public var updatableSelectedViews: Set<Int>
    public var uncachedSelectedViews: Set<Int>
    public var canCache: Bool
    public var canUpdate: Bool
    public var canDelete: Bool
    public var isAllSelected: Bool

    public init(
        selectedViews: Set<Int>,
        cachedSelectedViews: Set<Int>,
        cachingSelectedViews: Set<Int> = [],
        updatableSelectedViews: Set<Int>? = nil,
        uncachedSelectedViews: Set<Int>,
        canCache: Bool,
        canUpdate: Bool,
        canDelete: Bool,
        isAllSelected: Bool
    ) {
        self.selectedViews = selectedViews
        self.cachedSelectedViews = cachedSelectedViews
        self.cachingSelectedViews = cachingSelectedViews
        self.updatableSelectedViews = updatableSelectedViews ?? cachedSelectedViews.subtracting(cachingSelectedViews)
        self.uncachedSelectedViews = uncachedSelectedViews
        self.canCache = canCache
        self.canUpdate = canUpdate
        self.canDelete = canDelete
        self.isAllSelected = isAllSelected
    }
}

public enum NovelReaderCacheOperationMode: Sendable {
    case cache
    case update
}

public protocol NovelReaderCacheOperationRepository: Sendable {
    func cacheState(for context: NovelReaderCacheOperationContext) async -> NovelOfflineCacheViewsSnapshot
    func cachedViews(for context: NovelReaderCacheOperationContext) async -> Set<Int>

    func deleteCachedViews(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext
    ) async throws

    func cacheViews(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext,
        progress: (@Sendable (NovelReaderCacheBatchProgress) async -> Void)?
    ) async -> NovelReaderCacheBatchResult

    func updateCachedViews(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext,
        progress: (@Sendable (NovelReaderCacheBatchProgress) async -> Void)?
    ) async -> NovelReaderCacheBatchResult
}

@MainActor
public final class NovelReaderCacheOperationModule {
    public private(set) var cachedViews: Set<Int> = []
    public private(set) var cachingViews: Set<Int> = []
    public private(set) var cachedViewUpdateTimes: [Int: Date] = [:]
    public private(set) var state = NovelReaderCacheOperationState()
    public var onChange: (@MainActor (NovelOfflineCacheViewsSnapshot, NovelReaderCacheOperationState) -> Void)?

    private var operationTask: Task<Void, Never>?

    public init() {}

    deinit {
        operationTask?.cancel()
    }

    public func syncCachedViews(_ views: Set<Int>) {
        syncCacheState(NovelOfflineCacheViewsSnapshot(cachedViews: views))
    }

    public func syncCacheState(_ snapshot: NovelOfflineCacheViewsSnapshot) {
        cachedViews = snapshot.cachedViews
        cachingViews = snapshot.cachingViews
        cachedViewUpdateTimes = snapshot.updateTimesByView
        state.cachedViews = snapshot.cachedViews
        emitChange()
    }

    public func selectionState(
        for selectedViews: Set<Int>,
        snapshot: NovelReaderCacheOperationSnapshot
    ) -> NovelReaderCacheSelectionState {
        let validSelections = selectedViews.intersection(snapshot.cacheableViews)
        let cachedSelectedViews = validSelections.intersection(snapshot.cachedViews)
        let cachingSelectedViews = validSelections.intersection(snapshot.cachingViews)
        let updatableSelectedViews = cachedSelectedViews.subtracting(snapshot.cachingViews)
        let uncachedSelectedViews = validSelections
            .subtracting(snapshot.cachedViews)
            .subtracting(snapshot.cachingViews)
        return NovelReaderCacheSelectionState(
            selectedViews: validSelections,
            cachedSelectedViews: cachedSelectedViews,
            cachingSelectedViews: cachingSelectedViews,
            updatableSelectedViews: updatableSelectedViews,
            uncachedSelectedViews: uncachedSelectedViews,
            canCache: !uncachedSelectedViews.isEmpty,
            canUpdate: !updatableSelectedViews.isEmpty,
            canDelete: !cachedSelectedViews.isEmpty,
            isAllSelected: !snapshot.cacheableViews.isEmpty && validSelections.count == snapshot.cacheableViews.count
        )
    }

    public func startCaching(
        views: Set<Int>,
        snapshot: NovelReaderCacheOperationSnapshot,
        repository: NovelReaderCacheOperationRepository,
        summary: @escaping @MainActor (NovelReaderCacheOperationMode, NovelReaderCacheBatchResult) -> String
    ) {
        guard !state.isRunning else { return }
        let selection = selectionState(for: views, snapshot: snapshot)
        guard !selection.uncachedSelectedViews.isEmpty else { return }
        startOperation(
            mode: .cache,
            views: selection.uncachedSelectedViews,
            snapshot: snapshot,
            repository: repository,
            summary: summary
        )
    }

    public func updateCachedViews(
        _ views: Set<Int>,
        snapshot: NovelReaderCacheOperationSnapshot,
        repository: NovelReaderCacheOperationRepository,
        summary: @escaping @MainActor (NovelReaderCacheOperationMode, NovelReaderCacheBatchResult) -> String,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        guard !state.isRunning else { return }
        let selection = selectionState(for: views, snapshot: snapshot)
        guard !selection.updatableSelectedViews.isEmpty else { return }
        startOperation(
            mode: .update,
            views: selection.updatableSelectedViews,
            snapshot: snapshot,
            repository: repository,
            summary: summary
        )
    }

    public func deleteCachedViews(
        _ views: Set<Int>,
        snapshot: NovelReaderCacheOperationSnapshot,
        repository: NovelReaderCacheOperationRepository
    ) async throws {
        guard !state.isRunning else { return }
        let selection = selectionState(for: views, snapshot: snapshot)
        guard !selection.cachedSelectedViews.isEmpty else { return }

        try await repository.deleteCachedViews(
            selection.cachedSelectedViews,
            for: snapshot.context
        )
        syncCacheState(await repository.cacheState(for: snapshot.context))
    }

    public func showProgressIfRunning() {
        guard state.hasSession else { return }
        state.isProgressHidden = false
        emitChange()
    }

    public func hideProgress() {
        guard state.hasSession else { return }
        state.isProgressHidden = true
        emitChange()
    }

    public func dismissProgress() {
        operationTask = nil
        reset()
    }

    public func stopCaching() {
        guard state.isRunning else { return }
        operationTask?.cancel()
    }

    private func reset() {
        state = NovelReaderCacheOperationState(cachedViews: cachedViews)
        emitChange()
    }

    private func startOperation(
        mode: NovelReaderCacheOperationMode,
        views: Set<Int>,
        snapshot: NovelReaderCacheOperationSnapshot,
        repository: NovelReaderCacheOperationRepository,
        summary: @escaping @MainActor (NovelReaderCacheOperationMode, NovelReaderCacheBatchResult) -> String
    ) {
        let targets = views.sorted()
        guard !targets.isEmpty else { return }

        state = NovelReaderCacheOperationState(
            cachedViews: cachedViews,
            queuedViews: targets,
            totalCount: targets.count,
            status: .running
        )
        emitChange()

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let result = if mode == .update {
                await repository.updateCachedViews(
                    Set(targets),
                    for: snapshot.context
                ) { [weak self] progress in
                    await self?.apply(progress: progress, allTargets: targets)
                }
            } else {
                await repository.cacheViews(
                    Set(targets),
                    for: snapshot.context
                ) { [weak self] progress in
                    await self?.apply(progress: progress, allTargets: targets)
                }
            }
            await self.finalize(result: result, mode: mode, snapshot: snapshot, repository: repository, summary: summary)
        }
    }

    private func apply(progress: NovelReaderCacheBatchProgress, allTargets: [Int]) {
        state.totalCount = progress.totalCount
        state.completedCount = progress.completedCount
        state.currentView = progress.currentView
        state.completedViews = progress.completedViews
        state.failedViews = progress.failedViews
        state.status = progress.status == .cancelled ? .cancelled : .running

        let completed = Set(progress.completedViews)
        let failed = Set(progress.failedViews)
        state.queuedViews = allTargets.filter { !completed.contains($0) && !failed.contains($0) }
        syncCachedViews(cachedViews.union(completed))
    }

    private func finalize(
        result: NovelReaderCacheBatchResult,
        mode: NovelReaderCacheOperationMode,
        snapshot: NovelReaderCacheOperationSnapshot,
        repository: NovelReaderCacheOperationRepository,
        summary: @MainActor (NovelReaderCacheOperationMode, NovelReaderCacheBatchResult) -> String
    ) async {
        operationTask = nil
        let refreshedState = await repository.cacheState(for: snapshot.context)
        syncCacheState(refreshedState)

        state.cachedViews = cachedViews
        state.queuedViews = result.wasCancelled ? state.queuedViews : []
        state.completedViews = result.completedViews
        state.failedViews = result.failedViews
        state.totalCount = result.totalCount
        state.completedCount = result.completedViews.count
        state.currentView = nil
        state.status = result.wasCancelled ? .cancelled : .completed
        state.summaryMessage = summary(mode, result)
        state.isProgressHidden = false
        emitChange()
    }

    private func emitChange() {
        onChange?(
            NovelOfflineCacheViewsSnapshot(
                cachedViews: cachedViews,
                cachingViews: cachingViews,
                updateTimesByView: cachedViewUpdateTimes
            ),
            state
        )
    }
}

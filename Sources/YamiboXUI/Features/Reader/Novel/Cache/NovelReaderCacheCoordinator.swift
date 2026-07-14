import SwiftUI
import YamiboXCore

/// Aggregated offline-cache presentation state for the novel reader.
struct NovelReaderCacheState: Equatable {
    var views = NovelOfflineCacheViewsSnapshot()
    var queueEntryCount = 0
    var operation = NovelReaderCacheOperationState()
}

/// Owns the novel reader's offline-cache concerns: the aggregated cache
/// state (per-view snapshots, download-queue count, running batch
/// operation), the batch-operation module, and the cache repository.
/// The view model supplies the live reading context; cache views bind this
/// coordinator directly.
@MainActor
final class NovelReaderCacheCoordinator: ObservableObject {
    /// Live reading context supplied by the owning view model.
    struct Reading {
        var maxView: @MainActor () -> Int
        var displayedView: @MainActor () -> Int
        var operationContext: @MainActor () -> NovelReaderCacheOperationContext
        var onError: @MainActor (String) -> Void
    }

    @Published private(set) var state = NovelReaderCacheState()

    private let operationModule: NovelReaderCacheOperationModule
    private let repository: any NovelReaderCacheOperationRepository
    private let offlineCacheStore: any OfflineCacheStoring
    private let accountDependencies: AccountDependencies
    private let reading: Reading
    private var updatesTask: Task<Void, Never>?

    init(
        operationModule: NovelReaderCacheOperationModule,
        repository: any NovelReaderCacheOperationRepository,
        offlineCacheStore: any OfflineCacheStoring,
        accountDependencies: AccountDependencies,
        reading: Reading
    ) {
        self.operationModule = operationModule
        self.repository = repository
        self.offlineCacheStore = offlineCacheStore
        self.accountDependencies = accountDependencies
        self.reading = reading
        operationModule.onChange = { [weak self] viewsSnapshot, operationState in
            guard let self else { return }
            state.views = viewsSnapshot
            state.operation = operationState
            Task { [weak self] in
                await self?.refreshQueueCount()
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    var hasOperationSession: Bool {
        state.operation.hasSession
    }

    var allCacheableViews: [Int] {
        let maxView = reading.maxView()
        guard maxView > 0 else { return [] }
        return Array(1 ... maxView)
    }

    func refresh() async {
        startObservingOfflineCacheUpdates()
        operationModule.syncCacheState(await repository.cacheState(for: reading.operationContext()))
        await refreshQueueCount()
    }

    func refreshQueueCount() async {
        state.queueEntryCount = await offlineCacheStore.offlineCacheQueueWorks().count
    }

    func selectionState(for selectedViews: Set<Int>) -> NovelReaderCacheSelectionState {
        operationModule.selectionState(for: selectedViews, snapshot: operationSnapshot)
    }

    func status(for view: Int) -> NovelOfflineCacheViewStatus {
        state.views.state(for: view).status
    }

    func updateTime(for view: Int) -> Date? {
        state.views.updateTimesByView[max(1, view)]
    }

    func startCaching(views: Set<Int>) {
        operationModule.startCaching(
            views: views,
            snapshot: operationSnapshot,
            repository: repository,
            summary: operationSummary
        )
    }

    func updateCachedViews(_ views: Set<Int>) {
        operationModule.updateCachedViews(
            views,
            snapshot: operationSnapshot,
            repository: repository,
            summary: operationSummary,
            onFailure: { [weak self] error in
                self?.reading.onError(error.localizedDescription)
            }
        )
    }

    func deleteCachedViews(_ views: Set<Int>) async {
        do {
            try await operationModule.deleteCachedViews(
                views,
                snapshot: operationSnapshot,
                repository: repository
            )
        } catch {
            reading.onError(error.localizedDescription)
        }
    }

    func refreshCurrentCache() async {
        let result = await repository.updateCachedViews(
            [reading.displayedView()],
            for: reading.operationContext(),
            progress: nil
        )
        if result.failedViews.isEmpty {
            await refresh()
        } else {
            reading.onError(L10n.string("common.operation_failed"))
        }
    }

    func showProgressIfRunning() {
        operationModule.showProgressIfRunning()
    }

    func hideProgress() {
        operationModule.hideProgress()
    }

    func dismissProgress() {
        operationModule.dismissProgress()
    }

    func stopCaching() {
        operationModule.stopCaching()
    }

    func makeOfflineCacheQueueViewModel() -> OfflineCacheQueueViewModel {
        OfflineCacheQueueViewModel(dependencies: accountDependencies)
    }

    private var operationSnapshot: NovelReaderCacheOperationSnapshot {
        NovelReaderCacheOperationSnapshot(
            cacheableViews: Set(allCacheableViews),
            cachedViews: state.views.cachedViews,
            cachingViews: state.views.cachingViews,
            updateTimesByView: state.views.updateTimesByView,
            context: reading.operationContext()
        )
    }

    private func startObservingOfflineCacheUpdates() {
        guard updatesTask == nil else { return }
        let updates = offlineCacheStore.offlineCacheUpdates()
        updatesTask = Task { @MainActor [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func operationSummary(
        mode: NovelReaderCacheOperationMode,
        result: NovelReaderCacheBatchResult
    ) -> String {
        let actionText = switch mode {
        case .cache: L10n.string("reader.cache_action.cache")
        case .update: L10n.string("reader.cache_action.update")
        }

        var summary = result.wasCancelled
            ? L10n.string("reader.cache_summary.cancelled", result.completedViews.count, result.totalCount, actionText)
            : L10n.string("reader.cache_summary.completed", result.completedViews.count, result.totalCount, actionText)
        if !result.failedViews.isEmpty {
            summary += L10n.string("reader.cache_summary.failed_suffix", result.failedViews.count)
        }
        return summary
    }
}

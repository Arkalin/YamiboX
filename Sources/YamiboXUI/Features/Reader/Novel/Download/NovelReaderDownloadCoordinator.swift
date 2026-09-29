import SwiftUI
import YamiboXCore

/// Aggregated downloads presentation state for the novel reader.
struct NovelReaderDownloadState: Equatable {
    var views = NovelDownloadViewsSnapshot()
    var queueEntryCount = 0
    var operation = NovelReaderDownloadOperationState()
}

/// Owns the novel reader's downloads concerns: the aggregated download
/// state (per-view snapshots, download-queue count, running batch
/// operation), the batch-operation module, and the download repository.
/// The view model supplies the live reading context; download views bind this
/// coordinator directly.
@MainActor
final class NovelReaderDownloadCoordinator: ObservableObject {
    /// Live reading context supplied by the owning view model.
    struct Reading {
        var maxView: @MainActor () -> Int
        var displayedView: @MainActor () -> Int
        var operationContext: @MainActor () -> NovelReaderDownloadOperationContext
        var onError: @MainActor (LoadFailureDetails) -> Void
    }

    @Published private(set) var state = NovelReaderDownloadState()

    private let operationModule: NovelReaderDownloadOperationModule
    private let repository: any NovelReaderDownloadOperationRepository
    private let downloadStore: any DownloadQueueStoring & DownloadManagementStoring
    private let queueDependencies: DownloadQueueDependencies
    private let reading: Reading
    private var updatesTask: Task<Void, Never>?

    init(
        operationModule: NovelReaderDownloadOperationModule,
        repository: any NovelReaderDownloadOperationRepository,
        downloadStore: any DownloadQueueStoring & DownloadManagementStoring,
        queueDependencies: DownloadQueueDependencies,
        reading: Reading
    ) {
        self.operationModule = operationModule
        self.repository = repository
        self.downloadStore = downloadStore
        self.queueDependencies = queueDependencies
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

    var allDownloadableViews: [Int] {
        let maxView = reading.maxView()
        guard maxView > 0 else { return [] }
        return Array(1 ... maxView)
    }

    func refresh() async {
        startObservingDownloadUpdates()
        operationModule.syncDownloadState(await repository.downloadState(for: reading.operationContext()))
        await refreshQueueCount()
    }

    func refreshQueueCount() async {
        do {
            let count = try await downloadStore.downloadQueueWorks().count
            try Task.checkCancellation()
            state.queueEntryCount = count
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                reading.onError(LoadFailureDetails(error: error))
            }
        }
    }

    func selectionState(for selectedViews: Set<Int>) -> NovelReaderDownloadSelectionState {
        operationModule.selectionState(for: selectedViews, snapshot: operationSnapshot)
    }

    func status(for view: Int) -> NovelDownloadViewStatus {
        state.views.state(for: view).status
    }

    func updateTime(for view: Int) -> Date? {
        state.views.updateTimesByView[max(1, view)]
    }

    func startDownloading(views: Set<Int>) {
        operationModule.startDownloading(
            views: views,
            snapshot: operationSnapshot,
            repository: repository,
            summary: operationSummary
        )
    }

    func updateDownloadedViews(_ views: Set<Int>) {
        operationModule.updateDownloadedViews(
            views,
            snapshot: operationSnapshot,
            repository: repository,
            summary: operationSummary
        )
    }

    func deleteDownloadedViews(_ views: Set<Int>) async {
        do {
            try await operationModule.deleteDownloadedViews(
                views,
                snapshot: operationSnapshot,
                repository: repository
            )
        } catch {
            if !LoadDiagnosticError.isCancellation(error) {
                reading.onError(LoadFailureDetails(error: error))
            }
        }
    }

    func refreshCurrentDownload() async {
        let result = await repository.updateDownloadedViews(
            [reading.displayedView()],
            for: reading.operationContext(),
            progress: nil
        )
        if result.failedViews.isEmpty {
            await refresh()
        } else {
            reading.onError(LoadFailureDetails(message: L10n.string("common.operation_failed")))
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

    func stopDownloading() {
        operationModule.stopDownloading()
    }

    func makeDownloadQueueViewModel() -> DownloadQueueViewModel {
        DownloadQueueViewModel(dependencies: queueDependencies)
    }

    func makeDownloadManagementViewModel() -> DownloadManagementViewModel {
        DownloadManagementViewModel(downloadStore: downloadStore, sessionStore: queueDependencies.sessionStore)
    }

    private var operationSnapshot: NovelReaderDownloadOperationSnapshot {
        NovelReaderDownloadOperationSnapshot(
            downloadableViews: Set(allDownloadableViews),
            downloadedViews: state.views.downloadedViews,
            downloadingViews: state.views.downloadingViews,
            updateTimesByView: state.views.updateTimesByView,
            context: reading.operationContext()
        )
    }

    private func startObservingDownloadUpdates() {
        guard updatesTask == nil else { return }
        let updates = downloadStore.downloadUpdates()
        updatesTask = Task { @MainActor [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func operationSummary(
        mode: NovelReaderDownloadOperationMode,
        result: NovelReaderDownloadBatchResult
    ) -> String {
        let actionText = switch mode {
        case .download: L10n.string("reader.download_action.download")
        case .update: L10n.string("reader.download_action.update")
        }

        var summary = result.wasCancelled
            ? L10n.string("reader.download_summary.cancelled", result.completedViews.count, result.totalCount, actionText)
            : L10n.string("reader.download_summary.completed", result.completedViews.count, result.totalCount, actionText)
        if !result.failedViews.isEmpty {
            summary += L10n.string("reader.download_summary.failed_suffix", result.failedViews.count)
        }
        return summary
    }
}

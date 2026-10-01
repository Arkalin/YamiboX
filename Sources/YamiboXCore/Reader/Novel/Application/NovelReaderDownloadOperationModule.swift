import Foundation

public struct NovelReaderDownloadOperationContext: Equatable, Sendable {
    public var ownerTitle: String
    public var threadID: String
    public var authorID: String?

    public init(ownerTitle: String = "", threadID: String, authorID: String?) {
        self.ownerTitle = ownerTitle
        self.threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authorID = authorID
    }
}

public struct NovelReaderDownloadOperationSnapshot: Equatable, Sendable {
    public var downloadableViews: Set<Int>
    public var downloadedViews: Set<Int>
    public var downloadingViews: Set<Int>
    public var updateTimesByView: [Int: Date]
    public var context: NovelReaderDownloadOperationContext

    public init(
        downloadableViews: Set<Int>,
        downloadedViews: Set<Int>,
        downloadingViews: Set<Int> = [],
        updateTimesByView: [Int: Date] = [:],
        context: NovelReaderDownloadOperationContext
    ) {
        self.downloadableViews = downloadableViews
        self.downloadedViews = downloadedViews
        self.downloadingViews = downloadingViews
        self.updateTimesByView = updateTimesByView
        self.context = context
    }
}

public struct NovelReaderDownloadOperationState: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case idle
        case running
        case completed
        case cancelled
    }

    public var downloadedViews: Set<Int>
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
        downloadedViews: Set<Int> = [],
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
        self.downloadedViews = downloadedViews
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

public struct NovelReaderDownloadSelectionState: Equatable, Sendable {
    public var selectedViews: Set<Int>
    public var downloadedSelectedViews: Set<Int>
    public var downloadingSelectedViews: Set<Int>
    public var updatableSelectedViews: Set<Int>
    public var notDownloadedSelectedViews: Set<Int>
    public var canDownload: Bool
    public var canUpdate: Bool
    public var canDelete: Bool
    public var isAllSelected: Bool

    public init(
        selectedViews: Set<Int>,
        downloadedSelectedViews: Set<Int>,
        downloadingSelectedViews: Set<Int> = [],
        updatableSelectedViews: Set<Int>? = nil,
        notDownloadedSelectedViews: Set<Int>,
        canDownload: Bool,
        canUpdate: Bool,
        canDelete: Bool,
        isAllSelected: Bool
    ) {
        self.selectedViews = selectedViews
        self.downloadedSelectedViews = downloadedSelectedViews
        self.downloadingSelectedViews = downloadingSelectedViews
        self.updatableSelectedViews = updatableSelectedViews ?? downloadedSelectedViews.subtracting(downloadingSelectedViews)
        self.notDownloadedSelectedViews = notDownloadedSelectedViews
        self.canDownload = canDownload
        self.canUpdate = canUpdate
        self.canDelete = canDelete
        self.isAllSelected = isAllSelected
    }
}

public enum NovelReaderDownloadOperationMode: Sendable {
    case download
    case update
}

public protocol NovelReaderDownloadOperationRepository: Sendable {
    func downloadState(for context: NovelReaderDownloadOperationContext) async -> NovelDownloadViewsSnapshot
    func downloadedViews(for context: NovelReaderDownloadOperationContext) async -> Set<Int>

    func deleteDownloadedViews(
        _ views: Set<Int>,
        for context: NovelReaderDownloadOperationContext
    ) async throws

    func downloadViews(
        _ views: Set<Int>,
        for context: NovelReaderDownloadOperationContext,
        progress: (@Sendable (NovelReaderDownloadBatchProgress) async -> Void)?
    ) async -> NovelReaderDownloadBatchResult

    func updateDownloadedViews(
        _ views: Set<Int>,
        for context: NovelReaderDownloadOperationContext,
        progress: (@Sendable (NovelReaderDownloadBatchProgress) async -> Void)?
    ) async -> NovelReaderDownloadBatchResult
}

@MainActor
public final class NovelReaderDownloadOperationModule {
    public private(set) var downloadedViews: Set<Int> = []
    public private(set) var downloadingViews: Set<Int> = []
    public private(set) var downloadedViewUpdateTimes: [Int: Date] = [:]
    public private(set) var state = NovelReaderDownloadOperationState()
    public var onChange: (@MainActor (NovelDownloadViewsSnapshot, NovelReaderDownloadOperationState) -> Void)?

    private var operationTask: Task<Void, Never>?
    private var lastEmittedViews: NovelDownloadViewsSnapshot?
    private var lastEmittedState: NovelReaderDownloadOperationState?

    public init() {}

    deinit {
        operationTask?.cancel()
    }

    public func syncDownloadedViews(_ views: Set<Int>) {
        syncDownloadState(NovelDownloadViewsSnapshot(downloadedViews: views))
    }

    public func syncDownloadState(_ snapshot: NovelDownloadViewsSnapshot) {
        downloadedViews = snapshot.downloadedViews
        downloadingViews = snapshot.downloadingViews
        downloadedViewUpdateTimes = snapshot.updateTimesByView
        state.downloadedViews = snapshot.downloadedViews
        emitChange()
    }

    public func selectionState(
        for selectedViews: Set<Int>,
        snapshot: NovelReaderDownloadOperationSnapshot
    ) -> NovelReaderDownloadSelectionState {
        let validSelections = selectedViews.intersection(snapshot.downloadableViews)
        let downloadedSelectedViews = validSelections.intersection(snapshot.downloadedViews)
        let downloadingSelectedViews = validSelections.intersection(snapshot.downloadingViews)
        let updatableSelectedViews = downloadedSelectedViews.subtracting(snapshot.downloadingViews)
        let notDownloadedSelectedViews = validSelections
            .subtracting(snapshot.downloadedViews)
            .subtracting(snapshot.downloadingViews)
        return NovelReaderDownloadSelectionState(
            selectedViews: validSelections,
            downloadedSelectedViews: downloadedSelectedViews,
            downloadingSelectedViews: downloadingSelectedViews,
            updatableSelectedViews: updatableSelectedViews,
            notDownloadedSelectedViews: notDownloadedSelectedViews,
            canDownload: !notDownloadedSelectedViews.isEmpty,
            canUpdate: !updatableSelectedViews.isEmpty,
            canDelete: !downloadedSelectedViews.isEmpty,
            isAllSelected: !snapshot.downloadableViews.isEmpty && validSelections.count == snapshot.downloadableViews.count
        )
    }

    public func startDownloading(
        views: Set<Int>,
        snapshot: NovelReaderDownloadOperationSnapshot,
        repository: NovelReaderDownloadOperationRepository,
        summary: @escaping @MainActor (NovelReaderDownloadOperationMode, NovelReaderDownloadBatchResult) -> String
    ) {
        guard !state.isRunning else { return }
        let selection = selectionState(for: views, snapshot: snapshot)
        guard !selection.notDownloadedSelectedViews.isEmpty else { return }
        startOperation(
            mode: .download,
            views: selection.notDownloadedSelectedViews,
            snapshot: snapshot,
            repository: repository,
            summary: summary
        )
    }

    public func updateDownloadedViews(
        _ views: Set<Int>,
        snapshot: NovelReaderDownloadOperationSnapshot,
        repository: NovelReaderDownloadOperationRepository,
        summary: @escaping @MainActor (NovelReaderDownloadOperationMode, NovelReaderDownloadBatchResult) -> String
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

    public func deleteDownloadedViews(
        _ views: Set<Int>,
        snapshot: NovelReaderDownloadOperationSnapshot,
        repository: NovelReaderDownloadOperationRepository
    ) async throws {
        guard !state.isRunning else { return }
        let selection = selectionState(for: views, snapshot: snapshot)
        guard !selection.downloadedSelectedViews.isEmpty else { return }

        try await repository.deleteDownloadedViews(
            selection.downloadedSelectedViews,
            for: snapshot.context
        )
        syncDownloadState(await repository.downloadState(for: snapshot.context))
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

    public func stopDownloading() {
        guard state.isRunning else { return }
        operationTask?.cancel()
    }

    private func reset() {
        state = NovelReaderDownloadOperationState(downloadedViews: downloadedViews)
        emitChange()
    }

    private func startOperation(
        mode: NovelReaderDownloadOperationMode,
        views: Set<Int>,
        snapshot: NovelReaderDownloadOperationSnapshot,
        repository: NovelReaderDownloadOperationRepository,
        summary: @escaping @MainActor (NovelReaderDownloadOperationMode, NovelReaderDownloadBatchResult) -> String
    ) {
        let targets = views.sorted()
        guard !targets.isEmpty else { return }

        state = NovelReaderDownloadOperationState(
            downloadedViews: downloadedViews,
            queuedViews: targets,
            totalCount: targets.count,
            status: .running
        )
        emitChange()

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let result = if mode == .update {
                await repository.updateDownloadedViews(
                    Set(targets),
                    for: snapshot.context
                ) { [weak self] progress in
                    await self?.apply(progress: progress, allTargets: targets)
                }
            } else {
                await repository.downloadViews(
                    Set(targets),
                    for: snapshot.context
                ) { [weak self] progress in
                    await self?.apply(progress: progress, allTargets: targets)
                }
            }
            await self.finalize(result: result, mode: mode, snapshot: snapshot, repository: repository, summary: summary)
        }
    }

    private func apply(progress: NovelReaderDownloadBatchProgress, allTargets: [Int]) {
        state.totalCount = progress.totalCount
        state.completedCount = progress.completedCount
        state.currentView = progress.currentView
        state.completedViews = progress.completedViews
        state.failedViews = progress.failedViews
        state.status = progress.status == .cancelled ? .cancelled : .running

        let completed = Set(progress.completedViews)
        let failed = Set(progress.failedViews)
        state.queuedViews = allTargets.filter { !completed.contains($0) && !failed.contains($0) }
        syncDownloadedViews(downloadedViews.union(completed))
    }

    private func finalize(
        result: NovelReaderDownloadBatchResult,
        mode: NovelReaderDownloadOperationMode,
        snapshot: NovelReaderDownloadOperationSnapshot,
        repository: NovelReaderDownloadOperationRepository,
        summary: @MainActor (NovelReaderDownloadOperationMode, NovelReaderDownloadBatchResult) -> String
    ) async {
        operationTask = nil
        let refreshedState = await repository.downloadState(for: snapshot.context)
        syncDownloadState(refreshedState)

        state.downloadedViews = downloadedViews
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
        let views = NovelDownloadViewsSnapshot(
                downloadedViews: downloadedViews,
                downloadingViews: downloadingViews,
                updateTimesByView: downloadedViewUpdateTimes
        )
        guard views != lastEmittedViews || state != lastEmittedState else { return }
        lastEmittedViews = views
        lastEmittedState = state
        onChange?(views, state)
    }
}

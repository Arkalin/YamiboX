import Foundation
import Observation
import YamiboXCore

/// Session owner for repository/workflow creation, prepared content and load
/// follow-ups. Closing or replacing a request prevents late state publication.
@MainActor
@Observable
final class NovelReaderLoadingCoordinator {
    struct Presentation {
        var settings: @MainActor () -> NovelReaderAppearanceSettings
        var publish: @MainActor (NovelReadingWorkflowState) -> Void
        var clearFailure: @MainActor () -> Void
        var reportFailure: @MainActor (any Error) -> Void
        var refreshCache: @MainActor () async -> Void
        var prefetchAnchor: @MainActor () -> NovelReaderSurfaceIdentity?
    }

    private(set) var isLoading = false
    @ObservationIgnored private(set) var workflow: NovelReadingWorkflow?
    @ObservationIgnored private var repository: (any NovelReadingPageRepository)?
    @ObservationIgnored private var preparedInitialLoad: NovelReadingPreparedInitialLoad?
    @ObservationIgnored private var forceRefreshInitialLoad = false
    @ObservationIgnored private var hasRecordedVisit = false
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var loadRevision: UInt64 = 0
    @ObservationIgnored private var followUpTask: Task<Void, Never>?

    private let context: NovelLaunchContext
    private let makeRepository: @Sendable () async -> any NovelReadingPageRepository
    private let settingsStore: SettingsStore
    private let progressStore: ReadingProgressStore
    private let history: BrowsingHistoryWorkflow
    private let runtime: NovelReaderRuntimeUpdateCoordinator
    private let runtimeAdapter: any NovelTextLayoutRuntimeAdapter
    private let presentation: Presentation
    private var preparation: NovelReaderPreparationCoordinator { runtime.preparation }

    init(
        context: NovelLaunchContext,
        makeRepository: @escaping @Sendable () async -> any NovelReadingPageRepository,
        settingsStore: SettingsStore,
        progressStore: ReadingProgressStore,
        history: BrowsingHistoryWorkflow,
        runtime: NovelReaderRuntimeUpdateCoordinator,
        runtimeAdapter: any NovelTextLayoutRuntimeAdapter,
        presentation: Presentation
    ) {
        self.context = context
        self.makeRepository = makeRepository
        self.settingsStore = settingsStore
        self.progressStore = progressStore
        self.history = history
        self.runtime = runtime
        self.runtimeAdapter = runtimeAdapter
        self.presentation = presentation
    }

    deinit { followUpTask?.cancel() }

    func close() {
        isClosed = true
        loadRevision &+= 1
        followUpTask?.cancel()
        followUpTask = nil
        workflow?.close()
        workflow = nil
        preparedInitialLoad = nil
        isLoading = false
    }

    func ensureWorkflow() async -> NovelReadingWorkflow? {
        guard !isClosed else { return nil }
        if let workflow { return workflow }
        if repository == nil {
            let repository = await makeRepository()
            guard !isClosed, !Task.isCancelled else { return nil }
            if self.repository == nil { self.repository = repository }
        }
        if workflow == nil, let repository { workflow = makeWorkflow(repository: repository) }
        return workflow
    }

    private func makeWorkflow(repository: any NovelReadingPageRepository) -> NovelReadingWorkflow {
        NovelReadingWorkflow(
            context: context, settings: presentation.settings(), layout: preparation.layout,
            repository: repository, usesPadPresentation: runtime.usesPadPresentation,
            runtimeAdapter: runtimeAdapter
        )
    }

    func prepareInitialIfNeeded() async {
        guard !isClosed else { return }
        await preparation.runIfNeeded { [weak self] sequence in
            await self?.prepareInitial(sequence: sequence)
        }
    }

    func invalidateInitialForRefresh() async -> Bool {
        guard !isClosed, await preparation.invalidateForRefresh(), !isClosed else { return false }
        loadRevision &+= 1
        followUpTask?.cancel()
        preparedInitialLoad = nil
        forceRefreshInitialLoad = true
        if let repository {
            workflow?.close()
            workflow = makeWorkflow(repository: repository)
        }
        return true
    }

    private func prepareInitial(sequence: UInt64) async {
        guard !isClosed else { return }
        isLoading = true
        presentation.clearFailure()
        defer {
            if preparation.isCurrent(sequence) {
                isLoading = false
                preparation.finishCurrentRun(sequence)
            }
        }
        do {
            if repository == nil {
                let repository = await makeRepository()
                try Task.checkCancellation()
                guard preparation.isCurrent(sequence), !isClosed else { return }
                let settings = await settingsStore.load()
                try Task.checkCancellation()
                guard preparation.isCurrent(sequence), !isClosed else { return }
                self.repository = repository
                runtime.bootstrapSettings = settings.novelReader
                runtime.applePencilPageTurnSettings = settings.system.applePencilPageTurn
            }
            guard let workflow = await ensureWorkflow() else { return }
            if preparedInitialLoad == nil, workflow.state == nil {
                let progress = try await progressStore.load(threadID: context.threadID)
                try Task.checkCancellation()
                guard preparation.isCurrent(sequence), !isClosed else { return }
                let prepared = try await workflow.prepareInitialLoad(initial: NovelReadingInitialPosition(
                    resumePoint: context.initialResumePoint ?? progress?.novel?.novelResumePoint,
                    favoriteAuthorID: progress?.novel?.authorID
                ), forceRefresh: forceRefreshInitialLoad)
                try Task.checkCancellation()
                guard preparation.isCurrent(sequence), self.workflow === workflow, !isClosed else { return }
                preparedInitialLoad = prepared
                forceRefreshInitialLoad = false
            }
            // Drain geometry changes before admitting the first presentation.
            while preparation.isCurrent(sequence), !isClosed {
                try Task.checkCancellation()
                let layout = preparation.requestedLayout
                guard runtime.isReadyForTextLayout(layout) else {
                    preparation.advance(to: .waitingForLayout, for: sequence)
                    return
                }
                let layoutRevision = preparation.layoutRevision
                preparation.advance(to: .layingOut, for: sequence)
                if workflow.state == nil, let preparedInitialLoad {
                    _ = try await workflow.start(prepared: preparedInitialLoad, layout: layout)
                } else {
                    _ = try await runtime.requestRuntimeUpdate(
                        settings: presentation.settings(), layout: layout, usesPadPresentation: runtime.usesPadPresentation
                    )
                }
                try Task.checkCancellation()
                guard preparation.isCurrent(sequence), self.workflow === workflow, !isClosed else { return }
                guard layoutRevision == preparation.layoutRevision else { continue }
                guard let state = workflow.state else { return }
                preparation.commitLayout(layout)
                preparedInitialLoad = nil
                preparation.advance(to: .restoring, for: sequence)
                presentation.publish(state)
                recordVisitIfNeeded()
                scheduleFollowUp(refreshCache: true)
                return
            }
        } catch {
            guard preparation.isCurrent(sequence), !isClosed else { return }
            if Task.isCancelled {
                preparation.advance(to: .cancelled, for: sequence)
            } else {
                preparation.advance(to: .failed, for: sequence)
                presentation.reportFailure(error)
            }
        }
    }

    func load(
        view: Int, preferredSurfaceOrdinal: Int, preferredResumePoint: NovelResumePoint?,
        forceRefresh: Bool, reportsError: Bool
    ) async -> Bool {
        await performLoad(reportsError: reportsError, refreshCache: true) { workflow in
            try await workflow.loadView(view, preferredSurfaceOrdinal: preferredSurfaceOrdinal,
                preferredResumePoint: preferredResumePoint, forceRefresh: forceRefresh)
        }
    }

    func loadChapter(_ anchor: NovelChapterAnchor) async -> Bool {
        await performLoad(reportsError: true, refreshCache: false) { workflow in
            try await workflow.loadChapter(anchor)
        }
    }

    private func performLoad(
        reportsError: Bool, refreshCache: Bool,
        operation: @MainActor (NovelReadingWorkflow) async throws -> NovelReadingWorkflowState
    ) async -> Bool {
        guard let workflow = await ensureWorkflow() else { return false }
        loadRevision &+= 1
        let request = loadRevision
        followUpTask?.cancel()
        isLoading = true
        presentation.clearFailure()
        defer { if loadRevision == request { isLoading = false } }
        do {
            let state = try await operation(workflow)
            guard admits(request, workflow: workflow) else { return false }
            presentation.publish(state)
            isLoading = false
            if refreshCache {
                recordVisitIfNeeded()
                await presentation.refreshCache()
                guard admits(request, workflow: workflow) else { return false }
                scheduleFollowUp(refreshCache: false)
            }
            return true
        } catch {
            guard admits(request, workflow: workflow) else { return false }
            if reportsError {
                if !LoadDiagnosticError.isCancellation(error) { presentation.reportFailure(error) }
            } else {
                YamiboLog.reader.warning("Novel page load failed on a non-reporting fallback path: \(error)")
            }
            return false
        }
    }

    private func admits(_ request: UInt64, workflow: NovelReadingWorkflow) -> Bool {
        !isClosed && !Task.isCancelled && loadRevision == request && self.workflow === workflow
    }

    func prefetch(near anchor: NovelReaderSurfaceIdentity) async {
        guard let workflow = await ensureWorkflow() else { return }
        let request = loadRevision
        guard let state = await workflow.prefetchIfNeeded(near: anchor), admits(request, workflow: workflow) else { return }
        presentation.publish(state)
    }

    private func scheduleFollowUp(refreshCache: Bool) {
        followUpTask?.cancel()
        let request = loadRevision
        guard let workflow else { return }
        followUpTask = Task { [weak self, refresh = presentation.refreshCache] in
            if refreshCache { await refresh() }
            guard let self, self.admits(request, workflow: workflow), let anchor = self.presentation.prefetchAnchor() else { return }
            await self.prefetch(near: anchor)
        }
    }

    private func recordVisitIfNeeded() {
        guard !hasRecordedVisit, !context.isPreview else { return }
        hasRecordedVisit = true
        let visit = BrowsingHistoryVisit(
            threadID: context.threadID,
            title: context.threadTitle.isEmpty ? L10n.string("reader.title") : context.threadTitle,
            forumID: context.forumID, reader: .novel, authorID: context.authorID
        )
        // A completed visit is durable work, not speculative loading. It finishes
        // independently of closing the presenting reader, without retaining it.
        Task { [history, context] in
            do { try await history.recordVisit(visit) }
            catch { YamiboLog.reader.warning("Failed to record novel browsing-history visit for thread \(context.threadID, privacy: .public): \(error)") }
        }
    }
}

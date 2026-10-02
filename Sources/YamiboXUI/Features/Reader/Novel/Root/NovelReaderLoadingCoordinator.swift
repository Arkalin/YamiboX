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
        var refreshDownload: @MainActor () async -> Void
        var prefetchAnchor: @MainActor () -> NovelReaderSurfaceIdentity?
        var resolveFonts: @MainActor (NovelReaderAppearanceSettings) async -> NovelReaderAppearanceSettings
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
    @ObservationIgnored private var downloadRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var cachedViewsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadTask: Task<NovelReadingWorkflowState?, Error>?

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

    deinit {
        followUpTask?.cancel()
        downloadRefreshTask?.cancel()
        cachedViewsRefreshTask?.cancel()
        activeLoadTask?.cancel()
    }

    private func cancelFollowUps() {
        followUpTask?.cancel()
        downloadRefreshTask?.cancel()
        cachedViewsRefreshTask?.cancel()
        followUpTask = nil
        downloadRefreshTask = nil
        cachedViewsRefreshTask = nil
    }

    func close() {
        isClosed = true
        loadRevision &+= 1
        activeLoadTask?.cancel()
        activeLoadTask = nil
        cancelFollowUps()
        workflow?.close()
        workflow = nil
        preparedInitialLoad = nil
        isLoading = false
    }

    func ensureWorkflow(resolvedSettings: NovelReaderAppearanceSettings? = nil) async -> NovelReadingWorkflow? {
        guard !isClosed else { return nil }
        if let workflow { return workflow }
        if repository == nil {
            let repository = await makeRepository()
            guard !isClosed, !Task.isCancelled else { return nil }
            if self.repository == nil { self.repository = repository }
        }
        if workflow == nil, let repository {
            let resolvedSettings = if let resolvedSettings {
                resolvedSettings
            } else {
                await presentation.resolveFonts(presentation.settings())
            }
            guard !isClosed, !Task.isCancelled else { return nil }
            if workflow == nil {
                runtime.bootstrapSettings = resolvedSettings
                workflow = makeWorkflow(repository: repository)
            }
        }
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
        activeLoadTask?.cancel()
        activeLoadTask = nil
        cancelFollowUps()
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
            var bootstrap: (settings: NovelReaderAppearanceSettings, progress: ReadingProgressRecord?)?
            if repository == nil {
                async let repository = makeRepository()
                async let progress = progressStore.load(threadID: context.threadID)
                let settings = await settingsStore.load()
                async let resolvedSettings = presentation.resolveFonts(settings.novelReader)
                let (readyRepository, readySettings, readyProgress) = try await (repository, resolvedSettings, progress)
                try Task.checkCancellation()
                guard preparation.isCurrent(sequence), !isClosed else { return }
                self.repository = readyRepository
                runtime.bootstrapSettings = readySettings
                runtime.applePencilPageTurnSettings = settings.system.applePencilPageTurn
                bootstrap = (readySettings, readyProgress)
            }
            guard let workflow = await ensureWorkflow(resolvedSettings: bootstrap?.settings) else { return }
            if preparedInitialLoad == nil, workflow.state == nil {
                let progress: ReadingProgressRecord?
                if let bootstrap {
                    progress = bootstrap.progress
                } else {
                    progress = try await progressStore.load(threadID: context.threadID)
                }
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
            try await preparation.waitForInitialDisplay()
            try Task.checkCancellation()
            guard preparation.isCurrent(sequence), !isClosed else { return }
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
                scheduleFollowUp(refreshDownload: true)
                return
            }
        } catch {
            guard preparation.isCurrent(sequence), !isClosed else { return }
            if Task.isCancelled || LoadDiagnosticError.isCancellation(error) {
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
        await performLoad(reportsError: reportsError, refreshDownload: true) { workflow in
            try await workflow.loadView(view, preferredSurfaceOrdinal: preferredSurfaceOrdinal,
                preferredResumePoint: preferredResumePoint, forceRefresh: forceRefresh)
        }
    }

    func loadChapter(_ anchor: NovelChapterAnchor) async -> Bool {
        await performLoad(reportsError: true, refreshDownload: false) { workflow in
            try await workflow.loadChapter(anchor)
        }
    }

    private func performLoad(
        reportsError: Bool, refreshDownload: Bool,
        operation: @escaping @MainActor (NovelReadingWorkflow) async throws -> NovelReadingWorkflowState
    ) async -> Bool {
        guard let workflow = await ensureWorkflow() else { return false }
        loadRevision &+= 1
        let request = loadRevision
        activeLoadTask?.cancel()
        let loadTask = Task<NovelReadingWorkflowState?, Error> {
            try await operation(workflow)
        }
        activeLoadTask = loadTask
        cancelFollowUps()
        isLoading = true
        presentation.clearFailure()
        defer {
            if loadRevision == request {
                activeLoadTask = nil
                isLoading = false
            }
        }
        do {
            let loadedState = try await withTaskCancellationHandler {
                try await loadTask.value
            } onCancel: {
                loadTask.cancel()
            }
            guard let state = loadedState else { return false }
            guard admits(request, workflow: workflow) else { return false }
            presentation.publish(state)
            isLoading = false
            if refreshDownload {
                recordVisitIfNeeded()
            }
            scheduleFollowUp(refreshDownload: refreshDownload)
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

    func promotePrefetchedDocument(
        preferredSurfaceOrdinal: Int, resumePoint: NovelResumePoint?
    ) async throws -> Bool {
        guard let workflow = await ensureWorkflow() else { return false }
        loadRevision &+= 1
        let request = loadRevision
        activeLoadTask?.cancel()
        cancelFollowUps()
        let loadTask = Task<NovelReadingWorkflowState?, Error> {
            try await workflow.promotePrefetchedDocument(
                preferredSurfaceOrdinal: preferredSurfaceOrdinal, resumePoint: resumePoint
            )
        }
        activeLoadTask = loadTask
        defer { if loadRevision == request { activeLoadTask = nil } }
        let loadedState = try await withTaskCancellationHandler {
            try await loadTask.value
        } onCancel: {
            loadTask.cancel()
        }
        guard let state = loadedState, admits(request, workflow: workflow) else { return false }
        presentation.publish(state)
        scheduleFollowUp(refreshDownload: true)
        return true
    }

    private func scheduleFollowUp(refreshDownload: Bool) {
        cancelFollowUps()
        let request = loadRevision
        guard let workflow else { return }
        if refreshDownload {
            downloadRefreshTask = Task { [weak self, refresh = presentation.refreshDownload] in
                guard let self, self.admits(request, workflow: workflow) else { return }
                await refresh()
            }
        }
        cachedViewsRefreshTask = Task { [weak self] in
            guard let self, self.admits(request, workflow: workflow) else { return }
            await workflow.refreshCachedViewsForCurrentDocument()
        }
        followUpTask = Task { [weak self] in
            guard let self, self.admits(request, workflow: workflow) else { return }
            guard let anchor = self.presentation.prefetchAnchor() else { return }
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

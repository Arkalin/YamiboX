import Foundation

package protocol NovelReadingPageRepository: Sendable {
    func loadPage(_ request: NovelPageRequest) async throws -> NovelReaderProjection
    func loadPageIgnoringCache(_ request: NovelPageRequest) async throws -> NovelReaderProjection
    func loadPageResult(_ request: NovelPageRequest) async throws -> NovelReaderProjectionLoad
    func loadPageIgnoringCacheResult(_ request: NovelPageRequest) async throws -> NovelReaderProjectionLoad
    func cachedViews(
        for threadID: String,
        authorID: String?
    ) async -> Set<Int>
    func deleteCachedViews(
        _ views: Set<Int>,
        for threadID: String,
        authorID: String?
    ) async throws
}

extension NovelReadingPageRepository {
    func loadPageResult(_ request: NovelPageRequest) async throws -> NovelReaderProjectionLoad {
        NovelReaderProjectionLoad(projection: try await loadPage(request), source: .online)
    }

    func loadPageIgnoringCacheResult(_ request: NovelPageRequest) async throws -> NovelReaderProjectionLoad {
        NovelReaderProjectionLoad(projection: try await loadPageIgnoringCache(request), source: .online)
    }
}

extension NovelReaderRepository: NovelReadingPageRepository {}

public struct NovelReadingInitialPosition: Equatable, Sendable {
    public var resumePoint: NovelResumePoint?
    public var favoriteAuthorID: String?

    public init(resumePoint: NovelResumePoint? = nil, favoriteAuthorID: String? = nil) {
        self.resumePoint = resumePoint
        self.favoriteAuthorID = favoriteAuthorID
    }
}

public struct NovelReadingCacheContext: Equatable, Sendable {
    public var authorID: String?

    public init(authorID: String?) {
        self.authorID = authorID
    }
}

public struct NovelReadingWorkflowState: Equatable, Sendable {
    package var snapshot: NovelReadingSnapshot
    public var presentation: NovelReaderPresentation?
    public var cachedViews: Set<Int>

    package init(
        snapshot: NovelReadingSnapshot,
        presentation: NovelReaderPresentation? = nil,
        cachedViews: Set<Int> = []
    ) {
        self.snapshot = snapshot
        self.presentation = presentation
        self.cachedViews = cachedViews
    }
}

public struct NovelReadingWorkflowRuntimeUpdate: Equatable, Sendable {
    public var settings: NovelReaderAppearanceSettings
    public var layout: NovelReaderLayout
    public var usesPadPresentation: Bool

    public init(
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        usesPadPresentation: Bool
    ) {
        self.settings = settings
        self.layout = layout
        self.usesPadPresentation = usesPadPresentation
    }
}

package struct NovelReadingWorkflowDebugState: Equatable, Sendable {
    package var viewportSurfaces: [NovelTextViewportIndexSurface]
    package var fingerprints: NovelTextLayoutFingerprints?
    package var runtime: NovelTextViewportRuntimeDiagnostics
    package var transactions: NovelTextViewportRuntimeTransactionDiagnostics
}

public typealias NovelReadingWorkflowRuntimeUpdatePreparation = @Sendable (
    _ update: NovelReadingWorkflowRuntimeUpdate
) async throws -> NovelReadingWorkflowRuntimeUpdate

private struct NovelReadingPreparedTransaction {
    let runtime: NovelTextViewportRuntimeTransaction
    let session: NovelReadingSession
    let state: NovelReadingWorkflowState
    let settings: NovelReaderAppearanceSettings
    let layout: NovelReaderLayout
    let usesPadPresentation: Bool
    let currentDocument: NovelReaderProjection
    let prefetchedDocument: NovelReaderProjection?
    let currentLoadSource: NovelReaderProjectionLoadSource
    let prefetchedLoadSource: NovelReaderProjectionLoadSource?
    let currentAuthorID: String?
    let currentDocumentSurfaceCount: Int
}

/// Caller-isolated (non-`Sendable`): the workflow runs entirely in whatever
/// isolation domain owns it, so its synchronous per-frame paths (viewport
/// samples, display-reference lookups) stay synchronous and its `async`
/// methods (`nonisolated(nonsending)`) never hop executors. The live TextKit
/// graph is provided by the UI layer through `NovelTextLayoutRuntimeAdapter`.
public final class NovelReadingWorkflow {
    public private(set) var state: NovelReadingWorkflowState?
    public private(set) var runtimeUpdateRequestSequence: UInt64 = 0

    private let context: NovelLaunchContext
    private var settings: NovelReaderAppearanceSettings
    private var layout: NovelReaderLayout
    private let repository: any NovelReadingPageRepository
    private var session: NovelReadingSession?
    /// Snapshot carried by the last published `state`; every `state`
    /// assignment must keep it in sync or `shouldRebuildPresentation`'s
    /// accumulated-progress comparison drifts.
    private var lastPublishedSnapshot: NovelReadingSnapshot?
    private var currentDocument: NovelReaderProjection?
    private var prefetchedDocument: NovelReaderProjection?
    private var currentLoadSource: NovelReaderProjectionLoadSource = .online
    private var prefetchedLoadSource: NovelReaderProjectionLoadSource?
    private var currentAuthorID: String?
    private var currentDocumentSurfaceCount = 0
    private var usesPadPresentation: Bool
    private let viewportRuntime: NovelTextViewportRuntimeOwner
    private var pendingRuntimeUpdateTask: Task<(NovelReadingWorkflowRuntimeUpdate, NovelTextLayoutPreparedInput)?, Error>?
    private var prefetchInFlightView: Int?
    private var prefetchCooldown: (view: Int, until: Date)?
    private let now: @Sendable () -> Date

    private static let prefetchFailureCooldownInterval: TimeInterval = 5
    private static let verticalSampleProgressUpdateThreshold: Double = 0.02

    package var runtimeDiagnostics: NovelTextViewportRuntimeDiagnostics {
        viewportRuntime.diagnostics
    }

    package var runtimeTransactionDiagnostics: NovelTextViewportRuntimeTransactionDiagnostics {
        viewportRuntime.runtimeTransactionDiagnostics
    }

    package var debugState: NovelReadingWorkflowDebugState {
        NovelReadingWorkflowDebugState(
            viewportSurfaces: viewportRuntime.currentResult?.viewportIndex.surfaces ?? [],
            fingerprints: viewportRuntime.currentResult?.fingerprints,
            runtime: viewportRuntime.diagnostics,
            transactions: viewportRuntime.runtimeTransactionDiagnostics
        )
    }

    package var runtime: NovelTextViewportRuntimeOwner {
        viewportRuntime
    }

    /// `package`: the workflow is assembled inside this package (UI layer or
    /// tests) because the runtime adapter seam is a package-internal contract.
    package init(
        context: NovelLaunchContext,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        repository: any NovelReadingPageRepository,
        usesPadPresentation: Bool = false,
        runtimeAdapter: any NovelTextLayoutRuntimeAdapter,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.context = context
        self.settings = settings
        self.layout = layout
        self.repository = repository
        self.usesPadPresentation = usesPadPresentation
        self.now = now
        viewportRuntime = NovelTextViewportRuntimeOwner(adapter: runtimeAdapter)
    }

    @discardableResult
    public nonisolated(nonsending) func start(initial: NovelReadingInitialPosition) async throws -> NovelReadingWorkflowState {
        let resumePoint = initial.resumePoint
        let initialView = resumePoint?.view ?? context.initialView ?? 1
        currentAuthorID = resumePoint?.authorID ?? initial.favoriteAuthorID ?? context.authorID
        return try await load(
            view: initialView,
            preferredSurfaceOrdinal: 0,
            preferredResumePoint: resumePoint,
            forceRefresh: false
        )
    }

    @discardableResult
    public nonisolated(nonsending) func loadCurrent(
        preferredSurfaceOrdinal: Int,
        preferredResumePoint: NovelResumePoint?,
        forceRefresh: Bool
    ) async throws -> NovelReadingWorkflowState {
        let view = state?.snapshot.currentView ?? context.initialView ?? 1
        return try await loadView(
            view,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            preferredResumePoint: preferredResumePoint,
            forceRefresh: forceRefresh
        )
    }

    @discardableResult
    public nonisolated(nonsending) func loadView(
        _ view: Int,
        preferredSurfaceOrdinal: Int,
        preferredResumePoint: NovelResumePoint?,
        forceRefresh: Bool
    ) async throws -> NovelReadingWorkflowState {
        return try await load(
            view: view,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            preferredResumePoint: preferredResumePoint,
            forceRefresh: forceRefresh
        )
    }

    public func cacheContext(forView view: Int) -> NovelReadingCacheContext {
        if let currentDocument, currentDocument.view == view {
            return cacheContext(for: currentDocument)
        }

        if let prefetchedDocument, prefetchedDocument.view == view {
            return cacheContext(for: prefetchedDocument)
        }

        let authorID = currentAuthorID ?? context.authorID
        return NovelReadingCacheContext(authorID: authorID)
    }

    public func canPromotePrefetchedDocument(forView view: Int) -> Bool {
        prefetchedDocument?.view == max(1, view)
    }

    package nonisolated(nonsending) func previewChapterDirectory(view: Int) async throws -> [NovelChapterDirectoryEntry] {
        let request = NovelPageRequest(
            threadID: context.threadID,
            view: view,
            authorID: cacheContext(forView: view).authorID
        )
        let document = try await repository.loadPage(request)
        return NovelChapterDirectoryExtractor.entries(from: document, settings: settings)
    }

    package nonisolated(nonsending) func loadChapter(_ anchor: NovelChapterAnchor) async throws -> NovelReadingWorkflowState {
        try await load(
            view: anchor.resumePoint.view,
            preferredSurfaceOrdinal: 0,
            preferredResumePoint: anchor.resumePoint,
            forceRefresh: false
        )
    }

    @discardableResult
    public func commitSurfaceAppearance(_ settings: NovelReaderAppearanceSettings) -> NovelReadingWorkflowState? {
        guard let state,
              let session,
              state.presentation?.generation == viewportRuntime.currentGeneration else {
            self.settings = settings
            return nil
        }
        self.settings = settings
        let revision = (state.presentation?.revision ?? 0) + 1
        let nextState = NovelReadingWorkflowState(
            snapshot: session.snapshot,
            presentation: makePresentation(
                snapshot: session.snapshot,
                layoutResult: viewportRuntime.currentResult,
                generation: viewportRuntime.currentGeneration,
                revision: revision,
                settings: settings,
                usesTwoPageSpread: usesPagedSpread(
                    settings: settings,
                    layout: layout,
                    usesPadPresentation: usesPadPresentation
                ),
                pageLoadSource: currentLoadSource
            ),
            cachedViews: state.cachedViews
        )
        self.state = nextState
        lastPublishedSnapshot = nextState.snapshot
        return nextState
    }

    @discardableResult
    public nonisolated(nonsending) func requestRuntimeUpdate(
        _ update: NovelReadingWorkflowRuntimeUpdate,
        preparation: @escaping NovelReadingWorkflowRuntimeUpdatePreparation = { $0 }
    ) async throws -> NovelReadingWorkflowState? {
        runtimeUpdateRequestSequence &+= 1
        pendingRuntimeUpdateTask?.cancel()
        pendingRuntimeUpdateTask = nil
        let requestSequence = runtimeUpdateRequestSequence
        let document = currentDocument
        let task = Task.detached(priority: .userInitiated) {
            () async throws -> (NovelReadingWorkflowRuntimeUpdate, NovelTextLayoutPreparedInput)? in
            let preparedUpdate = try await preparation(update)
            try Task.checkCancellation()
            guard let document else { return nil }
            let paginationLayout = preparedUpdate.layout.novelTextBoxLayout(
                settings: preparedUpdate.settings,
                usesPadPresentation: preparedUpdate.usesPadPresentation
            )
            let semanticInput = try NovelTextLayout.prepareInput(
                document: document,
                settings: preparedUpdate.settings,
                layout: paginationLayout
            )
            try Task.checkCancellation()
            return (preparedUpdate, semanticInput)
        }
        pendingRuntimeUpdateTask = task
        do {
            let prepared = try await task.value
            if runtimeUpdateRequestSequence == requestSequence {
                pendingRuntimeUpdateTask = nil
            }
            guard let (preparedUpdate, semanticInput) = prepared else { return nil }
            return try commitRuntimeUpdateRequest(
                preparedUpdate,
                semanticInput: semanticInput,
                requestSequence: requestSequence
            )
        } catch {
            if runtimeUpdateRequestSequence == requestSequence {
                pendingRuntimeUpdateTask = nil
            }
            throw error
        }
    }

    private func commitRuntimeUpdateRequest(
        _ update: NovelReadingWorkflowRuntimeUpdate,
        semanticInput: NovelTextLayoutPreparedInput,
        requestSequence: UInt64
    ) throws -> NovelReadingWorkflowState? {
        guard requestSequence == runtimeUpdateRequestSequence,
              !Task.isCancelled,
              var candidateSession = session,
              state != nil,
              currentDocument == semanticInput.document else {
            return nil
        }
        let resumePoint = candidateSession.captureNovelReadingPosition()
        let transaction = try viewportRuntime.prepareTransaction(
            preparedInput: semanticInput
        )
        candidateSession.consumeCommittedLayoutResult(
            transaction.result,
            preferredSurfaceOrdinal: candidateSession.snapshot.selectedSurfaceOrdinal,
            preferredResumePoint: resumePoint,
            usesPagedSpread: usesPagedSpread(
                settings: update.settings,
                layout: update.layout,
                usesPadPresentation: update.usesPadPresentation
            ),
            pageTurnDirection: update.settings.pageTurnDirection
        )
        guard requestSequence == runtimeUpdateRequestSequence,
              !Task.isCancelled else {
            return nil
        }
        return try commitRuntimeTransaction(
            transaction: transaction,
            candidateSession: candidateSession,
            settings: update.settings,
            layout: update.layout,
            usesPadPresentation: update.usesPadPresentation
        )
    }

    private func supersedePendingRuntimeUpdate() {
        guard pendingRuntimeUpdateTask != nil else { return }
        runtimeUpdateRequestSequence &+= 1
        pendingRuntimeUpdateTask?.cancel()
        pendingRuntimeUpdateTask = nil
    }

    private func commitRuntimeTransaction(
        transaction: NovelTextViewportRuntimeTransaction,
        candidateSession: NovelReadingSession,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        usesPadPresentation: Bool
    ) throws -> NovelReadingWorkflowState? {
        guard let currentDocument else { return nil }
        let preparedTransaction = try makePreparedTransaction(
            runtime: transaction,
            session: candidateSession,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            currentDocument: currentDocument,
            prefetchedDocument: prefetchedDocument,
            currentLoadSource: currentLoadSource,
            prefetchedLoadSource: prefetchedLoadSource,
            currentAuthorID: candidateSession.snapshot.currentAuthorID ?? currentAuthorID,
            cachedViews: state?.cachedViews ?? []
        )
        return commit(preparedTransaction)
    }

    private func makePreparedTransaction(
        runtime: NovelTextViewportRuntimeTransaction,
        session: NovelReadingSession,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        usesPadPresentation: Bool,
        currentDocument: NovelReaderProjection,
        prefetchedDocument: NovelReaderProjection?,
        currentLoadSource: NovelReaderProjectionLoadSource,
        prefetchedLoadSource: NovelReaderProjectionLoadSource?,
        currentAuthorID: String?,
        cachedViews: Set<Int>
    ) throws -> NovelReadingPreparedTransaction {
        let snapshot = session.snapshot
        try viewportRuntime.prepareInitialViewport(
            for: runtime,
            around: snapshot.selectedSurfaceOrdinal
        )
        let state = NovelReadingWorkflowState(
            snapshot: snapshot,
            presentation: makePresentation(
                snapshot: snapshot,
                layoutResult: runtime.result,
                generation: runtime.generation,
                revision: 0,
                settings: settings,
                usesTwoPageSpread: usesPagedSpread(
                    settings: settings,
                    layout: layout,
                    usesPadPresentation: usesPadPresentation
                ),
                pageLoadSource: currentLoadSource
            ),
            cachedViews: cachedViews
        )
        return NovelReadingPreparedTransaction(
            runtime: runtime,
            session: session,
            state: state,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            currentDocument: currentDocument,
            prefetchedDocument: prefetchedDocument,
            currentLoadSource: currentLoadSource,
            prefetchedLoadSource: prefetchedLoadSource,
            currentAuthorID: currentAuthorID,
            currentDocumentSurfaceCount: session.surfaceCount(in: snapshot.currentView)
        )
    }

    private func commit(
        _ transaction: NovelReadingPreparedTransaction
    ) -> NovelReadingWorkflowState? {
        guard viewportRuntime.commit(transaction.runtime) else { return nil }
        settings = transaction.settings
        layout = transaction.layout
        usesPadPresentation = transaction.usesPadPresentation
        session = transaction.session
        currentDocument = transaction.currentDocument
        prefetchedDocument = transaction.prefetchedDocument
        currentLoadSource = transaction.currentLoadSource
        prefetchedLoadSource = transaction.prefetchedLoadSource
        currentAuthorID = transaction.currentAuthorID
        currentDocumentSurfaceCount = transaction.currentDocumentSurfaceCount
        state = transaction.state
        lastPublishedSnapshot = transaction.state.snapshot
        return transaction.state
    }

    public func selectSurface(
        _ surfaceIdentity: NovelReaderSurfaceIdentity,
        presentationRevision: UInt64
    ) -> NovelReadingWorkflowState? {
        guard let presentation = state?.presentation,
              presentation.generation == surfaceIdentity.generation,
              presentation.revision == presentationRevision,
              presentation.surfaces.contains(where: { $0.identity == surfaceIdentity }) else {
            return nil
        }
        let previousSnapshot = session?.snapshot
        session?.selectSurface(surfaceIdentity.ordinal)
        guard session?.snapshot != previousSnapshot else { return nil }
        return try? updateStateFromSession(cachedViews: state?.cachedViews ?? [])
    }

    public func restoreResumePointInCurrentDocument(
        _ resumePoint: NovelResumePoint
    ) -> NovelReadingWorkflowState? {
        guard let state,
              state.snapshot.currentView == resumePoint.view,
              session?.restoreResumePoint(resumePoint) == true else {
            return nil
        }
        return try? updateStateFromSession(cachedViews: state.cachedViews)
    }

    public func updateVerticalViewportPosition(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        intraSurfaceProgress: Double,
        presentationRevision: UInt64
    ) -> NovelReadingWorkflowState? {
        guard let presentation = state?.presentation,
              presentation.generation == surfaceIdentity.generation,
              presentation.revision == presentationRevision,
              presentation.surfaces.contains(where: { $0.identity == surfaceIdentity }) else {
            return nil
        }
        let previousSnapshot = session?.snapshot
        session?.updateVerticalViewportPosition(
            surfaceOrdinal: surfaceIdentity.ordinal,
            intraSurfaceProgress: intraSurfaceProgress
        )
        guard session?.snapshot != previousSnapshot else { return nil }
        return try? updateStateFromSession(cachedViews: state?.cachedViews ?? [])
    }

    @discardableResult
    package func updateVerticalViewportPosition(
        sample: NovelTextViewportSample
    ) -> NovelReadingWorkflowState? {
        let previousSnapshot = session?.snapshot
        session?.updateVerticalViewportPosition(sample: sample)
        guard shouldRebuildPresentation(afterSampleUpdateFrom: previousSnapshot) else { return nil }
        return try? updateStateFromSession(cachedViews: state?.cachedViews ?? [])
    }

    @discardableResult
    package func updateVerticalViewportPosition(
        sample: NovelTextViewportSample,
        presentationRevision: UInt64
    ) -> NovelReadingWorkflowState? {
        guard let presentation = state?.presentation,
              presentation.generation == sample.surfaceIdentity.generation,
              presentation.revision == presentationRevision else {
            return nil
        }
        let previousSnapshot = session?.snapshot
        session?.updateVerticalViewportPosition(sample: sample)
        guard shouldRebuildPresentation(afterSampleUpdateFrom: previousSnapshot) else { return nil }
        return try? updateStateFromSession(cachedViews: state?.cachedViews ?? [])
    }

    /// TextKit-resolved viewport samples arrive at glyph precision, so a
    /// naive `snapshot != previousSnapshot` guard rebuilds the (`O(surface
    /// count)`) presentation on every scroll tick. Only a non-progress change
    /// or the progress drift accumulated since `lastPublishedSnapshot`
    /// crossing `verticalSampleProgressUpdateThreshold` justifies that
    /// rebuild — comparing adjacent samples instead would let slow scrolling
    /// (per-sample deltas below the threshold) starve the rebuild forever.
    /// The session mutation above still runs unconditionally so resume-point
    /// capture stays glyph-accurate.
    private func shouldRebuildPresentation(afterSampleUpdateFrom previousSnapshot: NovelReadingSnapshot?) -> Bool {
        guard let newSnapshot = session?.snapshot else {
            return previousSnapshot != nil
        }
        guard newSnapshot != previousSnapshot else { return false }
        guard let lastPublishedSnapshot else { return true }
        var lastPublishedAtNewProgress = lastPublishedSnapshot
        lastPublishedAtNewProgress.currentSurfaceIntraProgress = newSnapshot.currentSurfaceIntraProgress
        let onlyProgressDiffers = lastPublishedAtNewProgress == newSnapshot
        let progressDelta = abs(newSnapshot.currentSurfaceIntraProgress - lastPublishedSnapshot.currentSurfaceIntraProgress)
        return !onlyProgressDiffers || progressDelta >= Self.verticalSampleProgressUpdateThreshold
    }

    @discardableResult
    package func jumpRelativeSurface(_ delta: Int) -> (state: NovelReadingWorkflowState, request: NovelReadingNavigationRequest?)? {
        guard session != nil else { return nil }
        var request = session?.jumpRelativeSurface(delta)
        if case let .loadView(view, preferredSurfaceOrdinal, resumePoint) = request,
           prefetchedDocument?.view == view {
            request = .promotePrefetched(
                preferredSurfaceOrdinal: preferredSurfaceOrdinal,
                resumePoint: resumePoint
            )
        }
        guard let state = try? updateStateFromSession(cachedViews: state?.cachedViews ?? []) else { return nil }
        return (state, request)
    }

    public func captureNovelReadingPosition() -> NovelResumePoint? {
        session?.captureNovelReadingPosition()
    }

    public func currentProgressPosition() -> NovelReadingPosition {
        let resumePoint = captureNovelReadingPosition()
        let snapshot = state?.snapshot
        let progressProjection = state?.presentation?.progressProjection
        let documentSurfaceProgressPercent = progressProjection.map { projection in
            guard projection.displayedPageCount > 1 else { return 0 }
            let fraction = Double(projection.displayedPageIndex) / Double(projection.displayedPageCount - 1)
            return Int((min(max(fraction, 0), 1) * 100).rounded())
        }
        let surfaces = viewportRuntime.currentResult?.viewportIndex.surfaces ?? []
        let view = currentDisplayedView(in: snapshot, surfaces: surfaces) ?? resumePoint?.view ?? context.initialView ?? 1
        return NovelReadingPosition(
            threadID: context.threadID,
            view: view,
            maxView: snapshot?.maxView,
            chapterTitle: resumePoint?.chapterTitle ?? snapshot?.currentChapterTitle,
            authorID: resumePoint?.authorID ?? snapshot?.currentAuthorID ?? currentAuthorID ?? context.authorID,
            resumePoint: resumePoint,
            documentSurfaceProgressPercent: documentSurfaceProgressPercent
        )
    }

    public func currentPreviewSourceText() -> String {
        session?.currentPreviewSourceText() ?? ""
    }

    public func updateVisibleSurfaceIdentities(_ surfaceIdentities: [NovelReaderSurfaceIdentity]) {
        viewportRuntime.updateVisibleSurfaceIdentities(surfaceIdentities)
    }

    public func handleMemoryPressure() {
        viewportRuntime.handleMemoryPressure()
    }

    public func close() {
        supersedePendingRuntimeUpdate()
        viewportRuntime.release()
        session = nil
        currentDocument = nil
        prefetchedDocument = nil
        currentLoadSource = .online
        prefetchedLoadSource = nil
        currentAuthorID = nil
        currentDocumentSurfaceCount = 0
        prefetchInFlightView = nil
        prefetchCooldown = nil
        state = nil
        lastPublishedSnapshot = nil
    }

    private func cacheContext(for document: NovelReaderProjection) -> NovelReadingCacheContext {
        let authorID = document.resolvedAuthorID ?? currentAuthorID ?? context.authorID
        return NovelReadingCacheContext(authorID: authorID)
    }

    private func currentDisplayedView(
        in snapshot: NovelReadingSnapshot?,
        surfaces: [NovelTextViewportIndexSurface]
    ) -> Int? {
        guard let snapshot else { return nil }
        let normalizedIndex = selectedSurfaceOrdinal(in: snapshot, surfaces: surfaces)
        guard surfaces.indices.contains(normalizedIndex) else {
            return snapshot.currentView
        }
        return surfaces[normalizedIndex].documentView
    }

    private func selectedSurfaceOrdinal(
        in snapshot: NovelReadingSnapshot,
        surfaces: [NovelTextViewportIndexSurface]
    ) -> Int {
        max(0, min(snapshot.selectedSurfaceOrdinal, max(surfaces.count - 1, 0)))
    }

    @discardableResult
    public nonisolated(nonsending) func prefetchIfNeeded(near surfaceIdentity: NovelReaderSurfaceIdentity) async -> NovelReadingWorkflowState? {
        guard let currentDocument else { return nil }
        guard surfaceIdentity.generation == viewportRuntime.currentGeneration,
              viewportRuntime.currentResult?.viewportIndex.surfaces.contains(where: {
                  $0.surfaceOrdinal == surfaceIdentity.ordinal
              }) == true else {
            return nil
        }
        guard currentDocument.view < currentDocument.maxView else { return nil }
        let thresholdIndex = max(currentDocumentSurfaceCount - 2, 0)
        guard surfaceIdentity.ordinal >= thresholdIndex else { return nil }
        if let prefetchedDocument, prefetchedDocument.view == currentDocument.view + 1 {
            return nil
        }

        let targetView = currentDocument.view + 1
        guard prefetchInFlightView != targetView else { return nil }
        if let prefetchCooldown, prefetchCooldown.view == targetView, prefetchCooldown.until > now() {
            return nil
        }

        prefetchInFlightView = targetView
        defer {
            if prefetchInFlightView == targetView {
                prefetchInFlightView = nil
            }
        }

        let nextRequest = NovelPageRequest(
            threadID: context.threadID,
            view: targetView,
            authorID: currentAuthorID ?? currentDocument.resolvedAuthorID ?? context.authorID
        )
        guard let nextLoad = try? await repository.loadPageResult(nextRequest) else {
            prefetchCooldown = (view: targetView, until: now().addingTimeInterval(Self.prefetchFailureCooldownInterval))
            return nil
        }
        prefetchCooldown = nil

        let nextDocument = nextLoad.projection
        prefetchedDocument = nextDocument
        prefetchedLoadSource = nextLoad.source
        if nextDocument.maxView > (session?.snapshot.maxView ?? 0) {
            session?.updateMaximumView(nextDocument.maxView)
        }
        return try? await updateStateFromSession(refreshCachedViews: false)
    }

    @discardableResult
    public nonisolated(nonsending) func promotePrefetchedDocument(
        preferredSurfaceOrdinal: Int,
        resumePoint: NovelResumePoint?
    ) async throws -> NovelReadingWorkflowState? {
        supersedePendingRuntimeUpdate()
        guard let nextDocument = prefetchedDocument,
              var candidateSession = session else {
            return nil
        }
        let effectiveResumePoint = resumePoint?.view == nextDocument.view ? resumePoint : nil
        let transaction = try prepareRuntimeTransaction(
            document: nextDocument,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation
        )
        try candidateSession.promotePrefetchedDocument(
            document: nextDocument,
            layoutResult: transaction.result,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            resumePoint: effectiveResumePoint,
            usesPagedSpread: usesPagedSpread(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            )
        )
        let nextAuthorID = nextDocument.resolvedAuthorID ?? currentAuthorID ?? context.authorID
        let preparedTransaction = try makePreparedTransaction(
            runtime: transaction,
            session: candidateSession,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            currentDocument: nextDocument,
            prefetchedDocument: nil,
            currentLoadSource: prefetchedLoadSource ?? .online,
            prefetchedLoadSource: nil,
            currentAuthorID: candidateSession.snapshot.currentAuthorID ?? nextAuthorID,
            cachedViews: state?.cachedViews ?? [],
        )
        return commit(preparedTransaction)
    }

    private nonisolated(nonsending) func load(
        view: Int,
        preferredSurfaceOrdinal: Int,
        preferredResumePoint: NovelResumePoint?,
        forceRefresh: Bool
    ) async throws -> NovelReadingWorkflowState {
        supersedePendingRuntimeUpdate()
        if forceRefresh {
            let context = cacheContext(forView: view)
            try await repository.deleteCachedViews(
                [view],
                for: self.context.threadID,
                authorID: context.authorID
            )
        }

        let request = NovelPageRequest(
            threadID: context.threadID,
            view: view,
            authorID: currentAuthorID ?? context.authorID
        )
        let pageLoad = forceRefresh
            ? try await repository.loadPageIgnoringCacheResult(request)
            : try await repository.loadPageResult(request)
        let document = pageLoad.projection
        let preservedResumePoint = preferredResumePoint ?? captureNovelReadingPosition()
        let nextAuthorID = document.resolvedAuthorID ?? currentAuthorID ?? context.authorID
        let transaction = try prepareRuntimeTransaction(
            document: document,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation
        )
        let candidateSession = try NovelReadingSession(
            validating: document,
            layoutResult: transaction.result,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            resumePoint: preservedResumePoint,
            currentAuthorID: nextAuthorID,
            usesPagedSpread: usesPagedSpread(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            ),
            pageTurnDirection: settings.pageTurnDirection
        )
        let documentCacheContext = cacheContext(for: document)
        let cachedViews = await repository.cachedViews(
            for: context.threadID,
            authorID: documentCacheContext.authorID
        )
        let preparedTransaction = try makePreparedTransaction(
            runtime: transaction,
            session: candidateSession,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            currentDocument: document,
            prefetchedDocument: nil,
            currentLoadSource: pageLoad.source,
            prefetchedLoadSource: nil,
            currentAuthorID: candidateSession.snapshot.currentAuthorID ?? nextAuthorID,
            cachedViews: cachedViews,
        )
        guard let nextState = commit(preparedTransaction) else {
            throw NovelTextLayoutFailure.textKitIndexing
        }
        return nextState
    }

    private nonisolated(nonsending) func updateStateFromSession(refreshCachedViews: Bool) async throws -> NovelReadingWorkflowState {
        guard let snapshot = session?.snapshot,
              currentDocument != nil else {
            preconditionFailure("Novel reading workflow has no active session")
        }
        currentAuthorID = snapshot.currentAuthorID ?? currentAuthorID
        currentDocumentSurfaceCount = session?.surfaceCount(in: snapshot.currentView) ?? 0
        let cachedViews = if refreshCachedViews {
            await repository.cachedViews(
                for: context.threadID,
                authorID: cacheContext(forView: snapshot.currentView).authorID
            )
        } else {
            state?.cachedViews ?? []
        }
        guard let nextState = try updateStateFromSession(cachedViews: cachedViews) else {
            preconditionFailure("Novel reading workflow has no active session")
        }
        return nextState
    }

    private func updateStateFromSession(cachedViews: Set<Int>) throws -> NovelReadingWorkflowState? {
        guard let snapshot = session?.snapshot else {
            return nil
        }
        currentAuthorID = snapshot.currentAuthorID ?? currentAuthorID
        currentDocumentSurfaceCount = session?.surfaceCount(in: snapshot.currentView) ?? 0
        let generation = viewportRuntime.currentGeneration
        let previousPresentation = state?.presentation
        let revision = previousPresentation?.generation == generation
            ? (previousPresentation?.revision ?? 0) + 1
            : 0
        let nextState = NovelReadingWorkflowState(
            snapshot: snapshot,
            presentation: makePresentation(
                snapshot: snapshot,
                layoutResult: viewportRuntime.currentResult,
                generation: generation,
                revision: revision,
                settings: settings,
                usesTwoPageSpread: usesPagedSpread(
                    settings: settings,
                    layout: layout,
                    usesPadPresentation: usesPadPresentation
                ),
                pageLoadSource: currentLoadSource
            ),
            cachedViews: cachedViews
        )
        state = nextState
        lastPublishedSnapshot = nextState.snapshot
        return nextState
    }

    private func makePresentation(
        snapshot: NovelReadingSnapshot,
        layoutResult: NovelTextLayoutResult?,
        generation: UInt64,
        revision: UInt64,
        settings: NovelReaderAppearanceSettings,
        usesTwoPageSpread: Bool,
        pageLoadSource: NovelReaderProjectionLoadSource
    ) -> NovelReaderPresentation {
        let readableSize = layoutResult?.viewportContext.identity.layout.readableFrame.size ?? layout.readableFrame.size
        let indexSurfaces = (layoutResult?.viewportIndex.surfaces ?? []).sorted { lhs, rhs in
            lhs.surfaceOrdinal < rhs.surfaceOrdinal
        }
        let surfaces = indexSurfaces.enumerated().map { index, surface in
            let presentationHeight = layoutResult?.layoutMetrics.surfaceHeight(for: surface.surfaceOrdinal) ?? readableSize.height
            let nextSurface = indexSurfaces.indices.contains(index + 1) ? indexSurfaces[index + 1] : nil
            let spacingAfter: CGFloat = {
                guard let nextSurface else { return 0 }
                return surface.externalBlocks.isEmpty && nextSurface.externalBlocks.isEmpty ? 0 : 14
            }()
            return NovelReaderSurface(
                identity: NovelReaderSurfaceIdentity(
                    generation: generation,
                    ordinal: surface.surfaceOrdinal
                ),
                presentationIndex: index,
                kind: surface.externalBlocks.isEmpty ? .text : .externalBlock,
                documentView: surface.documentView,
                chapterTitle: surface.chapterTitle,
                presentationSize: CGSize(width: readableSize.width, height: presentationHeight),
                presentationSpacingAfter: spacingAfter,
                externalBlocks: surface.externalBlocks.map { externalBlock in
                    NovelReaderExternalBlock(
                        url: externalBlock.url,
                        frame: externalBlock.frozenFrame.map {
                            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                        },
                        chapterIdentity: externalBlock.chapterIdentity,
                        imageSegmentIdentity: externalBlock.imageSegmentIdentity,
                        chapterOrdinal: externalBlock.chapterOrdinal
                    )
                },
                chapterCommentTarget: surface.chapterCommentTarget,
                resolvedAuthorID: snapshot.currentAuthorID
            )
        }
        let surfaceIdentityByOrdinal = Dictionary(
            uniqueKeysWithValues: surfaces.map { ($0.identity.ordinal, $0.identity) }
        )
        let surfaceIndexByOrdinal = Dictionary(
            uniqueKeysWithValues: surfaces.map { ($0.identity.ordinal, $0.presentationIndex) }
        )
        let spreads = makeSpreads(from: indexSurfaces).compactMap { spread -> NovelReaderPresentationSpread? in
            guard let leftIdentity = surfaceIdentityByOrdinal[spread.leftSurfaceIndex] else {
                return nil
            }
            return NovelReaderPresentationSpread(
                index: spread.index,
                leftSurfaceIndex: surfaceIndexByOrdinal[spread.leftSurfaceIndex] ?? spread.index,
                leftSurfaceIdentity: leftIdentity,
                rightSurfaceIndex: spread.rightSurfaceIndex.flatMap { surfaceIndexByOrdinal[$0] },
                rightSurfaceIdentity: spread.rightSurfaceIndex.flatMap { surfaceIdentityByOrdinal[$0] },
                chapterTitle: spread.chapterTitle
            )
        }
        let selectedSurfaceIndex = surfaceIndexByOrdinal[snapshot.selectedSurfaceOrdinal]
        let readingState = NovelReaderReadingState(
            currentView: snapshot.currentView,
            maxView: snapshot.maxView,
            currentChapterTitle: snapshot.currentChapterTitle,
            authorID: snapshot.currentAuthorID,
            currentSurfaceIntraProgress: snapshot.currentSurfaceIntraProgress
        )
        let progressProjection = NovelReaderProgressProjection(
            readingMode: settings.readingMode,
            usesTwoPageSpread: usesTwoPageSpread,
            pageTurnDirection: settings.pageTurnDirection,
            surfaces: surfaces,
            selectedSurfaceIndex: selectedSurfaceIndex ?? 0,
            spreads: spreads,
            readingState: readingState
        )
        return NovelReaderPresentation(
            generation: generation,
            revision: revision,
            surfaces: surfaces,
            selectedSurfaceIdentity: surfaceIdentityByOrdinal[snapshot.selectedSurfaceOrdinal],
            spreads: spreads,
            chapters: layoutResult?.viewportIndex.novelReaderChapters ?? [],
            committedSettings: settings,
            readingState: readingState,
            pageLoadSource: pageLoadSource,
            retainedChapterCount: snapshot.retainedChapterCount,
            filteredChapterCandidateCount: snapshot.filteredChapterCandidateCount,
            selectedSurfaceIndex: selectedSurfaceIndex,
            progressProjection: progressProjection,
            usesTwoPageSpread: usesTwoPageSpread
        )
    }

    private func makeSpreads(from surfaces: [NovelTextViewportIndexSurface]) -> [NovelReadingSpread] {
        guard !surfaces.isEmpty else { return [] }

        var spreads: [NovelReadingSpread] = []
        var surfaceCursor = 0

        while surfaceCursor < surfaces.count {
            let leftSurface = surfaces[surfaceCursor]
            let candidateRightIndex = surfaceCursor + 1
            let rightSurfaceIndex: Int? = if surfaces.indices.contains(candidateRightIndex),
                                          surfaces[candidateRightIndex].documentView == leftSurface.documentView {
                candidateRightIndex
            } else {
                nil
            }

            spreads.append(
                NovelReadingSpread(
                    index: spreads.count,
                    leftSurfaceIndex: leftSurface.surfaceOrdinal,
                    rightSurfaceIndex: rightSurfaceIndex,
                    chapterTitle: leftSurface.chapterTitle
                )
            )
            surfaceCursor += rightSurfaceIndex == nil ? 1 : 2
        }

        return spreads
    }

    private func prepareRuntimeTransaction(
        document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        usesPadPresentation: Bool
    ) throws -> NovelTextViewportRuntimeTransaction {
        let paginationLayout = layout.novelTextBoxLayout(
            settings: settings,
            usesPadPresentation: usesPadPresentation
        )
        return try viewportRuntime.prepareTransaction(
            preparedInput: try NovelTextLayout.prepareInput(
                document: document,
                settings: settings,
                layout: paginationLayout
            )
        )
    }

    private func usesPagedSpread(
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        usesPadPresentation: Bool
    ) -> Bool {
        settings.readingMode == .paged &&
            settings.showsTwoPagesInLandscapeOnPad &&
            usesPadPresentation &&
            layout.width > layout.height
    }
}

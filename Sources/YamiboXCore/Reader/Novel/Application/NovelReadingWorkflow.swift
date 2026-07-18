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
    let currentProjection: NovelReaderProjection
    let prefetchedProjection: NovelReaderProjection?
    let currentLoadSource: NovelReaderProjectionLoadSource
    let prefetchedLoadSource: NovelReaderProjectionLoadSource?
    let currentAuthorID: String?
    let currentProjectionSurfaceCount: Int
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
    private var currentProjection: NovelReaderProjection?
    private var prefetchedProjection: NovelReaderProjection?
    private var currentLoadSource: NovelReaderProjectionLoadSource = .online
    private var prefetchedLoadSource: NovelReaderProjectionLoadSource?
    private var currentAuthorID: String?
    private var currentProjectionSurfaceCount = 0
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
        if let currentProjection, currentProjection.view == view {
            return cacheContext(for: currentProjection)
        }

        if let prefetchedProjection, prefetchedProjection.view == view {
            return cacheContext(for: prefetchedProjection)
        }

        let authorID = currentAuthorID ?? context.authorID
        return NovelReadingCacheContext(authorID: authorID)
    }

    public func canPromotePrefetchedDocument(forView view: Int) -> Bool {
        prefetchedProjection?.view == max(1, view)
    }

    package nonisolated(nonsending) func previewChapterDirectory(view: Int) async throws -> [NovelChapterDirectoryEntry] {
        let request = NovelPageRequest(
            threadID: context.threadID,
            view: view,
            authorID: cacheContext(forView: view).authorID
        )
        let projection = try await repository.loadPage(request)
        return NovelChapterDirectoryExtractor.entries(from: projection, settings: settings)
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
            presentation: NovelReaderPresentationBuilder.makePresentation(
                snapshot: session.snapshot,
                layoutResult: viewportRuntime.currentResult,
                generation: viewportRuntime.currentGeneration,
                revision: revision,
                settings: settings,
                fallbackLayout: layout,
                usesTwoPageSpread: NovelReaderPresentationBuilder.usesPagedSpread(
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
        let projection = currentProjection
        let task = Task.detached(priority: .userInitiated) {
            () async throws -> (NovelReadingWorkflowRuntimeUpdate, NovelTextLayoutPreparedInput)? in
            let preparedUpdate = try await preparation(update)
            try Task.checkCancellation()
            guard let projection else { return nil }
            let paginationLayout = preparedUpdate.layout.novelTextBoxLayout(
                settings: preparedUpdate.settings,
                usesPadPresentation: preparedUpdate.usesPadPresentation
            )
            let semanticInput = try NovelTextLayout.prepareInput(
                document: projection,
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
              currentProjection == semanticInput.document else {
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
            usesPagedSpread: NovelReaderPresentationBuilder.usesPagedSpread(
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
        guard let currentProjection else { return nil }
        // A runtime update re-presents the same document with new appearance
        // inputs, so the load source and cached-views set are carried over
        // from the current fields by omission. The prefetch pair must still be
        // passed explicitly (its parameters have no carry-over default because
        // nil is a meaningful "drop the prefetch" value there).
        let preparedTransaction = try makePreparedTransaction(
            runtime: transaction,
            session: candidateSession,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            currentProjection: currentProjection,
            prefetchedProjection: prefetchedProjection,
            prefetchedLoadSource: prefetchedLoadSource,
            currentAuthorID: candidateSession.snapshot.currentAuthorID ?? currentAuthorID
        )
        return commit(preparedTransaction)
    }

    /// Builds the pre-commit bundle that `commit(_:)` later writes to the
    /// workflow's fields in a single step once the runtime transaction lands.
    /// Parameters fall into two groups:
    ///
    /// - `nil`-defaulted parameters mean "this transaction leaves that
    ///   dimension unchanged": omitting one resolves to the current field,
    ///   which is exactly the value the omitting call sites used to pass
    ///   explicitly. (Field mirroring is why these were parameters at all.)
    /// - Required parameters are the dimensions at least one call site
    ///   replaces with a pre-commit "next" value that must not be read from
    ///   `self` (the freshly loaded/promoted document, its load source, …).
    ///   `prefetchedProjection`/`prefetchedLoadSource`/`currentAuthorID` stay
    ///   required even though the runtime-update path passes the current
    ///   values, because `nil` is itself a meaningful next value for them
    ///   ("drop the prefetch" / "no author"), so a nil-means-carry-over
    ///   default would be ambiguous.
    private func makePreparedTransaction(
        runtime: NovelTextViewportRuntimeTransaction,
        session: NovelReadingSession,
        settings: NovelReaderAppearanceSettings? = nil,
        layout: NovelReaderLayout? = nil,
        usesPadPresentation: Bool? = nil,
        currentProjection: NovelReaderProjection,
        prefetchedProjection: NovelReaderProjection?,
        currentLoadSource: NovelReaderProjectionLoadSource? = nil,
        prefetchedLoadSource: NovelReaderProjectionLoadSource?,
        currentAuthorID: String?,
        cachedViews: Set<Int>? = nil
    ) throws -> NovelReadingPreparedTransaction {
        let settings = settings ?? self.settings
        let layout = layout ?? self.layout
        let usesPadPresentation = usesPadPresentation ?? self.usesPadPresentation
        let currentLoadSource = currentLoadSource ?? self.currentLoadSource
        let snapshot = session.snapshot
        try viewportRuntime.prepareInitialViewport(
            for: runtime,
            around: snapshot.selectedSurfaceOrdinal
        )
        let state = NovelReadingWorkflowState(
            snapshot: snapshot,
            presentation: NovelReaderPresentationBuilder.makePresentation(
                snapshot: snapshot,
                layoutResult: runtime.result,
                generation: runtime.generation,
                revision: 0,
                settings: settings,
                // Deliberately the committed field, not the transaction's
                // (possibly new) layout: this preserves the exact binding from
                // when makePresentation was an instance method reading
                // `self.layout`. It only matters as the readable-size fallback
                // when `layoutResult` is nil, which a runtime transaction's
                // non-optional `result` never is.
                fallbackLayout: self.layout,
                usesTwoPageSpread: NovelReaderPresentationBuilder.usesPagedSpread(
                    settings: settings,
                    layout: layout,
                    usesPadPresentation: usesPadPresentation
                ),
                pageLoadSource: currentLoadSource
            ),
            cachedViews: cachedViews ?? self.state?.cachedViews ?? []
        )
        return NovelReadingPreparedTransaction(
            runtime: runtime,
            session: session,
            state: state,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            currentProjection: currentProjection,
            prefetchedProjection: prefetchedProjection,
            currentLoadSource: currentLoadSource,
            prefetchedLoadSource: prefetchedLoadSource,
            currentAuthorID: currentAuthorID,
            currentProjectionSurfaceCount: session.surfaceCount(in: snapshot.currentView)
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
        currentProjection = transaction.currentProjection
        prefetchedProjection = transaction.prefetchedProjection
        currentLoadSource = transaction.currentLoadSource
        prefetchedLoadSource = transaction.prefetchedLoadSource
        currentAuthorID = transaction.currentAuthorID
        currentProjectionSurfaceCount = transaction.currentProjectionSurfaceCount
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
        return updateStateFromSession(cachedViews: state?.cachedViews ?? [])
    }

    public func restoreResumePointInCurrentDocument(
        _ resumePoint: NovelResumePoint
    ) -> NovelReadingWorkflowState? {
        guard let state,
              state.snapshot.currentView == resumePoint.view,
              session?.restoreResumePoint(resumePoint) == true else {
            return nil
        }
        return updateStateFromSession(cachedViews: state.cachedViews)
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
        return updateStateFromSession(cachedViews: state?.cachedViews ?? [])
    }

    @discardableResult
    package func updateVerticalViewportPosition(
        sample: NovelTextViewportSample
    ) -> NovelReadingWorkflowState? {
        let previousSnapshot = session?.snapshot
        session?.updateVerticalViewportPosition(sample: sample)
        guard shouldRebuildPresentation(afterSampleUpdateFrom: previousSnapshot) else { return nil }
        return updateStateFromSession(cachedViews: state?.cachedViews ?? [])
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
        return updateStateFromSession(cachedViews: state?.cachedViews ?? [])
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
           prefetchedProjection?.view == view {
            request = .promotePrefetched(
                preferredSurfaceOrdinal: preferredSurfaceOrdinal,
                resumePoint: resumePoint
            )
        }
        guard let state = updateStateFromSession(cachedViews: state?.cachedViews ?? []) else { return nil }
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
        currentProjection = nil
        prefetchedProjection = nil
        currentLoadSource = .online
        prefetchedLoadSource = nil
        currentAuthorID = nil
        currentProjectionSurfaceCount = 0
        prefetchInFlightView = nil
        prefetchCooldown = nil
        state = nil
        lastPublishedSnapshot = nil
    }

    private func cacheContext(for projection: NovelReaderProjection) -> NovelReadingCacheContext {
        let authorID = projection.resolvedAuthorID ?? currentAuthorID ?? context.authorID
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
        guard let currentProjection else { return nil }
        guard surfaceIdentity.generation == viewportRuntime.currentGeneration,
              viewportRuntime.currentResult?.viewportIndex.surfaces.contains(where: {
                  $0.surfaceOrdinal == surfaceIdentity.ordinal
              }) == true else {
            return nil
        }
        guard currentProjection.view < currentProjection.maxView else { return nil }
        let thresholdIndex = max(currentProjectionSurfaceCount - 2, 0)
        guard surfaceIdentity.ordinal >= thresholdIndex else { return nil }
        if let prefetchedProjection, prefetchedProjection.view == currentProjection.view + 1 {
            return nil
        }

        let targetView = currentProjection.view + 1
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
            authorID: currentAuthorID ?? currentProjection.resolvedAuthorID ?? context.authorID
        )
        guard let nextLoad = try? await repository.loadPageResult(nextRequest) else {
            prefetchCooldown = (view: targetView, until: now().addingTimeInterval(Self.prefetchFailureCooldownInterval))
            return nil
        }
        prefetchCooldown = nil

        let nextProjection = nextLoad.projection
        prefetchedProjection = nextProjection
        prefetchedLoadSource = nextLoad.source
        if nextProjection.maxView > (session?.snapshot.maxView ?? 0) {
            session?.updateMaximumView(nextProjection.maxView)
        }
        return await updateStateFromSession(refreshCachedViews: false)
    }

    @discardableResult
    public nonisolated(nonsending) func promotePrefetchedDocument(
        preferredSurfaceOrdinal: Int,
        resumePoint: NovelResumePoint?
    ) async throws -> NovelReadingWorkflowState? {
        supersedePendingRuntimeUpdate()
        guard let nextProjection = prefetchedProjection,
              var candidateSession = session else {
            return nil
        }
        let effectiveResumePoint = resumePoint?.view == nextProjection.view ? resumePoint : nil
        let transaction = try prepareRuntimeTransaction(
            projection: nextProjection,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation
        )
        try candidateSession.promotePrefetchedDocument(
            document: nextProjection,
            layoutResult: transaction.result,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            resumePoint: effectiveResumePoint,
            usesPagedSpread: NovelReaderPresentationBuilder.usesPagedSpread(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            )
        )
        let nextAuthorID = nextProjection.resolvedAuthorID ?? currentAuthorID ?? context.authorID
        // Promotion replaces the document dimensions (the prefetched page
        // becomes current, the prefetch slot empties); appearance and the
        // cached-views set carry over from the current fields by omission.
        let preparedTransaction = try makePreparedTransaction(
            runtime: transaction,
            session: candidateSession,
            currentProjection: nextProjection,
            prefetchedProjection: nil,
            currentLoadSource: prefetchedLoadSource ?? .online,
            prefetchedLoadSource: nil,
            currentAuthorID: candidateSession.snapshot.currentAuthorID ?? nextAuthorID
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
        let projection = pageLoad.projection
        let preservedResumePoint = preferredResumePoint ?? captureNovelReadingPosition()
        let nextAuthorID = projection.resolvedAuthorID ?? currentAuthorID ?? context.authorID
        let transaction = try prepareRuntimeTransaction(
            projection: projection,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation
        )
        let candidateSession = try NovelReadingSession(
            validating: projection,
            layoutResult: transaction.result,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            resumePoint: preservedResumePoint,
            currentAuthorID: nextAuthorID,
            usesPagedSpread: NovelReaderPresentationBuilder.usesPagedSpread(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            ),
            pageTurnDirection: settings.pageTurnDirection
        )
        let projectionCacheContext = cacheContext(for: projection)
        let cachedViews = await repository.cachedViews(
            for: context.threadID,
            authorID: projectionCacheContext.authorID
        )
        // A fresh load replaces every document dimension plus the cached-views
        // set (just refetched above); appearance carries over from the current
        // fields by omission.
        let preparedTransaction = try makePreparedTransaction(
            runtime: transaction,
            session: candidateSession,
            currentProjection: projection,
            prefetchedProjection: nil,
            currentLoadSource: pageLoad.source,
            prefetchedLoadSource: nil,
            currentAuthorID: candidateSession.snapshot.currentAuthorID ?? nextAuthorID,
            cachedViews: cachedViews
        )
        guard let nextState = commit(preparedTransaction) else {
            throw NovelTextLayoutFailure.textKitIndexing
        }
        return nextState
    }

    /// Returns nil when the session was torn down while this call was
    /// suspended (e.g. the reader closed mid-prefetch); callers treat that as
    /// "no state change", never as a programmer error — `close()` racing a
    /// suspended prefetch is a legitimate user action, not a broken invariant.
    private nonisolated(nonsending) func updateStateFromSession(refreshCachedViews: Bool) async -> NovelReadingWorkflowState? {
        guard let snapshot = session?.snapshot,
              currentProjection != nil else {
            return nil
        }
        currentAuthorID = snapshot.currentAuthorID ?? currentAuthorID
        currentProjectionSurfaceCount = session?.surfaceCount(in: snapshot.currentView) ?? 0
        let cachedViews = if refreshCachedViews {
            await repository.cachedViews(
                for: context.threadID,
                authorID: cacheContext(forView: snapshot.currentView).authorID
            )
        } else {
            state?.cachedViews ?? []
        }
        // The cached-views load above is a suspension point; the sync variant
        // re-checks the session before touching state.
        return updateStateFromSession(cachedViews: cachedViews)
    }

    private func updateStateFromSession(cachedViews: Set<Int>) -> NovelReadingWorkflowState? {
        guard let snapshot = session?.snapshot else {
            return nil
        }
        currentAuthorID = snapshot.currentAuthorID ?? currentAuthorID
        currentProjectionSurfaceCount = session?.surfaceCount(in: snapshot.currentView) ?? 0
        let generation = viewportRuntime.currentGeneration
        let previousPresentation = state?.presentation
        let revision = previousPresentation?.generation == generation
            ? (previousPresentation?.revision ?? 0) + 1
            : 0
        let nextState = NovelReadingWorkflowState(
            snapshot: snapshot,
            presentation: NovelReaderPresentationBuilder.makePresentation(
                snapshot: snapshot,
                layoutResult: viewportRuntime.currentResult,
                generation: generation,
                revision: revision,
                settings: settings,
                fallbackLayout: layout,
                usesTwoPageSpread: NovelReaderPresentationBuilder.usesPagedSpread(
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

    private func prepareRuntimeTransaction(
        projection: NovelReaderProjection,
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
                document: projection,
                settings: settings,
                layout: paginationLayout
            )
        )
    }
}

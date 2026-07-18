import Observation
import SwiftUI
import YamiboXCore

@MainActor
@Observable
public final class NovelReaderViewModel {
    // The properties below were `@Published` before the `@Observable`
    // migration; they stay tracked so the views keep re-rendering on the
    // exact same writes as before.
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var novelReaderPresentation: NovelReaderPresentation?
    public private(set) var chapterComments = ReaderChapterCommentsSnapshot()
    public var applePencilPageTurnSettings = ApplePencilPageTurnSettings()
    private(set) var isNavigatingNovelReaderProjection = false
    private(set) var isApplyingAppearanceSettings = false
    private var bootstrapSettings = NovelReaderAppearanceSettings()
    // Every `var` from here down was a plain (non-`@Published`) stored
    // property under `ObservableObject`, so writes to it never invalidated
    // views on their own; `@ObservationIgnored` keeps that notification
    // surface strictly identical after the `@Observable` migration.
    //
    // `chromeProgressSnapshot` specifically: the chrome always repainted
    // through the `novelReaderPresentation` write that accompanies every
    // snapshot refresh (`syncFromWorkflowState` / `close()` co-write both),
    // so leaving it untracked loses nothing.
    @ObservationIgnored private(set) var chromeProgressSnapshot = NovelReaderChromeProgressSnapshot.empty

    public let context: NovelLaunchContext

    private let dependencies: NovelReaderDependencies
    @ObservationIgnored private var repository: NovelReaderRepository?
    @ObservationIgnored private var readingWorkflow: NovelReadingWorkflow?
    @ObservationIgnored private var appearanceSettingsApplicationSequence: UInt64 = 0
    @ObservationIgnored private var layout: NovelReaderLayout = .zero
    @ObservationIgnored private var latestRequestedLayout: NovelReaderLayout = .zero
    @ObservationIgnored private var layoutRequestSequence: UInt64 = 0
    @ObservationIgnored private var usesPadPresentation = false
    @ObservationIgnored private var currentStableResumePoint: NovelResumePoint?
    private let runtimeAdapter: (any NovelTextLayoutRuntimeAdapter)?
    private let onReaderResumeRouteChange: ReaderResumeRouteChangeHandler
    // The three package hooks are test seams (assigned, never rendered),
    // so they stay unobserved like every other non-published property.
    @ObservationIgnored package var runtimeUpdatePreparation: NovelReadingWorkflowRuntimeUpdatePreparation = { $0 }
    @ObservationIgnored package var novelReaderPageDocumentNavigationOverlayPreparation: (@MainActor () async -> Void) = {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    @ObservationIgnored package var novelReaderPageDocumentNavigationStateDidChange: (@MainActor (Bool) -> Void)?
    private let progressSync: ProgressSyncModule
    @ObservationIgnored private var hasRecordedBrowsingHistoryVisit = false
    // The chapter-comments module is built by the composition root
    // (`NovelReaderDependencies`); the view model only sinks its snapshots.
    // It is driven exclusively from this main-actor view model, so its
    // caller-isolated onChange provably fires on the main actor.
    // (`@ObservationIgnored` on the lazy module/coordinator references:
    // never published, and `lazy` storage cannot be rewritten into the
    // macro's tracked accessors anyway.)
    @ObservationIgnored private lazy var chapterCommentsModule = dependencies.makeChapterCommentsModule { [weak self] snapshot in
        MainActor.assumeIsolated {
            self?.chapterComments = snapshot
        }
    }

    /// Offline-cache coordinator: owns cache/queue state and batch
    /// operations. Cache views bind it directly.
    @ObservationIgnored private(set) lazy var cache = NovelReaderCacheCoordinator(
        operationModule: dependencies.makeCacheOperationModule(),
        repository: dependencies.makeCacheOperationRepository(),
        offlineCacheStore: dependencies.offlineCacheStore,
        accountDependencies: dependencies.account,
        reading: NovelReaderCacheCoordinator.Reading(
            maxView: { [weak self] in self?.maxView ?? 0 },
            displayedView: { [weak self] in self?.visibleView ?? 1 },
            operationContext: { [weak self] in
                self?.currentCacheOperationContext() ?? NovelReaderCacheOperationContext(
                    ownerTitle: "",
                    threadID: "",
                    authorID: nil
                )
            },
            onError: { [weak self] message in
                self?.errorMessage = message
            }
        )
    )

    /// Wayfinding coordinator: owns chapter-catalog browsing and the
    /// nonlinear navigation history. Catalog and chrome views bind it
    /// directly.
    @ObservationIgnored private(set) lazy var navigation = NovelReaderNavigationCoordinator(
        reading: NovelReaderNavigationCoordinator.Reading(
            maxView: { [weak self] in self?.maxView ?? 1 },
            visibleView: { [weak self] in self?.visibleView ?? 1 },
            chapters: { [weak self] in self?.chapters ?? [] },
            surfaceCount: { [weak self] in self?.surfaceCount ?? 0 },
            currentChapterIndex: { [weak self] in self?.currentChapterIndex },
            stableResumePoint: { [weak self] in self?.currentStableResumePoint },
            currentPageKey: { [weak self] in self?.currentLinearReadingPageKey },
            previewChapterCatalog: { [weak self] view in
                guard let self, let workflow = await self.ensureReadingWorkflow() else {
                    throw ReaderChapterCommentsUnavailableError()
                }
                return try await workflow.previewChapterDirectory(view: view)
            },
            jumpToChapter: { [weak self] chapter in
                self?.jumpToChapter(chapter)
            },
            openChapterAnchor: { [weak self] anchor in
                guard let self else { return false }
                return await self.openChapterAnchor(anchor)
            },
            loadWebView: { [weak self] view in
                await self?.load(
                    view: view,
                    preferredSurfaceOrdinal: 0,
                    preferredResumePoint: nil,
                    forceRefresh: false,
                    showsNovelReaderProjectionNavigationOverlay: true
                ) ?? false
            },
            restoreResumePoint: { [weak self] resumePoint in
                await self?.restoreResumePoint(resumePoint) ?? false
            },
            scheduleProgressSync: { [weak self] in
                self?.scheduleProgressSync()
            }
        )
    )

    public convenience init(
        context: NovelLaunchContext,
        dependencies: NovelReaderDependencies,
        initialSettings: NovelReaderAppearanceSettings? = nil,
        onReaderResumeRouteChange: @escaping ReaderResumeRouteChangeHandler = { _ in }
    ) {
        self.init(
            context: context,
            dependencies: dependencies,
            initialSettings: initialSettings,
            runtimeAdapter: nil,
            onReaderResumeRouteChange: onReaderResumeRouteChange
        )
    }

    package convenience init(
        context: NovelLaunchContext,
        dependencies: NovelReaderDependencies,
        initialSettings: NovelReaderAppearanceSettings? = nil,
        runtimeAdapter: any NovelTextLayoutRuntimeAdapter,
        onReaderResumeRouteChange: @escaping ReaderResumeRouteChangeHandler = { _ in }
    ) {
        self.init(
            context: context,
            dependencies: dependencies,
            initialSettings: initialSettings,
            runtimeAdapter: runtimeAdapter as (any NovelTextLayoutRuntimeAdapter)?,
            onReaderResumeRouteChange: onReaderResumeRouteChange
        )
    }

    private init(
        context: NovelLaunchContext,
        dependencies: NovelReaderDependencies,
        initialSettings: NovelReaderAppearanceSettings?,
        runtimeAdapter: (any NovelTextLayoutRuntimeAdapter)?,
        onReaderResumeRouteChange: @escaping ReaderResumeRouteChangeHandler
    ) {
        self.context = context
        self.dependencies = dependencies
        self.onReaderResumeRouteChange = onReaderResumeRouteChange
        self.runtimeAdapter = runtimeAdapter
        progressSync = ProgressSyncModule(
            adapter: FavoriteLibraryProgressSyncAdapter(
                readingProgressStore: dependencies.readingProgressStore,
                browsingHistoryStore: dependencies.browsingHistoryStore
            )
        )
        if let initialSettings {
            bootstrapSettings = initialSettings
        }
    }

    public var title: String {
        context.threadTitle.isEmpty ? L10n.string("reader.title") : context.threadTitle
    }

    /// Cover menu entries for images opened from this novel's thread. The
    /// novel reader never supplies a manga directory store, and a novel
    /// board is never a smart-enabled manga board, so the smart gate is a
    /// constant `false`.
    var imageBrowserCoverActionsProvider: ImageBrowserCoverActionsProvider {
        ImageBrowserThreadCoverActions.provider(
            tid: context.threadID,
            contentCoverStore: { [dependencies] in dependencies.contentCoverStore },
            isSmartComicModeEnabled: { false }
        )
    }

    public var settings: NovelReaderAppearanceSettings {
        novelReaderPresentation?.committedSettings ?? bootstrapSettings
    }

    var isTwoPageSpreadActive: Bool {
        settings.readingMode == .paged &&
            settings.showsTwoPagesInLandscapeOnPad &&
            usesPadPresentation &&
            layout.width > layout.height
    }

    var novelReaderSurfaces: [NovelReaderSurface] {
        novelReaderPresentation?.surfaces ?? []
    }

    var chapters: [NovelReaderChapter] {
        novelReaderPresentation?.chapters ?? []
    }

    var currentView: Int {
        novelReaderPresentation?.readingState.currentView ?? 1
    }

    var maxView: Int {
        novelReaderPresentation?.readingState.maxView ?? 1
    }

    var currentChapterTitle: String? {
        novelReaderPresentation?.readingState.currentChapterTitle
    }

    private var currentAuthorID: String? {
        novelReaderPresentation?.readingState.authorID
    }

    var retainedChapterCount: Int {
        novelReaderPresentation?.retainedChapterCount ?? 0
    }

    var filteredChapterCandidateCount: Int {
        novelReaderPresentation?.filteredChapterCandidateCount ?? 0
    }

    var selectedSurfaceIndex: Int {
        normalizedPagedSurfaceIndex(novelReaderPresentation?.selectedSurfaceIndex ?? 0)
    }

    var currentSurfaceIntraProgress: Double {
        novelReaderPresentation?.readingState.currentSurfaceIntraProgress ?? 0
    }

    package var presentationSpreads: [NovelReaderPresentationSpread] {
        novelReaderPresentation?.spreads ?? []
    }

    package var novelReaderDebugState: NovelReadingWorkflowDebugState? {
        readingWorkflow?.debugState
    }

    var progressText: String {
        chromeProgressSnapshot.progressText
    }

    func previewText(
        translationMode: ReaderTranslationMode,
        characterCount: Int,
        fallback: String
    ) -> String {
        let sourceText = readingWorkflow?.currentPreviewSourceText().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previewSource = sourceText.isEmpty ? fallback : sourceText
        let transformed = NovelTextTransformer.transform(previewSource, mode: translationMode)
        return String(transformed.prefix(max(characterCount, 0)))
    }

    var surfaceCount: Int {
        chromeProgressSnapshot.surfaceCount
    }

    var currentSurfaceNumber: Int {
        chromeProgressSnapshot.currentSurfaceNumber
    }

    var currentProgressFraction: Double {
        chromeProgressSnapshot.currentProgressFraction
    }

    var currentProgressPercent: Int {
        chromeProgressSnapshot.currentProgressPercent
    }

    var currentProgressPercentText: String {
        chromeProgressSnapshot.currentProgressPercentText
    }

    var progressChapterTicks: [NovelReaderProgressChapterTick] {
        chromeProgressSnapshot.progressChapterTicks
    }

    func progressSliderLabelText(
        isEditing: Bool,
        sliderValue: Double,
        targetSurfaceIndex: Int
    ) -> String {
        chromeProgressSnapshot.progressSliderLabelText(
            isEditing: isEditing,
            sliderValue: sliderValue,
            targetSurfaceIndex: targetSurfaceIndex
        )
    }

    public var currentChapterCommentTarget: ReaderChapterCommentTarget? {
        selectedSurface?.chapterCommentTarget
    }

    var currentWebViewText: String {
        L10n.string("reader.web_view_progress", displayedView, max(maxView, 1))
    }

    var directoryWebTitle: String {
        L10n.string("reader.web_view_chapters", currentWebViewText)
    }

    var pagedViewportSelectionIndex: Int {
        guard isTwoPageSpreadActive else { return selectedSurfaceIndex }
        return spreadIndex(forSurfaceIndex: selectedSurfaceIndex)
    }

    public func commitNovelTextPresentationEnvironment(isPad: Bool) async {
        guard usesPadPresentation != isPad else { return }
        let previousUsesPadPresentation = usesPadPresentation
        guard settings.readingMode == .paged,
              readingWorkflow?.state != nil else {
            usesPadPresentation = isPad
            return
        }
        do {
            guard let state = try await requestRuntimeUpdate(
                settings: settings,
                layout: layout,
                usesPadPresentation: isPad
            ) else { return }
            usesPadPresentation = isPad
            syncFromWorkflowState(state)
        } catch {
            usesPadPresentation = previousUsesPadPresentation
            errorMessage = error.localizedDescription
        }
    }

    func selectPagedViewportIndex(_ selectionIndex: Int) {
        let targetSurfaceIndex = isTwoPageSpreadActive
            ? progressSurfaceIndex(forSpreadIndex: selectionIndex)
            : selectionIndex
        selectSurface(targetSurfaceIndex)
    }

    func novelTextViewportDisplayReference(
        for surfaceIdentity: NovelReaderSurfaceIdentity
    ) -> NovelTextViewportDisplayReference? {
        readingWorkflow?.displayReference(for: surfaceIdentity)
    }

    func updateNovelTextViewportVisibleSurfaceIdentities(_ surfaceIdentities: [NovelReaderSurfaceIdentity]) {
        readingWorkflow?.updateVisibleSurfaceIdentities(surfaceIdentities)
    }

    func chapterTitle(forSurfaceIndex surfaceIndex: Int) -> String? {
        chromeProgressSnapshot.chapterTitle(forSurfaceIndex: surfaceIndex)
    }

    func progressChapterTickStartIndex(forSurfaceIndex surfaceIndex: Int) -> Int? {
        chromeProgressSnapshot.progressChapterTickStartIndex(forSurfaceIndex: surfaceIndex)
    }

    var verticalProgressScrubContext: ReaderProgressScrubContext {
        chromeProgressSnapshot.progressScrubContext
    }

    func targetSurfaceIndex(forProgressValue value: Double) -> Int {
        chromeProgressSnapshot.targetSurfaceIndex(forProgressValue: value)
    }

    var visibleView: Int {
        displayedView
    }

    var currentNovelResumePoint: NovelResumePoint? {
        readingWorkflow?.captureNovelReadingPosition()
    }

    public func handleMemoryPressure() {
        readingWorkflow?.handleMemoryPressure()
    }

    public func close() {
        appearanceSettingsApplicationSequence &+= 1
        layoutRequestSequence &+= 1
        latestRequestedLayout = layout
        isApplyingAppearanceSettings = false
        readingWorkflow?.close()
        readingWorkflow = nil
        navigation.resetHistory()
        currentStableResumePoint = nil
        chromeProgressSnapshot = .empty
        novelReaderPresentation = nil
    }

    var currentChapterIndex: Int? {
        chapters.lastIndex(where: { $0.startIndex <= selectedSurfaceIndex })
    }

    var hasPreviousChapter: Bool {
        guard let currentChapterIndex else { return false }
        return currentChapterIndex > 0
    }

    var hasNextChapter: Bool {
        guard let currentChapterIndex else { return false }
        return currentChapterIndex < chapters.count - 1
    }

    var sourceStatusText: String? {
        guard let pageLoadSource = novelReaderPresentation?.pageLoadSource,
              case let .offlineFallback(updatedAt) = pageLoadSource else {
            return nil
        }
        guard let updatedAt else {
            return L10n.string("reader.offline_stale_notice")
        }
        return L10n.string(
            "reader.offline_stale_notice_with_time",
            updatedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    var chapterSummaryText: String {
        L10n.string("reader.chapter_summary", retainedChapterCount, filteredChapterCandidateCount)
    }

    var inlineImageOfflineScope: YamiboImageOfflineScope? {
        YamiboImageOfflineScope(tid: context.threadID)
    }

    var forumURL: URL {
        YamiboRoute.threadByID(
            tid: context.threadID,
            page: displayedView,
            authorID: currentAuthorID ?? context.authorID,
            reverse: false
        ).url
    }

    var currentForumTargetURL: URL {
        guard let target = currentChapterCommentTarget else { return forumURL }
        return YamiboRoute.findPostURL(threadID: target.threadID, postID: target.ownerPostID) ?? forumURL
    }

    public func prepare(layout: NovelReaderLayout) async {
        self.layout = layout
        latestRequestedLayout = layout
        layoutRequestSequence &+= 1
        if repository == nil {
            repository = await dependencies.makeNovelReaderRepository()
            let appSettings = await dependencies.settingsStore.load()
            bootstrapSettings = appSettings.novelReader
            applePencilPageTurnSettings = appSettings.system.applePencilPageTurn
            if let repository {
                readingWorkflow = makeReadingWorkflow(repository: repository)
            }
        }
        if novelReaderSurfaces.isEmpty {
            await performInitialLoadIfNeeded()
        } else {
            do {
                if let state = try await requestRuntimeUpdate(
                    settings: settings,
                    layout: layout,
                    usesPadPresentation: usesPadPresentation
                ) {
                    syncFromWorkflowState(state)
                }
            } catch is CancellationError {
            } catch {
                YamiboLog.reader.warning("prepare(layout:) failed to refresh runtime state on relaunch; UI may show a stale layout: \(error)")
            }
            await cache.refresh()
        }
    }

    /// Runs the initial page load when `novelReaderSurfaces` has never been
    /// populated yet. Shared by `prepare(layout:)`'s first call and by
    /// `commitNovelTextLayout`'s recovery path below, so that a first layout
    /// pass too small to build a TextKit index (e.g. right after the reader
    /// is presented while another sheet is still dismissing, as with a My
    /// Likes jump-to-original) doesn't strand the reader on a permanent
    /// error once a valid layout follows.
    // MARK: - Loading

    private func performInitialLoadIfNeeded() async {
        guard novelReaderSurfaces.isEmpty, !isLoading else { return }
        if readingWorkflow?.state == nil {
            // `makeReadingWorkflow` bakes `layout` in at construction time
            // and nothing updates it while `state` is nil, so a workflow
            // that never got past its first `start()` would otherwise retry
            // with the same failing geometry. Rebuild it to pick up the
            // corrected `self.layout`.
            readingWorkflow = nil
        }
        let progress = await dependencies.readingProgressStore.load(threadID: context.threadID)
        let novelProgress = progress?.novel
        await startReadingWorkflow(
            resumePoint: context.initialResumePoint ?? novelProgress?.novelResumePoint,
            favoriteAuthorID: novelProgress?.authorID
        )
    }

    public func commitNovelTextLayout(_ layout: NovelReaderLayout) async {
        guard latestRequestedLayout != layout else { return }
        latestRequestedLayout = layout
        layoutRequestSequence &+= 1
        let requestSequence = layoutRequestSequence
        guard readingWorkflow?.state != nil else {
            self.layout = layout
            await performInitialLoadIfNeeded()
            return
        }
        do {
            guard let state = try await requestRuntimeUpdate(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            ) else {
                if layoutRequestSequence == requestSequence {
                    latestRequestedLayout = self.layout
                }
                return
            }
            guard layoutRequestSequence == requestSequence else { return }
            self.layout = layout
            syncFromWorkflowState(state)
        } catch is CancellationError {
            if layoutRequestSequence == requestSequence {
                latestRequestedLayout = self.layout
            }
        } catch {
            guard layoutRequestSequence == requestSequence else { return }
            latestRequestedLayout = self.layout
            errorMessage = error.localizedDescription
        }
    }

    public func loadCurrent(forceRefresh: Bool) async {
        let didLoad = await load(
            view: displayedView,
            preferredSurfaceOrdinal: displayedPageIndex,
            preferredResumePoint: readingWorkflow?.captureNovelReadingPosition(),
            forceRefresh: forceRefresh
        )
        if didLoad {
            navigation.resetHistory()
        }
    }

    public func loadAdjacent(delta: Int) async {
        let target = max(1, min(maxView, displayedView + delta))
        guard target != displayedView else { return }

        if delta > 0,
           readingWorkflow?.canPromotePrefetchedDocument(forView: target) == true {
            await promotePrefetchedDocument(
                startingAt: 0,
                preferredResumePoint: nil,
                showsNovelReaderProjectionNavigationOverlay: true
            )
            return
        }

        await load(
            view: target,
            preferredSurfaceOrdinal: 0,
            preferredResumePoint: nil,
            forceRefresh: false,
            showsNovelReaderProjectionNavigationOverlay: true
        )
    }

    public func commitNovelTextAppearance(
        _ newSettings: NovelReaderAppearanceSettings,
        applePencilPageTurnSettings requestedApplePencilPageTurnSettings: ApplePencilPageTurnSettings? = nil
    ) async {
        let newApplePencilPageTurnSettings = requestedApplePencilPageTurnSettings ?? applePencilPageTurnSettings
        let oldSettings = settings
        let oldApplePencilPageTurnSettings = applePencilPageTurnSettings
        let novelReaderSettingsChanged = oldSettings != newSettings
        let applePencilSettingsChanged = oldApplePencilPageTurnSettings != newApplePencilPageTurnSettings
        guard novelReaderSettingsChanged else {
            guard applePencilSettingsChanged else { return }
            applePencilPageTurnSettings = newApplePencilPageTurnSettings
            persistSettings(applePencilPageTurnSettings: newApplePencilPageTurnSettings)
            return
        }

        if oldSettings.isSurfaceOnlyAppearanceChange(to: newSettings) {
            applePencilPageTurnSettings = newApplePencilPageTurnSettings
            if let state = readingWorkflow?.commitSurfaceAppearance(newSettings) {
                syncFromWorkflowState(state)
            }
            bootstrapSettings = newSettings
            persistSettings(
                novelReaderSettings: newSettings,
                applePencilPageTurnSettings: applePencilSettingsChanged ? newApplePencilPageTurnSettings : nil
            )
            return
        }

        guard readingWorkflow?.state != nil else {
            bootstrapSettings = newSettings
            applePencilPageTurnSettings = newApplePencilPageTurnSettings
            persistSettings(
                novelReaderSettings: newSettings,
                applePencilPageTurnSettings: applePencilSettingsChanged ? newApplePencilPageTurnSettings : nil
            )
            return
        }

        let applicationSequence = beginApplyingAppearanceSettings()
        defer { finishApplyingAppearanceSettings(applicationSequence) }

        do {
            guard let state = try await requestRuntimeUpdate(
                settings: newSettings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            ) else { return }
            guard appearanceSettingsApplicationSequence == applicationSequence else { return }
            applePencilPageTurnSettings = newApplePencilPageTurnSettings
            syncFromWorkflowState(state)
            bootstrapSettings = newSettings
            persistSettings(
                novelReaderSettings: newSettings,
                applePencilPageTurnSettings: applePencilSettingsChanged ? newApplePencilPageTurnSettings : nil
            )
        } catch is CancellationError {
        } catch {
            guard appearanceSettingsApplicationSequence == applicationSequence else { return }
            applePencilPageTurnSettings = oldApplePencilPageTurnSettings
            errorMessage = error.localizedDescription
        }
    }

    public func applyApplePencilPageTurnSettings(_ newSettings: ApplePencilPageTurnSettings) {
        applePencilPageTurnSettings = newSettings
        persistSettings(applePencilPageTurnSettings: newSettings)
    }

    @discardableResult
    public func saveProgress() async -> NovelLaunchContext {
        await flushProgress()
    }

    public func selectSurface(_ surfaceIndex: Int) {
        selectSurface(surfaceIndex, recordsLinearReading: true)
    }

    private func selectSurface(_ surfaceIndex: Int, recordsLinearReading: Bool) {
        guard let presentation = novelReaderPresentation,
              presentation.surfaces.indices.contains(surfaceIndex) else {
            return
        }
        let oldSurfaceIndex = selectedSurfaceIndex
        if let state = readingWorkflow?.selectSurface(
            presentation.surfaces[surfaceIndex].identity,
            presentationRevision: presentation.revision
        ) {
            syncFromWorkflowState(state)
            if recordsLinearReading {
                navigation.recordLinearReading(direction: surfaceIndex >= oldSurfaceIndex ? .forward : .backward)
            }
        }
        scheduleProgressSync()

        Task {
            await prefetchIfNeeded(for: selectedSurfaceIndex)
        }

        promoteIfNeededAfterLocationUpdate()
    }

    package func updateVerticalViewportPosition(surfaceIndex: Int, intraSurfaceProgress: Double, force: Bool = false) {
        let normalizedProgress = min(max(intraSurfaceProgress, 0), 1)
        let progressUpdateThreshold = force ? 0.002 : 0.02
        guard surfaceIndex != selectedSurfaceIndex ||
            abs(normalizedProgress - currentSurfaceIntraProgress) >= progressUpdateThreshold else {
            return
        }
        guard let presentation = novelReaderPresentation,
              presentation.surfaces.indices.contains(surfaceIndex) else { return }
        guard let state = readingWorkflow?.updateVerticalViewportPosition(
            surfaceIdentity: presentation.surfaces[surfaceIndex].identity,
            intraSurfaceProgress: normalizedProgress,
            presentationRevision: presentation.revision
        ) else { return }
        let oldSurfaceIndex = selectedSurfaceIndex
        syncFromWorkflowState(state)
        if oldSurfaceIndex != selectedSurfaceIndex {
            navigation.recordLinearReading(direction: selectedSurfaceIndex > oldSurfaceIndex ? .forward : .backward)
        }
        scheduleProgressSync()

        Task {
            await prefetchIfNeeded(for: selectedSurfaceIndex)
        }

        promoteIfNeededAfterLocationUpdate()
    }

    package func updateVerticalViewportPosition(sample: NovelTextViewportSample) {
        let oldSurfaceIndex = selectedSurfaceIndex
        let oldProgress = currentSurfaceIntraProgress
        let oldResumePoint = currentNovelResumePoint
        guard let presentation = novelReaderPresentation,
              presentation.surfaces.contains(where: {
                  $0.identity == sample.surfaceIdentity
              }) else {
            return
        }
        if let state = readingWorkflow?.updateVerticalViewportPosition(
            sample: sample,
            presentationRevision: presentation.revision
        ) {
            syncFromWorkflowState(state)
            if oldSurfaceIndex != selectedSurfaceIndex {
                navigation.recordLinearReading(direction: selectedSurfaceIndex > oldSurfaceIndex ? .forward : .backward)
            }
            let newResumePoint = currentNovelResumePoint
            let didChangePosition = oldSurfaceIndex != selectedSurfaceIndex ||
                oldProgress != currentSurfaceIntraProgress ||
                oldResumePoint != newResumePoint
            guard didChangePosition else {
                return
            }
        } else {
            return
        }
        scheduleProgressSync()

        Task {
            await prefetchIfNeeded(for: selectedSurfaceIndex)
        }

        promoteIfNeededAfterLocationUpdate()
    }

    public func jumpToChapter(_ chapter: NovelReaderChapter) {
        jumpToSurface(chapter.startIndex)
    }

    package func jumpToSurface(_ surfaceIndex: Int) {
        let navigationSequence = navigation.beginNavigationRequest()
        let sourceResumePoint = currentStableResumePoint
        selectSurface(surfaceIndex, recordsLinearReading: false)
        if navigation.isCurrentNavigationRequest(navigationSequence) {
            navigation.recordSuccessfulNonlinearNavigation(from: sourceResumePoint, to: currentStableResumePoint)
        }
    }

    public func jumpRelativeSurface(_ delta: Int) async {
        guard let result = readingWorkflow?.jumpRelativeSurface(delta) else {
            scheduleProgressSync()
            Task {
                await prefetchIfNeeded(for: selectedSurfaceIndex)
            }
            return
        }

        let direction: ReaderNavigationLinearReadingDirection = delta >= 0 ? .forward : .backward
        syncFromWorkflowState(result.state)
        switch result.request {
        case nil:
            navigation.recordLinearReading(direction: direction)
            scheduleProgressSync()
            Task {
                await prefetchIfNeeded(for: selectedSurfaceIndex)
            }
        case let .loadView(view, preferredSurfaceOrdinal, resumePoint):
            let didLoad = await load(
                view: view,
                preferredSurfaceOrdinal: preferredSurfaceOrdinal,
                preferredResumePoint: resumePoint,
                forceRefresh: false,
                showsNovelReaderProjectionNavigationOverlay: true
            )
            if didLoad {
                navigation.recordLinearReading(direction: direction)
            }
        case let .promotePrefetched(preferredSurfaceOrdinal, resumePoint):
            let didPromote = await promotePrefetchedDocument(
                startingAt: preferredSurfaceOrdinal,
                preferredResumePoint: resumePoint,
                showsNovelReaderProjectionNavigationOverlay: true
            )
            if didPromote {
                navigation.recordLinearReading(direction: direction)
            }
        }
    }

    public func jumpToAdjacentChapter(_ delta: Int) {
        guard let currentChapterIndex else { return }
        let targetIndex = currentChapterIndex + delta
        guard chapters.indices.contains(targetIndex) else { return }
        jumpToSurface(chapters[targetIndex].startIndex)
    }

    public func jumpToWebView(_ view: Int, preferredSurfaceOrdinal: Int = 0) async {
        let navigationSequence = navigation.beginNavigationRequest()
        let sourceResumePoint = currentStableResumePoint
        let clampedView = max(1, min(maxView, view))

        if readingWorkflow?.canPromotePrefetchedDocument(forView: clampedView) == true {
            let didPromote = await promotePrefetchedDocument(
                startingAt: preferredSurfaceOrdinal,
                preferredResumePoint: nil,
                showsNovelReaderProjectionNavigationOverlay: true
            )
            if didPromote, navigation.isCurrentNavigationRequest(navigationSequence) {
                navigation.recordSuccessfulNonlinearNavigation(from: sourceResumePoint, to: currentStableResumePoint)
            }
            return
        }

        if clampedView == currentView {
            jumpToSurface(normalizedPagedSurfaceIndex(preferredSurfaceOrdinal))
            return
        }

        let didLoad = await load(
            view: clampedView,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            preferredResumePoint: nil,
            forceRefresh: false,
            showsNovelReaderProjectionNavigationOverlay: true
        )
        if didLoad, navigation.isCurrentNavigationRequest(navigationSequence) {
            navigation.recordSuccessfulNonlinearNavigation(from: sourceResumePoint, to: currentStableResumePoint)
        }
    }

    public func loadChapterComments(for target: ReaderChapterCommentTarget?) async {
        await chapterCommentsModule.load(target)
    }

    public func refreshChapterComments(for target: ReaderChapterCommentTarget?) async {
        await chapterCommentsModule.refresh(target)
    }

    public func loadNextChapterCommentsPage() async {
        await chapterCommentsModule.loadNextPage()
    }

    @discardableResult
    // MARK: - Page loads

    private func load(
        view: Int,
        preferredSurfaceOrdinal: Int,
        preferredResumePoint: NovelResumePoint?,
        forceRefresh: Bool,
        showsNovelReaderProjectionNavigationOverlay: Bool = false,
        reportsError: Bool = true
    ) async -> Bool {
        guard let workflow = await ensureReadingWorkflow() else { return false }
        if showsNovelReaderProjectionNavigationOverlay {
            await beginNovelReaderProjectionNavigation()
        }
        defer {
            if showsNovelReaderProjectionNavigationOverlay {
                setNovelReaderProjectionNavigation(false)
            }
        }
        isLoading = true
        errorMessage = nil
        do {
            let state = try await workflow.loadView(
                view,
                preferredSurfaceOrdinal: preferredSurfaceOrdinal,
                preferredResumePoint: preferredResumePoint,
                forceRefresh: forceRefresh
            )
            syncFromWorkflowState(state)
            isLoading = false
            recordBrowsingHistoryVisitIfNeeded()
            await cache.refresh()

            Task {
                await prefetchIfNeeded(for: selectedSurfaceIndex)
            }
            return true
        } catch {
            if reportsError {
                errorMessage = error.localizedDescription
            } else {
                YamiboLog.reader.warning("load(view:) failed on a non-reporting fallback path (reportsError=false); error dropped without surfacing to UI: \(error)")
            }
            isLoading = false
            return false
        }
    }

    private func startReadingWorkflow(resumePoint: NovelResumePoint?, favoriteAuthorID: String?) async {
        guard let workflow = await ensureReadingWorkflow() else { return }
        isLoading = true
        errorMessage = nil
        do {
            let state = try await workflow.start(
                initial: NovelReadingInitialPosition(
                    resumePoint: resumePoint,
                    favoriteAuthorID: favoriteAuthorID
                )
            )
            syncFromWorkflowState(state)
            isLoading = false
            recordBrowsingHistoryVisitIfNeeded()
            await cache.refresh()

            Task {
                await prefetchIfNeeded(for: selectedSurfaceIndex)
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// One-shot browsing-history record for this reader session, fired on
    /// the first successful content load (browsing-history decision #5's
    /// "打开即记"). Position/chapter refreshes then ride the debounced
    /// progress saves via `FavoriteLibraryProgressSyncAdapter`. Preview
    /// sessions never record (Reader Preview Mode exemption).
    private func recordBrowsingHistoryVisitIfNeeded() {
        guard !hasRecordedBrowsingHistoryVisit, !context.isPreview else { return }
        hasRecordedBrowsingHistoryVisit = true
        guard let browsingHistoryStore = dependencies.browsingHistoryStore else { return }
        let entry = BrowsingHistoryEntry(
            target: .novelThread(threadID: context.threadID),
            title: title,
            authorID: context.authorID,
            chapterTitle: context.initialResumePoint?.chapterTitle,
            lastVisitTime: .now
        )
        Task {
            do {
                try await browsingHistoryStore.record(entry)
            } catch {
                YamiboLog.reader.warning("Failed to record novel browsing-history visit for thread \(self.context.threadID, privacy: .public): \(error)")
            }
        }
    }

    private func ensureNovelReaderRepository() async -> NovelReaderRepository {
        if repository == nil {
            repository = await dependencies.makeNovelReaderRepository()
        }
        guard let repository else {
            preconditionFailure("Reader repository should be initialized")
        }
        return repository
    }

    private func ensureReadingWorkflow() async -> NovelReadingWorkflow? {
        let repository = await ensureNovelReaderRepository()
        if readingWorkflow == nil {
            readingWorkflow = makeReadingWorkflow(repository: repository)
        }
        return readingWorkflow
    }

    private func makeReadingWorkflow(repository: NovelReaderRepository) -> NovelReadingWorkflow {
        NovelReadingWorkflow(
            context: context,
            settings: settings,
            layout: layout,
            repository: repository,
            usesPadPresentation: usesPadPresentation,
            runtimeAdapter: runtimeAdapter ?? DefaultNovelTextLayoutRuntimeAdapter()
        )
    }

    private func requestRuntimeUpdate(
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        usesPadPresentation: Bool
    ) async throws -> NovelReadingWorkflowState? {
        try await readingWorkflow?.requestRuntimeUpdate(
            NovelReadingWorkflowRuntimeUpdate(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            ),
            preparation: runtimeUpdatePreparation
        )
    }

    private func syncFromWorkflowState(_ state: NovelReadingWorkflowState) {
        chromeProgressSnapshot = state.presentation.map(NovelReaderChromeProgressSnapshot.init) ?? .empty
        novelReaderPresentation = state.presentation
        currentStableResumePoint = readingWorkflow?.captureNovelReadingPosition()
    }

    // Internal (not private): the raw resume-point jump primitive, also used
    // by the navigation coordinator to restore back/forward history anchors.
    // Does not itself record navigation history — callers that represent a
    // user-initiated nonlinear jump (see `jumpToLikeAnchor` below) must do
    // that themselves.
    // MARK: - Resume points and like anchors

    func restoreResumePoint(_ resumePoint: NovelResumePoint) async -> Bool {
        if resumePoint.view == currentView,
           let state = readingWorkflow?.restoreResumePointInCurrentDocument(resumePoint) {
            syncFromWorkflowState(state)
            Task {
                await prefetchIfNeeded(for: selectedSurfaceIndex)
            }
            return true
        }

        if readingWorkflow?.canPromotePrefetchedDocument(forView: resumePoint.view) == true {
            return await promotePrefetchedDocument(
                startingAt: 0,
                preferredResumePoint: resumePoint,
                showsNovelReaderProjectionNavigationOverlay: true,
                reportsError: false
            )
        }

        return await load(
            view: resumePoint.view,
            preferredSurfaceOrdinal: 0,
            preferredResumePoint: resumePoint,
            forceRefresh: false,
            showsNovelReaderProjectionNavigationOverlay: true,
            reportsError: false
        )
    }

    // The Like sheet's `onOpenAnchor` jump path in `NovelReaderView` opens a
    // synthesized resume point from a liked anchor while the reader for that
    // work is already open; this is a nonlinear jump like any other (chapter
    // directory, relative-chapter jump, cross-view jump), so it is recorded
    // the same way, making it eligible for the chrome's back/forward history.
    func jumpToLikeAnchor(_ resumePoint: NovelResumePoint) async -> Bool {
        let navigationSequence = navigation.beginNavigationRequest()
        let sourceResumePoint = currentStableResumePoint
        let didRestore = await restoreResumePoint(resumePoint)
        if didRestore, navigation.isCurrentNavigationRequest(navigationSequence) {
            navigation.recordSuccessfulNonlinearNavigation(from: sourceResumePoint, to: currentStableResumePoint)
        }
        return didRestore
    }

    /// Opens a chapter anchor discovered while browsing another web view's
    /// catalog; returns nil when the reading workflow is unavailable so the
    /// navigation coordinator can fall back to a plain view load.
    private func openChapterAnchor(_ anchor: NovelChapterAnchor) async -> Bool? {
        guard let workflow = await ensureReadingWorkflow() else { return nil }
        await beginNovelReaderProjectionNavigation()
        defer { setNovelReaderProjectionNavigation(false) }
        isLoading = true
        errorMessage = nil
        do {
            let state = try await workflow.loadChapter(anchor)
            syncFromWorkflowState(state)
            isLoading = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return false
        }
    }

    private var currentLinearReadingPageKey: NovelReaderLinearReadingPageKey? {
        guard currentStableResumePoint != nil, novelReaderPresentation != nil else { return nil }
        return NovelReaderLinearReadingPageKey(view: currentView, surfaceIndex: selectedSurfaceIndex)
    }

    private func beginNovelReaderProjectionNavigation() async {
        setNovelReaderProjectionNavigation(true)
        await novelReaderPageDocumentNavigationOverlayPreparation()
    }

    private func setNovelReaderProjectionNavigation(_ isNavigating: Bool) {
        guard isNavigatingNovelReaderProjection != isNavigating else { return }
        isNavigatingNovelReaderProjection = isNavigating
        novelReaderPageDocumentNavigationStateDidChange?(isNavigating)
    }

    private func prefetchIfNeeded(for surfaceIndex: Int) async {
        guard let workflow = await ensureReadingWorkflow(),
              let presentation = novelReaderPresentation,
              presentation.surfaces.indices.contains(surfaceIndex),
              let state = await workflow.prefetchIfNeeded(near: presentation.surfaces[surfaceIndex].identity) else {
            return
        }
        syncFromWorkflowState(state)
    }

    private func chapterTitle(for surfaceIndex: Int) -> String? {
        guard novelReaderSurfaces.indices.contains(surfaceIndex) else {
            return chapters.last(where: { $0.startIndex <= surfaceIndex })?.title
        }
        return novelReaderSurfaces[surfaceIndex].chapterTitle ?? chapters.last(where: { $0.startIndex <= surfaceIndex })?.title
    }

    private var displayedPageLabel: String {
        novelReaderPresentation?.progressProjection.displayedPageLabel ?? "1"
    }

    private var displayedView: Int {
        chromeProgressSnapshot.visibleView
    }

    private var displayedPageIndex: Int {
        novelReaderPresentation?.progressProjection.displayedPageIndex ?? 0
    }

    private var displayedPageCount: Int {
        novelReaderPresentation?.progressProjection.displayedPageCount ?? 1
    }

    private var selectedSurface: NovelReaderSurface? {
        let normalizedIndex = normalizedPagedSurfaceIndex(selectedSurfaceIndex)
        guard novelReaderSurfaces.indices.contains(normalizedIndex) else { return nil }
        return novelReaderSurfaces[normalizedIndex]
    }

    private func currentProgressSnapshot() -> NovelReadingPosition {
        readingWorkflow?.currentProgressPosition() ?? NovelReadingPosition(
            threadID: context.threadID,
            view: displayedView,
            maxView: maxView,
            chapterTitle: currentChapterTitle,
            authorID: currentAuthorID ?? context.authorID,
            documentSurfaceProgressPercent: currentDocumentSurfaceProgressPercent
        )
    }

    private var currentDocumentSurfaceProgressPercent: Int? {
        guard let projection = novelReaderPresentation?.progressProjection else { return nil }
        guard projection.displayedPageCount > 1 else { return 0 }
        let fraction = Double(projection.displayedPageIndex) / Double(projection.displayedPageCount - 1)
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    private func promoteIfNeededAfterLocationUpdate() {
        if settings.readingMode == .paged,
           isAtPagedDocumentEnd,
           readingWorkflow?.canPromotePrefetchedDocument(forView: currentView + 1) == true {
            Task {
                await promotePrefetchedDocument(
                    startingAt: 0,
                    preferredResumePoint: nil,
                    showsNovelReaderProjectionNavigationOverlay: true
                )
            }
        }
    }

    private var isAtPagedDocumentEnd: Bool {
        guard settings.readingMode == .paged else { return false }
        if isTwoPageSpreadActive {
            let currentDocumentSpreads = presentationSpreads.filter { spread in
                guard novelReaderSurfaces.indices.contains(spread.leftSurfaceIndex) else { return false }
                return novelReaderSurfaces[spread.leftSurfaceIndex].documentView == currentView
            }
            guard let lastSpread = currentDocumentSpreads.last else { return false }
            return pagedViewportSelectionIndex >= lastSpread.index
        }

        let currentDocumentSurfaceIndexes = novelReaderSurfaces.indices.filter {
            novelReaderSurfaces[$0].documentView == currentView
        }
        guard let lastSurfaceIndex = currentDocumentSurfaceIndexes.last else { return false }
        return selectedSurfaceIndex >= lastSurfaceIndex
    }

    private func scheduleProgressSync() {
        guard !context.isPreview else { return }
        let snapshot = currentProgressSnapshot()
        Task { [weak self, progressSync] in
            await self?.persistNovelResumeRoute(snapshot)
            await progressSync.queue(.novel(snapshot))
        }
    }

    private func flushProgress() async -> NovelLaunchContext {
        let snapshot = currentProgressSnapshot()
        let resumeContext = resumeContext(for: snapshot)
        guard !context.isPreview else { return resumeContext }
        await persistNovelResumeRoute(resumeContext)
        try? await progressSync.flush(.novel(snapshot))
        return resumeContext
    }

    private func persistNovelResumeRoute(_ snapshot: NovelReadingPosition) async {
        await persistNovelResumeRoute(resumeContext(for: snapshot))
    }

    private func persistNovelResumeRoute(_ resumeContext: NovelLaunchContext) async {
        await onReaderResumeRouteChange(.novel(resumeContext))
    }

    private func resumeContext(for snapshot: NovelReadingPosition) -> NovelLaunchContext {
        NovelLaunchContext(
            threadID: context.threadID,
            threadTitle: context.threadTitle,
            source: .resume,
            initialView: snapshot.view,
            authorID: snapshot.authorID ?? context.authorID,
            initialResumePoint: snapshot.resumePoint,
            isPreview: context.isPreview
        )
    }

    private func spreadIndex(forSurfaceIndex surfaceIndex: Int) -> Int {
        guard isTwoPageSpreadActive else {
            return max(0, min(surfaceIndex, max(novelReaderSurfaces.count - 1, 0)))
        }

        let normalizedIndex = max(0, min(surfaceIndex, max(novelReaderSurfaces.count - 1, 0)))
        return presentationSpreads.first(where: { spread in
            spread.leftSurfaceIndex == normalizedIndex || spread.rightSurfaceIndex == normalizedIndex
        })?.index ?? 0
    }

    private func progressSurfaceIndex(forSpreadIndex spreadIndex: Int) -> Int {
        guard let spread = presentationSpreads.first(where: { $0.index == spreadIndex }) ?? presentationSpreads.last else {
            return 0
        }
        switch settings.pageTurnDirection {
        case .leftToRight:
            return spread.rightSurfaceIndex ?? spread.leftSurfaceIndex
        case .rightToLeft:
            return spread.leftSurfaceIndex
        }
    }

    private func normalizedPagedSurfaceIndex(_ surfaceIndex: Int) -> Int {
        let clampedIndex = max(0, min(surfaceIndex, max(novelReaderSurfaces.count - 1, 0)))
        guard isTwoPageSpreadActive else { return clampedIndex }
        return progressSurfaceIndex(forSpreadIndex: spreadIndex(forSurfaceIndex: clampedIndex))
    }

    private func cacheContext(forView view: Int) -> String? {
        guard let workflowContext = readingWorkflow?.cacheContext(forView: view) else {
            return currentAuthorID ?? context.authorID
        }
        return workflowContext.authorID
    }

    private func currentCacheOperationContext() -> NovelReaderCacheOperationContext {
        NovelReaderCacheOperationContext(
            ownerTitle: title,
            threadID: context.threadID,
            authorID: cacheContext(forView: displayedView)
        )
    }

    @discardableResult
    private func promotePrefetchedDocument(startingAt preferredSurfaceOrdinal: Int) async -> Bool {
        await promotePrefetchedDocument(startingAt: preferredSurfaceOrdinal, preferredResumePoint: nil)
    }

    @discardableResult
    private func promotePrefetchedDocument(
        startingAt preferredSurfaceOrdinal: Int,
        preferredResumePoint: NovelResumePoint?,
        showsNovelReaderProjectionNavigationOverlay: Bool = false,
        reportsError: Bool = true
    ) async -> Bool {
        if showsNovelReaderProjectionNavigationOverlay {
            await beginNovelReaderProjectionNavigation()
        }
        defer {
            if showsNovelReaderProjectionNavigationOverlay {
                setNovelReaderProjectionNavigation(false)
            }
        }
        do {
            guard let workflowState = try await readingWorkflow?.promotePrefetchedDocument(
                preferredSurfaceOrdinal: preferredSurfaceOrdinal,
                resumePoint: preferredResumePoint
            ) else { return false }
            syncFromWorkflowState(workflowState)
            await prefetchIfNeeded(for: selectedSurfaceIndex)
            return true
        } catch {
            if reportsError {
                errorMessage = error.localizedDescription
            } else {
                YamiboLog.reader.warning("promotePrefetchedDocument failed on a non-reporting fallback path (reportsError=false); error dropped without surfacing to UI: \(error)")
            }
            return false
        }
    }

    // MARK: - Appearance persistence

    private func persistSettings(
        novelReaderSettings: NovelReaderAppearanceSettings? = nil,
        applePencilPageTurnSettings: ApplePencilPageTurnSettings? = nil
    ) {
        Task { [weak self] in
            guard let self else { return }
            var appSettings = await dependencies.settingsStore.load()
            if let novelReaderSettings {
                appSettings.novelReader = novelReaderSettings
            }
            if let applePencilPageTurnSettings {
                appSettings.system.applePencilPageTurn = applePencilPageTurnSettings
            }
            do {
                try await dependencies.settingsStore.save(appSettings)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func beginApplyingAppearanceSettings() -> UInt64 {
        appearanceSettingsApplicationSequence &+= 1
        isApplyingAppearanceSettings = true
        return appearanceSettingsApplicationSequence
    }

    private func finishApplyingAppearanceSettings(_ sequence: UInt64) {
        guard appearanceSettingsApplicationSequence == sequence else { return }
        isApplyingAppearanceSettings = false
    }
}

private extension NovelReaderAppearanceSettings {
    func isSurfaceOnlyAppearanceChange(to other: NovelReaderAppearanceSettings) -> Bool {
        var lhs = self
        var rhs = other
        lhs.backgroundStyle = .system
        rhs.backgroundStyle = .system
        lhs.pagedTurnStyle = .slide
        rhs.pagedTurnStyle = .slide
        return lhs == rhs &&
            (backgroundStyle != other.backgroundStyle || pagedTurnStyle != other.pagedTurnStyle)
    }
}

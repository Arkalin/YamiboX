import SwiftUI
import YamiboXCore
import UIKit

public struct NovelReaderView: View {
    /// `@State` (not `@StateObject`) because the view model is `@Observable`.
    /// SwiftUI keeps the first instance for the view's lifetime; the
    /// constructions on later `init` calls are discarded, which is safe here
    /// because `NovelReaderViewModel.init` only stores its context and
    /// dependencies and has no side effects (the reading workflow, repository
    /// and lazy coordinators are all created later, on first use).
    @State private var model: NovelReaderViewModel
    @State private var verticalScrollCoordinator = NovelReaderVerticalScrollCoordinator()
    // The vertical restore state machine (scroll request, retry polling,
    // positioning fingerprint) lives in its own @MainActor @Observable
    // coordinator; the view only forwards events into it and renders its two
    // tracked fields. `@State` keeps the first instance alive exactly like
    // the previous `@StateObject` did; the per-init discards are inert (the
    // coordinator's init only zero-fills state and starts no work).
    @State private var verticalRestore = NovelReaderVerticalRestoreCoordinator()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The five boolean-presented sheets are mutually exclusive (every setter
    // is a chrome button, and chrome is disabled while any overlay is up),
    // so a single optional enum replaces the six booleans. The item-driven
    // covers (`forumThreadOverlayItem`, `imageBrowserItem`) stay separate.
    @State private var presentedSheet: NovelReaderPresentedSheet?
    @State private var forumThreadOverlayItem: ForumThreadOverlayItem?
    @State private var imageBrowserItem: ImageBrowserItem?
    @State private var chapterCommentsTarget: ReaderChapterCommentTarget?
    @State private var chromeState = NovelReaderChromeState()
    @State private var isVerticalProgressScrubbing = false
    @State private var verticalTapSuppressionUntil: CFTimeInterval = 0
    @State private var verticalBoundaryPullState = NovelReaderVerticalBoundaryPullState.idle
    @State private var isHandlingVerticalBoundaryPull = false
    @State private var isDismissing = false
    /// Reader-session-scoped: once dismissed the banner stays gone until the
    /// reader is closed and reopened (this view is recreated).
    @State private var isOfflineBannerDismissed = false
    @State private var topChromeHeight: CGFloat = 0
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var pagedScrollAnimationRequest: ReaderPagedScrollAnimationRequest?
    @State private var novelTextSelectionController = NovelTextSelectionController()
    @State private var likeHighlightController = NovelLikeHighlightController()
    @State private var likedNovelImageAnchors: Set<NovelImageLikeAnchor> = []
    @State private var likeFeedbackGenerator = UINotificationFeedbackGenerator()
    /// Drives the 书签与喜欢 capsule (visibility + count) and the bookmark
    /// button's filled/outline state. Refreshed from the two stores rather
    /// than derived, because the capsule must also reflect changes made in
    /// another scene or synced in from another device.
    @State private var annotationCapsule = ReaderAnnotationCapsulePresentation(bookmarkCount: 0, likeCount: 0)
    /// Whether the bookmark action at the viewport's current position removes
    /// an existing bookmark rather than adding a new one.
    @State private var isCurrentPositionBookmarked = false
    /// Remembered for the reader session so reopening the panel returns to the
    /// segment the user last looked at; nil means "not chosen yet".
    @State private var rememberedAnnotationSegment: ReaderAnnotationSegment?
    /// The directory entry always lands on Chapters, while the annotation
    /// entry preserves its bookmarks-or-likes destination.
    @State private var initialReaderLibraryTab: ReaderLibraryPanelTab = .bookmarks
    @State private var controlHandlerToken: UUID?
    @State private var controlPagedPagerIdentity: ReaderPagedPagerIdentity?
    /// Scene-local window safe-area insets reported by
    /// `ReaderWindowSafeAreaInsetsProbe`; seeded from the key-window
    /// backstop for the frames before the reader attaches to its window.
    @State private var windowSafeAreaInsets: UIEdgeInsets = ReaderShellMetrics.windowSafeAreaInsets
    private let appModel: YamiboAppModel
    private let dependencies: NovelReaderDependencies

    public init(context: NovelLaunchContext, dependencies: NovelReaderDependencies, appModel: YamiboAppModel) {
        let initialSettings = appModel.bootstrapState?.settings.novelReader
        // `State(initialValue:)` evaluates its argument on every init (unlike
        // `StateObject(wrappedValue:)`'s autoclosure), so a view model is now
        // built — and, past the first init, discarded — on each parent
        // render. Accepted deliberately, mirroring `LocalFavoritesRootView`:
        // the init is side-effect-free, so the extra constructions are inert.
        _model = State(initialValue: NovelReaderViewModel(
            context: context,
            dependencies: dependencies,
            initialSettings: initialSettings,
            onReaderResumeRouteChange: { route in
                appModel.updateReaderResumeRoute(route)
            }
        ))
        _chromeState = State(initialValue: NovelReaderChromeState(
            showsChrome: initialSettings?.readingMode != .vertical
        ))
        self.appModel = appModel
        self.dependencies = dependencies
    }

    private var isPadDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    public var body: some View {
        GeometryReader { proxy in
            let rawTopInset = max(proxy.safeAreaInsets.top, windowSafeAreaInsets.top)
            let topInset = effectiveTopInset(rawTopInset)
            let contentTopInset = model.settings.readingMode == .paged
                ? readerPagedContentTopInset(for: topInset)
                : readerContentTopInset(for: topInset, rawTopInset: rawTopInset)
            let bottomInset = max(proxy.safeAreaInsets.bottom, windowSafeAreaInsets.bottom)
            let currentLayout = readerLayout(
                proxy: proxy,
                topInset: topInset,
                bottomInset: bottomInset
            )
            let pagedPagerIdentity = ReaderPagedPagerIdentity(
                visibleView: model.visibleView,
                surfaceCount: model.novelReaderSurfaces.count,
                spreadCount: model.presentationSpreads.count,
                usesTwoPageSpread: model.isTwoPageSpreadActive,
                layout: currentLayout
            )
            let loadingOverlayPresentation = readerLoadingOverlayPresentation

            ZStack {
                backgroundColor
                    .ignoresSafeArea()

                content(
                    topInset: contentTopInset,
                    bottomInset: bottomInset,
                    layout: currentLayout
                )
                .ignoresSafeArea(.container, edges: .top)
                .transaction { transaction in
                    if model.settings.readingMode == .paged {
                        transaction.animation = nil
                    }
                }
                .opacity(loadingOverlayPresentation.isPresented ? 0 : 1)

                // Chrome-visible only, and only once the top chrome has
                // reported its height: on the first chrome frame
                // `topChromeHeight` is still 0 and the banner would sit on
                // top of the close button.
                if let sourceStatusText = model.sourceStatusText,
                   !model.novelReaderSurfaces.isEmpty,
                   !isOfflineBannerDismissed,
                   chromeState.showsChrome,
                   topChromeHeight > 0 {
                    VStack(spacing: 0) {
                        NovelReaderOfflineFallbackBanner(
                            message: sourceStatusText,
                            retry: refreshReader,
                            dismiss: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isOfflineBannerDismissed = true
                                }
                            }
                        )
                        .padding(.top, topInset + topChromeHeight + 6)
                        .padding(.horizontal, 12)

                        Spacer(minLength: 0)
                    }
                    .transition(.opacity)
                    .zIndex(2.5)
                }

                ApplePencilPageTurnInteractionOverlay(
                    settings: model.applePencilPageTurnSettings,
                    canTurnPage: canReceiveApplePencilPageTurn
                ) { delta in
                    Task { await goRelativePage(delta, pagerIdentity: pagedPagerIdentity) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if loadingOverlayPresentation.allowsChrome {
                    NovelReaderChromeControls(
                        model: model,
                        topInset: topInset,
                        bottomInset: bottomInset,
                        isChromeVisible: chromeState.showsChrome,
                        onNavigateBack: {
                            Task { await navigateBackFromChrome() }
                        },
                        onNavigateForward: {
                            Task { await navigateForwardFromChrome() }
                        },
                        onClose: closeReader,
                        onRefresh: refreshReader,
                        onShowChapters: openChapterDrawer,
                        onShowSettings: openSettings,
                        onShowCache: openCachePanel,
                        onShowComments: openChapterComments,
                        onOpenForum: openInForum,
                        onToggleBookmark: toggleBookmarkAtCurrentPosition,
                        onShowAnnotations: openAnnotations,
                        isBookmarked: isCurrentPositionBookmarked,
                        annotationCapsule: annotationCapsule,
                        onJumpChapter: { delta in
                            jumpAdjacentChapter(delta)
                        },
                        onProgressCommit: { surfaceIndex in
                            commitProgressSlider(surfaceIndex)
                        },
                        onVerticalProgressCommit: { surfaceIndex in
                            commitVerticalProgressScrub(surfaceIndex)
                        },
                        onBeginVerticalProgressScrub: {
                            beginVerticalProgressScrub()
                        },
                        onEndVerticalProgressScrub: {
                            endVerticalProgressScrub()
                        },
                        isProgressScrubbing: isVerticalProgressScrubbing
                    )
                    .zIndex(2)
                }

                verticalBoundaryPullOverlayLayer(
                    topInset: topInset,
                    bottomInset: bottomInset
                )
                .zIndex(3)

                if loadingOverlayPresentation.isPresented {
                    readerLoadingOverlay
                        .zIndex(4)
                }
            }
            .disabled(hasPresentedOverlay)
            .allowsHitTesting(!hasPresentedOverlay)
            .background(ReaderWindowSafeAreaInsetsProbe(insets: $windowSafeAreaInsets))
            .onChange(of: pagedPagerIdentity, initial: true) { _, newValue in
                controlPagedPagerIdentity = newValue
            }
            .onAppear {
                guard controlHandlerToken == nil else { return }
                controlHandlerToken = appModel.peripheralInput.pushHandler { event in
                    handleControlEvent(event)
                }
            }
            .modifier(readerLifecycleModifier(currentLayout: currentLayout))
            .modifier(novelReaderPresentationModifier())
            .modifier(readerStateObserverModifier())
            .modifier(readerChromeHeightObserverModifier())
            .onChange(of: model.novelReaderPresentation?.generation) { _, _ in
                novelTextSelectionController.clearSelection()
            }
            .onChange(of: model.settings.readingMode) { _, _ in
                novelTextSelectionController.clearSelection()
            }
            // Appearance-scoped `.task` replacing the removed `.onReceive`
            // bridge. The reader stays the visible full-screen surface for
            // its whole session — its own panels are sheets/covers presented
            // *from* it, which don't cancel this task — so like changes made
            // anywhere in the session keep refreshing the anchors live,
            // exactly as the Combine subscription did.
            .task {
                for await changeID in dependencies.like.likeStore.changes() {
                    // Per-instance stream: the guard is kept as the explicit
                    // "only this exact store instance" contract.
                    guard changeID == dependencies.like.likeStore.changeID else {
                        continue
                    }
                    Task { await loadLikedNovelImageAnchors() }
                    Task { await refreshAnnotationState() }
                }
            }
            // Bookmarks live in their own store, so they need their own
            // stream: the capsule count and the toggle glyph must also follow
            // deletions made in the panel and rows synced in from another
            // device.
            .task {
                for await _ in dependencies.like.bookmarkStore.changes() {
                    await refreshAnnotationState()
                }
            }
            // The bookmark glyph is only readable while the chrome is up, so
            // that is when it is worth re-deriving from the current position.
            .onChange(of: chromeState.showsChrome) { _, showsChrome in
                guard showsChrome else { return }
                Task { await refreshAnnotationState() }
            }
            // The ordinals are scoped to the forum page currently laid out, so
            // moving to another page reveals a fresh set.
            .onChange(of: model.visibleView) { _, _ in
                Task { await resolveAnnotationSortKeys() }
            }
        }
    }

    private func readerLifecycleModifier(currentLayout: NovelReaderLayout) -> NovelReaderLifecycleModifier {
        NovelReaderLifecycleModifier(
            currentLayout: currentLayout,
            onInitialTask: {
                configureLikeCapture()
                likeHighlightController.configure(
                    workKey: .novel(threadID: model.context.threadID),
                    likeStore: dependencies.like.likeStore
                )
                Task { await loadLikedNovelImageAnchors() }
                await model.commitNovelTextPresentationEnvironment(isPad: isPadDevice)
                await model.prepare(layout: currentLayout)
                // `prepare` is what makes a semantic reader position
                // available. Refreshing earlier always reads nil and leaves
                // an existing bookmark looking like an add action.
                await refreshAnnotationState()
                // Strictly after `prepare`: it is what creates the reading
                // workflow, and the ordinals come off the laid-out projection.
                // Spawned before it, this read always saw a nil workflow and
                // silently no-opped, leaving every chapter ordinal unresolved.
                await resolveAnnotationSortKeys()
                updateChromeForContentState()
                restoreVerticalPositionIfNeeded()
            },
            onLayoutChange: { newValue in
                Task {
                    guard !hasPresentedOverlay else {
                        updateChromeForContentState()
                        return
                    }
                    await model.commitNovelTextLayout(newValue)
                    updateChromeForContentState()
                    restoreVerticalPositionIfNeeded()
                }
            },
            onMemoryWarning: {
                model.handleMemoryPressure()
            },
            onDisappear: {
                appModel.peripheralInput.removeHandler(controlHandlerToken)
                controlHandlerToken = nil
                verticalRestore.cancelPendingRestoreWork()
                syncVerticalViewportBeforeSave()
                Task {
                    await model.saveProgress()
                    model.close()
                }
            }
        )
    }

    private func novelReaderPresentationModifier() -> NovelReaderPresentationModifier {
        NovelReaderPresentationModifier(
            model: model,
            presentedSheet: $presentedSheet,
            forumThreadOverlayItem: $forumThreadOverlayItem,
            imageBrowserItem: $imageBrowserItem,
            chapterCommentsTarget: chapterCommentsTarget,
            likeDependencies: dependencies.like,
            appModel: appModel,
            onJumpToChapterDirectoryChapter: { chapter in
                Task { await jumpToChapterDirectoryChapter(chapter) }
            },
            onPreviewChapterDirectoryWebView: { view in
                Task { await model.navigation.previewChapterDirectoryWebView(view) }
            },
            onOpenLikeAnchor: { payload in
                handleLikeAnchorOpen(payload)
            },
            onOpenBookmark: { item in
                handleBookmarkOpen(item)
            },
            onSaveNote: { item, note in
                Task {
                    _ = try? await dependencies.like.likeStore.updateNote(id: item.id, note: note)
                }
            },
            annotationSegment: annotationSegmentBinding,
            initialReaderLibraryTab: initialReaderLibraryTab
        )
    }

    private func readerStateObserverModifier() -> NovelReaderStateObserverModifier {
        NovelReaderStateObserverModifier(
            model: model,
            presentedSheet: $presentedSheet,
            forumThreadOverlayItem: $forumThreadOverlayItem,
            imageBrowserItem: $imageBrowserItem,
            isStatusBarHidden: chromeState.mode == .immersiveHidden,
            isChromeVisible: chromeState.showsChrome,
            onUpdateChromeForContentState: {
                updateChromeForContentState()
            },
            onRestoreVerticalPositionIfNeeded: {
                restoreVerticalPositionIfNeeded()
            }
        )
    }

    private func readerChromeHeightObserverModifier() -> NovelReaderChromeHeightObserverModifier {
        NovelReaderChromeHeightObserverModifier(
            topChromeHeight: $topChromeHeight,
            bottomChromeHeight: $bottomChromeHeight
        )
    }

    @ViewBuilder
    private func content(topInset: CGFloat, bottomInset: CGFloat, layout: NovelReaderLayout) -> some View {
        if let errorMessage = model.errorMessage, model.novelReaderSurfaces.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(errorMessage)
                    .multilineTextAlignment(.center)
                Button(L10n.string("common.retry"), action: retryLoad)
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.settings.readingMode == .paged {
            pagedContent(
                topInset: topInset,
                layout: layout
            )
        } else {
            verticalContent(
                topInset: topInset,
                bottomInset: bottomInset
            )
        }
    }

    /// Reduce Motion downgrades the 3D page-curl transition to the already
    /// available quick-fade style; direct-manipulation slide stays as is.
    private var effectivePagedSettings: NovelReaderAppearanceSettings {
        guard reduceMotion, model.settings.pagedTurnStyle == .pageCurl else { return model.settings }
        var adjusted = model.settings
        adjusted.pagedTurnStyle = .quickFade
        return adjusted
    }


    /// Shared bindings for the three paged viewport branches; see
    /// `NovelReaderPagedViewportBindings`.
    // MARK: - Content viewports

    private func pagedViewportBindings(pagerIdentity: ReaderPagedPagerIdentity) -> NovelReaderPagedViewportBindings {
        NovelReaderPagedViewportBindings(
            displayReferenceProvider: { surfaceIdentity in
                model.novelTextViewportDisplayReference(for: surfaceIdentity)
            },
            selectionController: novelTextSelectionController,
            likeHighlightController: likeHighlightController,
            likedImageAnchors: likedNovelImageAnchors,
            isChromeVisible: chromeState.showsChrome,
            canBoundaryPageTurn: { delta in
                canNavigatePagedBoundary(delta: delta)
            },
            onSelectionChange: self.handlePagedViewportSelection,
            onBoundaryPageTurn: { delta in
                Task { await goRelativePage(delta, pagerIdentity: pagerIdentity) }
            },
            onPageTapZone: { zone in
                handlePagedTapZone(zone, pagerIdentity: pagerIdentity)
            },
            onScrollAnimationRequestConsumed: { request in
                clearPagedScrollAnimationRequest(request)
            },
            onChromeVisibleImageTap: {
                enterImmersiveMode()
            },
            onImageTap: { url, title in
                handleImageTap(url: url, title: title)
            },
            onImageLongPress: { anchor, imageURL in
                handleImageLongPress(anchor, imageURL: imageURL)
            }
        )
    }

    private func pagedContent(topInset: CGFloat, layout: NovelReaderLayout) -> some View {
        let pagerIdentity = ReaderPagedPagerIdentity(
            visibleView: model.visibleView,
            surfaceCount: model.novelReaderSurfaces.count,
            spreadCount: model.presentationSpreads.count,
            usesTwoPageSpread: model.isTwoPageSpreadActive,
            layout: layout
        )
        let pagedTopInset = topInset + layout.chromeInsets.top
        let bindings = pagedViewportBindings(pagerIdentity: pagerIdentity)
        return Group {
            if effectivePagedSettings.pagedTurnStyle == .pageCurl {
                NovelReaderPagedPageCurlViewport(
                    spreads: model.presentationSpreads,
                    surfaces: model.novelReaderSurfaces,
                    settings: effectivePagedSettings,
                    refererURL: model.forumURL,
                    offlineScope: model.inlineImageOfflineScope,
                    topInset: pagedTopInset,
                    bottomInset: layout.chromeInsets.bottom,
                    selectionIndex: model.pagedViewportSelectionIndex,
                    usesTwoPageSpread: model.isTwoPageSpreadActive,
                    pagerIdentity: pagerIdentity,
                    scrollAnimationRequest: pagedScrollAnimationRequest,
                    displayReferenceProvider: bindings.displayReferenceProvider,
                    selectionController: bindings.selectionController,
                    likeHighlightController: bindings.likeHighlightController,
                    likedImageAnchors: bindings.likedImageAnchors,
                    isChromeVisible: bindings.isChromeVisible,
                    canBoundaryPageTurn: bindings.canBoundaryPageTurn,
                    onSelectionChange: bindings.onSelectionChange,
                    onBoundaryPageTurn: bindings.onBoundaryPageTurn,
                    onPageTapZone: bindings.onPageTapZone,
                    onScrollAnimationRequestConsumed: bindings.onScrollAnimationRequestConsumed,
                    onChromeVisibleImageTap: bindings.onChromeVisibleImageTap,
                    onImageTap: bindings.onImageTap,
                    onImageLongPress: bindings.onImageLongPress
                )
            } else {
                NovelReaderPagedCollectionViewport(
                    itemSource: model.isTwoPageSpreadActive
                        ? .spreads(model.presentationSpreads)
                        : .surfaces,
                    surfaces: model.novelReaderSurfaces,
                    settings: effectivePagedSettings,
                    refererURL: model.forumURL,
                    offlineScope: model.inlineImageOfflineScope,
                    topInset: pagedTopInset,
                    bottomInset: layout.chromeInsets.bottom,
                    selectionIndex: model.pagedViewportSelectionIndex,
                    pagerIdentity: pagerIdentity,
                    scrollAnimationRequest: pagedScrollAnimationRequest,
                    displayReferenceProvider: bindings.displayReferenceProvider,
                    selectionController: bindings.selectionController,
                    likeHighlightController: bindings.likeHighlightController,
                    likedImageAnchors: bindings.likedImageAnchors,
                    isChromeVisible: bindings.isChromeVisible,
                    canBoundaryPageTurn: bindings.canBoundaryPageTurn,
                    onSelectionChange: bindings.onSelectionChange,
                    onBoundaryPageTurn: bindings.onBoundaryPageTurn,
                    onPageTapZone: bindings.onPageTapZone,
                    onScrollAnimationRequestConsumed: bindings.onScrollAnimationRequestConsumed,
                    onChromeVisibleImageTap: bindings.onChromeVisibleImageTap,
                    onImageTap: bindings.onImageTap,
                    onImageLongPress: bindings.onImageLongPress
                )
            }
        }
        .id(pagerIdentity)
        .scrollDisabled(chromeState.showsChrome)
    }

    private func verticalContent(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        NovelReaderVerticalViewportScrollView(
            surfaces: model.novelReaderSurfaces,
            settings: model.settings,
            refererURL: model.forumURL,
            offlineScope: model.inlineImageOfflineScope,
            topInset: topInset,
            bottomInset: bottomInset,
            scrollRequest: verticalRestore.verticalScrollRequest,
            displayReferenceProvider: { surfaceIdentity in
                model.novelTextViewportDisplayReference(for: surfaceIdentity)
            },
            selectionController: novelTextSelectionController,
            likeHighlightController: likeHighlightController,
            likedImageAnchors: likedNovelImageAnchors,
            isChromeVisible: chromeState.showsChrome,
            onVisibleSurfaceIdentitiesChange: { surfaceIdentities in
                model.updateNovelTextViewportVisibleSurfaceIdentities(surfaceIdentities)
            },
            onScrollRequestHandled: { request in
                verticalRestore.handleScrollRequestHandled(
                    request,
                    model: model,
                    scrollCoordinator: verticalScrollCoordinator
                )
            },
            onScrollViewReady: { scrollView in
                verticalScrollCoordinator.attach(scrollView: scrollView)
                verticalScrollCoordinator.onBoundaryPullRelease = { direction in
                    Task { @MainActor in
                        await handleVerticalBoundaryPullRelease(direction)
                    }
                }
                verticalScrollCoordinator.onViewportMetricsChange = {
                    Task { @MainActor in
                        verticalRestore.tryAdvanceVerticalRestore(
                            model: model,
                            scrollCoordinator: verticalScrollCoordinator
                        )
                        verticalRestore.applyVerticalViewportPositionUpdate(
                            for: .viewportGeometryChanged,
                            model: model
                        )
                    }
                }
                verticalScrollCoordinator.onBoundaryPullStateChange = { state in
                    Task { @MainActor in
                        updateVerticalBoundaryPullState(state)
                    }
                }
            },
            onSurfaceFramesChange: { frames in
                verticalRestore.handleSurfaceFramesChange(
                    frames,
                    model: model,
                    scrollCoordinator: verticalScrollCoordinator
                )
            },
            onTextViewportSampleChange: { sample in
                verticalRestore.handleTextViewportSampleChange(sample, model: model)
            },
            onViewportChange: {
                verticalRestore.applyVerticalViewportPositionUpdate(
                    for: .viewportGeometryChanged,
                    model: model
                )
            },
            onScrollSettled: {
                verticalRestore.updateVerticalViewportPosition(model: model)
                Task { await self.refreshCurrentPositionBookmarkState() }
            },
            onTap: {
                handleVerticalTap()
            },
            onChromeVisibleImageTap: {
                enterImmersiveMode()
            },
            onImageTap: { url, title in
                handleImageTap(url: url, title: title)
            },
            onImageLongPress: { anchor, imageURL in
                handleImageLongPress(anchor, imageURL: imageURL)
            }
        )
        .contentShape(Rectangle())
        .simultaneousGesture(verticalScrollSuppressionGesture)
    }

    private var backgroundColor: Color {
        readerThemeColor(for: model.settings.backgroundStyle, colorScheme: colorScheme)
    }

    private var readerLoadingOverlayPresentation: NovelReaderLoadingOverlayPresentation {
        NovelReaderLoadingOverlayPresentation(
            isLoading: model.isLoading,
            hasSurfaces: !model.novelReaderSurfaces.isEmpty,
            hasInitialLoadError: model.errorMessage != nil,
            isApplyingAppearanceSettings: model.isApplyingAppearanceSettings,
            isNavigatingNovelReaderProjection: model.isNavigatingNovelReaderProjection,
            shouldConcealViewportContent: verticalRestore.verticalRestoreController.shouldConcealViewportContent
        )
    }

    private var readerLoadingOverlay: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                ProgressView(L10n.string("common.loading"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func verticalBoundaryPullOverlayLayer(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            verticalBoundaryPullOverlay(
                direction: .previous,
                topInset: topInset,
                bottomInset: bottomInset
            )

            Spacer(minLength: 0)

            verticalBoundaryPullOverlay(
                direction: .next,
                topInset: topInset,
                bottomInset: bottomInset
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func verticalBoundaryPullOverlay(
        direction: NovelReaderVerticalBoundaryDirection,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        if verticalBoundaryPullState.direction == direction,
           canNavigateVerticalBoundary(direction) {
            let progress = min(max(verticalBoundaryPullState.distance / NovelReaderVerticalScrollCoordinator.boundaryTriggerDistance, 0), 1)
            NovelReaderVerticalBoundaryPullBadge(
                text: verticalBoundaryPullText(for: direction, isArmed: verticalBoundaryPullState.isArmed),
                systemImage: direction == .next ? "arrow.down.circle" : "arrow.up.circle",
                progress: progress,
                isArmed: verticalBoundaryPullState.isArmed
            )
            .padding(.top, direction == .previous ? verticalBoundaryPullTopPadding(topInset: topInset) : 0)
            .padding(.bottom, direction == .next ? verticalBoundaryPullBottomPadding(bottomInset: bottomInset) : 0)
            .opacity(0.45 + 0.55 * progress)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.96))
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func verticalBoundaryPullTopPadding(topInset: CGFloat) -> CGFloat {
        verticalBands.boundaryPullTopPadding(
            topInset: topInset,
            isChromeVisible: chromeState.showsChrome,
            measuredTopChromeHeight: topChromeHeight
        )
    }

    private func verticalBoundaryPullBottomPadding(bottomInset: CGFloat) -> CGFloat {
        verticalBands.boundaryPullBottomPadding(
            bottomInset: bottomInset,
            isChromeVisible: chromeState.showsChrome,
            measuredBottomChromeHeight: bottomChromeHeight
        )
    }

    private func verticalBoundaryPullText(
        for direction: NovelReaderVerticalBoundaryDirection,
        isArmed: Bool
    ) -> String {
        switch (direction, isArmed) {
        case (.previous, false):
            return L10n.string("reader.pull_previous_web_page")
        case (.previous, true):
            return L10n.string("reader.release_previous_web_page")
        case (.next, false):
            return L10n.string("reader.pull_next_web_page")
        case (.next, true):
            return L10n.string("reader.release_next_web_page")
        }
    }

    private func readerLayout(proxy: GeometryProxy, topInset: CGFloat, bottomInset: CGFloat) -> NovelReaderLayout {
        let horizontalPadding = max(model.settings.horizontalPadding, 0)
        let safeAreaInsets = NovelReaderLayoutInsets(
            top: topInset,
            bottom: bottomInset
        )
        let contentInsets = NovelReaderLayoutInsets(
            top: model.settings.readingMode == .vertical ? 16 : 0,
            leading: horizontalPadding,
            bottom: model.settings.readingMode == .vertical ? 24 : 0,
            trailing: horizontalPadding
        )
        let chromeInsets = model.settings.readingMode == .paged
            ? NovelReaderLayoutInsets(
                top: verticalBands.pagedTopBandHeight,
                bottom: verticalBands.pagedContentBottomReserve(forBottomInset: bottomInset)
            )
            : .zero
        return NovelReaderLayout(
            containerSize: proxy.size,
            safeAreaInsets: safeAreaInsets,
            contentInsets: contentInsets,
            chromeInsets: chromeInsets,
            readingMode: model.settings.readingMode
        )
    }

    private func effectiveTopInset(_ rawTopInset: CGFloat) -> CGFloat {
        // Keep pagination based on the status-bar-visible safe area so immersive status bar changes
        // do not move text or alter rendered page counts.
        guard isPadDevice else { return rawTopInset }
        return verticalBands.padVisibleStatusBarTopInset
    }

    private func readerContentTopInset(for layoutTopInset: CGFloat, rawTopInset: CGFloat) -> CGFloat {
        guard isPadDevice else { return layoutTopInset }
        return rawTopInset > 0
            ? layoutTopInset
            : layoutTopInset + verticalBands.padVisibleStatusBarTopInset
    }

    private func readerPagedContentTopInset(for layoutTopInset: CGFloat) -> CGFloat {
        layoutTopInset
    }

    private func retryLoad() {
        chromeState.showChrome()
        Task { await model.loadCurrent(forceRefresh: false) }
    }

    private func refreshReader() {
        chromeState.showChrome()
        Task { await model.loadCurrent(forceRefresh: true) }
    }

    /// 打开原帖 layers the thread over the reader instead of dismissing it —
    /// closing the overlay drops straight back into the passage being read.
    private func openInForum() {
        forumThreadOverlayItem = ForumThreadOverlayItem(
            url: model.currentForumTargetURL,
            title: model.title
        )
    }

    // MARK: - Image taps and browser

    private func handleImageTap(url: URL, title: String?) {
        guard !chromeState.showsChrome else {
            enterImmersiveMode()
            return
        }
        openImageBrowser(url: url, title: title)
    }

    private func openImageBrowser(url: URL, title: String?) {
        imageBrowserItem = ImageBrowserItem(
            id: url.absoluteString,
            source: YamiboImageSource(
                url: url,
                refererPageURL: model.forumURL,
                offlineScope: model.inlineImageOfflineScope
            ),
            title: imageBrowserTitle(title),
        )
    }

    private func imageBrowserTitle(_ title: String?) -> String {
        let candidates = [
            title,
            model.currentChapterTitle,
            model.title,
            L10n.string("reader.inline_images")
        ]
        return candidates.compactMap { candidate in
            let normalized = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalized.isEmpty ? nil : normalized
        }.first ?? L10n.string("reader.inline_images")
    }

    private func closeReader() {
        chromeState.showChrome()
        guard !isDismissing else { return }
        isDismissing = true
        syncVerticalViewportBeforeSave()
        Task {
            await model.saveProgress()
            appModel.dismissNovelReader()
        }
    }

    // MARK: - Chrome state and control events

    private func toggleChrome() {
        guard !model.novelReaderSurfaces.isEmpty else { return }
        guard !hasPresentedOverlay else { return }
        withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
            chromeState.toggleChrome()
        }
    }

    private func handleControlEvent(_ event: ReaderControlEvent) {
        guard !isDismissing, !hasPresentedOverlay else { return }
        guard !model.novelReaderSurfaces.isEmpty, !readerLoadingOverlayPresentation.isPresented else {
            // Loading/error: Menu still flips the chrome state so a
            // controller user keeps an escape hatch wherever chrome renders.
            if event == .menu {
                withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
                    chromeState.toggleChrome()
                }
            }
            return
        }

        let surface: ReaderControlSurface = model.settings.readingMode == .paged
            ? .paged(isRightToLeft: model.settings.pageTurnDirection == .rightToLeft)
            : .vertical
        guard let command = ReaderControlCommandResolver.readerCommand(for: event, surface: surface) else { return }

        switch command {
        case .toggleChrome:
            toggleChrome()
        case .openComments:
            openChapterComments()
        case let .turnPage(delta):
            hideChromeForControlReading()
            Task { await goRelativePage(delta, pagerIdentity: controlPagedPagerIdentity) }
        case let .scrollStep(direction):
            hideChromeForControlReading()
            performControlVerticalScrollStep(direction)
        }
    }

    /// A page turn while the chrome is up means "keep reading": perform it
    /// and tuck the chrome away, mirroring the tap-zone mental model.
    private func hideChromeForControlReading() {
        guard chromeState.showsChrome else { return }
        withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
            chromeState.hideChrome()
        }
    }

    private func performControlVerticalScrollStep(_ direction: ReaderControlScrollDirection) {
        cancelVerticalRestoreForUserScroll()
        switch verticalScrollCoordinator.performControlScrollStep(direction) {
        case .scrolled, .unavailable:
            break
        case .atEdge:
            // Pressed while already clamped: cross to the adjacent web page
            // through the same linear path as the touch boundary pull.
            Task {
                await handleVerticalBoundaryPullRelease(direction == .down ? .next : .previous)
            }
        }
    }

    private func enterImmersiveMode() {
        guard !model.novelReaderSurfaces.isEmpty else { return }
        guard !hasPresentedOverlay else { return }
        withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
            chromeState.hideChrome()
        }
    }

    // MARK: - Tap routing

    private func handlePagedContentTap(
        pageDelta: Int? = nil,
        pagerIdentity: ReaderPagedPagerIdentity? = nil
    ) {
        guard !chromeState.showsChrome else {
            enterImmersiveMode()
            return
        }

        if let pageDelta {
            Task { await goRelativePage(pageDelta, pagerIdentity: pagerIdentity) }
        } else {
            toggleChrome()
        }
    }

    private func handlePagedTapZone(_ zone: ReaderPagedTapZone, pagerIdentity: ReaderPagedPagerIdentity) {
        switch zone {
        case .previous:
            handlePagedContentTap(pageDelta: -1, pagerIdentity: pagerIdentity)
        case .toggleChrome:
            handlePagedContentTap()
        case .next:
            handlePagedContentTap(pageDelta: 1, pagerIdentity: pagerIdentity)
        }
    }

    private func handleVerticalTap() {
        guard !model.novelReaderSurfaces.isEmpty else { return }
        let now = CACurrentMediaTime()
        if now <= verticalTapSuppressionUntil {
            verticalTapSuppressionUntil = now + 0.35
            _ = verticalScrollCoordinator.interruptScrollingIfNeeded()
            return
        }
        if verticalScrollCoordinator.shouldSuppressChromeToggle() {
            return
        }
        if verticalScrollCoordinator.interruptScrollingIfNeeded() {
            verticalTapSuppressionUntil = now + 0.35
            return
        }
        toggleChrome()
    }

    private var verticalScrollSuppressionGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                cancelVerticalRestoreForUserScroll()
                verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
            }
            .onEnded { _ in
                verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
            }
    }

    private func openChapterDrawer() {
        initialReaderLibraryTab = .chapters
        presentedSheet = .annotations
    }

    private func openChapterComments() {
        chapterCommentsTarget = model.currentChapterCommentTarget
        presentedSheet = .chapterComments
    }

    private func openSettings() {
        presentedSheet = .settings
    }

    private func openCachePanel() {
        if model.cache.hasOperationSession {
            model.cache.showProgressIfRunning()
            presentedSheet = .cacheProgress
        } else {
            presentedSheet = .cachePanel
        }
    }

    private func openAnnotations() {
        initialReaderLibraryTab = ReaderLibraryPanelTab(
            annotationSegment: annotationSegmentBinding.wrappedValue
        )
        presentedSheet = .annotations
    }

    // MARK: - Bookmarks

    private var annotationSegmentBinding: Binding<ReaderAnnotationSegment> {
        Binding(
            get: { rememberedAnnotationSegment ?? annotationCapsule.initialSegment(remembering: nil) },
            set: { rememberedAnnotationSegment = $0 }
        )
    }

    /// The position the bookmark button marks: whatever the viewport is
    /// showing right now. Returns nil on content the reader cannot give a
    /// semantic position to (the same A3 gate that hides 加入喜欢), in which
    /// case the button is a no-op rather than writing a bookmark that could
    /// never be resolved back.
    private func currentBookmarkAnchor() -> NovelBookmarkAnchor? {
        guard let resumePoint = model.currentNovelResumePoint else { return nil }
        return NovelBookmarkAnchor(
            chapterIdentity: resumePoint.chapterIdentity,
            textSegmentIdentity: resumePoint.textSegmentIdentity,
            displayedTextOffset: resumePoint.displayedTextOffset,
            view: resumePoint.view,
            chapterOrdinal: resumePoint.chapterOrdinal,
            chapterTitle: resumePoint.chapterTitle,
            resolvedAuthorID: resumePoint.authorID
        )
    }

    /// Paged swipes update the reader model outside the button actions, so
    /// the glyph must follow that new viewport position too.
    private func handlePagedViewportSelection(_ selectionIndex: Int) {
        model.selectPagedViewportIndex(selectionIndex)
        Task { await self.refreshCurrentPositionBookmarkState() }
    }

    private func toggleBookmarkAtCurrentPosition() {
        // In vertical mode the committed viewport sample lags the scroll by up
        // to ~100 ms; without this the bookmark can land a screen behind.
        syncVerticalViewportBeforeSave()
        guard let anchor = currentBookmarkAnchor() else { return }
        let snapshot = model.previewText(
            translationMode: model.settings.translationMode,
            characterCount: Self.bookmarkExcerptCharacterCount,
            fallback: ""
        )
        likeFeedbackGenerator.prepare()
        Task {
            guard let outcome = try? await dependencies.like.bookmarkStore.toggle(
                workKey: .novel(threadID: model.context.threadID),
                anchor: .novel(anchor),
                excerptText: snapshot.isEmpty ? nil : snapshot
            ) else {
                return
            }
            if currentBookmarkAnchor() == anchor {
                isCurrentPositionBookmarked = outcome.isBookmarked
            }
            likeFeedbackGenerator.notificationOccurred(.success)
            await refreshAnnotationState()
        }
    }

    private static let bookmarkExcerptCharacterCount = 40

    /// Sharpens stored annotations' book-order keys with the chapter positions
    /// this page's layout just revealed.
    ///
    /// Lazy rather than eager: the key is derived from the anchor, and the only
    /// part the anchor cannot carry — where a post sits on its forum page — is
    /// knowable exactly when the reader lays that page out. Rows the user never
    /// revisits keep their approximate key, which is already correct except
    /// among several posts sharing one page.
    private func resolveAnnotationSortKeys() async {
        let ordinals = model.currentChapterOrdinalsByIdentity
        guard !ordinals.isEmpty else { return }
        await dependencies.like.likeStore.resolveChapterOrdinals(
            ordinals,
            for: .novel(threadID: model.context.threadID)
        )
    }

    private func refreshAnnotationState() async {
        let workKey = LikeWorkKey.novel(threadID: model.context.threadID)
        let bookmarkCount = await dependencies.like.bookmarkStore.count(for: workKey)
        let likeCount = await dependencies.like.likeStore.likes(for: workKey).count
        annotationCapsule = ReaderAnnotationCapsulePresentation(
            bookmarkCount: bookmarkCount,
            likeCount: likeCount
        )
        await refreshCurrentPositionBookmarkState()
    }

    /// Refreshes only the position-specific glyph. A location change can
    /// happen while the store query is suspended (for example, while paging),
    /// so verify the anchor before applying the answer from the old query.
    private func refreshCurrentPositionBookmarkState() async {
        guard let anchor = currentBookmarkAnchor() else {
            isCurrentPositionBookmarked = false
            return
        }
        let workKey = LikeWorkKey.novel(threadID: model.context.threadID)
        let isBookmarked = await dependencies.like.bookmarkStore
            .bookmark(marking: .novel(anchor), in: workKey) != nil
        guard currentBookmarkAnchor() == anchor else { return }
        isCurrentPositionBookmarked = isBookmarked
    }

    private func handleBookmarkOpen(_ item: BookmarkItem) {
        guard case let .novel(anchor) = item.anchor else { return }
        Task { await jumpToAnnotationAnchor(resumePoint(forBookmarkAnchor: anchor)) }
    }

    private func resumePoint(forBookmarkAnchor anchor: NovelBookmarkAnchor) -> NovelResumePoint {
        NovelResumePoint(
            view: anchor.view,
            chapterIdentity: anchor.chapterIdentity,
            textSegmentIdentity: anchor.textSegmentIdentity,
            displayedTextOffset: anchor.displayedTextOffset,
            chapterOrdinal: anchor.chapterOrdinal,
            chapterTitle: anchor.chapterTitle,
            segmentProgress: 0,
            authorID: anchor.resolvedAuthorID,
            readingModeHint: model.settings.readingMode
        )
    }

    // MARK: - Like capture

    private func configureLikeCapture() {
        novelTextSelectionController.configureNoteEditor { item in
            presentedSheet = .note(item)
        }
        novelTextSelectionController.configureLikeCapture(
            workKey: .novel(threadID: model.context.threadID),
            service: NovelTextLikeCaptureService(likeStore: dependencies.like.likeStore),
            onLikeActionVisible: {
                likeFeedbackGenerator.prepare()
            },
            onCaptured: { outcome in
                // Paint the highlight and fire the haptic on the same tick.
                switch outcome {
                case .added(let item), .merged(let item), .alreadyLiked(let item):
                    likeHighlightController.applyCapturedItem(item)
                    // Nothing pops up afterwards on purpose: the style row is
                    // now the way in to capturing at all, so the colour was
                    // already chosen on the way here and there is nothing left
                    // to ask. Tapping the annotation reopens the menu.
                }
                likeFeedbackGenerator.notificationOccurred(.success)
                Task { await refreshAnnotationState() }
            }
        )
    }

    private func handleImageLongPress(_ anchor: NovelImageLikeAnchor, imageURL: URL) {
        // The async capture below gives the Taptic Engine time to spin up
        // before the success haptic fires.
        likeFeedbackGenerator.prepare()
        let workKey = LikeWorkKey.novel(threadID: model.context.threadID)
        let likeStore = dependencies.like.likeStore
        let likeImageStore = dependencies.like.likeImageStore
        let refererURL = model.forumURL
        let offlineScope = model.inlineImageOfflineScope
        Task {
            let existing = await likeStore.likes(for: workKey)
            if let liked = existing.first(where: { $0.kind == .image && $0.anchor == .novelImage(anchor) }) {
                try? await likeStore.delete(id: liked.id)
                try? await likeImageStore.delete(id: liked.id)
                likeFeedbackGenerator.notificationOccurred(.success)
                return
            }
            let service = NovelImageLikeCaptureService(likeStore: likeStore, likeImageStore: likeImageStore)
            guard (try? await service.like(
                workKey: workKey,
                anchor: anchor,
                sourceImageURL: imageURL,
                imageData: {
                    try await YamiboImagePipeline.shared.data(for: YamiboImageSource(
                        url: imageURL,
                        refererPageURL: refererURL,
                        offlineScope: offlineScope
                    ))
                }
            )) != nil else {
                return
            }
            likeFeedbackGenerator.notificationOccurred(.success)
        }
    }

    private func loadLikedNovelImageAnchors() async {
        let workKey = LikeWorkKey.novel(threadID: model.context.threadID)
        let items = await dependencies.like.likeStore.likes(for: workKey)
        likedNovelImageAnchors = Set(items.compactMap { item -> NovelImageLikeAnchor? in
            guard item.kind == .image, case let .novelImage(anchor) = item.anchor else { return nil }
            return anchor
        })
    }

    private func handleLikeAnchorOpen(_ payload: LikeAnchorPayload) {
        // Was `showingLikes = false`, which could only ever dismiss the likes
        // sheet; the guard keeps that per-sheet scoping now that a single
        // enum drives all boolean-style sheets.
        if presentedSheet == .annotations {
            presentedSheet = nil
        }
        switch payload {
        case let .novelText(anchor):
            Task { await jumpToAnnotationAnchor(resumePoint(forTextLikeAnchor: anchor)) }
        case let .novelImage(anchor):
            Task { await jumpToAnnotationAnchor(resumePoint(forImageLikeAnchor: anchor)) }
        case .mangaImage:
            break
        }
    }

    /// Same-document annotation jumps keep their layout generation. The
    /// vertical UIKit viewport needs an explicit scroll request for that
    /// path; paged mode simply no-ops here.
    private func jumpToAnnotationAnchor(_ resumePoint: NovelResumePoint) async {
        let didJump = await NovelReaderAnnotationJump(
            model: model,
            requestVerticalRestore: { restoreVerticalPositionIfNeeded() }
        ).perform(resumePoint)
        if didJump {
            await refreshCurrentPositionBookmarkState()
        }
    }

    // NovelTextLikeAnchor/NovelImageLikeAnchor carry `view` (the forum page
    // the excerpt/image came from) directly, but not the other cosmetic
    // resume-point fields (chapterOrdinal/segmentProgress/readingModeHint);
    // this synthesizes a best-effort resume point from what the anchor does
    // carry.
    private func resumePoint(forTextLikeAnchor anchor: NovelTextLikeAnchor) -> NovelResumePoint {
        NovelResumePoint(
            view: anchor.view,
            chapterIdentity: anchor.chapterIdentity,
            textSegmentIdentity: anchor.startSegmentIdentity,
            displayedTextOffset: anchor.start.offset,
            chapterOrdinal: 0,
            segmentProgress: 0,
            authorID: anchor.resolvedAuthorID,
            readingModeHint: model.settings.readingMode
        )
    }

    private func resumePoint(forImageLikeAnchor anchor: NovelImageLikeAnchor) -> NovelResumePoint {
        NovelResumePoint(
            view: anchor.view,
            chapterIdentity: anchor.chapterIdentity,
            textSegmentIdentity: NovelTextSegmentIdentity(rawValue: anchor.imageSegmentIdentity),
            displayedTextOffset: 0,
            chapterOrdinal: 0,
            segmentProgress: 0,
            authorID: anchor.resolvedAuthorID,
            readingModeHint: model.settings.readingMode
        )
    }

    private func updateChromeForContentState() {
        let previousState = chromeState
        var nextState = chromeState
        nextState.update(
            isLoading: model.isLoading,
            errorMessage: model.errorMessage,
            hasPages: !model.novelReaderSurfaces.isEmpty,
            hasPresentedOverlay: hasChromePresentedOverlay,
            usesVerticalReadingMode: model.settings.readingMode == .vertical
        )
        if previousState != nextState {
            withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
                chromeState = nextState
            }
        } else {
            chromeState = nextState
        }

        verticalRestore.synchronizePositioningFingerprintWithContentState(model: model)
    }

    // MARK: - Vertical position persistence and restore
    // Thin forwarders into `NovelReaderVerticalRestoreCoordinator`; kept so
    // the many call sites across the view read the same as before the move.

    private func restoreVerticalPositionIfNeeded() {
        verticalRestore.restoreVerticalPositionIfNeeded(
            model: model,
            scrollCoordinator: verticalScrollCoordinator
        )
    }

    private func commitProgressSlider(_ targetIndex: Int) {
        model.jumpToSurface(targetIndex)
        restoreVerticalPositionIfNeeded()
        Task { await refreshCurrentPositionBookmarkState() }
    }

    private func jumpAdjacentChapter(_ delta: Int) {
        model.jumpToAdjacentChapter(delta)
        restoreVerticalPositionIfNeeded()
        Task { await refreshCurrentPositionBookmarkState() }
    }

    // MARK: - Navigation intents

    private func jumpToChapter(_ chapter: NovelReaderChapter) {
        model.jumpToChapter(chapter)
        restoreVerticalPositionIfNeeded()
        Task { await refreshCurrentPositionBookmarkState() }
    }

    private func jumpToChapterDirectoryChapter(_ chapter: NovelReaderChapter) async {
        await model.navigation.jumpToChapterDirectoryChapter(chapter)
        restoreVerticalPositionIfNeeded()
        await refreshCurrentPositionBookmarkState()
    }

    private func jumpToWebView(_ view: Int) async {
        await jumpToWebView(view, preferredSurfaceOrdinal: 0)
    }

    private func jumpToWebView(_ view: Int, preferredSurfaceOrdinal: Int) async {
        chromeState.showChrome()
        await model.jumpToWebView(view, preferredSurfaceOrdinal: preferredSurfaceOrdinal)
        restoreVerticalPositionIfNeeded()
        await refreshCurrentPositionBookmarkState()
    }

    private func navigateBackFromChrome() async {
        await model.navigation.navigateBack()
        restoreVerticalPositionIfNeeded()
        await refreshCurrentPositionBookmarkState()
    }

    private func navigateForwardFromChrome() async {
        await model.navigation.navigateForward()
        restoreVerticalPositionIfNeeded()
        await refreshCurrentPositionBookmarkState()
    }

    private func goRelativePage(_ delta: Int) async {
        pagedScrollAnimationRequest = nil
        await model.jumpRelativeSurface(delta)
        restoreVerticalPositionIfNeeded()
        await refreshCurrentPositionBookmarkState()
    }

    private func goRelativePage(_ delta: Int, pagerIdentity: ReaderPagedPagerIdentity?) async {
        let animationRequest = pagerIdentity.flatMap {
            makePagedScrollAnimationRequest(delta: delta, pagerIdentity: $0)
        }
        pagedScrollAnimationRequest = animationRequest
        await model.jumpRelativeSurface(delta)
        if let request = pagedScrollAnimationRequest,
           request.selectionIndex != model.pagedViewportSelectionIndex {
            pagedScrollAnimationRequest = nil
        }
        restoreVerticalPositionIfNeeded()
        await refreshCurrentPositionBookmarkState()
    }

    private func makePagedScrollAnimationRequest(
        delta: Int,
        pagerIdentity: ReaderPagedPagerIdentity
    ) -> ReaderPagedScrollAnimationRequest? {
        guard model.settings.readingMode == .paged else { return nil }
        let targetSelectionIndex = model.pagedViewportSelectionIndex + delta
        let selectionCount = model.isTwoPageSpreadActive
            ? model.presentationSpreads.count
            : model.novelReaderSurfaces.count
        guard targetSelectionIndex >= 0, targetSelectionIndex < selectionCount else {
            return nil
        }
        return ReaderPagedScrollAnimationRequest(
            pagerIdentity: pagerIdentity,
            selectionIndex: targetSelectionIndex
        )
    }

    private func clearPagedScrollAnimationRequest(_ request: ReaderPagedScrollAnimationRequest) {
        guard pagedScrollAnimationRequest == request else { return }
        pagedScrollAnimationRequest = nil
    }

    private func canNavigatePagedBoundary(delta: Int) -> Bool {
        guard model.settings.readingMode == .paged, !model.novelReaderSurfaces.isEmpty else { return false }
        if delta < 0 {
            return model.visibleView > 1
        }
        if delta > 0 {
            return model.visibleView < model.maxView
        }
        return false
    }

    private func canNavigateVerticalBoundary(_ direction: NovelReaderVerticalBoundaryDirection) -> Bool {
        guard model.settings.readingMode == .vertical, !model.novelReaderSurfaces.isEmpty else { return false }
        switch direction {
        case .previous:
            return model.visibleView > 1
        case .next:
            return model.visibleView < model.maxView
        }
    }

    private func updateVerticalBoundaryPullState(_ state: NovelReaderVerticalBoundaryPullState) {
        guard let direction = state.direction,
              canNavigateVerticalBoundary(direction) else {
            if verticalBoundaryPullState != .idle {
                withAnimation(.easeInOut(duration: 0.12)) {
                    verticalBoundaryPullState = .idle
                }
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.12)) {
            verticalBoundaryPullState = state
        }
    }

    private func handleVerticalBoundaryPullRelease(_ direction: NovelReaderVerticalBoundaryDirection) async {
        guard canNavigateVerticalBoundary(direction), !isHandlingVerticalBoundaryPull else { return }
        isHandlingVerticalBoundaryPull = true
        verticalBoundaryPullState = .idle
        cancelVerticalRestoreForUserScroll()
        switch direction {
        case .previous:
            await jumpToWebView(model.visibleView - 1, preferredSurfaceOrdinal: .max)
        case .next:
            await jumpToWebView(model.visibleView + 1, preferredSurfaceOrdinal: 0)
        }
        isHandlingVerticalBoundaryPull = false
    }

    private var hasPresentedOverlay: Bool {
        presentedSheet != nil ||
            forumThreadOverlayItem != nil ||
            imageBrowserItem != nil
    }

    /// Deliberately excludes `imageBrowserItem`: the image browser overlays
    /// the reader without forcing the chrome back on.
    private var hasChromePresentedOverlay: Bool {
        presentedSheet != nil ||
            forumThreadOverlayItem != nil
    }

    private var canReceiveApplePencilPageTurn: Bool {
        ReaderApplePencilPageTurnGate.canTurnPage(
            isPadDevice: isPadDevice,
            isPagedReadingMode: model.settings.readingMode == .paged,
            hasReadableContent: !model.novelReaderSurfaces.isEmpty,
            hasBlockingOverlay: hasPresentedOverlay,
            isDismissing: isDismissing,
            isChromeVisible: chromeState.showsChrome
        )
    }

    private func beginVerticalProgressScrub() {
        guard !isVerticalProgressScrubbing else { return }
        isVerticalProgressScrubbing = true
        verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
    }

    private func commitVerticalProgressScrub(_ target: Int) {
        model.jumpToSurface(target)
        restoreVerticalPositionIfNeeded()
        Task { await refreshCurrentPositionBookmarkState() }
        verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
    }

    private func endVerticalProgressScrub() {
        guard isVerticalProgressScrubbing else { return }
        isVerticalProgressScrubbing = false
        verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
    }

    private func syncVerticalViewportBeforeSave() {
        verticalRestore.syncVerticalViewportBeforeSave(
            model: model,
            scrollCoordinator: verticalScrollCoordinator
        )
    }

    private func cancelVerticalRestoreForUserScroll() {
        verticalRestore.cancelVerticalRestoreForUserScroll()
    }

    /// The vertical band definitions shared by pagination, the paged
    /// viewports and the chrome; see `NovelReaderVerticalBandsPresentation`.
    private var verticalBands: NovelReaderVerticalBandsPresentation {
        NovelReaderVerticalBandsPresentation()
    }
}

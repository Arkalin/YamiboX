import SwiftUI
import YamiboXCore
import UIKit

public struct NovelReaderView: View {
    @StateObject private var model: NovelReaderViewModel
    @State private var verticalScrollCoordinator = NovelReaderVerticalScrollCoordinator()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSettings = false
    @State private var showingCachePanel = false
    @State private var showingCacheProgress = false
    @State private var showingChapterSheet = false
    @State private var showingChapterComments = false
    @State private var forumThreadOverlayItem: ForumThreadOverlayItem?
    @State private var imageBrowserItem: ImageBrowserItem?
    @State private var chapterCommentsTarget: ReaderChapterCommentTarget?
    @State private var chromeState = NovelReaderChromeState()
    @State private var verticalScrollRequest: NovelReaderVerticalScrollRequest?
    @State private var verticalScrollRequestCommandID: UInt64 = 0
    @State private var verticalRestoreController = ReaderVerticalRestoreController()
    @State private var verticalRestoreRetryTask: Task<Void, Never>?
    @State private var verticalViewportPositionUpdateTask: Task<Void, Never>?
    @State private var verticalViewportSampling = NovelReaderVerticalViewportSamplingBox()
    @State private var lastVerticalPositioningFingerprint: NovelReaderVerticalPositioningFingerprint?
    @State private var isVerticalProgressScrubbing = false
    @State private var verticalTapSuppressionUntil: CFTimeInterval = 0
    @State private var verticalBoundaryPullState = NovelReaderVerticalBoundaryPullState.idle
    @State private var isHandlingVerticalBoundaryPull = false
    @State private var isDismissing = false
    @State private var topChromeHeight: CGFloat = 0
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var pagedScrollAnimationRequest: ReaderPagedScrollAnimationRequest?
    @State private var novelTextSelectionController = NovelTextSelectionController()
    @State private var likeHighlightController = NovelLikeHighlightController()
    @State private var likedNovelImageAnchors: Set<NovelImageLikeAnchor> = []
    @State private var showingLikes = false
    @State private var likeFeedbackGenerator = UINotificationFeedbackGenerator()
    @State private var controlHandlerToken: UUID?
    @State private var controlPagedPagerIdentity: ReaderPagedPagerIdentity?
    private let appModel: YamiboAppModel
    private let dependencies: NovelReaderDependencies

    public init(context: NovelLaunchContext, dependencies: NovelReaderDependencies, appModel: YamiboAppModel) {
        let initialSettings = appModel.bootstrapState?.settings.novelReader
        _model = StateObject(wrappedValue: NovelReaderViewModel(
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

                if let sourceStatusText = model.sourceStatusText,
                   !model.novelReaderSurfaces.isEmpty {
                    VStack(spacing: 0) {
                        NovelReaderOfflineFallbackBanner(
                            message: sourceStatusText,
                            retry: refreshReader
                        )
                        .padding(.top, topInset + (chromeState.showsChrome ? topChromeHeight + 6 : 12))
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
                        onShowLikes: openLikes,
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
            .onReceive(NotificationCenter.default.publisher(for: LikeStore.didChangeNotification)) { notification in
                guard let changeID = notification.userInfo?[LikeStore.changeIDUserInfoKey] as? String,
                      changeID == dependencies.like.likeStore.changeID else {
                    return
                }
                Task { await loadLikedNovelImageAnchors() }
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
                verticalRestoreRetryTask?.cancel()
                verticalViewportPositionUpdateTask?.cancel()
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
            showingSettings: $showingSettings,
            showingCachePanel: $showingCachePanel,
            showingCacheProgress: $showingCacheProgress,
            showingChapterSheet: $showingChapterSheet,
            showingChapterComments: $showingChapterComments,
            showingLikes: $showingLikes,
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
            }
        )
    }

    private func readerStateObserverModifier() -> NovelReaderStateObserverModifier {
        NovelReaderStateObserverModifier(
            model: model,
            showingSettings: $showingSettings,
            showingCachePanel: $showingCachePanel,
            showingCacheProgress: $showingCacheProgress,
            showingChapterSheet: $showingChapterSheet,
            showingChapterComments: $showingChapterComments,
            showingLikes: $showingLikes,
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
            onSelectionChange: { selectionIndex in
                model.selectPagedViewportIndex(selectionIndex)
            },
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
            } else if model.isTwoPageSpreadActive {
                NovelReaderPresentationSpreadCollectionViewport(
                    spreads: model.presentationSpreads,
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
            } else {
                NovelReaderPagedCollectionViewport(
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
            scrollRequest: verticalScrollRequest,
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
                guard verticalRestoreController.scrollingRequest == request else {
                    if verticalScrollRequest == request {
                        verticalScrollRequest = nil
                    }
                    return
                }
                verticalScrollRequest = nil
                if request.textAnchor != nil {
                    verticalRestoreController.beginSettling(request, now: CACurrentMediaTime())
                    verticalRestoreRetryTask?.cancel()
                    verticalRestoreRetryTask = nil
                    return
                }
                tryAdvanceVerticalRestore()
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
                        tryAdvanceVerticalRestore()
                        applyVerticalViewportPositionUpdate(for: .viewportGeometryChanged)
                    }
                }
                verticalScrollCoordinator.onBoundaryPullStateChange = { state in
                    Task { @MainActor in
                        updateVerticalBoundaryPullState(state)
                    }
                }
            },
            onSurfaceFramesChange: { frames in
                guard verticalViewportSampling.surfaceFrames != frames else { return }
                verticalViewportSampling.surfaceFrames = frames
                tryAdvanceVerticalRestore()
                applyVerticalViewportPositionUpdate(for: .viewportGeometryChanged)
            },
            onTextViewportSampleChange: { sample in
                guard verticalViewportSampling.textViewportSample != sample else { return }
                verticalViewportSampling.textViewportSample = sample
                applyVerticalViewportPositionUpdate(for: .textViewportSampleChanged)
            },
            onViewportChange: {
                applyVerticalViewportPositionUpdate(for: .viewportGeometryChanged)
            },
            onScrollSettled: {
                updateVerticalViewportPosition()
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
            shouldConcealViewportContent: verticalRestoreController.shouldConcealViewportContent
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
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func verticalBoundaryPullTopPadding(topInset: CGFloat) -> CGFloat {
        let chromeAvoidance = chromeState.showsChrome ? max(topChromeHeight, topInset + 140) : 0
        return max(chromeAvoidance, topInset, 24) + 8
    }

    private func verticalBoundaryPullBottomPadding(bottomInset: CGFloat) -> CGFloat {
        let chromeAvoidance = chromeState.showsChrome ? max(bottomChromeHeight, bottomInset + 210) + 55 : 0
        return max(chromeAvoidance, bottomInset, 24) + 8
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
            ? NovelReaderLayoutInsets(top: 48)
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
        return readerPadVisibleStatusBarTopInset
    }

    private func readerContentTopInset(for layoutTopInset: CGFloat, rawTopInset: CGFloat) -> CGFloat {
        guard isPadDevice else { return layoutTopInset }
        return rawTopInset > 0
            ? layoutTopInset
            : layoutTopInset + readerPadVisibleStatusBarTopInset
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
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeState.toggleChrome()
        }
    }

    private func handleControlEvent(_ event: ReaderControlEvent) {
        guard !isDismissing, !hasPresentedOverlay else { return }
        guard !model.novelReaderSurfaces.isEmpty, !readerLoadingOverlayPresentation.isPresented else {
            // Loading/error: Menu still flips the chrome state so a
            // controller user keeps an escape hatch wherever chrome renders.
            if event == .menu {
                withAnimation(.easeInOut(duration: 0.2)) {
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
        withAnimation(.easeInOut(duration: 0.2)) {
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
        withAnimation(.easeInOut(duration: 0.2)) {
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
        showingChapterSheet = true
    }

    private func openChapterComments() {
        chapterCommentsTarget = model.currentChapterCommentTarget
        showingChapterComments = true
    }

    private func openSettings() {
        showingSettings = true
    }

    private func openCachePanel() {
        if model.cache.hasOperationSession {
            model.cache.showProgressIfRunning()
            showingCacheProgress = true
        } else {
            showingCachePanel = true
        }
    }

    private func openLikes() {
        showingLikes = true
    }

    // MARK: - Like capture

    private func configureLikeCapture() {
        novelTextSelectionController.configureLikeCapture(
            workKey: .novel(threadID: model.context.threadID),
            service: NovelTextLikeCaptureService(likeStore: dependencies.like.likeStore),
            onCaptured: { _ in
                likeFeedbackGenerator.notificationOccurred(.success)
            }
        )
    }

    private func handleImageLongPress(_ anchor: NovelImageLikeAnchor, imageURL: URL) {
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
        showingLikes = false
        switch payload {
        case let .novelText(anchor):
            Task { await model.jumpToLikeAnchor(resumePoint(forTextLikeAnchor: anchor)) }
        case let .novelImage(anchor):
            Task { await model.jumpToLikeAnchor(resumePoint(forImageLikeAnchor: anchor)) }
        case .mangaImage:
            break
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
            textSegmentIdentity: anchor.textSegmentIdentity,
            displayedTextOffset: anchor.range.location,
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
            withAnimation(.easeInOut(duration: 0.2)) {
                chromeState = nextState
            }
        } else {
            chromeState = nextState
        }

        if model.isLoading && model.novelReaderSurfaces.isEmpty {
            lastVerticalPositioningFingerprint = nil
            return
        }

        if model.errorMessage != nil && model.novelReaderSurfaces.isEmpty {
            lastVerticalPositioningFingerprint = nil
            return
        }

        guard !model.novelReaderSurfaces.isEmpty else {
            lastVerticalPositioningFingerprint = nil
            return
        }

        if currentVerticalPositioningFingerprint == nil {
            lastVerticalPositioningFingerprint = nil
        }
    }

    private var currentVerticalPositioningFingerprint: NovelReaderVerticalPositioningFingerprint? {
        guard model.settings.readingMode == .vertical,
              !model.novelReaderSurfaces.isEmpty,
              let generation = model.novelReaderPresentation?.generation else {
            return nil
        }
        return NovelReaderVerticalPositioningFingerprint(
            generation: generation,
            view: model.visibleView,
            surfaceCount: model.novelReaderSurfaces.count,
            surfaceIndex: model.selectedSurfaceIndex,
            intraSurfaceProgressBucket: Int((model.currentSurfaceIntraProgress * 1000).rounded()),
            readingMode: model.settings.readingMode
        )
    }

    // MARK: - Vertical position persistence and restore

    private func rememberCurrentVerticalPositioningFingerprint() {
        lastVerticalPositioningFingerprint = currentVerticalPositioningFingerprint
    }

    private func restoreVerticalPositionIfNeeded() {
        guard let fingerprint = currentVerticalPositioningFingerprint else {
            lastVerticalPositioningFingerprint = nil
            return
        }
        guard lastVerticalPositioningFingerprint != fingerprint else { return }
        lastVerticalPositioningFingerprint = fingerprint
        requestVerticalScrollToCurrentPage()
    }

    private func commitProgressSlider(_ targetIndex: Int) {
        model.jumpToSurface(targetIndex)
        restoreVerticalPositionIfNeeded()
    }

    private func jumpAdjacentChapter(_ delta: Int) {
        model.jumpToAdjacentChapter(delta)
        restoreVerticalPositionIfNeeded()
    }

    // MARK: - Navigation intents

    private func jumpToChapter(_ chapter: NovelReaderChapter) {
        model.jumpToChapter(chapter)
        restoreVerticalPositionIfNeeded()
    }

    private func jumpToChapterDirectoryChapter(_ chapter: NovelReaderChapter) async {
        await model.navigation.jumpToChapterDirectoryChapter(chapter)
        restoreVerticalPositionIfNeeded()
    }

    private func jumpToWebView(_ view: Int) async {
        await jumpToWebView(view, preferredSurfaceOrdinal: 0)
    }

    private func jumpToWebView(_ view: Int, preferredSurfaceOrdinal: Int) async {
        chromeState.showChrome()
        await model.jumpToWebView(view, preferredSurfaceOrdinal: preferredSurfaceOrdinal)
        restoreVerticalPositionIfNeeded()
    }

    private func navigateBackFromChrome() async {
        await model.navigation.navigateBack()
        restoreVerticalPositionIfNeeded()
    }

    private func navigateForwardFromChrome() async {
        await model.navigation.navigateForward()
        restoreVerticalPositionIfNeeded()
    }

    private func goRelativePage(_ delta: Int) async {
        pagedScrollAnimationRequest = nil
        await model.jumpRelativeSurface(delta)
        restoreVerticalPositionIfNeeded()
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
        showingSettings ||
            showingCachePanel ||
            showingCacheProgress ||
            showingChapterSheet ||
            showingChapterComments ||
            showingLikes ||
            forumThreadOverlayItem != nil ||
            imageBrowserItem != nil
    }

    private var hasChromePresentedOverlay: Bool {
        showingSettings ||
            showingCachePanel ||
            showingCacheProgress ||
            showingChapterSheet ||
            showingChapterComments ||
            showingLikes ||
            forumThreadOverlayItem != nil
    }

    private var canReceiveApplePencilPageTurn: Bool {
        isPadDevice &&
            model.settings.readingMode == .paged &&
            !model.novelReaderSurfaces.isEmpty &&
            !hasPresentedOverlay &&
            !isDismissing &&
            !chromeState.showsChrome
    }

    private func beginVerticalProgressScrub() {
        guard !isVerticalProgressScrubbing else { return }
        isVerticalProgressScrubbing = true
        verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
    }

    private func commitVerticalProgressScrub(_ target: Int) {
        model.jumpToSurface(target)
        restoreVerticalPositionIfNeeded()
        verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
    }

    private func endVerticalProgressScrub() {
        guard isVerticalProgressScrubbing else { return }
        isVerticalProgressScrubbing = false
        verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
    }

    private func makeVerticalScrollRequest() -> NovelReaderVerticalScrollRequest {
        let resumePoint = model.currentNovelResumePoint
        let textAnchor = resumePoint?.view == model.visibleView
            ? resumePoint.map(NovelReaderVerticalTextAnchor.init(position:))
            : nil
        verticalScrollRequestCommandID &+= 1
        let request = NovelReaderVerticalScrollRequest(
            commandID: verticalScrollRequestCommandID,
            view: model.visibleView,
            surfaceIndex: model.selectedSurfaceIndex,
            intraSurfaceProgress: model.currentSurfaceIntraProgress,
            textAnchor: textAnchor
        )
        return request
    }

    private func requestVerticalScrollToCurrentPage() {
        let request = makeVerticalScrollRequest()
        beginVerticalRestoreScrolling(for: request)
        verticalScrollRequest = request
        scheduleVerticalRestoreRetry(for: request)
    }

    private func updateVerticalViewportPosition() {
        guard model.settings.readingMode == .vertical else { return }
        guard verticalRestoreController.canSampleViewport(now: CACurrentMediaTime()) else {
            return
        }

        if let sample = verticalViewportSampling.textViewportSample {
            model.updateVerticalViewportPosition(sample: sample)
            rememberCurrentVerticalPositioningFingerprint()
        }
    }

    private func applyVerticalViewportPositionUpdate(for trigger: NovelReaderVerticalViewportPositionUpdateTiming.Trigger) {
        switch NovelReaderVerticalViewportPositionUpdateTiming.updateMode(for: trigger) {
        case .immediate:
            verticalViewportPositionUpdateTask?.cancel()
            verticalViewportPositionUpdateTask = nil
            updateVerticalViewportPosition()
        case .deferred:
            scheduleVerticalViewportPositionUpdate()
        }
    }

    private func scheduleVerticalViewportPositionUpdate() {
        verticalViewportPositionUpdateTask?.cancel()
        verticalViewportPositionUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                updateVerticalViewportPosition()
                verticalViewportPositionUpdateTask = nil
            }
        }
    }

    private func applyVerticalFineTune(for request: NovelReaderVerticalScrollRequest) {
        guard verticalRestoreController.scrollingRequest == request else {
            return
        }
        guard request.view == nil || request.view == model.visibleView else {
            return
        }
        if request.textAnchor != nil {
            return
        }
        guard let frame = currentVerticalSurfaceFrames[request.surfaceIndex] else {
            return
        }
        verticalRestoreController.beginFineTuning(request)
        guard verticalScrollCoordinator.restoreOffset(
            to: frame,
            intraSurfaceProgress: request.intraSurfaceProgress
        ) else {
            verticalRestoreController.beginScrolling(to: request)
            return
        }
        verticalRestoreController.beginSettling(request, now: CACurrentMediaTime())
        verticalRestoreRetryTask?.cancel()
        verticalRestoreRetryTask = nil
    }

    private func tryAdvanceVerticalRestore() {
        refreshVerticalRestorePhase()
        guard let request = verticalRestoreController.scrollingRequest else { return }
        guard request.view == nil || request.view == model.visibleView else {
            return
        }
        guard verticalScrollCoordinator.hasAttachedScrollView else {
            return
        }
        let frames = currentVerticalSurfaceFrames
        guard let frame = frames[request.surfaceIndex] else {
            return
        }
        guard frame.height > 0 else {
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1))
            applyVerticalFineTune(for: request)
        }
    }

    private func syncVerticalViewportBeforeSave() {
        guard model.settings.readingMode == .vertical else { return }
        tryAdvanceVerticalRestore()
        guard verticalRestoreController.canSampleViewport(now: CACurrentMediaTime()) else {
            return
        }
        updateVerticalViewportPosition()
    }

    private func beginVerticalRestoreScrolling(for request: NovelReaderVerticalScrollRequest) {
        verticalRestoreController.beginScrolling(to: request)
    }

    private var currentVerticalSurfaceFrames: [Int: CGRect] {
        verticalViewportSampling.surfaceFrames.compactMapValues { value in
            value.documentView == model.visibleView ? value.frame : nil
        }
    }

    private func refreshVerticalRestorePhase(now: CFTimeInterval = CACurrentMediaTime()) {
        verticalRestoreController.refresh(now: now)
    }

    private func cancelVerticalRestoreForUserScroll() {
        guard verticalRestoreController.activeRequest != nil else { return }
        verticalRestoreController.cancel(now: CACurrentMediaTime())
        verticalScrollRequest = nil
        verticalRestoreRetryTask?.cancel()
        verticalRestoreRetryTask = nil
    }

    private func reissueVerticalScrollRequest(_ request: NovelReaderVerticalScrollRequest) {
        guard verticalRestoreController.scrollingRequest == request else { return }
        verticalScrollRequest = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1))
            guard verticalRestoreController.scrollingRequest == request else { return }
            verticalScrollRequest = request
        }
    }

    private func scheduleVerticalRestoreRetry(for request: NovelReaderVerticalScrollRequest) {
        verticalRestoreRetryTask?.cancel()
        verticalRestoreRetryTask = Task {
            for attempt in 1 ... 10 {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard verticalRestoreController.scrollingRequest == request else { return }
                    tryAdvanceVerticalRestore()
                    if verticalRestoreController.scrollingRequest == request, attempt == 3 || attempt == 6 || attempt == 9 {
                        reissueVerticalScrollRequest(request)
                    }
                }
            }
        }
    }

    private var windowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets ?? .zero
    }
}

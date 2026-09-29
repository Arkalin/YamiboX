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
    @State private var chapterCommentsHasLaterChapter = false
    @State private var searchPresentation: NovelReaderSearchPresentation?
    @State private var chromeState = NovelReaderChromeState()
    @State private var isVerticalProgressScrubbing = false
    @State private var verticalTapSuppressionUntil: CFTimeInterval = 0
    @State private var verticalBoundaryPullState = NovelReaderVerticalBoundaryPullState.idle
    @State private var isHandlingVerticalBoundaryPull = false
    @State private var isDismissing = false
    /// Reader-session-scoped: once dismissed the banner stays gone until the
    /// reader is closed and reopened (this view is recreated).
    @State private var isOfflineBannerDismissed = false
    @State private var isFontBannerDismissed = false
    @State private var topChromeHeight: CGFloat = 0
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var pagedScrollAnimationRequest: ReaderPagedScrollAnimationRequest?
    @State private var annotations: NovelReaderAnnotationCoordinator
    @State private var searchHighlightController = NovelReaderSearchHighlightController()
    /// The directory entry always lands on Chapters, while the annotation
    /// entry preserves its bookmarks-or-likes destination.
    @State private var initialReaderLibraryTab: ReaderLibraryPanelTab = .bookmarks
    @State private var controlHandlerToken: UUID?
    @State private var controlPagedPagerIdentity: ReaderPagedPagerIdentity?
    /// Scene-local window safe-area insets reported by
    /// `ReaderWindowSafeAreaInsetsProbe`; nil until this reader attaches.
    @State private var windowSafeAreaInsets: UIEdgeInsets?
    private let appModel: YamiboAppModel
    private let dependencies: NovelReaderDependencies
    private let forumDependencies: ForumNavigationDependencies
    private let onClose: () -> Void
    private let onOpenOriginalPost: (URL, NovelLaunchContext) async -> Bool

    public init(
        context: NovelLaunchContext,
        dependencies: NovelReaderDependencies,
        forumDependencies: ForumNavigationDependencies,
        appModel: YamiboAppModel,
        onClose: (() -> Void)? = nil,
        onOpenOriginalPost: ((URL, NovelLaunchContext) async -> Bool)? = nil,
        onResumeRouteChange: ReaderResumeRouteChangeHandler? = nil
    ) {
        let initialSettings = appModel.bootstrapState?.settings.novelReader
        // `State(initialValue:)` evaluates its argument on every init (unlike
        // `StateObject(wrappedValue:)`'s autoclosure), so a view model is now
        // built — and, past the first init, discarded — on each parent
        // render. Accepted deliberately, mirroring `LocalFavoritesRootView`:
        // the init is side-effect-free, so the extra constructions are inert.
        let model = NovelReaderViewModel(
            context: context,
            dependencies: dependencies,
            initialSettings: initialSettings,
            fontLibrary: appModel.readerFontLibrary,
            imagePipeline: appModel.imagePipeline,
            onReaderResumeRouteChange: { route in
                if let onResumeRouteChange {
                    await onResumeRouteChange(route)
                } else {
                    appModel.updateReaderResumeRoute(route)
                }
            }
        )
        _model = State(initialValue: model)
        _annotations = State(initialValue: NovelReaderAnnotationCoordinator(
            model: model, dependencies: dependencies.like, imagePipeline: dependencies.imagePipeline
        ))
        _chromeState = State(initialValue: NovelReaderChromeState(
            showsChrome: initialSettings?.readingMode != .vertical
        ))
        self.appModel = appModel
        self.dependencies = dependencies
        self.forumDependencies = forumDependencies
        self.onClose = onClose ?? { appModel.dismissNovelReader() }
        self.onOpenOriginalPost = onOpenOriginalPost ?? { url, context in
            await appModel.switchReaderToOriginalPost(url: url, resumeRoute: .novel(context))
        }
    }

    private var isPadDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    public var body: some View {
        GeometryReader { proxy in
            let rawTopInset = max(proxy.safeAreaInsets.top, windowSafeAreaInsets?.top ?? proxy.safeAreaInsets.top)
            let topInset = effectiveTopInset(rawTopInset)
            let contentTopInset = model.settings.readingMode == .paged
                ? readerPagedContentTopInset(for: topInset)
                : readerContentTopInset(for: topInset, rawTopInset: rawTopInset)
            let bottomInset = max(proxy.safeAreaInsets.bottom, windowSafeAreaInsets?.bottom ?? proxy.safeAreaInsets.bottom)
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
                .ignoresSafeArea(.container, edges: model.settings.readingMode == .paged ? .vertical : .top)
                .transaction { transaction in
                    if model.settings.readingMode == .paged {
                        transaction.animation = nil
                    }
                }
                .opacity(loadingOverlayPresentation.isPresented ? 0 : 1)
                .allowsHitTesting(!loadingOverlayPresentation.isPresented)

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
                            details: model.offlineFailureDetails,
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

                if let warning = model.fontWarning, !isFontBannerDismissed,
                   chromeState.showsChrome, topChromeHeight > 0, model.sourceStatusText == nil {
                    VStack {
                        NovelReaderOfflineFallbackBanner(
                            message: warning, details: nil,
                            retryTitle: L10n.string("reader.font.library"), retrySystemName: "textformat",
                            retry: openSettings,
                            dismiss: { isFontBannerDismissed = true }
                        )
                        .padding(.top, topInset + topChromeHeight + 6)
                        .padding(.horizontal, 12)
                        Spacer(minLength: 0)
                    }
                    .zIndex(2.5)
                }

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
                        onShowDownload: openDownloadPanel,
                        onShowComments: openChapterComments,
                        onOpenForum: openInForum,
                        onShowSearch: openSearch,
                        onToggleBookmark: toggleBookmarkAtCurrentPosition,
                        onShowAnnotations: openAnnotations,
                        isBookmarked: annotations.isCurrentPositionBookmarked,
                        annotationCapsule: annotations.capsule,
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
                    // Match the viewport's origin; the chrome already includes topInset.
                    .ignoresSafeArea(.container, edges: .top)
                    .zIndex(2)
                }

                verticalBoundaryPullOverlayLayer(
                    topInset: topInset,
                    bottomInset: bottomInset
                )
                .zIndex(3)

                if loadingOverlayPresentation.isPresented {
                    readerLoadingOverlay
                        .zIndex(1)
                }
            }
            .disabled(hasPresentedOverlay)
            // Hide only the reading surface's bar, not a presented panel's commands.
            .toolbar(.hidden, for: .navigationBar)
            .transientMessage(
                loadingOverlayPresentation.isPresented || hasPresentedOverlay
                    ? nil : model.pageBoundary?.message,
                bottomPadding: chromeState.showsChrome
                    ? max(bottomChromeHeight, bottomInset + 210) + 8
                    : max(bottomInset, 24) + 8
            ) {
                model.pageBoundary = nil
            }
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
            .sheet(item: $searchPresentation) { presentation in
                NovelReaderSearchView(
                    snapshot: presentation.snapshot,
                    backgroundColor: backgroundColor,
                    usesDarkBackground: model.settings.backgroundStyle == .quiet || colorScheme == .dark,
                    onSelect: handleSearchResult,
                    onDismiss: closeSearch
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(backgroundColor)
            }
            .modifier(readerStateObserverModifier())
            .modifier(readerChromeHeightObserverModifier())
            .onChange(of: model.novelReaderPresentation?.generation) { _, _ in
                annotations.selectionController.clearSelection()
                searchHighlightController.clear()
            }
            .onChange(of: model.settings.readingMode) { _, _ in
                annotations.selectionController.clearSelection()
            }
            .onChange(of: model.initialPresentationPhase) { _, phase in
                guard phase == .restoring else { return }
                restoreVerticalPositionIfNeeded()
            }
            .onChange(of: verticalRestore.verticalRestoreController.shouldConcealViewportContent) { _, concealed in
                model.completeInitialPresentationIfReady(isRestoringViewport: concealed)
            }
            .task { await annotations.observeChanges() }
            .onChange(of: annotations.noteToEdit?.id) { _, _ in
                guard let item = annotations.noteToEdit else { return }
                presentedSheet = .note(item)
                annotations.noteToEdit = nil
            }
            // The bookmark glyph is only readable while the chrome is up, so
            // that is when it is worth re-deriving from the current position.
            .onChange(of: chromeState.showsChrome) { _, showsChrome in
                guard showsChrome else { return }
                Task { await annotations.refresh() }
            }
            // The ordinals are scoped to the forum page currently laid out, so
            // moving to another page reveals a fresh set.
            .onChange(of: model.visibleView) { _, _ in
                Task { await annotations.resolveSortKeys() }
            }
        }
        // Inspector belongs outside the viewport geometry so a pinned panel
        // reflows the reader rather than covering already laid-out text.
        .modifier(novelReaderPresentationModifier())
        .environment(\.readerToolbarPaper, readerThemeColor(for: model.settings.backgroundStyle, colorScheme: colorScheme))
        .environment(\.readerToolbarInk, model.settings.backgroundStyle == .quiet
            ? Color(uiColor: readerThemeTextUIColor(for: .quiet))
            : (colorScheme == .dark ? .white : .black))
        .annotationOperationFeedback(annotations.operations)
    }

    private func readerLifecycleModifier(currentLayout: NovelReaderLayout) -> NovelReaderLifecycleModifier {
        NovelReaderLifecycleModifier(
            currentLayout: currentLayout,
            onInitialTask: {
                annotations.configure()
                await model.commitNovelTextPresentationEnvironment(isPad: isPadDevice)
                await model.prepare(layout: currentLayout)
                guard !Task.isCancelled else { return }
                // `prepare` is what makes a semantic reader position
                // available. Refreshing earlier always reads nil and leaves
                // an existing bookmark looking like an add action.
                await annotations.refresh()
                // Strictly after `prepare`: it is what creates the reading
                // workflow, and the ordinals come off the laid-out projection.
                // Spawned before it, this read always saw a nil workflow and
                // silently no-opped, leaving every chapter ordinal unresolved.
                await annotations.resolveSortKeys()
                updateChromeForContentState()
                restoreVerticalPositionIfNeeded()
            },
            onLayoutChange: { newValue in
                Task {
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
                searchHighlightController.clear()
                if isDismissing {
                    model.close()
                } else {
                    syncVerticalViewportBeforeSave()
                    Task {
                        await model.saveProgress()
                        model.close()
                    }
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
            chapterCommentsHasLaterChapter: chapterCommentsHasLaterChapter,
            likeDependencies: dependencies.like,
            settingsStore: dependencies.settingsStore,
            forumDependencies: forumDependencies,
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
                Task { await annotations.saveNote(for: item, note: note) }
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
                LoadFailureDetailsButton(details: model.errorDetails, message: errorMessage)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.settings.readingMode == .paged {
            NovelReaderPagedContent(
                model: model,
                layout: layout,
                topInset: topInset,
                bottomInset: bottomInset,
                isPadDevice: isPadDevice,
                pagedScrollAnimationRequest: pagedScrollAnimationRequest,
                makeBindings: pagedViewportBindings
            )
        } else {
            NovelReaderVerticalContent(
                model: model,
                layout: layout,
                topInset: topInset,
                bottomInset: bottomInset,
                isPadDevice: isPadDevice,
                isChromeVisible: chromeState.showsChrome,
                verticalRestore: verticalRestore,
                verticalScrollCoordinator: verticalScrollCoordinator,
                annotations: annotations,
                searchHighlightController: searchHighlightController,
                verticalTapSuppressionUntil: $verticalTapSuppressionUntil,
                handleVerticalBoundaryPullRelease: handleVerticalBoundaryPullRelease,
                updateVerticalBoundaryPullState: updateVerticalBoundaryPullState,
                handleVerticalTap: handleVerticalTap,
                enterImmersiveMode: enterImmersiveMode,
                handleImageTap: handleImageTap
            )
        }
    }

    private func pagedViewportBindings(pagerIdentity: ReaderPagedPagerIdentity) -> NovelReaderPagedViewportBindings {
        NovelReaderPagedViewportBindings(
            displayReferenceProvider: { surfaceIdentity in
                model.novelTextViewportDisplayReference(for: surfaceIdentity)
            },
            selectionController: annotations.selectionController,
            likeHighlightController: annotations.highlightController,
            searchHighlightController: searchHighlightController,
            likedImageAnchors: annotations.likedImageAnchors,
            isChromeVisible: chromeState.showsChrome,
            canBoundaryPageTurn: { delta in
                canNavigatePagedBoundary(delta: delta)
            },
            onSelectionChange: self.handlePagedViewportSelection,
            onBoundaryPageTurn: { delta in
                Task { await goRelativePage(delta, pagerIdentity: pagerIdentity) }
            },
            onBoundaryPageTurnRejected: { delta in
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
            onImageLongPress: { anchor, imageURL, chapterTitle in
                annotations.toggleImage(anchor, imageURL: imageURL, chapterTitle: chapterTitle)
            }
        )
    }

    private var backgroundColor: Color {
        readerThemeColor(for: model.settings.backgroundStyle, colorScheme: colorScheme)
    }

    private var readerLoadingOverlayPresentation: NovelReaderLoadingOverlayPresentation {
        NovelReaderLoadingOverlayPresentation(
            isLoading: model.isLoading,
            hasSurfaces: !model.novelReaderSurfaces.isEmpty,
            isPreparingInitialPresentation: model.initialPresentationPhase.concealsContent,
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
            .onTapGesture(perform: toggleChrome)
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

    private func openInForum() {
        guard !isDismissing else { return }
        isDismissing = true
        searchHighlightController.clear()
        syncVerticalViewportBeforeSave()
        let url = model.currentForumTargetURL
        Task {
            let context = await model.saveProgress()
            if await onOpenOriginalPost(url, context) {
                model.close()
            } else {
                isDismissing = false
            }
        }
    }

    private func openSearch() {
        guard let snapshot = model.currentPageSearchSnapshot() else { return }
        searchPresentation = NovelReaderSearchPresentation(snapshot: snapshot)
    }

    private func closeSearch() {
        searchPresentation = nil
    }

    private func handleSearchResult(_ match: NovelReaderSearchMatch) {
        searchPresentation = nil
        Task {
            await navigationPresentation.performAsync {
                guard await model.jumpToSearchResult(match.startResumePoint) else { return false }
                searchHighlightController.highlight(
                    from: match.startResumePoint,
                    to: match.endResumePoint
                )
                return true
            }
        }
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
        searchHighlightController.clear()
        syncVerticalViewportBeforeSave()
        Task {
            await model.saveProgress()
            onClose()
        }
    }

    // MARK: - Chrome state and control events

    private func toggleChrome() {
        guard !isDismissing, !hasPresentedOverlay else { return }
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

    private func openChapterDrawer() {
        initialReaderLibraryTab = .chapters
        presentedSheet = .annotations
    }

    private func openChapterComments() {
        chapterCommentsTarget = model.currentChapterCommentTarget
        chapterCommentsHasLaterChapter = model.hasChapterAfter(model.currentChapterCommentTarget)
        presentedSheet = .chapterComments
    }

    private func openSettings() {
        presentedSheet = .settings
    }

    private func openDownloadPanel() {
        if model.download.hasOperationSession {
            model.download.showProgressIfRunning()
            presentedSheet = .downloadProgress
        } else {
            presentedSheet = .downloadPanel
        }
    }

    private func openAnnotations() {
        initialReaderLibraryTab = ReaderLibraryPanelTab(
            annotationSegment: annotationSegmentBinding.wrappedValue
        )
        presentedSheet = .annotations
    }

    // MARK: - Annotation presentation and viewport events

    private var annotationSegmentBinding: Binding<ReaderAnnotationSegment> {
        Binding(
            get: { annotations.selectedSegment },
            set: { annotations.selectedSegment = $0 }
        )
    }

    private func handlePagedViewportSelection(_ selectionIndex: Int) {
        model.selectPagedViewportIndex(selectionIndex)
        Task { await annotations.refreshPosition() }
    }

    private func toggleBookmarkAtCurrentPosition() {
        // The vertical sample can lag a gesture; synchronize before capturing.
        syncVerticalViewportBeforeSave()
        annotations.toggleBookmark()
    }

    private func handleBookmarkOpen(_ item: BookmarkItem) {
        guard let point = annotations.resumePoint(for: item) else { return }
        Task { await jumpToAnnotationAnchor(point) }
    }

    private func handleLikeAnchorOpen(_ payload: LikeAnchorPayload) {
        if presentedSheet == .annotations { presentedSheet = nil }
        guard let point = annotations.resumePoint(for: payload) else { return }
        Task { await jumpToAnnotationAnchor(point) }
    }

    /// Same-document annotation jumps need an explicit vertical scroll request.
    private func jumpToAnnotationAnchor(_ resumePoint: NovelResumePoint) async {
        await navigationPresentation.performAsync {
            await model.jumpToLikeAnchor(resumePoint)
        }
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
        model.completeInitialPresentationIfReady(
            isRestoringViewport: verticalRestore.verticalRestoreController.shouldConcealViewportContent
        )
    }

    private func commitProgressSlider(_ targetIndex: Int) {
        navigationPresentation.perform { model.jumpToSurface(targetIndex) }
    }

    private func jumpAdjacentChapter(_ delta: Int) {
        navigationPresentation.perform { model.jumpToAdjacentChapter(delta) }
    }

    // MARK: - Navigation intents

    private var navigationPresentation: NovelReaderNavigationCoordinator.Presentation {
        .init(
            restoreViewport: restoreVerticalPositionIfNeeded,
            refreshAnnotations: { await annotations.refreshPosition() }
        )
    }

    private func jumpToChapter(_ chapter: NovelReaderChapter) {
        navigationPresentation.perform { model.jumpToChapter(chapter) }
    }

    private func jumpToChapterDirectoryChapter(_ chapter: NovelReaderChapter) async {
        await navigationPresentation.performAsync {
            await model.navigation.jumpToChapterDirectoryChapter(chapter)
            return true
        }
    }

    private func jumpToWebView(_ view: Int) async {
        await jumpToWebView(view, preferredSurfaceOrdinal: 0)
    }

    private func jumpToWebView(_ view: Int, preferredSurfaceOrdinal: Int) async {
        chromeState.showChrome()
        await navigationPresentation.performAsync {
            await model.jumpToWebView(view, preferredSurfaceOrdinal: preferredSurfaceOrdinal)
            return true
        }
    }

    private func navigateBackFromChrome() async {
        await navigationPresentation.performAsync {
            await model.navigation.navigateBack()
            return true
        }
    }

    private func navigateForwardFromChrome() async {
        await navigationPresentation.performAsync {
            await model.navigation.navigateForward()
            return true
        }
    }

    private func goRelativePage(_ delta: Int) async {
        pagedScrollAnimationRequest = nil
        await navigationPresentation.performAsync {
            await model.jumpRelativeSurface(delta)
            return true
        }
    }

    private func goRelativePage(_ delta: Int, pagerIdentity: ReaderPagedPagerIdentity?) async {
        let animationRequest = pagerIdentity.flatMap {
            makePagedScrollAnimationRequest(delta: delta, pagerIdentity: $0)
        }
        pagedScrollAnimationRequest = animationRequest
        await navigationPresentation.performAsync {
            await model.jumpRelativeSurface(delta)
            if let request = pagedScrollAnimationRequest,
               request.selectionIndex != model.pagedViewportSelectionIndex {
                pagedScrollAnimationRequest = nil
            }
            return true
        }
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
        guard !isHandlingVerticalBoundaryPull else { return }
        guard canNavigateVerticalBoundary(direction) else {
            model.reportVerticalPageBoundary(direction == .next ? 1 : -1)
            return
        }
        model.pageBoundary = nil
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
            imageBrowserItem != nil ||
            searchPresentation != nil
    }

    /// Deliberately excludes `imageBrowserItem`: the image browser overlays
    /// the reader without forcing the chrome back on.
    private var hasChromePresentedOverlay: Bool {
        presentedSheet != nil ||
            forumThreadOverlayItem != nil ||
            searchPresentation != nil
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
        navigationPresentation.perform { model.jumpToSurface(target) }
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

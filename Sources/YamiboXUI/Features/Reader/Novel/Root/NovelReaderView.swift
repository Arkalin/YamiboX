import SwiftUI
import YamiboXCore
import UIKit

struct NovelReaderView: View {
    @Bindable var reader: NovelReaderSessionState
    let viewport: ReaderViewportLifetime
    @State private var attachmentID = UUID()
    @State private var verticalScrollCoordinator = NovelReaderVerticalScrollCoordinator()
    @State private var verticalRestore = NovelReaderVerticalRestoreCoordinator()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.readingHandoffAllowed) private var allowsReadingHandoff
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.readerExternalGeometry) private var externalGeometry
    @Environment(\.readerDeviceInteraction) private var deviceInteraction
    @Environment(\.readerRemoteInput) private var remoteInput
    @State private var verticalTapSuppression = NovelReaderVerticalTapSuppression()
    @State private var verticalBoundaryPullState = NovelReaderVerticalBoundaryPullState.idle
    @State private var isHandlingVerticalBoundaryPull = false
    @State private var topChromeHeight: CGFloat = 0
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var pagedScrollAnimationRequest: ReaderPagedScrollAnimationRequest?
    @State private var controlPagedPagerIdentity: ReaderPagedPagerIdentity?
    /// Scene-local window safe-area insets reported by
    /// `ReaderWindowSafeAreaInsetsProbe`; nil until this reader attaches.
    @State private var windowSafeAreaInsets: UIEdgeInsets?
    let dependencies: NovelReaderDependencies
    let forumDependencies: ForumNavigationDependencies
    let appModel: YamiboAppModel
    let onClose: () -> Void
    let onOpenOriginalPost: (URL, NovelLaunchContext, @escaping @MainActor () async -> NovelLaunchContext) async -> Bool
    let onResumeRouteChangeImmediately: @MainActor (ReaderResumeRoute) -> Void

    private var model: NovelReaderViewModel { reader.model }
    private var showsChrome: Bool { externalGeometry == nil && reader.chromeState.showsChrome }

    private var isPadDevice: Bool {
        externalGeometry?.supportsSpreads ?? (UIDevice.current.userInterfaceIdiom == .pad)
    }

    var body: some View {
        GeometryReader { proxy in
            let rawTopInset = externalGeometry?.insets.top
                ?? max(proxy.safeAreaInsets.top, windowSafeAreaInsets?.top ?? proxy.safeAreaInsets.top)
            let topInset = effectiveTopInset(rawTopInset)
            let contentTopInset = model.settings.readingMode == .paged
                ? readerPagedContentTopInset(for: topInset)
                : readerContentTopInset(for: topInset, rawTopInset: rawTopInset)
            let bottomInset = externalGeometry?.insets.bottom
                ?? max(proxy.safeAreaInsets.bottom, windowSafeAreaInsets?.bottom ?? proxy.safeAreaInsets.bottom)
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
                .readerRemoteTarget(priority: 0, actions: ReaderRemoteActions(tap: { point in
                    guard !loadingOverlayPresentation.isPresented, viewport.acceptsGeometry,
                          let window = remoteInput?.targets.window else { return }
                    NovelReaderImageInteraction.openImage(at: point, in: window, onOpen: openImageBrowser(url:title:))
                }, scroll: { delta in
                    guard !loadingOverlayPresentation.isPresented, viewport.acceptsGeometry,
                          model.settings.readingMode == .vertical else { return }
                    cancelVerticalRestoreForUserScroll()
                    verticalScrollCoordinator.scrollFromTrackpad(delta)
                }, gestureID: model.presentationStructure?.id))

                // Chrome-visible only, and only once the top chrome has
                // reported its height: on the first chrome frame
                // `topChromeHeight` is still 0 and the banner would sit on
                // top of the close button.
                if let sourceStatusText = model.sourceStatusText,
                   !model.novelReaderSurfaces.isEmpty,
                   !reader.isOfflineBannerDismissed,
                   showsChrome,
                   topChromeHeight > 0 {
                    VStack(spacing: 0) {
                        NovelReaderOfflineFallbackBanner(
                            message: sourceStatusText,
                            details: model.offlineFailureDetails,
                            retry: refreshReader,
                            dismiss: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    reader.isOfflineBannerDismissed = true
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

                if let warning = model.fontWarning, !reader.isFontBannerDismissed,
                   showsChrome, topChromeHeight > 0, model.sourceStatusText == nil {
                    VStack {
                        NovelReaderOfflineFallbackBanner(
                            message: warning, details: nil,
                            retryTitle: L10n.string("reader.font.library"), retrySystemName: "textformat",
                            retry: openSettings,
                            dismiss: { reader.isFontBannerDismissed = true }
                        )
                        .padding(.top, topInset + topChromeHeight + 6)
                        .padding(.horizontal, 12)
                        Spacer(minLength: 0)
                    }
                    .zIndex(2.5)
                }

                if externalGeometry == nil {
                    chrome(topInset: topInset, bottomInset: bottomInset, isVisible: showsChrome)
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
                        .background {
                            NovelReaderNavigationOverlayDisplayProbe(
                                revision: model.navigationOverlayRevision,
                                waitsForPresentation: model.initialPresentationPhase.concealsContent,
                                didDisplay: { revision in
                                    guard viewport.acceptsGeometry else { return }
                                    model.initialPresentationDidDisplay()
                                    model.navigationOverlayDidDisplay(revision: revision)
                                }
                            )
                        }
                        .zIndex(1)
                }
            }
            .onAppear { [viewport] in
                guard viewport.isCurrent else { return }
                viewport.attach(attachmentID, peripheralInput: appModel.peripheralInput,
                    capturePosition: { [model, verticalRestore, verticalScrollCoordinator] in
                        verticalRestore.syncVerticalViewportBeforeSave(model: model, scrollCoordinator: verticalScrollCoordinator)
                    },
                    onDetach: { [model, verticalRestore, verticalScrollCoordinator] in
                        model.setInitialPresentationReporter(active: false)
                        model.setNavigationOverlayReporter(active: false)
                        verticalScrollCoordinator.attach(scrollView: nil)
                        verticalRestore.cancelPendingRestoreWork()
                    },
                    externalInput: remoteInput,
                    deviceMenu: deviceInteraction == nil ? nil : deviceMenu,
                    handleInput: handleControlEvent
                )
                verticalRestore.admitsViewport = { [weak viewport] in viewport?.acceptsGeometry == true }
                model.setInitialPresentationReporter(active: true)
                model.setNavigationOverlayReporter(active: true)
                reader.observeAnnotationsIfNeeded()
            }
            .disabled(hasPresentedOverlay)
            // Hide only the reading surface's bar, not a presented panel's commands.
            .toolbar(.hidden, for: .navigationBar)
            .transientMessage(
                loadingOverlayPresentation.isPresented || hasPresentedOverlay
                    ? nil : model.pageBoundary?.message,
                bottomPadding: showsChrome
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
            .modifier(readerLifecycleModifier(currentLayout: currentLayout))
            .onChange(of: model.isApplyingAppearanceSettings) { _, applying in
                if !applying { updateViewportLayout(currentLayout) }
            }
            .modifier(ReaderViewportRenderAcknowledgement(
                ready: model.committedViewportLayout == currentLayout && !loadingOverlayPresentation.isPresented &&
                    !model.novelReaderSurfaces.isEmpty,
                viewport: viewport
            ))
            .sheet(item: $reader.searchPresentation) { presentation in
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
                reader.annotations.selectionController.clearSelection()
                reader.searchHighlightController.clear()
            }
            .onChange(of: model.settings.readingMode) { _, _ in
                reader.annotations.selectionController.clearSelection()
            }
            .onChange(of: model.initialPresentationPhase) { _, phase in
                guard phase == .restoring else { return }
                restoreVerticalPositionIfNeeded()
            }
            .onChange(of: verticalRestore.verticalRestoreController.shouldConcealViewportContent) { _, concealed in
                guard viewport.accepts(attachmentID) else { return }
                model.completeInitialPresentationIfReady(isRestoringViewport: concealed)
            }
            .onChange(of: reader.annotations.noteToEdit?.id) { _, _ in
                guard let item = reader.annotations.noteToEdit else { return }
                reader.annotations.noteToEdit = nil
                if let deviceInteraction {
                    deviceInteraction.editNote(item) { await reader.annotations.saveNote(for: item, note: $0) }
                } else {
                    reader.presentedSheet = .note(item)
                }
            }
            // The bookmark glyph is only readable while the chrome is up, so
            // that is when it is worth re-deriving from the current position.
            .onChange(of: showsChrome) { _, showsChrome in
                guard showsChrome else { return }
                Task { await reader.annotations.refresh() }
            }
            // The ordinals are scoped to the forum page currently laid out, so
            // moving to another page reveals a fresh set.
            .onChange(of: model.visibleView) { _, _ in
                Task { await reader.annotations.resolveSortKeys() }
            }
        }
        // Inspector belongs outside the viewport geometry so a pinned panel
        // reflows the reader rather than covering already laid-out text.
        .modifier(novelReaderPresentationModifier())
        .modifier(NovelReaderToolbarColors(backgroundStyle: model.settings.backgroundStyle))
        .annotationOperationFeedback(reader.annotations.operations)
        .background {
            NovelReaderHandoffSource(model: model, isActive: !reader.isDismissing
                && reader.presentedSheet == nil && reader.searchPresentation == nil && reader.chapterCommentsTarget == nil
                && reader.forumThreadOverlayItem == nil && reader.imageBrowserItem == nil)
        }
        .onChange(of: scenePhase) { _, phase in
            guard externalGeometry == nil, phase != .active, viewport.accepts(attachmentID), model.novelReaderPresentation != nil else { return }
            syncVerticalViewportBeforeSave()
            appModel.handoffPublisher.flushLatest(.novel(model.currentResumeContext))
            guard let route = model.resumeRouteForBackground() else { return }
            // The default continuation store is synchronous. Flush it before
            // iOS can suspend the scene; the async save also flushes progress.
            onResumeRouteChangeImmediately(route)
            model.flushViewportSnapshot()
        }
        .environment(\.readingHandoffAllowed, allowsReadingHandoff && !model.context.isPreview)
    }

    private func chrome(topInset: CGFloat, bottomInset: CGFloat, isVisible: Bool) -> some View {
        NovelReaderChromeControls(
            model: model,
            topInset: topInset,
            bottomInset: bottomInset,
            isChromeVisible: isVisible,
            onNavigateBack: { Task { await navigateBackFromChrome() } },
            onNavigateForward: { Task { await navigateForwardFromChrome() } },
            onClose: closeReader,
            onShowChapters: openChapterDrawer,
            onShowSettings: openSettings,
            onShowDownload: openDownloadPanel,
            onShowComments: openChapterComments,
            onOpenForum: openInForum,
            onShowSearch: openSearch,
            onToggleBookmark: toggleBookmarkAtCurrentPosition,
            onShowAnnotations: openAnnotations,
            isBookmarked: reader.annotations.isCurrentPositionBookmarked,
            annotationCapsule: reader.annotations.capsule,
            onJumpChapter: jumpAdjacentChapter,
            onProgressCommit: commitProgressSlider,
            onVerticalProgressCommit: commitVerticalProgressScrub,
            onBeginVerticalProgressScrub: suppressVerticalTapAfterScrub,
            onEndVerticalProgressScrub: suppressVerticalTapAfterScrub
        )
    }

    private func deviceMenu(_ insets: EdgeInsets) -> AnyView {
        let topInset = UIDevice.current.userInterfaceIdiom == .pad
            ? verticalBands.padVisibleStatusBarTopInset : insets.top
        return AnyView(chrome(topInset: topInset, bottomInset: insets.bottom, isVisible: true)
            .modifier(NovelReaderToolbarColors(backgroundStyle: model.settings.backgroundStyle))
            .task { await reader.annotations.refresh() })
    }

    private func readerLifecycleModifier(currentLayout: NovelReaderLayout) -> NovelReaderLifecycleModifier {
        NovelReaderLifecycleModifier(
            currentLayout: currentLayout,
            onInitialTask: {
                guard viewport.accepts(attachmentID) else { return }
                let usesWidePresentation = isPadDevice
                await model.commitNovelTextPresentationEnvironment(isPad: usesWidePresentation)
                guard viewport.accepts(attachmentID) else { return }
                await model.prepare(layout: currentLayout)
                guard !Task.isCancelled, viewport.accepts(attachmentID) else { return }
                updateChromeForContentState()
                restoreVerticalPositionIfNeeded()
                // `prepare` is what makes a semantic reader position
                // available. Refreshing earlier always reads nil and leaves
                // an existing bookmark looking like an add action.
                await reader.annotations.refresh()
                // Strictly after `prepare`: it is what creates the reading
                // workflow, and the ordinals come off the laid-out projection.
                // Spawned before it, this read always saw a nil workflow and
                // silently no-opped, leaving every chapter ordinal unresolved.
                await reader.annotations.resolveSortKeys()
            },
            onLayoutChange: updateViewportLayout,
            onMemoryWarning: {
                model.handleMemoryPressure()
            },
            onDisappear: {
                viewport.detach(attachmentID)
            }
        )
    }

    private func updateViewportLayout(_ layout: NovelReaderLayout) {
        Task {
            // Let the scoped appearance transaction win. Its completion
            // triggers another read of the current viewport geometry.
            guard viewport.accepts(attachmentID), !model.isApplyingAppearanceSettings else { return }
            if externalGeometry != nil {
                await model.commitNovelTextPresentationEnvironment(isPad: isPadDevice)
            }
            guard viewport.accepts(attachmentID), !model.isApplyingAppearanceSettings else { return }
            await model.commitNovelTextLayout(layout)
            guard viewport.accepts(attachmentID) else { return }
            updateChromeForContentState()
            restoreVerticalPositionIfNeeded()
        }
    }

    private func novelReaderPresentationModifier() -> NovelReaderPresentationModifier {
        NovelReaderPresentationModifier(
            model: model,
            presentedSheet: $reader.presentedSheet,
            forumThreadOverlayItem: $reader.forumThreadOverlayItem,
            imageBrowserItem: $reader.imageBrowserItem,
            chapterCommentsTarget: reader.chapterCommentsTarget,
            chapterCommentsHasLaterChapter: reader.chapterCommentsHasLaterChapter,
            likeDependencies: dependencies.like,
            settingsStore: dependencies.settingsStore,
            settingsTarget: viewport.settingsTarget,
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
                Task { await reader.annotations.saveNote(for: item, note: note) }
            },
            annotationSegment: annotationSegmentBinding,
            readerLibraryTab: $reader.readerLibraryTab
        )
    }

    private func readerStateObserverModifier() -> NovelReaderStateObserverModifier {
        NovelReaderStateObserverModifier(
            model: model,
            presentedSheet: $reader.presentedSheet,
            forumThreadOverlayItem: $reader.forumThreadOverlayItem,
            imageBrowserItem: $reader.imageBrowserItem,
            isStatusBarHidden: externalGeometry != nil || reader.chromeState.mode == .immersiveHidden,
            isChromeVisible: showsChrome,
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
                ReaderRemoteButton(L10n.string("common.retry"), action: retryLoad)
                    .appProminentButtonStyle()
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
                isChromeVisible: showsChrome,
                verticalRestore: verticalRestore,
                verticalScrollCoordinator: verticalScrollCoordinator,
                viewport: viewport,
                annotations: reader.annotations,
                searchHighlightController: reader.searchHighlightController,
                verticalTapSuppression: verticalTapSuppression,
                handleVerticalBoundaryPullRelease: handleVerticalBoundaryPullRelease,
                updateVerticalBoundaryPullState: updateVerticalBoundaryPullState,
                handleVerticalTap: handleVerticalTap,
                enterImmersiveMode: enterImmersiveMode,
                handleImageTap: handleImageTap
            )
        }
    }

    private func pagedViewportBindings(pagerIdentity: ReaderPagedPagerIdentity) -> NovelReaderPagedViewportBindings {
        let structureID = model.presentationStructure?.id
        return NovelReaderPagedViewportBindings(
            displayReferenceProvider: { surfaceIdentity in
                model.novelTextViewportDisplayReference(for: surfaceIdentity)
            },
            selectionController: reader.annotations.selectionController,
            likeHighlightController: reader.annotations.highlightController,
            searchHighlightController: reader.searchHighlightController,
            likedImageAnchors: reader.annotations.likedImageAnchors,
            isChromeVisible: showsChrome,
            canBoundaryPageTurn: { delta in
                canNavigatePagedBoundary(delta: delta)
            },
            onSelectionChange: { selectionIndex in
                guard viewport.acceptsGeometry,
                      model.presentationStructure?.id == structureID,
                      model.settings.readingMode == .paged else { return }
                handlePagedViewportSelection(selectionIndex)
            },
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
                reader.annotations.toggleImage(anchor, imageURL: imageURL, chapterTitle: chapterTitle)
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
            isChromeVisible: showsChrome,
            measuredTopChromeHeight: topChromeHeight
        )
    }

    private func verticalBoundaryPullBottomPadding(bottomInset: CGFloat) -> CGFloat {
        verticalBands.boundaryPullBottomPadding(
            bottomInset: bottomInset,
            isChromeVisible: showsChrome,
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
        NovelReaderLayoutPresentation.layout(
            containerSize: externalGeometry?.size ?? proxy.size,
            safeAreaInsets: NovelReaderLayoutInsets(top: topInset, leading: externalGeometry?.insets.leading ?? 0,
                                                    bottom: bottomInset, trailing: externalGeometry?.insets.trailing ?? 0),
            settings: model.settings
        )
    }

    private func effectiveTopInset(_ rawTopInset: CGFloat) -> CGFloat {
        // Keep pagination based on the status-bar-visible safe area so immersive status bar changes
        // do not move text or alter rendered page counts.
        guard externalGeometry == nil, isPadDevice else { return rawTopInset }
        return verticalBands.padVisibleStatusBarTopInset
    }

    private func readerContentTopInset(for layoutTopInset: CGFloat, rawTopInset: CGFloat) -> CGFloat {
        guard externalGeometry == nil, isPadDevice else { return layoutTopInset }
        return rawTopInset > 0
            ? layoutTopInset
            : layoutTopInset + verticalBands.padVisibleStatusBarTopInset
    }

    private func readerPagedContentTopInset(for layoutTopInset: CGFloat) -> CGFloat {
        layoutTopInset
    }

    private func retryLoad() {
        reader.chromeState.showChrome()
        Task { await model.loadCurrent(forceRefresh: false) }
    }

    private func refreshReader() {
        reader.chromeState.showChrome()
        Task { await model.loadCurrent(forceRefresh: true) }
    }

    private func openInForum() {
        guard !reader.isDismissing else { return }
        reader.isDismissing = true
        reader.searchHighlightController.clear()
        syncVerticalViewportBeforeSave()
        let url = model.currentForumTargetURL
        let context = model.currentResumeContext
        Task {
            if !(await onOpenOriginalPost(url, context, { await model.saveProgress() })) {
                reader.isDismissing = false
            }
        }
    }

    private func openSearch() {
        guard let snapshot = model.currentPageSearchSnapshot() else { return }
        if let deviceInteraction {
            deviceInteraction.present { id in
                NovelReaderSearchView(
                    snapshot: snapshot,
                    backgroundColor: backgroundColor,
                    usesDarkBackground: model.settings.backgroundStyle == .quiet || colorScheme == .dark,
                    onSelect: { match in
                        guard deviceInteraction.isCurrent(id) else { return }
                        handleSearchResult(match)
                        deviceInteraction.finish(id)
                    },
                    onDismiss: { deviceInteraction.finish(id) }
                )
                .presentationDetents([.large])
                .presentationBackground(backgroundColor)
            }
            return
        }
        reader.searchPresentation = NovelReaderSearchPresentation(snapshot: snapshot)
    }

    private func closeSearch() {
        reader.searchPresentation = nil
    }

    private func handleSearchResult(_ match: NovelReaderSearchMatch) {
        reader.searchPresentation = nil
        Task {
            await navigationPresentation.performAsync {
                guard await model.jumpToSearchResult(match.startResumePoint) else { return false }
                reader.searchHighlightController.highlight(
                    from: match.startResumePoint,
                    to: match.endResumePoint
                )
                return true
            }
        }
    }

    // MARK: - Image taps and browser

    private func handleImageTap(url: URL, title: String?) {
        guard !showsChrome else {
            enterImmersiveMode()
            return
        }
        openImageBrowser(url: url, title: title)
    }

    private func openImageBrowser(url: URL, title: String?) {
        let item = ImageBrowserItem(
            id: url.absoluteString,
            source: YamiboImageSource(
                url: url,
                refererPageURL: model.forumURL,
                offlineScope: model.inlineImageOfflineScope
            ),
            title: imageBrowserTitle(title),
        )
        if let deviceInteraction {
            deviceInteraction.present { id in
                ImageBrowserView(items: [item], initialItemID: item.id, mode: .single,
                    coverActionsProvider: model.imageBrowserCoverActionsProvider,
                    onDismiss: { deviceInteraction.finish(id) })
            }
        } else { reader.imageBrowserItem = item }
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
        reader.chromeState.showChrome()
        guard !reader.isDismissing else { return }
        reader.isDismissing = true
        reader.searchHighlightController.clear()
        onClose()
    }

    // MARK: - Chrome state and control events

    private func toggleChrome() {
        guard !reader.isDismissing, !hasPresentedOverlay else { return }
        if let deviceInteraction {
            deviceInteraction.showMenu(from: viewport)
            return
        }
        withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
            reader.chromeState.toggleChrome()
        }
    }

    private func handleControlEvent(_ event: ReaderControlEvent) {
        guard !reader.isDismissing, !hasPresentedOverlay else { return }
        guard !model.novelReaderSurfaces.isEmpty, !readerLoadingOverlayPresentation.isPresented else {
            // Loading/error: Menu still flips the chrome state so a
            // controller user keeps an escape hatch wherever chrome renders.
            if event == .menu { toggleChrome() }
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
        guard showsChrome else { return }
        withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
            reader.chromeState.hideChrome()
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
            reader.chromeState.hideChrome()
        }
    }

    // MARK: - Tap routing

    private func handlePagedContentTap(
        pageDelta: Int? = nil,
        pagerIdentity: ReaderPagedPagerIdentity? = nil
    ) {
        guard !showsChrome else {
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
        if now <= verticalTapSuppression.until {
            verticalTapSuppression.until = now + 0.35
            _ = verticalScrollCoordinator.interruptScrollingIfNeeded()
            return
        }
        if verticalScrollCoordinator.shouldSuppressChromeToggle() {
            return
        }
        if verticalScrollCoordinator.interruptScrollingIfNeeded() {
            verticalTapSuppression.until = now + 0.35
            return
        }
        toggleChrome()
    }

    private func openChapterDrawer() {
        reader.readerLibraryTab = .chapters
        reader.presentedSheet = .annotations
    }

    private func openChapterComments() {
        reader.chapterCommentsTarget = model.currentChapterCommentTarget
        reader.chapterCommentsHasLaterChapter = model.hasChapterAfter(model.currentChapterCommentTarget)
        reader.presentedSheet = .chapterComments
    }

    private func openSettings() {
        reader.presentedSheet = .settings
    }

    private func openDownloadPanel() {
        if model.download.hasOperationSession {
            model.download.showProgressIfRunning()
            reader.presentedSheet = .downloadProgress
        } else {
            reader.presentedSheet = .downloadPanel
        }
    }

    private func openAnnotations() {
        reader.readerLibraryTab = ReaderLibraryPanelTab(
            annotationSegment: annotationSegmentBinding.wrappedValue
        )
        reader.presentedSheet = .annotations
    }

    // MARK: - Annotation presentation and viewport events

    private var annotationSegmentBinding: Binding<ReaderAnnotationSegment> {
        Binding(
            get: { reader.annotations.selectedSegment },
            set: { reader.annotations.selectedSegment = $0 }
        )
    }

    private func handlePagedViewportSelection(_ selectionIndex: Int) {
        model.selectPagedViewportIndex(selectionIndex)
        Task { await reader.annotations.refreshPosition() }
    }

    private func toggleBookmarkAtCurrentPosition() {
        // The vertical sample can lag a gesture; synchronize before capturing.
        syncVerticalViewportBeforeSave()
        reader.annotations.toggleBookmark()
    }

    private func handleBookmarkOpen(_ item: BookmarkItem) {
        guard let point = reader.annotations.resumePoint(for: item) else { return }
        Task { await jumpToAnnotationAnchor(point) }
    }

    private func handleLikeAnchorOpen(_ payload: LikeAnchorPayload) {
        guard let point = reader.annotations.resumePoint(for: payload) else { return }
        Task { await jumpToAnnotationAnchor(point) }
    }

    /// Same-document annotation jumps need an explicit vertical scroll request.
    private func jumpToAnnotationAnchor(_ resumePoint: NovelResumePoint) async {
        await navigationPresentation.performAsync {
            await model.jumpToLikeAnchor(resumePoint)
        }
    }

    private func updateChromeForContentState() {
        let previousState = reader.chromeState
        var nextState = reader.chromeState
        nextState.update(
            isLoading: model.isLoading,
            errorMessage: model.errorMessage,
            hasPages: !model.novelReaderSurfaces.isEmpty,
            hasPresentedOverlay: hasChromePresentedOverlay,
            usesVerticalReadingMode: model.settings.readingMode == .vertical
        )
        if previousState != nextState {
            withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
                reader.chromeState = nextState
            }
        } else {
            reader.chromeState = nextState
        }

        verticalRestore.synchronizePositioningFingerprintWithContentState(model: model)
    }

    // MARK: - Vertical position persistence and restore
    // Thin forwarders into `NovelReaderVerticalRestoreCoordinator`; kept so
    // the many call sites across the view read the same as before the move.

    private func restoreVerticalPositionIfNeeded() {
        guard viewport.accepts(attachmentID) else { return }
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
            refreshAnnotations: { await reader.annotations.refreshPosition() }
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
        reader.chromeState.showChrome()
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
        guard viewport.acceptsInput(attachmentID), model.settings.readingMode == .paged else { return }
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
        reader.presentedSheet != nil ||
            reader.forumThreadOverlayItem != nil ||
            reader.imageBrowserItem != nil ||
            reader.searchPresentation != nil
    }

    /// Deliberately excludes `imageBrowserItem`: the image browser overlays
    /// the reader without forcing the chrome back on.
    private var hasChromePresentedOverlay: Bool {
        reader.presentedSheet != nil ||
            reader.forumThreadOverlayItem != nil ||
            reader.searchPresentation != nil
    }

    private var canReceiveApplePencilPageTurn: Bool {
        ReaderApplePencilPageTurnGate.canTurnPage(
            isPadDevice: externalGeometry == nil && isPadDevice,
            isPagedReadingMode: model.settings.readingMode == .paged,
            hasReadableContent: !model.novelReaderSurfaces.isEmpty,
            hasBlockingOverlay: hasPresentedOverlay,
            isDismissing: reader.isDismissing,
            isChromeVisible: showsChrome
        )
    }

    private func suppressVerticalTapAfterScrub() {
        verticalTapSuppression.until = CACurrentMediaTime() + 0.5
    }

    private func commitVerticalProgressScrub(_ target: Int) {
        navigationPresentation.perform { model.jumpToSurface(target) }
        verticalTapSuppression.until = CACurrentMediaTime() + 0.5
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

private struct NovelReaderToolbarColors: ViewModifier {
    let backgroundStyle: ReaderBackgroundStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.readerToolbarPaper, readerThemeColor(for: backgroundStyle, colorScheme: colorScheme))
            .environment(\.readerToolbarInk, backgroundStyle == .quiet
                ? Color(uiColor: readerThemeTextUIColor(for: .quiet))
                : (colorScheme == .dark ? .white : .black))
    }
}

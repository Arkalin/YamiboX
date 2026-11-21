import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderView: View {
    @Bindable var reader: MangaReaderSessionState
    let viewport: ReaderViewportLifetime
    @State private var attachmentID = UUID()
    @Environment(\.readerToolbarStyle) private var toolbarStyle
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.readingHandoffAllowed) private var allowsReadingHandoff
    @Environment(\.readerExternalGeometry) private var externalGeometry
    @Environment(\.readerExternalMenuPresented) private var externalMenuPresented
    @Environment(\.readerRemoteInput) private var remoteInput
    @Environment(\.readerDeviceInteraction) private var deviceInteraction
    @State private var bottomChromeHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlPageTurnBridge = MangaPagedControlPageTurnBridge()
    @State private var controlUsesTwoPageSpread = false
    @State private var chromeSummaryMemo = MangaChromeSummaryMemo()
    @State private var windowSafeAreaInsets: UIEdgeInsets?
    @State private var readingViewportInsets = MangaReadingViewportInsets()
    @State private var visibleStatusBarTopInset: CGFloat = 0

    let dependencies: MangaReaderDependencies
    let forumDependencies: ForumNavigationDependencies
    let appModel: YamiboAppModel
    let onClose: () -> Void
    let onOpenOriginalPost: (URL, MangaLaunchContext, @escaping @MainActor () async -> MangaLaunchContext) async -> Bool

    private var model: MangaReaderViewModel { reader.model }
    private var context: MangaLaunchContext { model.context }
    private var showsChrome: Bool { externalGeometry == nil && reader.isChromeVisible }
    private var initialPresentationFailed: Bool {
        if case .failed = model.presentation.state { return true }
        return false
    }

    private var admitsContentInput: Bool {
        viewport.acceptsInput(attachmentID) && model.hasCurrentPage && !reader.isDismissing && !hasControlBlockingSheet
    }

    private var remoteContentID: String? {
        guard remoteInput != nil else { return nil }
        let page = model.presentation.settings.readingMode == .vertical ? "" : model.currentPageProjection?.id ?? ""
        return "\(attachmentID)#\(model.viewportContentID)#\(page)"
    }

    private func remoteImage(at point: CGPoint) -> MangaNativeSurfaceView? {
        guard let window = remoteInput?.targets.window else { return nil }
        return window.readerHit(MangaNativeSurfaceView.self, at: point, in: window) { surface, _ in
            surface.remoteImageHit(at: point, in: window) ? surface : nil
        }
    }

    private func remoteTransform(at point: CGPoint, zoom: Bool) -> ReaderRemoteTransform? {
        if model.presentation.settings.readingMode == .vertical {
            return controlPageTurnBridge.verticalViewport?.remoteTransform(at: point, zoom: zoom)
        }
        guard let surface = controlPageTurnBridge.pagedSurface?() else { return nil }
        guard !zoom || focusHitsPagedSurface(surface, at: point) else { return nil }
        return surface.remoteTransform(at: point, zoom: zoom)
    }

    private func focusHitsPagedSurface(_ surface: MangaSurfaceRuntime, at point: CGPoint) -> Bool {
        if case .spread = surface.geometry { return true }
        return remoteImage(at: point) != nil
    }

    private func remoteDoubleTap(at point: CGPoint) {
        let settings = model.presentation.settings
        guard settings.zoomEnabled else { return }
        if settings.readingMode == .vertical {
            controlPageTurnBridge.verticalViewport?.doubleTapFromTrackpad(at: point)
        } else {
            controlPageTurnBridge.pagedSurface?()?.doubleTapFromTrackpad(at: point)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let presentation = model.presentation
            let topInset = externalGeometry?.insets.top
                ?? max(proxy.safeAreaInsets.top, windowSafeAreaInsets?.top ?? proxy.safeAreaInsets.top)
            let informationTopInset = UIDevice.current.userInterfaceIdiom == .pad
                ? max(topInset, visibleStatusBarTopInset) : topInset
            let bottomInset = externalGeometry?.insets.bottom
                ?? max(proxy.safeAreaInsets.bottom, windowSafeAreaInsets?.bottom ?? proxy.safeAreaInsets.bottom)
            let readingTopInset = externalGeometry?.insets.top
                ?? readingViewportInsets.topInset(for: proxy.size, proposed: topInset)
            let pagedContentTopInset = MangaPagedLayoutPolicy.pagedContentTopInset(
                settings: model.presentation.settings,
                topInset: readingTopInset
            )
            let usesTwoPageSpread = MangaPagedLayoutPolicy.usesTwoPageSpread(
                settings: model.presentation.settings,
                availableSize: CGSize(width: proxy.size.width, height: max(proxy.size.height - pagedContentTopInset, 0))
            )

            let surface = MangaReaderPresentationContent(
                informationLayout: ReaderAttachedInformationConfiguration(
                    topInset: informationTopInset, bottomInset: bottomInset,
                    titleSidePadding: model.canNavigateForward ? 128 : 76,
                    contentTopInset: pagedContentTopInset,
                    toolbarStyle: toolbarStyle
                ),
                presentation: presentation,
                imageLoader: model.imageLoader,
                isChromeVisible: showsChrome,
                likedPageIDs: model.likedPageIDs,
                pagedContentTopInset: pagedContentTopInset,
                controlPageTurnBridge: controlPageTurnBridge,
                pagedZoom: reader.pagedZoom,
                onRetryInitialLoad: {
                    Task { await model.retryInitialLoad() }
                },
                onCurrentPageChange: { globalIndex in
                    guard viewport.acceptsGeometry,
                          case let .loaded(previous) = presentation.state,
                          previous.pages.indices.contains(globalIndex) else { return }
                    model.updateCurrentPage(visiblePage: previous.pages[globalIndex], placement: previous.viewportPlacement)
                },
                canBoundaryPageTurn: { delta, usesTwoPageSpread in
                    model.canJumpRelativePage(delta, usesTwoPageSpread: usesTwoPageSpread)
                },
                onBoundaryPageTurn: { delta, usesTwoPageSpread in
                    navigateFromViewport {
                        await model.jumpRelativePage(delta, usesTwoPageSpread: usesTwoPageSpread)
                    }
                },
                onVerticalBoundaryPull: { boundary in
                    guard admitsContentInput else { return }
                    model.reportVerticalPageBoundary(boundary == .next ? 1 : -1)
                },
                onPageLongPress: { page in
                    openImageActions(page)
                },
                onTap: {
                    toggleChrome()
                }
            )
            .readerRemoteTarget(priority: 0, actions: ReaderRemoteActions(
                doubleTap: { point in remoteDoubleTap(at: point) },
                gestureID: remoteContentID,
                isAvailable: { admitsContentInput },
                hold: { point in
                    if model.presentation.settings.readingMode == .vertical {
                        return (controlPageTurnBridge.verticalViewport?.performRemoteImageAction(at: point) == true, nil)
                    }
                    guard let image = remoteImage(at: point) else { return (false, nil) }
                    image.onLongPress?()
                    return (true, nil)
                },
                transform: { remoteTransform(at: $0, zoom: $1) },
                mangaIsZoomed: {
                    if model.presentation.settings.readingMode == .vertical {
                        return controlPageTurnBridge.verticalViewport?.isZoomed == true
                    }
                    return controlPageTurnBridge.pagedSurface?()?.isZoomed == true
                },
                verticalScroll: {
                    guard model.presentation.settings.readingMode == .vertical else { return nil }
                    return controlPageTurnBridge.verticalViewport?.remoteScrollTarget()
                }
            ))
            .onChange(of: remoteContentID, initial: true) { _, identity in
                guard viewport.isCurrent, let identity else { return }
                remoteInput?.configure(model.presentation.settings.readingMode == .vertical ? .mangaVertical : .mangaPaged,
                                       content: identity)
            }
            .onChange(of: model.presentation.settings.gestureRegionLayout, initial: true) { _, layout in
                guard viewport.isCurrent else { return }
                remoteInput?.gestureRegionLayout = layout
            }
            .modifier(ReaderViewportRenderAcknowledgement(ready: model.hasCurrentPage, viewport: viewport))
            .onChange(of: initialPresentationFailed, initial: true) { _, failed in
                guard failed, viewport.acceptsGeometry else { return }
                viewport.didFailInitialPresentation?()
            }
            .ignoresSafeArea(.container, edges: .vertical)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: proxy.size, initial: true) { _, size in
                readingViewportInsets.update(viewport: size, topInset: topInset)
            }
            .onChange(of: topInset, initial: true) { _, inset in
                if inset > 0 { visibleStatusBarTopInset = inset }
            }
            .onChange(of: usesTwoPageSpread, initial: true) { _, newValue in
                controlUsesTwoPageSpread = newValue
            }
            .overlay {
                if externalGeometry == nil {
                    ApplePencilPageTurnInteractionOverlay(
                        settings: model.applePencilPageTurnSettings,
                        canTurnPage: canReceiveApplePencilPageTurn
                    ) { delta in
                        performPageTurn(delta, usesTwoPageSpread: usesTwoPageSpread)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .top) {
                if externalGeometry == nil {
                    chrome(topInset: informationTopInset, bottomInset: bottomInset,
                           isVisible: showsChrome, usesTwoPageSpread: usesTwoPageSpread) {
                        bottomChromeHeight = $0
                    }
                } else if externalMenuPresented, presentation.settings.readingMode == .vertical,
                          let summary = mangaChromeSummary(from: presentation, usesTwoPageSpread: false) {
                    ReaderExternalVerticalInformation(
                        page: .init(pageID: nil, title: summary.headerTitle, pageNumber: summary.pageNumber,
                                    pageLine: summary.pageSummary, webLine: ""),
                        topInset: informationTopInset, bottomInset: bottomInset
                    )
                }
            }
            .transientMessage(
                model.chapterJumpErrorMessage != nil || reader.imageSavePresentation.feedback != nil
                    ? nil : model.pageBoundary?.message,
                bottomPadding: showsChrome
                    ? max(bottomChromeHeight, bottomInset + 210) + 8
                    : max(bottomInset, 24) + 8
            ) {
                model.pageBoundary = nil
            }
            .onAppear {
                guard viewport.isCurrent else { return }
                viewport.attach(attachmentID, peripheralInput: appModel.peripheralInput,
                    capturePosition: {
                        let bridge = controlPageTurnBridge
                        let sample = bridge.capturePosition?()
                        if let page = sample?.page { model.updateCurrentPage(visiblePage: page, placement: sample?.placement) }
                        if let sample { reader.viewportHandoff.pendingFocus = sample.focus }
                    },
                    externalInput: remoteInput,
                    deviceMenu: deviceInteraction == nil ? nil : deviceMenu,
                    admitsApplePencilPageTurn: { canReceiveApplePencilPageTurn && admitsContentInput },
                    handleInput: handleControlEvent
                )
                reader.prepareIfNeeded()
            }
            .onDisappear {
                viewport.detach(attachmentID)
            }

            ReaderPanelHost(item: $reader.presentedPanel) {
                surface
                    .transientMessage(model.chapterJumpFeedback) {
                        model.chapterJumpErrorMessage = nil
                    }
            } panel: { panel, close in
                panelContent(panel, viewportSize: proxy.size, readingTopInset: readingTopInset, close: close)
            }
        }
        .ignoresSafeArea(.container, edges: .vertical)
        .background(Color.black.ignoresSafeArea())
        .readingHandoff(handoffPayload)
        .onChange(of: scenePhase) { _, phase in
            guard externalGeometry == nil, phase != .active, viewport.accepts(attachmentID) else { return }
            appModel.handoffPublisher.flushLatest(handoffPayload)
        }
        .background(ReaderWindowSafeAreaInsetsProbe(insets: $windowSafeAreaInsets))
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .fullScreenCover(item: $reader.forumThreadOverlayItem) { item in
            ForumThreadOverlayScreen(
                item: item,
                dependencies: forumDependencies,
                appModel: appModel,
                rootIsDiscussionView: true,
                discussionWorkTIDs: discussionWorkTIDs
            )
        }
        .sheet(item: $reader.noteEditTarget) { item in
            LikeNoteEditorSheet(item: item) { note in
                Task {
                    guard let annotation = model.annotationSheetContext else { return }
                    await model.annotationOperations.perform {
                        try await annotation.like.annotations.updateNote(id: item.id, note: note)
                    }
                }
            }
        }
        .confirmationDialog(
            L10n.string("image.actions.title"),
            isPresented: Binding(
                get: { reader.imageSavePresentation.isActionDialogPresented },
                set: { reader.imageSavePresentation.setActionDialogPresented($0) }
            ),
            titleVisibility: .visible
        ) {
            if let target = reader.imageSavePresentation.actionTarget {
                Button(L10n.string("image.save_to_photos")) {
                    Task {
                        await saveImage(target.page)
                    }
                }
                .disabled(reader.isSavingImage)

                if model.canSetMangaCover {
                    Button(L10n.string("cover.set_as_cover")) {
                        Task {
                            await setMangaCover(target.page)
                        }
                    }
                    if reader.canRestoreMangaCover {
                        Button(L10n.string("cover.restore_auto_cover")) {
                            Task {
                                await restoreMangaCover()
                            }
                        }
                    }
                }

                if let likedItem = reader.likedItemForActionTarget {
                    Button(L10n.string(likedItem.hasNote ? "likes.edit_note" : "likes.add_note")) {
                        reader.imageSavePresentation.clearActionTarget()
                        reader.likedItemForActionTarget = nil
                        editNote(likedItem)
                    }
                    Button(L10n.string("likes.remove_like"), role: .destructive) {
                        Task {
                            await unlikePage(likedItem)
                        }
                    }
                } else {
                    Button(L10n.string("likes.add_note")) {
                        Task {
                            await addNote(to: target.page)
                        }
                    }
                    Button(L10n.string("likes.add_to_likes")) {
                        Task {
                            await likePage(target.page)
                        }
                    }
                }
            }

            Button(L10n.string("common.cancel"), role: .cancel) {
                reader.imageSavePresentation.clearActionTarget()
                reader.likedItemForActionTarget = nil
            }
        }
        .transientMessage(
            reader.imageSavePresentation.feedback?.transientFeedback,
            bottomPadding: 28
        ) {
            reader.imageSavePresentation.feedback = nil
        }
        .onChange(of: reader.imageSavePresentation.feedback?.id) {
            if reader.imageSavePresentation.feedback != nil { model.chapterJumpErrorMessage = nil }
        }
        .onChange(of: model.chapterJumpFeedback?.id) {
            if model.chapterJumpFeedback != nil { reader.imageSavePresentation.feedback = nil }
        }
        .sensoryFeedback(trigger: reader.imageSavePresentation.feedback?.id) { _, _ in
            switch reader.imageSavePresentation.feedback?.kind {
            case .success, .custom:
                .success
            case .failure:
                .error
            case nil:
                nil
            }
        }
        .annotationOperationFeedback(model.annotationOperations)
        .failureAlert(
            L10n.string("image.save_photo_permission_denied_title"),
            message: L10n.string("image.save_photo_permission_denied"),
            details: LoadFailureDetails(error: ImagePhotoSaveError.authorizationDenied),
            isPresented: $reader.isPhotoPermissionAlertPresented
        ) {
            Button(L10n.string("favorites.updates.notifications_open_settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        }
        .environment(\.mangaViewportHandoff, reader.viewportHandoff)
        .environment(\.readingHandoffAllowed, allowsReadingHandoff && !context.isPreview)
    }

    private func chrome(
        topInset: CGFloat, bottomInset: CGFloat, isVisible: Bool, usesTwoPageSpread: Bool,
        onBottomChromeHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) -> some View {
        MangaReaderChromeControls(
            topInset: topInset,
            bottomInset: bottomInset,
            isVisible: isVisible,
            isPreview: context.isPreview,
            imageLoader: model.imageLoader,
            summary: mangaChromeSummary(from: model.presentation, usesTwoPageSpread: usesTwoPageSpread),
            readingMode: model.presentation.settings.readingMode,
            isImmersive: model.presentation.settings.isImmersiveModeEnabled,
            pageTurnDirection: model.presentation.settings.pageTurnDirection,
            canNavigateBack: model.canNavigateBack,
            canNavigateForward: model.canNavigateForward,
            onNavigateBack: {
                Task { await model.navigateBack() }
            },
            onNavigateForward: {
                Task { await model.navigateForward() }
            },
            onClose: closeReader,
            onShowDirectory: openDirectory,
            onShowComments: {
                reader.presentedPanel = .companion(.comments)
            },
            onShowSettings: {
                reader.presentedPanel = .settings
            },
            onShowDownload: {
                reader.presentedPanel = .download
            },
            onToggleBookmark: {
                Task { await model.toggleBookmarkForCurrentPage() }
            },
            onShowAnnotations: {
                guard model.canShowLikes else { return }
                reader.readerLibraryTab = ReaderLibraryPanelTab(
                    annotationSegment: annotationSegmentBinding.wrappedValue
                )
                reader.presentedPanel = .companion(.annotations)
            },
            isBookmarked: model.isCurrentPageBookmarked,
            annotationCapsule: model.annotationCapsule,
            onOpenOriginalPost: openOriginalPost,
            onJumpToLocalPage: { targetIndex in
                Task { await model.jumpToPage(localIndex: targetIndex) }
            },
            onBottomChromeHeightChange: onBottomChromeHeightChange
        )
    }

    private func deviceMenu(_ insets: EdgeInsets, isVisible: Bool) -> AnyView {
        AnyView(chrome(topInset: insets.top, bottomInset: insets.bottom,
                      isVisible: isVisible, usesTwoPageSpread: controlUsesTwoPageSpread)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing))
    }

    private func toggleChrome() {
        if let deviceInteraction {
            deviceInteraction.showMenu(from: viewport)
            return
        }
        withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
            reader.isChromeVisible.toggle()
        }
    }

    private var discussionWorkTIDs: Set<String> {
        var tids: Set<String> = [context.originalThreadID, context.chapterTID]
        if case let .loaded(loaded) = model.presentation.state {
            tids.formUnion(loaded.directoryPanel.displayChapters.map(\.tid))
        }
        return tids
    }

    @ViewBuilder
    private func panelContent(
        _ panel: MangaReaderPanel, viewportSize: CGSize, readingTopInset: CGFloat, close: @escaping () -> Void
    ) -> some View {
        switch panel {
        case .settings:
            MangaReaderSettingsSheet(
                model: model,
                settingsStore: dependencies.settingsStore,
                settingsTarget: viewport.settingsTarget,
                peripheralInput: appModel.peripheralInput,
                controlAccent: AppTheme.theme(for: appModel.appAppearanceSettings).controlAccent,
                readerViewportSize: viewportSize,
                readerTopInset: readingTopInset
            )
        case .download:
            if case let .loaded(loaded) = model.presentation.state {
                MangaReaderDownloadSheet(context: context, panel: loaded.directoryPanel, dependencies: dependencies)
            } else {
                MangaDirectoryUnavailableSheet()
            }
        case let .companion(companion):
            MangaReaderCompanionPanel(
                companion: companion,
                context: context,
                model: model,
                settingsTarget: viewport.settingsTarget,
                forumDependencies: forumDependencies,
                appModel: appModel,
                discussionWorkTIDs: discussionWorkTIDs,
                annotationSegment: annotationSegmentBinding,
                selectedTab: $reader.readerLibraryTab,
                dismissesAfterNavigation: true,
                onOpenBookmark: { item in Task { await openBookmark(item) } },
                onOpenLikeAnchor: { anchor in Task { await openLikedAnchor(anchor) } },
                onDismiss: close
            )
        }
    }

    private var canReceiveApplePencilPageTurn: Bool {
        guard case let .loaded(loaded) = model.presentation.state else { return false }
        return ReaderApplePencilPageTurnGate.canTurnPage(
            isPadDevice: UIDevice.current.userInterfaceIdiom == .pad,
            isPagedReadingMode: model.presentation.settings.readingMode == .paged,
            hasReadableContent: !loaded.pages.isEmpty,
            hasBlockingOverlay: reader.presentedPanel != nil
                || reader.noteEditTarget != nil
                || reader.forumThreadOverlayItem != nil,
            isDismissing: reader.isDismissing,
            isChromeVisible: showsChrome
        )
    }

    private var hasControlBlockingSheet: Bool {
        reader.presentedPanel != nil ||
            reader.noteEditTarget != nil ||
            reader.forumThreadOverlayItem != nil ||
            reader.imageSavePresentation.isActionDialogPresented ||
            reader.isPhotoPermissionAlertPresented
    }

    private var handoffPayload: YamiboHandoffPayload? {
        guard !reader.isDismissing, !hasControlBlockingSheet,
              case let .loaded(loaded) = model.presentation.state,
              loaded.currentPage != nil else { return nil }
        return .manga(model.currentResumeContext)
    }

    private func openDirectory() {
        guard context.isSmartModeEnabled else { return }
        if model.annotationSheetContext != nil {
            reader.readerLibraryTab = .chapters
            reader.presentedPanel = .companion(.annotations)
        } else {
            reader.presentedPanel = .companion(.directory)
        }
    }

    private func handleControlEvent(_ event: ReaderControlEvent) {
        guard !reader.isDismissing, !hasControlBlockingSheet else { return }
        guard case let .loaded(loaded) = model.presentation.state, !loaded.pages.isEmpty else {
            if event == .menu { toggleChrome() }
            return
        }

        let settings = model.presentation.settings
        let surface: ReaderControlSurface = settings.readingMode == .paged
            ? .paged(isRightToLeft: settings.pageTurnDirection == .rightToLeft)
            : .vertical
        guard let command = ReaderControlCommandResolver.readerCommand(for: event, surface: surface) else { return }

        switch command {
        case .toggleChrome:
            toggleChrome()
        case .openComments:
            reader.presentedPanel = .companion(.comments)
        case let .turnPage(delta):
            remoteInput?.interruptMotion()
            hideChromeForControlReading()
            performPageTurn(delta, usesTwoPageSpread: controlUsesTwoPageSpread)
        case let .scrollStep(direction):
            remoteInput?.interruptMotion()
            hideChromeForControlReading()
            if controlPageTurnBridge.verticalViewport?.performControlScrollStep(direction) == .atEdge {
                navigateFromViewport {
                    await model.jumpToAdjacentChapterFromVerticalBoundary(direction == .down ? 1 : -1)
                }
            }
        }
    }

    private func navigateFromViewport(_ operation: @escaping () async -> Void) {
        let contentID = model.viewportContentID
        viewport.enqueueInput(attachmentID, while: { admitsContentInput && model.viewportContentID == contentID }, operation)
    }

    private func performPageTurn(_ delta: Int, usesTwoPageSpread: Bool) {
        if model.presentation.settings.readingMode == .paged {
            controlPageTurnBridge.requestPageTurn(delta)
            return
        }
        navigateFromViewport { await model.jumpRelativePage(delta, usesTwoPageSpread: usesTwoPageSpread) }
    }

    private func hideChromeForControlReading() {
        guard showsChrome else { return }
        withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
            reader.isChromeVisible = false
        }
    }

    private func closeReader() {
        guard !reader.isDismissing else { return }
        reader.isDismissing = true
        onClose()
    }

    private func openOriginalPost() {
        guard !reader.isDismissing else { return }
        reader.isDismissing = true
        let url = model.currentForumTargetURL
        let context = model.currentResumeContext
        Task {
            if !(await onOpenOriginalPost(url, context, { await model.saveProgress() })) {
                reader.isDismissing = false
            }
        }
    }

    private func openImageActions(_ page: MangaReaderPageProjection) {
        guard !reader.isSavingImage, !hasControlBlockingSheet, viewport.acceptsGeometry else { return }
        Task {
            let canRestoreCover = model.canSetMangaCover ? await model.hasManualMangaCover() : false
            let likedItem: LikeItem?
            do { likedItem = try await model.isPageLiked(page) }
            catch {
                model.annotationOperations.report(error)
                return
            }
            guard viewport.acceptsGeometry, !hasControlBlockingSheet else { return }
            if let deviceInteraction {
                let image = ImageBrowserItem(id: page.id, source: model.imageSource(for: page), title: context.displayTitle)
                deviceInteraction.present { _ in
                    MangaReaderDeviceImageActions(
                        image: image,
                        likedItem: likedItem,
                        setCover: model.canSetMangaCover ? { Task { await setMangaCover(page) } } : nil,
                        restoreCover: model.canSetMangaCover && canRestoreCover ? { Task { await restoreMangaCover() } } : nil,
                        addLike: { Task { await likePage(page) } },
                        removeLike: { item in Task { await unlikePage(item) } },
                        createNoteItem: { await prepareNoteItem(for: page) },
                        saveNote: { item, note in await saveNote(note, to: item) }
                    )
                }
            } else {
                reader.canRestoreMangaCover = canRestoreCover
                reader.likedItemForActionTarget = likedItem
                reader.imageSavePresentation.presentActions(for: page)
            }
        }
    }

    @MainActor
    private func saveImage(_ page: MangaReaderPageProjection) async {
        guard !reader.isSavingImage else { return }
        reader.imageSavePresentation.clearActionTarget()

        reader.isSavingImage = true
        defer {
            reader.isSavingImage = false
        }

        do {
            let data = try await dependencies.imagePipeline.data(for: model.imageSource(for: page))
            let photoSaver = ImagePhotoSaver()
            try await photoSaver.saveImageData(data)
            reader.imageSavePresentation.finishSave(with: .success)
        } catch ImagePhotoSaveError.authorizationDenied {
            guard !Task.isCancelled else { return }
            YamiboLog.reader.warning("Manga page image save denied: Photos authorization was not granted")
            reader.isPhotoPermissionAlertPresented = true
        } catch {
            guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            YamiboLog.reader.error("Failed to save manga page image: \(error.localizedDescription)")
            reader.imageSavePresentation.finishSave(with: .failure(message: L10n.string("image.save_failed"),
                                                           details: LoadFailureDetails(error: error)))
        }
    }

    @MainActor
    private func setMangaCover(_ page: MangaReaderPageProjection) async {
        reader.imageSavePresentation.clearActionTarget()
        let succeeded = await model.setMangaCover(page: page)
        guard !Task.isCancelled, !model.coverActionWasCancelled else { return }
        reader.imageSavePresentation.finishSave(with: succeeded
            ? .custom(
                title: L10n.string("cover.action_success_title"),
                message: L10n.string("cover.set_success_message")
            )
            : .failure(message: L10n.string("image.action_failed"), details: model.coverActionFailureDetails))
    }

    @MainActor
    private func restoreMangaCover() async {
        reader.imageSavePresentation.clearActionTarget()
        let succeeded = await model.restoreAutomaticMangaCover()
        guard !Task.isCancelled, !model.coverActionWasCancelled else { return }
        reader.imageSavePresentation.finishSave(with: succeeded
            ? .custom(
                title: L10n.string("cover.action_success_title"),
                message: L10n.string("cover.restore_success_message")
            )
            : .failure(message: L10n.string("image.action_failed"), details: model.coverActionFailureDetails))
    }

    @MainActor
    private func likePage(_ page: MangaReaderPageProjection) async {
        reader.imageSavePresentation.clearActionTarget()
        reader.likedItemForActionTarget = nil
        guard let outcome = await model.likePage(page) else {
            guard !Task.isCancelled, !model.likeActionWasCancelled else { return }
            reader.imageSavePresentation.finishSave(with: .failure(message: L10n.string("image.action_failed"),
                                                           details: model.likeActionFailureDetails))
            return
        }
        switch outcome {
        case .added, .merged, .alreadyLiked:
            reader.imageSavePresentation.finishSave(with: .custom(
                title: L10n.string("likes.already_liked"),
                message: ""
            ))
        }
    }

    @MainActor
    private func addNote(to page: MangaReaderPageProjection) async {
        if let item = await prepareNoteItem(for: page) { editNote(item) }
    }

    @MainActor
    private func prepareNoteItem(for page: MangaReaderPageProjection) async -> LikeItem? {
        reader.imageSavePresentation.clearActionTarget()
        reader.likedItemForActionTarget = nil
        guard let outcome = await model.likePage(page) else {
            guard !Task.isCancelled, !model.likeActionWasCancelled else { return nil }
            reader.imageSavePresentation.finishSave(with: .failure(message: L10n.string("image.action_failed"),
                                                           details: model.likeActionFailureDetails))
            return nil
        }

        switch outcome {
        case let .added(item), let .merged(item), let .alreadyLiked(item):
            return item
        }
    }

    private func editNote(_ item: LikeItem) {
        if let deviceInteraction {
            deviceInteraction.editNote(item) { note in
                await saveNote(note, to: item)
            }
        } else {
            reader.noteEditTarget = item
        }
    }

    private func saveNote(_ note: String?, to item: LikeItem) async -> Bool {
        guard let annotation = model.annotationSheetContext else { return false }
        return await model.annotationOperations.perform {
            try await annotation.like.annotations.updateNote(id: item.id, note: note)
        } != nil
    }

    @MainActor
    private func unlikePage(_ item: LikeItem) async {
        reader.imageSavePresentation.clearActionTarget()
        reader.likedItemForActionTarget = nil
        let succeeded = await model.unlikePage(item)
        guard !Task.isCancelled, !model.likeActionWasCancelled else { return }
        reader.imageSavePresentation.finishSave(with: succeeded
            ? .custom(title: L10n.string("likes.remove_like"), message: "")
            : .failure(message: L10n.string("image.action_failed"), details: model.likeActionFailureDetails))
    }

    private var annotationSegmentBinding: Binding<ReaderAnnotationSegment> {
        Binding(
            get: { reader.rememberedAnnotationSegment ?? model.annotationCapsule.initialSegment(remembering: nil) },
            set: { reader.rememberedAnnotationSegment = $0 }
        )
    }

    private func openBookmark(_ item: BookmarkItem) async {
        guard case let .manga(anchor) = item.anchor else { return }
        if reader.presentedPanel == .companion(.annotations) { reader.presentedPanel = nil }
        if await model.jumpToLikedMangaPage(tid: anchor.chapterTID, localIndex: anchor.pageLocalIndex) {
            return
        }
        appModel.requestMangaReader(
            MangaLaunchContext(
                originalThreadID: context.originalThreadID,
                chapterTID: anchor.chapterTID,
                displayTitle: context.displayTitle,
                source: .like,
                initialPage: anchor.pageLocalIndex,
                directoryName: context.directoryName,
                directoryID: model.currentDirectoryID,
                downloadFavoriteID: context.downloadFavoriteID,
                isSmartModeEnabled: context.isSmartModeEnabled,
                forumID: anchor.forumID ?? context.forumID
            )
        )
    }

    private func openLikedAnchor(_ anchor: LikeAnchorPayload) async {
        guard case let .mangaImage(mangaAnchor) = anchor else { return }
        if await model.jumpToLikedMangaPage(tid: mangaAnchor.chapterTID, localIndex: mangaAnchor.pageLocalIndex) {
            return
        }
        appModel.requestMangaReader(
            MangaLaunchContext(
                originalThreadID: context.originalThreadID,
                chapterTID: mangaAnchor.chapterTID,
                displayTitle: context.displayTitle,
                source: .like,
                initialPage: mangaAnchor.pageLocalIndex,
                directoryName: context.directoryName,
                directoryID: model.currentDirectoryID,
                downloadFavoriteID: context.downloadFavoriteID,
                isSmartModeEnabled: context.isSmartModeEnabled,
                forumID: context.forumID
            )
        )
    }

    private func mangaChromeSummary(
        from presentation: MangaReaderPresentation,
        usesTwoPageSpread: Bool
    ) -> MangaReaderChromeSummary? {
        guard case let .loaded(loaded) = presentation.state,
              !loaded.pages.isEmpty else {
            return nil
        }

        let pages = loaded.pages
        let currentPage = loaded.currentPage
            ?? loaded.currentPageIndex.flatMap { pages.indices.contains($0) ? pages[$0] : nil }
            ?? pages[0]
        let currentPageIndex = loaded.currentPageIndex ?? pages.firstIndex(of: currentPage)
        let itemCount = max(currentPage.chapterPageCount, 1)
        let currentIndex = min(max(currentPage.localIndex, 0), itemCount - 1)
        let progressFraction = ReaderPageProgress.fraction(index: currentIndex, count: itemCount)
        let percentText = "\(Int((progressFraction * 100).rounded()))%"
        let readingPlan = chromeSummaryMemo.plan(
            loaded: loaded,
            currentPageIndex: currentPageIndex,
            pageTurnDirection: presentation.settings.pageTurnDirection,
            usesTwoPageSpread: usesTwoPageSpread
        )
        let pageLabel = readingPlan.currentChapterPageLabel
        let pageSummary = L10n.string("manga.preview_page_label", pageLabel, itemCount)
        let headerTitle = chromeSummaryMemo.headerTitle(for: currentPage, loaded: loaded)
        let pagePreviewTargets = chromeSummaryMemo.previewTargets(for: currentPage.tid)
        let capsuleTitleKey = context.isSmartModeEnabled ? "manga.directory" : "manga.progress"
        let capsuleIconSystemName = context.isSmartModeEnabled ? "list.bullet" : "chart.bar.fill"
        var progress = ReaderChromeProgress(
            itemCount: itemCount,
            currentIndex: currentIndex,
            progressFraction: progressFraction,
            percentText: percentText,
            primaryText: L10n.string(capsuleTitleKey) + " · \(percentText)",
            secondaryText: pageSummary,
            ticks: [],
            iconSystemName: capsuleIconSystemName,
            scrubTargetIndexes: [0]
        )
        progress.useValidatedScrubTargetIndexes(chromeSummaryMemo.scrubTargets(itemCount: itemCount))

        return MangaReaderChromeSummary(
            headerTitle: headerTitle,
            pageSummary: pageSummary,
            pagePreviewTargets: pagePreviewTargets,
            progress: progress,
            spreadPageSummaries: readingPlan.spreadPageSummaries,
            spreadWorkTitle: usesTwoPageSpread ? loaded.directoryTitle : nil,
            spreadPageNumbers: readingPlan.spreadPageNumbers,
            pageNumber: currentIndex + 1,
            remainingChapterPageCount: readingPlan.remainingChapterPageCount
        )
    }
}

@MainActor
private final class MangaChromeSummaryMemo {
    private var basePlan: MangaPagedReadingPlan?
    private var previewsByChapter: [String: [Int: MangaReaderPageProjection]] = [:]
    private var chapters: [MangaChapter] = []
    private var rawTitles: [String: String] = [:]
    private var headerKey: [String] = []
    private var cachedHeader = ""
    private var cachedScrubTargets: [Int] = []

    nonisolated init() {}

    func plan(loaded: MangaReaderLoadedPresentation, currentPageIndex: Int?,
              pageTurnDirection: MangaPageTurnDirection, usesTwoPageSpread: Bool) -> MangaPagedReadingPlan {
        let pagesChanged = basePlan?.pages != loaded.pages
        if pagesChanged {
            previewsByChapter = [:]
            for page in loaded.pages {
                previewsByChapter[page.tid, default: [:]][page.localIndex] = page
            }
        }
        if pagesChanged || basePlan?.pageTurnDirection != pageTurnDirection
            || basePlan?.usesTwoPageSpread != usesTwoPageSpread {
            basePlan = MangaPagedReadingPlan(pages: loaded.pages, currentPageIndex: nil,
                pageTurnDirection: pageTurnDirection, usesTwoPageSpread: usesTwoPageSpread)
        }
        return basePlan!.selectingPage(at: currentPageIndex)
    }

    func previewTargets(for tid: String) -> [Int: MangaReaderPageProjection] {
        previewsByChapter[tid] ?? [:]
    }

    func scrubTargets(itemCount: Int) -> [Int] {
        if cachedScrubTargets.count != itemCount { cachedScrubTargets = Array(0 ..< itemCount) }
        return cachedScrubTargets
    }

    func headerTitle(for page: MangaReaderPageProjection, loaded: MangaReaderLoadedPresentation) -> String {
        if chapters != loaded.directoryPanel.displayChapters {
            chapters = loaded.directoryPanel.displayChapters
            rawTitles = [:]
            for chapter in chapters where rawTitles[chapter.tid] == nil {
                rawTitles[chapter.tid] = chapter.rawTitle
            }
        }
        let rawTitle = rawTitles[page.tid] ?? page.chapterTitle
        let key = [rawTitle, loaded.directoryTitle, Locale.current.identifier,
                   L10n.bundle.preferredLocalizations.joined(separator: ",")]
        if headerKey != key {
            headerKey = key
            cachedHeader = MangaChapterDisplayFormatter.readerHeaderTitle(
                rawTitle: rawTitle, cleanBookName: loaded.directoryTitle)
        }
        return cachedHeader
    }
}

#endif

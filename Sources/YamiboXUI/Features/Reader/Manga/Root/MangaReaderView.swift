import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

public struct MangaReaderView: View {
    @Environment(\.readerToolbarStyle) private var toolbarStyle
    private let context: MangaLaunchContext
    private let dependencies: MangaReaderDependencies
    private let forumDependencies: ForumNavigationDependencies
    private let appModel: YamiboAppModel
    /// `@State` (not `@StateObject`) because the view model is `@Observable`.
    /// SwiftUI keeps the first instance for the view's lifetime; the
    /// constructions on later `init` calls are discarded, which is safe here
    /// because `MangaReaderViewModel.init` only stores its context and
    /// dependencies plus a loading-placeholder presentation, and has no side
    /// effects (workflow and modules are created in `prepare()`/on first use).
    @State private var model: MangaReaderViewModel
    @State private var isDismissing = false
    @State private var isChromeVisible = true
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var companionPanel: MangaReaderCompanion?
    @State private var forumThreadOverlayItem: ForumThreadOverlayItem?
    @State private var isSettingsPresented = false
    @State private var isDownloadPresented = false
    /// Remembered for the reader session so reopening returns to the segment
    /// the user last looked at; nil means "not chosen yet".
    @State private var rememberedAnnotationSegment: ReaderAnnotationSegment?
    /// Which tab the unified reader-library sheet should initially show for
    /// its next presentation.
    @State private var initialReaderLibraryTab: ReaderLibraryPanelTab = .bookmarks
    @State private var likedItemForActionTarget: LikeItem?
    /// Item-driven so the editor always renders the note it was opened for,
    /// even if the store changes underneath while it is up.
    @State private var noteEditTarget: LikeItem?
    @State private var imageSavePresentation = MangaImageSavePresentationState()
    @State private var isPhotoPermissionAlertPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var canRestoreMangaCover = false
    @State private var isSavingImage = false
    @State private var controlHandlerToken: UUID?
    @State private var controlScrollStep: ReaderControlScrollStepRequest?
    @State private var controlPageTurnBridge = MangaPagedControlPageTurnBridge()
    @State private var controlUsesTwoPageSpread = false
    @State private var chromeSummaryMemo = MangaChromeSummaryMemo()
    /// Scene-local window safe-area insets reported by
    /// `ReaderWindowSafeAreaInsetsProbe`; nil until this reader attaches.
    @State private var windowSafeAreaInsets: UIEdgeInsets?
    @State private var readingViewportInsets = MangaReadingViewportInsets()
    @State private var visibleStatusBarTopInset: CGFloat = 0

    private let onClose: () -> Void
    private let onOpenOriginalPost: (URL, MangaLaunchContext, @escaping @MainActor () async -> MangaLaunchContext) async -> Bool

    public init(
        context: MangaLaunchContext,
        dependencies: MangaReaderDependencies,
        forumDependencies: ForumNavigationDependencies,
        appModel: YamiboAppModel,
        initialProjection: MangaReaderProjection? = nil,
        onClose: (() -> Void)? = nil,
        onOpenOriginalPost: ((URL, MangaLaunchContext, @escaping @MainActor () async -> MangaLaunchContext) async -> Bool)? = nil,
        onResumeRouteChange: ReaderResumeRouteChangeHandler? = nil
    ) {
        self.context = context
        self.dependencies = dependencies
        self.forumDependencies = forumDependencies
        self.appModel = appModel
        self.onClose = onClose ?? { appModel.dismissMangaReader() }
        self.onOpenOriginalPost = onOpenOriginalPost ?? { url, context, saveProgress in
            await appModel.switchReaderToOriginalPost(url: url, resumeRoute: .manga(context)) {
                .manga(await saveProgress())
            }
        }
        // `State(initialValue:)` evaluates its argument on every init (unlike
        // `StateObject(wrappedValue:)`'s autoclosure), so a view model is now
        // built — and, past the first init, discarded — on each parent
        // render. Accepted deliberately, mirroring `LocalFavoritesRootView`:
        // the init is side-effect-free, so the extra constructions are inert.
        _model = State(
            initialValue: MangaReaderViewModel(
                context: context,
                dependencies: dependencies,
                initialProjection: initialProjection,
                imagePipeline: appModel.imagePipeline,
                onReaderResumeRouteChange: { route in
                    if let onResumeRouteChange {
                        await onResumeRouteChange(route)
                    } else {
                        appModel.updateReaderResumeRoute(route)
                    }
                }
            )
        )
    }

    public var body: some View {
        GeometryReader { proxy in
            let topInset = max(proxy.safeAreaInsets.top, windowSafeAreaInsets?.top ?? proxy.safeAreaInsets.top)
            // iPad hides the status-bar safe area before the information fade finishes.
            let informationTopInset = UIDevice.current.userInterfaceIdiom == .pad
                ? max(topInset, visibleStatusBarTopInset) : topInset
            let bottomInset = max(proxy.safeAreaInsets.bottom, windowSafeAreaInsets?.bottom ?? proxy.safeAreaInsets.bottom)
            let usesTwoPageSpread = MangaPagedLayoutPolicy.usesTwoPageSpread(
                settings: model.presentation.settings,
                isPadDevice: UIDevice.current.userInterfaceIdiom == .pad,
                availableSize: proxy.size
            )
            let readingTopInset = readingViewportInsets.topInset(for: proxy.size, proposed: topInset)
            let pagedContentTopInset = MangaPagedLayoutPolicy.pagedContentTopInset(
                settings: model.presentation.settings,
                topInset: readingTopInset
            )

            MangaReaderPresentationContent(
                informationLayout: ReaderAttachedInformationConfiguration(
                    topInset: informationTopInset, bottomInset: bottomInset,
                    titleSidePadding: model.canNavigateForward ? 128 : 76,
                    contentTopInset: pagedContentTopInset,
                    toolbarStyle: toolbarStyle
                ),
                presentation: model.presentation,
                imageLoader: model.imageLoader,
                isChromeVisible: isChromeVisible,
                likedPageIDs: model.likedPageIDs,
                pagedContentTopInset: pagedContentTopInset,
                controlScrollStep: controlScrollStep,
                controlPageTurnBridge: controlPageTurnBridge,
                onRetryInitialLoad: {
                    Task { await model.retryInitialLoad() }
                },
                onCurrentPageChange: { globalIndex in
                    model.updateCurrentPage(globalIndex: globalIndex)
                },
                canBoundaryPageTurn: { delta, usesTwoPageSpread in
                    model.canJumpRelativePage(delta, usesTwoPageSpread: usesTwoPageSpread)
                },
                onBoundaryPageTurn: { delta, usesTwoPageSpread in
                    Task { await model.jumpRelativePage(delta, usesTwoPageSpread: usesTwoPageSpread) }
                },
                onControlScrollEdgeReached: { direction in
                    Task {
                        await model.jumpToAdjacentChapterFromVerticalBoundary(direction == .down ? 1 : -1)
                    }
                },
                onVerticalBoundaryPull: { boundary in
                    model.reportVerticalPageBoundary(boundary == .next ? 1 : -1)
                },
                onPageLongPress: { page in
                    guard !isSavingImage else { return }
                    Task {
                        canRestoreMangaCover = await model.hasManualMangaCover()
                        do { likedItemForActionTarget = try await model.isPageLiked(page) }
                        catch {
                            model.annotationOperations.report(error)
                            return
                        }
                        imageSavePresentation.presentActions(for: page)
                    }
                },
                onTap: {
                    toggleChrome()
                }
            )
            .ignoresSafeArea()
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
            .sheet(isPresented: $isSettingsPresented) {
                MangaReaderSettingsSheet(
                    model: model,
                    settingsStore: dependencies.settingsStore,
                    peripheralInput: appModel.peripheralInput,
                    controlAccent: AppTheme.theme(for: appModel.appThemePreset).controlAccent,
                    readerViewportSize: proxy.size,
                    readerTopInset: readingTopInset
                )
            }
            .overlay {
                ApplePencilPageTurnInteractionOverlay(
                    settings: model.applePencilPageTurnSettings,
                    canTurnPage: canReceiveApplePencilPageTurn
                ) { delta in
                    performPageTurn(delta, usesTwoPageSpread: usesTwoPageSpread)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                MangaReaderChromeControls(
                    topInset: informationTopInset,
                    bottomInset: bottomInset,
                    isVisible: isChromeVisible,
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
                    onShowDirectory: {
                        // Smart Comic Mode off (decision #2/#12): there is no
                        // `MangaDirectory` to show — `MangaReaderWorkflow`
                        // skipped resolution entirely and is holding a
                        // single-chapter pseudo-directory. The capsule itself
                        // keeps showing its own within-chapter page-progress
                        // text unaffected (that comes from `summary?.progress`
                        // independently of this closure); only the
                        // tap-to-open-directory-sheet interaction becomes a
                        // no-op.
                        guard model.context.isSmartModeEnabled else { return }
                        if model.annotationSheetContext != nil {
                            initialReaderLibraryTab = .chapters
                            companionPanel = .annotations
                        } else {
                            // A directory may become available before a Like
                            // identity does; keep that narrow transition on
                            // the existing directory-only fallback rather than
                            // presenting an empty unified sheet.
                            companionPanel = .directory
                        }
                    },
                    onShowComments: {
                        companionPanel = .comments
                    },
                    onShowSettings: {
                        isSettingsPresented = true
                    },
                    onShowDownload: {
                        isDownloadPresented = true
                    },
                    onToggleBookmark: {
                        Task { await model.toggleBookmarkForCurrentPage() }
                    },
                    onShowAnnotations: {
                        guard model.canShowLikes else { return }
                        initialReaderLibraryTab = ReaderLibraryPanelTab(
                            annotationSegment: annotationSegmentBinding.wrappedValue
                        )
                        companionPanel = .annotations
                    },
                    isBookmarked: model.isCurrentPageBookmarked,
                    annotationCapsule: model.annotationCapsule,
                    onOpenOriginalPost: openOriginalPost,
                    onJumpToLocalPage: { targetIndex in
                        Task { await model.jumpToPage(localIndex: targetIndex) }
                    },
                    onBottomChromeHeightChange: { height in
                        bottomChromeHeight = height
                    }
                )
            }
            .task {
                await model.prepare()
            }
            .transientMessage(
                model.chapterJumpErrorMessage != nil || imageSavePresentation.feedback != nil
                    ? nil : model.pageBoundary?.message,
                bottomPadding: isChromeVisible
                    ? max(bottomChromeHeight, bottomInset + 210) + 8
                    : max(bottomInset, 24) + 8
            ) {
                model.pageBoundary = nil
            }
            .onAppear {
                guard controlHandlerToken == nil else { return }
                controlHandlerToken = appModel.peripheralInput.pushHandler { event in
                    handleControlEvent(event)
                }
            }
            .onDisappear {
                appModel.peripheralInput.removeHandler(controlHandlerToken)
                controlHandlerToken = nil
                if isDismissing {
                    model.close()
                } else {
                    Task { await model.saveProgress() }
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .background(ReaderWindowSafeAreaInsetsProbe(insets: $windowSafeAreaInsets))
        .statusBarHidden(!isChromeVisible)
        .persistentSystemOverlays(isChromeVisible ? .automatic : .hidden)
        .transientMessage(model.chapterJumpFeedback) {
            model.chapterJumpErrorMessage = nil
        }
        .modifier(ReaderCompanionPresentation(isPresented: $companionPanel.isPresented) {
            if let companionPanel {
                MangaReaderCompanionPanel(
                    companion: companionPanel,
                    context: context,
                    model: model,
                    forumDependencies: forumDependencies,
                    appModel: appModel,
                    discussionWorkTIDs: discussionWorkTIDs,
                    annotationSegment: annotationSegmentBinding,
                    initialTab: initialReaderLibraryTab,
                    dismissesAfterNavigation: true,
                    onOpenBookmark: { item in Task { await openBookmark(item) } },
                    onOpenLikeAnchor: { anchor in Task { await openLikedAnchor(anchor) } },
                    onDismiss: { self.companionPanel = nil }
                )
            }
        })
        .fullScreenCover(item: $forumThreadOverlayItem) { item in
            ForumThreadOverlayScreen(
                item: item,
                dependencies: forumDependencies,
                appModel: appModel,
                rootIsDiscussionView: true,
                discussionWorkTIDs: discussionWorkTIDs
            )
        }
        .sheet(isPresented: $isDownloadPresented) {
            if case let .loaded(loaded) = model.presentation.state {
                MangaReaderDownloadSheet(
                    context: context,
                    panel: loaded.directoryPanel,
                    dependencies: dependencies
                )
            } else {
                MangaDirectoryUnavailableSheet()
            }
        }
        .sheet(item: $noteEditTarget) { item in
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
                get: { imageSavePresentation.isActionDialogPresented },
                set: { imageSavePresentation.setActionDialogPresented($0) }
            ),
            titleVisibility: .visible
        ) {
            if let target = imageSavePresentation.actionTarget {
                Button(L10n.string("image.save_to_photos")) {
                    Task {
                        await saveImage(target.page)
                    }
                }
                .disabled(isSavingImage)

                if model.canSetMangaCover {
                    Button(L10n.string("cover.set_as_cover")) {
                        Task {
                            await setMangaCover(target.page)
                        }
                    }
                    if canRestoreMangaCover {
                        Button(L10n.string("cover.restore_auto_cover")) {
                            Task {
                                await restoreMangaCover()
                            }
                        }
                    }
                }

                if let likedItem = likedItemForActionTarget {
                    // A note lives on a like, so this only appears once the
                    // page is liked — the same "notes depend on likes" rule the
                    // novel reader follows.
                    Button(L10n.string(likedItem.hasNote ? "likes.edit_note" : "likes.add_note")) {
                        imageSavePresentation.clearActionTarget()
                        likedItemForActionTarget = nil
                        noteEditTarget = likedItem
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
                imageSavePresentation.clearActionTarget()
                likedItemForActionTarget = nil
            }
        }
        .transientMessage(
            imageSavePresentation.feedback?.transientFeedback,
            bottomPadding: 28
        ) {
            imageSavePresentation.feedback = nil
        }
        .onChange(of: imageSavePresentation.feedback?.id) {
            if imageSavePresentation.feedback != nil { model.chapterJumpErrorMessage = nil }
        }
        .onChange(of: model.chapterJumpFeedback?.id) {
            if model.chapterJumpFeedback != nil { imageSavePresentation.feedback = nil }
        }
        .sensoryFeedback(trigger: imageSavePresentation.feedback?.id) { _, _ in
            switch imageSavePresentation.feedback?.kind {
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
            isPresented: $isPhotoPermissionAlertPresented
        ) {
            Button(L10n.string("favorites.updates.notifications_open_settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        }
    }

    private func toggleChrome() {
        guard canToggleChrome else { return }
        withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
            isChromeVisible.toggle()
        }
    }

    private var canToggleChrome: Bool {
        guard case let .loaded(loaded) = model.presentation.state else { return false }
        return !loaded.pages.isEmpty
    }

    /// Every thread ID this reading session covers: the work thread plus (for
    /// smart manga) all directory chapter threads. Threads from this set
    /// opened inside a forum overlay stay discussion companions and must not
    /// write their own browsing-history rows.
    private var discussionWorkTIDs: Set<String> {
        var tids: Set<String> = [context.originalThreadID, context.chapterTID]
        if case let .loaded(loaded) = model.presentation.state {
            tids.formUnion(loaded.directoryPanel.displayChapters.map(\.tid))
        }
        return tids
    }

    private var canReceiveApplePencilPageTurn: Bool {
        guard case let .loaded(loaded) = model.presentation.state else { return false }
        return ReaderApplePencilPageTurnGate.canTurnPage(
            isPadDevice: UIDevice.current.userInterfaceIdiom == .pad,
            isPagedReadingMode: model.presentation.settings.readingMode == .paged,
            hasReadableContent: !loaded.pages.isEmpty,
            hasBlockingOverlay: companionPanel != nil
                || isSettingsPresented
                || isDownloadPresented
                || noteEditTarget != nil
                || forumThreadOverlayItem != nil,
            isDismissing: isDismissing,
            isChromeVisible: isChromeVisible
        )
    }

    private var hasControlBlockingSheet: Bool {
        companionPanel != nil ||
            isSettingsPresented ||
            isDownloadPresented ||
            noteEditTarget != nil ||
            forumThreadOverlayItem != nil
    }

    private func handleControlEvent(_ event: ReaderControlEvent) {
        guard !isDismissing, !hasControlBlockingSheet else { return }
        guard case let .loaded(loaded) = model.presentation.state, !loaded.pages.isEmpty else {
            // Loading/error: Menu still toggles the chrome so a controller
            // user can always reach the close button.
            if event == .menu {
                withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
                    isChromeVisible.toggle()
                }
            }
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
            companionPanel = .comments
        case let .turnPage(delta):
            hideChromeForControlReading()
            performPageTurn(delta, usesTwoPageSpread: controlUsesTwoPageSpread)
        case let .scrollStep(direction):
            hideChromeForControlReading()
            controlScrollStep = ReaderControlScrollStepRequest(
                direction: direction,
                revision: (controlScrollStep?.revision ?? 0) + 1
            )
        }
    }

    /// Non-touch page-turn triggers (keyboard, gamepad, Apple Pencil) share
    /// this entry point so a fit-height/zoomed page reveals its hidden edge
    /// content on the first press instead of jumping straight to the next
    /// page — the same defer-to-surface decision a tap in the edge zone
    /// already makes, surfaced through `controlPageTurnBridge`.
    private func performPageTurn(_ delta: Int, usesTwoPageSpread: Bool) {
        if model.presentation.settings.readingMode == .paged {
            controlPageTurnBridge.requestPageTurn(delta)
            return
        }
        Task { await model.jumpRelativePage(delta, usesTwoPageSpread: usesTwoPageSpread) }
    }

    /// A page turn while the chrome is up means "keep reading": perform it
    /// and tuck the chrome away, mirroring the tap-zone mental model.
    private func hideChromeForControlReading() {
        guard isChromeVisible else { return }
        withAnimation(.easeInOut(duration: ReaderChromeVisibilityAnimationPresentation.fade.duration)) {
            isChromeVisible = false
        }
    }

    private func closeReader() {
        guard !isDismissing else { return }
        isDismissing = true
        Task {
            await model.saveProgress()
            model.close()
            onClose()
        }
    }

    private func openOriginalPost() {
        guard !isDismissing else { return }
        isDismissing = true
        let url = model.currentForumTargetURL
        let context = model.currentResumeContext
        Task {
            if await onOpenOriginalPost(url, context, { await model.saveProgress() }) {
                model.close()
            } else {
                isDismissing = false
            }
        }
    }

    @MainActor
    private func saveImage(_ page: MangaReaderPageProjection) async {
        guard !isSavingImage else { return }
        imageSavePresentation.clearActionTarget()

        isSavingImage = true
        defer {
            isSavingImage = false
        }

        do {
            let data = try await dependencies.imagePipeline.data(for: model.imageSource(for: page))
            let photoSaver = ImagePhotoSaver()
            try await photoSaver.saveImageData(data)
            imageSavePresentation.finishSave(with: .success)
        } catch ImagePhotoSaveError.authorizationDenied {
            guard !Task.isCancelled else { return }
            YamiboLog.reader.warning("Manga page image save denied: Photos authorization was not granted")
            isPhotoPermissionAlertPresented = true
        } catch {
            guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            YamiboLog.reader.error("Failed to save manga page image: \(error.localizedDescription)")
            imageSavePresentation.finishSave(with: .failure(message: L10n.string("image.save_failed"),
                                                           details: LoadFailureDetails(error: error)))
        }
    }

    @MainActor
    private func setMangaCover(_ page: MangaReaderPageProjection) async {
        imageSavePresentation.clearActionTarget()
        let succeeded = await model.setMangaCover(page: page)
        guard !Task.isCancelled, !model.coverActionWasCancelled else { return }
        imageSavePresentation.finishSave(with: succeeded
            ? .custom(
                title: L10n.string("cover.action_success_title"),
                message: L10n.string("cover.set_success_message")
            )
            : .failure(message: L10n.string("image.action_failed"), details: model.coverActionFailureDetails))
    }

    @MainActor
    private func restoreMangaCover() async {
        imageSavePresentation.clearActionTarget()
        let succeeded = await model.restoreAutomaticMangaCover()
        guard !Task.isCancelled, !model.coverActionWasCancelled else { return }
        imageSavePresentation.finishSave(with: succeeded
            ? .custom(
                title: L10n.string("cover.action_success_title"),
                message: L10n.string("cover.restore_success_message")
            )
            : .failure(message: L10n.string("image.action_failed"), details: model.coverActionFailureDetails))
    }

    @MainActor
    private func likePage(_ page: MangaReaderPageProjection) async {
        imageSavePresentation.clearActionTarget()
        likedItemForActionTarget = nil
        guard let outcome = await model.likePage(page) else {
            guard !Task.isCancelled, !model.likeActionWasCancelled else { return }
            imageSavePresentation.finishSave(with: .failure(message: L10n.string("image.action_failed"),
                                                           details: model.likeActionFailureDetails))
            return
        }
        switch outcome {
        case .added, .merged, .alreadyLiked:
            imageSavePresentation.finishSave(with: .custom(
                title: L10n.string("likes.already_liked"),
                message: ""
            ))
        }
    }

    /// Matches the novel reader's add-note action: creating an annotation is
    /// part of adding the note, rather than a prerequisite the reader has to
    /// discover and perform separately.
    @MainActor
    private func addNote(to page: MangaReaderPageProjection) async {
        imageSavePresentation.clearActionTarget()
        likedItemForActionTarget = nil
        guard let outcome = await model.likePage(page) else {
            guard !Task.isCancelled, !model.likeActionWasCancelled else { return }
            imageSavePresentation.finishSave(with: .failure(message: L10n.string("image.action_failed"),
                                                           details: model.likeActionFailureDetails))
            return
        }

        switch outcome {
        case let .added(item), let .merged(item), let .alreadyLiked(item):
            noteEditTarget = item
        }
    }

    @MainActor
    private func unlikePage(_ item: LikeItem) async {
        imageSavePresentation.clearActionTarget()
        likedItemForActionTarget = nil
        let succeeded = await model.unlikePage(item)
        guard !Task.isCancelled, !model.likeActionWasCancelled else { return }
        imageSavePresentation.finishSave(with: succeeded
            ? .custom(title: L10n.string("likes.remove_like"), message: "")
            : .failure(message: L10n.string("image.action_failed"), details: model.likeActionFailureDetails))
    }

    private var annotationSegmentBinding: Binding<ReaderAnnotationSegment> {
        Binding(
            get: { rememberedAnnotationSegment ?? model.annotationCapsule.initialSegment(remembering: nil) },
            set: { rememberedAnnotationSegment = $0 }
        )
    }

    /// Mirrors `openLikedAnchor`: try the in-session jump first and only fall
    /// back to presenting a fresh reader when that fails.
    private func openBookmark(_ item: BookmarkItem) async {
        guard case let .manga(anchor) = item.anchor else { return }
        companionPanel = nil
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

/// Keep window indexes separate from the selected page. Page turns and chrome
/// toggles only derive the small position summary, not spreads or preview maps.
@MainActor
private final class MangaChromeSummaryMemo {
    private var basePlan: MangaPagedReadingPlan?
    private var previewsByChapter: [String: [Int: MangaReaderPageProjection]] = [:]
    private var chapters: [MangaChapter] = []
    private var rawTitles: [String: String] = [:]
    private var headerKey: [String] = []
    private var cachedHeader = ""
    private var cachedScrubTargets: [Int] = []

    // `@State`'s initial value is built in the view's nonisolated init; the
    // box only becomes main-actor-bound once body starts using it.
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

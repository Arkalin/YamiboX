import SwiftUI
import YamiboXCore

enum NovelReaderLoadingOverlayReason: Equatable, Sendable {
    case appearanceSettingsApply
    case verticalRestore
    case novelReaderPageDocumentNavigation
    case initialContentLoad
}

struct NovelReaderLoadingOverlayPresentation: Equatable, Sendable {
    let reason: NovelReaderLoadingOverlayReason?

    init(
        isLoading: Bool,
        hasSurfaces: Bool,
        hasInitialLoadError: Bool = false,
        isApplyingAppearanceSettings: Bool,
        isNavigatingNovelReaderProjection: Bool = false,
        shouldConcealViewportContent: Bool
    ) {
        if isApplyingAppearanceSettings {
            reason = .appearanceSettingsApply
        } else if shouldConcealViewportContent {
            reason = .verticalRestore
        } else if isNavigatingNovelReaderProjection {
            reason = .novelReaderPageDocumentNavigation
        } else if isLoading && !hasSurfaces && !hasInitialLoadError {
            reason = .initialContentLoad
        } else {
            reason = nil
        }
    }

    var isPresented: Bool {
        reason != nil
    }

    var allowsChrome: Bool {
        !isPresented
    }
}

struct NovelReaderLifecycleModifier: ViewModifier {
    let currentLayout: NovelReaderLayout
    let onInitialTask: () async -> Void
    let onLayoutChange: (NovelReaderLayout) -> Void
    let onMemoryWarning: () -> Void
    let onDisappear: () -> Void

    func body(content: Content) -> some View {
        content
            .task {
                await onInitialTask()
            }
            .onChange(of: currentLayout) { _, newValue in
                onLayoutChange(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )) { _ in
                onMemoryWarning()
            }
            .onDisappear {
                onDisappear()
            }
    }
}

/// The reader's boolean-presented sheets, collapsed into one enum: they are
/// mutually exclusive by construction (each is opened from the chrome, and
/// the chrome is disabled while any overlay is presented), so a single
/// optional drives one `.sheet(item:)` instead of five independent booleans.
/// The item-driven full-screen covers (`forumThreadOverlayItem`,
/// `imageBrowserItem`) are separate presentation slots and stay item-based.
enum NovelReaderPresentedSheet: Identifiable, Hashable {
    case settings
    case cachePanel
    case cacheProgress
    case chapterComments
    /// Chapters, bookmarks, and likes share this one reader-library panel.
    case annotations
    /// Note editor for one annotation. Carries the item so the sheet renders
    /// the excerpt it is a note on; `LikeItem` is Hashable, which is all
    /// `Identifiable` by `Self` needs.
    case note(LikeItem)

    var id: Self { self }
}

/// Performs an in-session annotation jump and restores the imperative
/// vertical viewport when the jump succeeds.
@MainActor
struct NovelReaderAnnotationJump {
    let model: NovelReaderViewModel
    let requestVerticalRestore: () -> Void

    @discardableResult
    func perform(_ resumePoint: NovelResumePoint) async -> Bool {
        guard await model.jumpToLikeAnchor(resumePoint) else { return false }
        requestVerticalRestore()
        return true
    }
}

struct NovelReaderPresentationModifier: ViewModifier {
    // Plain reference (was `@ObservedObject`): the `@Observable` model's
    // tracked properties read in `body` register observation on their own.
    let model: NovelReaderViewModel
    @Binding var presentedSheet: NovelReaderPresentedSheet?
    @Binding var forumThreadOverlayItem: ForumThreadOverlayItem?
    @Binding var imageBrowserItem: ImageBrowserItem?

    let chapterCommentsTarget: ReaderChapterCommentTarget?
    let likeDependencies: LikeDependencies
    let appModel: YamiboAppModel
    let onJumpToChapterDirectoryChapter: (NovelReaderChapter) -> Void
    let onPreviewChapterDirectoryWebView: (Int) -> Void
    let onOpenLikeAnchor: (LikeAnchorPayload) -> Void
    let onOpenBookmark: (BookmarkItem) -> Void
    let onSaveNote: (LikeItem, String?) -> Void
    @Binding var annotationSegment: ReaderAnnotationSegment
    let initialReaderLibraryTab: ReaderLibraryPanelTab

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .settings:
                    NovelReaderSettingsSheet(model: model, appModel: appModel)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.hidden)
                        .presentationBackground(.clear)
                case .chapterComments:
                    ReaderChapterCommentsSheet(
                        target: chapterCommentsTarget,
                        state: model.chapterComments.state,
                        isLoadingMore: model.chapterComments.isLoadingMore,
                        loadMoreError: model.chapterComments.loadMoreError,
                        refreshError: model.chapterComments.refreshError,
                        loadInitial: model.loadChapterComments(for:),
                        refresh: model.refreshChapterComments(for:),
                        loadNext: model.loadNextChapterCommentsPage,
                        forumDependencies: appModel.appContext.forumDependencies,
                        appModel: appModel,
                        discussionWorkTIDs: [model.context.threadID]
                    )
                case .cachePanel:
                    NovelReaderCachePanel(cache: model.cache)
                case .cacheProgress:
                    NovelReaderCacheProgressSheet(cache: model.cache) {
                        presentedSheet = nil
                    }
                    // Was this sheet's own `onDismiss`. The shared
                    // `.sheet(item:)` cannot scope an `onDismiss` to a single
                    // case (the item is already nil when it fires), so the
                    // side effect rides on the content's disappearance, which
                    // in every reachable flow coincides with dismissal of
                    // exactly this sheet.
                    .onDisappear {
                        if model.cache.hasOperationSession {
                            model.cache.hideProgress()
                        }
                    }
                case .annotations:
                    NavigationStack {
                        ReaderAnnotationPanel(
                            work: .novel(threadID: model.context.threadID),
                            workTitle: model.title,
                            like: likeDependencies,
                            annotationSegment: $annotationSegment,
                            initialTab: initialReaderLibraryTab,
                            onOpenBookmark: onOpenBookmark,
                            onOpenLikeAnchor: onOpenLikeAnchor,
                            onDismiss: { presentedSheet = nil }
                        ) { isActive, _ in
                            NovelReaderChapterSheet(
                                model: model,
                                onSelect: { chapter in
                                    presentedSheet = nil
                                    onJumpToChapterDirectoryChapter(chapter)
                                },
                                onSelectWebView: onPreviewChapterDirectoryWebView,
                                isEmbeddedInReaderPanel: true,
                                isActive: isActive
                            )
                        }
                    }
                case let .note(item):
                    LikeNoteEditorSheet(item: item) { note in
                        onSaveNote(item, note)
                    }
                }
            }
            .fullScreenCover(item: $forumThreadOverlayItem) { item in
                ForumThreadOverlayScreen(
                    item: item,
                    dependencies: appModel.appContext.forumDependencies,
                    appModel: appModel,
                    rootIsDiscussionView: true,
                    discussionWorkTIDs: [model.context.threadID]
                )
            }
            .fullScreenCover(item: $imageBrowserItem) { item in
                ImageBrowserView(
                    items: [item],
                    initialItemID: item.id,
                    mode: .single,
                    coverActionsProvider: model.imageBrowserCoverActionsProvider
                ) {
                    imageBrowserItem = nil
                }
            }
    }
}

struct NovelReaderStateObserverModifier: ViewModifier {
    // Plain reference (was `@ObservedObject`): the `onChange(of:)` reads of
    // the `@Observable` model's tracked properties in `body` register
    // observation on their own.
    let model: NovelReaderViewModel
    @Binding var presentedSheet: NovelReaderPresentedSheet?
    @Binding var forumThreadOverlayItem: ForumThreadOverlayItem?
    @Binding var imageBrowserItem: ImageBrowserItem?

    let isStatusBarHidden: Bool
    let isChromeVisible: Bool
    let onUpdateChromeForContentState: () -> Void
    let onRestoreVerticalPositionIfNeeded: () -> Void

    func body(content: Content) -> some View {
        content
            .statusBarHidden(isStatusBarHidden)
            .persistentSystemOverlays(isChromeVisible ? .automatic : .hidden)
            .onChange(of: model.isLoading) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: model.errorMessage) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: model.novelReaderSurfaces.count) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: model.novelReaderPresentation?.generation) { _, _ in
                onUpdateChromeForContentState()
                onRestoreVerticalPositionIfNeeded()
            }
            .onChange(of: model.settings.readingMode) { _, _ in
                onUpdateChromeForContentState()
                onRestoreVerticalPositionIfNeeded()
            }
            // Replaces the five per-boolean observers: every boolean flip maps
            // to a change of the single sheet enum, and the handler is an
            // idempotent state sync, so one observer is equivalent.
            .onChange(of: presentedSheet) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: forumThreadOverlayItem) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: imageBrowserItem) { _, _ in
                onUpdateChromeForContentState()
            }
    }
}

struct NovelReaderChromeHeightObserverModifier: ViewModifier {
    @Binding var topChromeHeight: CGFloat
    @Binding var bottomChromeHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(NovelReaderTopChromeHeightPreferenceKey.self) { value in
                guard topChromeHeight != value else { return }
                topChromeHeight = value
            }
            .onPreferenceChange(NovelReaderBottomChromeHeightPreferenceKey.self) { value in
                guard bottomChromeHeight != value else { return }
                bottomChromeHeight = value
            }
    }
}

struct NovelReaderOfflineFallbackBanner: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: retry) {
                Label(L10n.string("common.retry"), systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(L10n.string("common.retry"))

            Button(action: dismiss) {
                Label(L10n.string("common.close"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(L10n.string("common.close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The per-render closure/controller set every paged viewport branch
/// (page-curl / two-page spread / single page) receives identically — built
/// once in `NovelReaderView.pagedContent` so the three branches cannot drift.
@MainActor
struct NovelReaderPagedViewportBindings {
    let displayReferenceProvider: @MainActor (NovelReaderSurfaceIdentity) -> NovelTextViewportDisplayReference?
    let selectionController: NovelTextSelectionController?
    let likeHighlightController: NovelLikeHighlightController?
    let likedImageAnchors: Set<NovelImageLikeAnchor>
    let isChromeVisible: Bool
    let canBoundaryPageTurn: (Int) -> Bool
    let onSelectionChange: (Int) -> Void
    let onBoundaryPageTurn: (Int) -> Void
    let onPageTapZone: (ReaderPagedTapZone) -> Void
    let onScrollAnimationRequestConsumed: (ReaderPagedScrollAnimationRequest) -> Void
    let onChromeVisibleImageTap: () -> Void
    let onImageTap: (URL, String?) -> Void
    let onImageLongPress: (NovelImageLikeAnchor, URL) -> Void
}

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

struct NovelReaderPresentationModifier: ViewModifier {
    @ObservedObject var model: NovelReaderViewModel
    @Binding var showingSettings: Bool
    @Binding var showingCachePanel: Bool
    @Binding var showingCacheProgress: Bool
    @Binding var showingChapterSheet: Bool
    @Binding var showingChapterComments: Bool
    @Binding var showingLikes: Bool
    @Binding var forumThreadOverlayItem: ForumThreadOverlayItem?
    @Binding var imageBrowserItem: ImageBrowserItem?

    let chapterCommentsTarget: ReaderChapterCommentTarget?
    let likeDependencies: LikeDependencies
    let appModel: YamiboAppModel
    let onJumpToChapterDirectoryChapter: (NovelReaderChapter) -> Void
    let onPreviewChapterDirectoryWebView: (Int) -> Void
    let onOpenLikeAnchor: (LikeAnchorPayload) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingSettings) {
                NovelReaderSettingsSheet(model: model)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationBackground(.clear)
            }
            .sheet(isPresented: $showingChapterSheet) {
                NovelReaderChapterSheet(model: model) { chapter in
                    onJumpToChapterDirectoryChapter(chapter)
                } onSelectWebView: { view in
                    onPreviewChapterDirectoryWebView(view)
                }
            }
            .sheet(isPresented: $showingChapterComments) {
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
            .sheet(isPresented: $showingCachePanel) {
                NovelReaderCachePanel(cache: model.cache)
            }
            .sheet(
                isPresented: $showingCacheProgress,
                onDismiss: {
                    if model.cache.hasOperationSession {
                        model.cache.hideProgress()
                    }
                }
            ) {
                NovelReaderCacheProgressSheet(cache: model.cache) {
                    showingCacheProgress = false
                }
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
            .sheet(isPresented: $showingLikes) {
                NavigationStack {
                    LikeWorkItemsView(
                        work: .novel(threadID: model.context.threadID),
                        workTitle: model.title,
                        like: likeDependencies,
                        onOpenAnchor: onOpenLikeAnchor,
                        onDismiss: { showingLikes = false }
                    )
                }
            }
    }
}

struct NovelReaderStateObserverModifier: ViewModifier {
    @ObservedObject var model: NovelReaderViewModel
    @Binding var showingSettings: Bool
    @Binding var showingCachePanel: Bool
    @Binding var showingCacheProgress: Bool
    @Binding var showingChapterSheet: Bool
    @Binding var showingChapterComments: Bool
    @Binding var showingLikes: Bool
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
            .onChange(of: showingSettings) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: showingCachePanel) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: showingCacheProgress) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: showingChapterSheet) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: showingChapterComments) { _, _ in
                onUpdateChromeForContentState()
            }
            .onChange(of: showingLikes) { _, _ in
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

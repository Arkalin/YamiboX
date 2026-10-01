import SwiftUI
import YamiboXCore

/// Projects window geometry and settings together, before asking TextKit to
/// lay out the document. Appearance commits and the view must use the same
/// inputs so publishing new settings does not trigger a second pagination.
@MainActor
enum NovelReaderLayoutPresentation {
    static func layout(
        containerSize: CGSize,
        safeAreaInsets: NovelReaderLayoutInsets,
        settings: NovelReaderAppearanceSettings
    ) -> NovelReaderLayout {
        let horizontalPadding = max(settings.horizontalPadding, 0)
        let verticalBands = NovelReaderVerticalBandsPresentation()
        return NovelReaderLayout(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            contentInsets: NovelReaderLayoutInsets(
                top: settings.readingMode == .vertical ? 16 : 0,
                leading: horizontalPadding,
                bottom: settings.readingMode == .vertical ? 24 : 0,
                trailing: horizontalPadding
            ),
            chromeInsets: settings.readingMode == .paged
                ? NovelReaderLayoutInsets(
                    top: verticalBands.pagedTopBandHeight,
                    bottom: verticalBands.pagedContentBottomReserve(forBottomInset: safeAreaInsets.bottom)
                )
                : .zero,
            readingMode: settings.readingMode
        )
    }
}

@MainActor
final class NovelReaderVerticalTapSuppression {
    var until: CFTimeInterval = 0
}

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
        isPreparingInitialPresentation: Bool,
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
        } else if !hasInitialLoadError && (isPreparingInitialPresentation || (isLoading && !hasSurfaces)) {
            reason = .initialContentLoad
        } else {
            reason = nil
        }
    }

    var isPresented: Bool {
        reason != nil
    }

    var allowsChrome: Bool {
        // Loading conceals unfinished content, not the reader's controls.
        true
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

/// A single route keeps companion panels and modal work mutually exclusive.
/// Chapters and comments use large sheets; complete settings,
/// download management and note editing have independent sheet content.
/// The item-driven full-screen covers (`forumThreadOverlayItem`,
/// `imageBrowserItem`) are separate presentation slots and stay item-based.
enum NovelReaderPresentedSheet: Identifiable, Hashable {
    case settings
    case downloadPanel
    case downloadProgress
    case chapterComments
    /// Chapters, bookmarks, and likes share this one reader-library panel.
    case annotations
    /// Note editor for one annotation. Carries the item so the sheet renders
    /// the excerpt it is a note on; `LikeItem` is Hashable, which is all
    /// `Identifiable` by `Self` needs.
    case note(LikeItem)

    var id: Self { self }

    var isCompanionPanel: Bool {
        switch self {
        case .annotations, .chapterComments: true
        case .settings, .downloadPanel, .downloadProgress, .note: false
        }
    }
}

extension Optional where Wrapped == NovelReaderPresentedSheet {
    var modalSheet: Wrapped? {
        get { self?.isCompanionPanel == true ? nil : self }
        set {
            // A modal's dismissal must not clear a newly opened companion.
            if newValue != nil || self?.isCompanionPanel != true {
                self = newValue
            }
        }
    }

    var isCompanionPresented: Bool {
        get { self?.isCompanionPanel == true }
        set {
            if !newValue, self?.isCompanionPanel == true {
                self = nil
            }
        }
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
    let chapterCommentsHasLaterChapter: Bool
    let likeDependencies: LikeDependencies
    let settingsStore: SettingsStore
    let forumDependencies: ForumNavigationDependencies
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
            .modifier(ReaderCompanionPresentation(isPresented: $presentedSheet.isCompanionPresented) {
                if let sheet = presentedSheet, sheet.isCompanionPanel {
                    auxiliaryContent(sheet)
                }
            })
            .sheet(item: $presentedSheet.modalSheet) { sheet in
                auxiliaryContent(sheet)
            }
            .fullScreenCover(item: $forumThreadOverlayItem) { item in
                ForumThreadOverlayScreen(
                    item: item,
                    dependencies: forumDependencies,
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

    @ViewBuilder
    private func auxiliaryContent(_ sheet: NovelReaderPresentedSheet) -> some View {
        switch sheet {
        case .settings:
            NovelReaderSettingsSheet(
                model: model,
                settingsStore: settingsStore,
                peripheralInput: appModel.peripheralInput,
                controlAccent: AppTheme.theme(for: appModel.appThemePreset).controlAccent
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        case .chapterComments:
            ReaderChapterCommentsSheet(
                target: chapterCommentsTarget,
                state: model.chapterComments.state,
                isLoadingMore: model.chapterComments.isLoadingMore,
                loadMoreError: model.chapterComments.loadMoreError,
                loadMoreErrorDetails: model.chapterComments.loadMoreErrorDetails,
                refreshError: model.chapterComments.refreshError,
                refreshErrorDetails: model.chapterComments.refreshErrorDetails,
                failureEventID: model.chapterComments.failureEventID,
                clearFailure: model.clearChapterCommentsFailure,
                loadInitial: model.loadChapterComments(for:),
                refresh: model.refreshChapterComments(for:),
                loadNext: model.loadNextChapterCommentsPage,
                forumDependencies: forumDependencies,
                appModel: appModel,
                discussionWorkTIDs: [model.context.threadID],
                isNovel: true,
                hasLaterChapter: chapterCommentsHasLaterChapter,
                cancelLoading: model.cancelChapterCommentsLoading
            )
        case .downloadPanel:
            NovelReaderDownloadPanel(download: model.download)
        case .downloadProgress:
            NovelReaderDownloadProgressSheet(download: model.download) {
                presentedSheet = nil
            }
            .onDisappear {
                if model.download.hasOperationSession {
                    model.download.hideProgress()
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
                    onDismiss: { presentedSheet = nil },
                    dismissesAfterNavigation: true
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
    var details: LoadFailureDetails?
    var retryTitle: String = L10n.string("common.retry")
    var retrySystemName: String = "arrow.clockwise"
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

            VStack(spacing: 0) {
                Button(action: retry) {
                    Label(retryTitle, systemImage: retrySystemName)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(retryTitle)
                LoadFailureDetailsButton(details: details, message: message)
            }

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
    let searchHighlightController: NovelReaderSearchHighlightController?
    let likedImageAnchors: Set<NovelImageLikeAnchor>
    let isChromeVisible: Bool
    let canBoundaryPageTurn: (Int) -> Bool
    let onSelectionChange: (Int) -> Void
    let onBoundaryPageTurn: (Int) -> Void
    var onBoundaryPageTurnRejected: (Int) -> Void = { _ in }
    let onPageTapZone: (ReaderPagedTapZone) -> Void
    let onScrollAnimationRequestConsumed: (ReaderPagedScrollAnimationRequest) -> Void
    let onChromeVisibleImageTap: () -> Void
    let onImageTap: (URL, String?) -> Void
    let onImageLongPress: (NovelImageLikeAnchor, URL, String?) -> Void
}

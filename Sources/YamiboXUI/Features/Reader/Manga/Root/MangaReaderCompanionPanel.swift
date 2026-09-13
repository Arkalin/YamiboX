import SwiftUI
import YamiboXCore

enum MangaReaderCompanion: Hashable {
    case directory
    case annotations
    case comments
}

extension Optional where Wrapped == MangaReaderCompanion {
    var isPresented: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}

struct MangaReaderCompanionPanel: View {
    let companion: MangaReaderCompanion
    let context: MangaLaunchContext
    let model: MangaReaderViewModel
    let appModel: YamiboAppModel
    let discussionWorkTIDs: Set<String>
    @Binding var annotationSegment: ReaderAnnotationSegment
    let initialTab: ReaderLibraryPanelTab
    let dismissesAfterNavigation: Bool
    let onOpenBookmark: (BookmarkItem) -> Void
    let onOpenLikeAnchor: (LikeAnchorPayload) -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch companion {
        case .directory:
            MangaReaderDirectoryCompanion(
                model: model,
                isEmbedded: false,
                isActive: true,
                onNavigate: dismissAfterNavigation,
                onNavigationStateChange: { _ in }
            )
        case .annotations:
            if let annotation = model.annotationSheetContext {
                NavigationStack {
                    if context.isSmartModeEnabled {
                        ReaderAnnotationPanel(
                            work: annotation.workKey,
                            workTitle: context.displayTitle,
                            like: annotation.like,
                            annotationSegment: $annotationSegment,
                            initialTab: initialTab,
                            onOpenBookmark: onOpenBookmark,
                            onOpenLikeAnchor: openLikeAnchor,
                            onDismiss: onDismiss,
                            dismissesAfterNavigation: dismissesAfterNavigation
                        ) { isActive, onNavigationStateChange in
                            MangaReaderDirectoryCompanion(
                                model: model,
                                isEmbedded: true,
                                isActive: isActive,
                                onNavigate: dismissAfterNavigation,
                                onNavigationStateChange: onNavigationStateChange
                            )
                        }
                    } else {
                        ReaderAnnotationPanel(
                            work: annotation.workKey,
                            workTitle: context.displayTitle,
                            like: annotation.like,
                            annotationSegment: $annotationSegment,
                            onOpenBookmark: onOpenBookmark,
                            onOpenLikeAnchor: openLikeAnchor,
                            onDismiss: onDismiss,
                            dismissesAfterNavigation: dismissesAfterNavigation
                        )
                    }
                }
            }
        case .comments:
            ReaderChapterCommentsSheet(
                target: model.currentChapterCommentTarget,
                state: model.chapterCommentsState,
                isLoadingMore: model.isLoadingMoreChapterComments,
                loadMoreError: model.chapterCommentsLoadMoreError,
                loadMoreErrorDetails: model.chapterCommentsLoadMoreErrorDetails,
                refreshError: model.chapterCommentsRefreshError,
                refreshErrorDetails: model.chapterCommentsRefreshErrorDetails,
                failureEventID: model.chapterCommentsFailureEventID,
                clearFailure: model.clearChapterCommentsFailure,
                loadInitial: model.loadChapterComments(for:),
                refresh: model.refreshChapterComments(for:),
                loadNext: model.loadNextChapterCommentsPage,
                forumDependencies: appModel.appContext.forumDependencies,
                appModel: appModel,
                discussionWorkTIDs: discussionWorkTIDs
            )
        }
    }

    private func dismissAfterNavigation() {
        if dismissesAfterNavigation { onDismiss() }
    }

    private func openLikeAnchor(_ anchor: LikeAnchorPayload) {
        dismissAfterNavigation()
        onOpenLikeAnchor(anchor)
    }
}

private struct MangaReaderDirectoryCompanion: View {
    let model: MangaReaderViewModel
    let isEmbedded: Bool
    let isActive: Bool
    let onNavigate: () -> Void
    let onNavigationStateChange: (ReaderAnnotationSegmentNavigationState) -> Void

    var body: some View {
        if case let .loaded(loaded) = model.presentation.state {
            MangaDirectorySheet(
                panel: loaded.directoryPanel,
                onClearFailure: model.clearDirectoryFailure,
                onSortOrderChange: { sortOrder in
                    var settings = model.presentation.settings
                    settings.directorySortOrder = sortOrder
                    model.applySettings(settings)
                },
                onUpdateDirectory: { Task { await model.updateDirectoryFromPanel() } },
                onResetDirectory: { Task { await model.resetDirectory() } },
                onSaveCorrection: { draft in Task { await model.renameDirectory(with: draft) } },
                onDeleteChapters: { tids in Task { await model.deleteDirectoryChapters(tids: tids) } },
                onSelectChapter: { chapter in
                    onNavigate()
                    Task { await model.jumpToChapter(chapter) }
                },
                isEmbeddedInReaderPanel: isEmbedded,
                isActive: isActive,
                onNavigationStateChange: onNavigationStateChange
            )
        } else if isEmbedded {
            MangaDirectoryUnavailableContent()
        } else {
            MangaDirectoryUnavailableSheet()
        }
    }
}

import SwiftUI
import YamiboXCore

#if os(iOS)
struct MangaReaderChromeSummary: Equatable, Sendable {
    let headerTitle: String
    let pageSummary: String
    let pagePreviewTargets: [Int: MangaReaderPageProjection]
    let progress: ReaderChromeProgress
    var spreadPageSummaries: [String?]? = nil
    var spreadWorkTitle: String? = nil
    var spreadPageNumbers: [Int?]? = nil
    var pageNumber: Int = 1
    var remainingChapterPageCount: Int = 0
}

struct MangaReaderChromeControls: View {
    let topInset: CGFloat
    let bottomInset: CGFloat
    let isVisible: Bool
    let isPreview: Bool
    let imageLoader: MangaReaderPageImageLoader?
    let summary: MangaReaderChromeSummary?
    let readingMode: MangaReadingMode
    let isImmersive: Bool
    let pageTurnDirection: MangaPageTurnDirection
    let canNavigateBack: Bool
    let canNavigateForward: Bool
    let onNavigateBack: () -> Void
    let onNavigateForward: () -> Void
    let onClose: () -> Void
    let onShowDirectory: () -> Void
    let onShowComments: () -> Void
    let onShowSettings: () -> Void
    let onShowCache: () -> Void
    let onToggleBookmark: () -> Void
    let onShowAnnotations: () -> Void
    let isBookmarked: Bool
    let annotationCapsule: ReaderAnnotationCapsulePresentation
    let onOpenOriginalPost: () -> Void
    let onJumpToLocalPage: (Int) -> Void
    var onBottomChromeHeightChange: (CGFloat) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let information = ReaderPageInformationPresentation(
            isPaged: readingMode == .paged, isImmersive: isImmersive, isChromeVisible: isVisible
        )
        ZStack(alignment: .top) {
            if isVisible || readingMode == .paged {
                MangaReaderTopChrome(
                    title: summary.map { information.chapterText(title: $0.headerTitle, remainingPages: $0.remainingChapterPageCount) },
                    spreadWorkTitle: summary?.spreadWorkTitle,
                    isRightToLeft: pageTurnDirection == .rightToLeft,
                    isChromeVisible: isVisible,
                    topInset: topInset,
                    isPreview: isPreview,
                    canNavigateBack: canNavigateBack,
                    canNavigateForward: canNavigateForward,
                    onNavigateBack: onNavigateBack,
                    onNavigateForward: onNavigateForward,
                    onClose: onClose
                )
                .readerChromeFadeVisibility(information.isVisible)
                .transition(.opacity)
            }

            MangaReaderBottomChrome(
                bottomInset: bottomInset,
                isVisible: isVisible,
                information: information,
                colorScheme: colorScheme,
                imageLoader: imageLoader,
                summary: summary,
                readingMode: readingMode,
                pageTurnDirection: pageTurnDirection,
                onShowDirectory: onShowDirectory,
                onShowComments: onShowComments,
                onShowSettings: onShowSettings,
                onShowCache: onShowCache,
                onToggleBookmark: onToggleBookmark,
                onShowAnnotations: onShowAnnotations,
                isBookmarked: isBookmarked,
                annotationCapsule: annotationCapsule,
                onOpenOriginalPost: onOpenOriginalPost,
                onJumpToLocalPage: onJumpToLocalPage,
                onHeightChange: onBottomChromeHeightChange
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
#endif

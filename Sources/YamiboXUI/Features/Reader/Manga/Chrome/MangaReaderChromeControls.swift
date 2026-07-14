import SwiftUI
import YamiboXCore

#if os(iOS)
struct MangaReaderChromeSummary: Equatable, Sendable {
    let headerTitle: String
    let pageSummary: String
    let pagePreviewTargets: [Int: MangaReaderPageProjection]
    let progress: ReaderChromeProgress
}

struct MangaReaderChromeControls: View {
    let topInset: CGFloat
    let bottomInset: CGFloat
    let isVisible: Bool
    let isPreview: Bool
    let imageLoader: MangaReaderPageImageLoader?
    let summary: MangaReaderChromeSummary?
    let readingMode: MangaReadingMode
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
    let onShowLikes: () -> Void
    let onOpenOriginalPost: () -> Void
    let onJumpToLocalPage: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            if isVisible {
                MangaReaderTopChrome(
                    title: summary?.headerTitle,
                    topInset: topInset,
                    isPreview: isPreview,
                    canNavigateBack: canNavigateBack,
                    canNavigateForward: canNavigateForward,
                    onNavigateBack: onNavigateBack,
                    onNavigateForward: onNavigateForward,
                    onClose: onClose
                )
                .transition(.opacity)
            }

            MangaReaderBottomChrome(
                bottomInset: bottomInset,
                isVisible: isVisible,
                colorScheme: colorScheme,
                imageLoader: imageLoader,
                summary: summary,
                readingMode: readingMode,
                pageTurnDirection: pageTurnDirection,
                onShowDirectory: onShowDirectory,
                onShowComments: onShowComments,
                onShowSettings: onShowSettings,
                onShowCache: onShowCache,
                onShowLikes: onShowLikes,
                onOpenOriginalPost: onOpenOriginalPost,
                onJumpToLocalPage: onJumpToLocalPage
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
#endif

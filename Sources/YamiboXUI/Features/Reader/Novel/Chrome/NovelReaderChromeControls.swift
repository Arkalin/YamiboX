import SwiftUI
import YamiboXCore

#if os(iOS)
struct NovelReaderChromeControls: View {
    let model: NovelReaderViewModel
    let topInset: CGFloat
    let bottomInset: CGFloat
    let isChromeVisible: Bool
    let onNavigateBack: () -> Void
    let onNavigateForward: () -> Void
    let onClose: () -> Void
    let onRefresh: () -> Void
    let onShowChapters: () -> Void
    let onShowSettings: () -> Void
    let onShowCache: () -> Void
    let onShowComments: () -> Void
    let onOpenForum: () -> Void
    let onShowLikes: () -> Void
    let onJumpChapter: (Int) -> Void
    let onProgressCommit: (Int) -> Void
    let onVerticalProgressCommit: (Int) -> Void
    let onBeginVerticalProgressScrub: () -> Void
    let onEndVerticalProgressScrub: () -> Void
    let isProgressScrubbing: Bool

    var body: some View {
        ZStack {
            if isChromeVisible {
                VStack(spacing: 0) {
                    topChrome
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bottomChrome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topChrome: some View {
        NovelReaderTopChrome(
            model: model,
            navigation: model.navigation,
            topInset: topInset,
            onNavigateBack: onNavigateBack,
            onNavigateForward: onNavigateForward,
            onClose: onClose,
            onRefresh: onRefresh
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: NovelReaderTopChromeHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
    }

    private var bottomChrome: some View {
        NovelReaderBottomChrome(
            progress: model.chromeProgressSnapshot.chromeProgress,
            readingMode: model.settings.readingMode,
            fillDirection: model.settings.pageTurnDirection.progressFillDirection,
            bottomInset: bottomInset,
            isVisible: isChromeVisible,
            onShowChapters: onShowChapters,
            onShowSettings: onShowSettings,
            onShowCache: onShowCache,
            onShowComments: onShowComments,
            onOpenForum: onOpenForum,
            onShowLikes: onShowLikes,
            onJumpChapter: onJumpChapter,
            onProgressCommit: onProgressCommit,
            onVerticalProgressCommit: onVerticalProgressCommit,
            onBeginVerticalProgressScrub: onBeginVerticalProgressScrub,
            onEndVerticalProgressScrub: onEndVerticalProgressScrub,
            isProgressScrubbing: isProgressScrubbing
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: NovelReaderBottomChromeHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
    }
}
#endif

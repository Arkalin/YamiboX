import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderBottomChrome: View {
    let bottomInset: CGFloat
    let isVisible: Bool
    let colorScheme: ColorScheme
    let imageLoader: MangaReaderPageImageLoader?
    let summary: MangaReaderChromeSummary?
    let readingMode: MangaReadingMode
    let pageTurnDirection: MangaPageTurnDirection
    let onShowDirectory: () -> Void
    let onShowComments: () -> Void
    let onShowSettings: () -> Void
    let onShowCache: () -> Void
    let onShowLikes: () -> Void
    let onOpenOriginalPost: () -> Void
    let onJumpToLocalPage: (Int) -> Void

    @State private var horizontalScrubState = ReaderProgressScrubState()
    @State private var activeVerticalProgressPreview: ReaderProgressScrubPreview?

    var body: some View {
        let layout = ReaderBottomChromeLayoutPresentation()
        let progressChromePresentation = ReaderProgressChromePresentation(
            readingMode: readingMode.readerChromeReadingMode,
            isChromeVisible: true
        )
        let verticalScrubVisibility = ReaderBottomActionRowPresentation(isScrubbing: activeVerticalProgressPreview != nil)
        let staticControlVisibility = ReaderBottomActionRowPresentation(
            isScrubbing: horizontalScrubState.phase == .scrubbing || activeVerticalProgressPreview != nil
        )
        let centerProgressPreview = progressChromePresentation.showsVerticalScrubber
            ? activeVerticalProgressPreview
            : horizontalScrubState.preview

        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: layout.verticalScrubberSideSpacing) {
                Spacer(minLength: 0)
                VStack(spacing: layout.panelSpacing) {
                    if let progress = summary?.progress {
                        MangaReaderDirectoryProgressControl(
                            progress: progress,
                            progressChromePresentation: progressChromePresentation,
                            fillDirection: pageTurnDirection.progressFillDirection,
                            scrubState: $horizontalScrubState,
                            onShowDirectory: onShowDirectory,
                            onJumpToLocalPage: onJumpToLocalPage
                        )
                    }

                    MangaReaderStaticActionControls(
                        colorScheme: colorScheme,
                        originalPostTitle: L10n.string("common.original_post"),
                        commentsTitle: L10n.string("reader.comments"),
                        settingsTitle: L10n.string("settings.title"),
                        bookmarkTitle: L10n.string("mine.my_likes"),
                        cacheTitle: L10n.string("reader.cache"),
                        onOpenOriginalPost: onOpenOriginalPost,
                        onShowComments: onShowComments,
                        onShowSettings: onShowSettings,
                        onShowCache: onShowCache,
                        onShowLikes: onShowLikes
                    )
                    .opacity(staticControlVisibility.opacity)
                    .allowsHitTesting(staticControlVisibility.allowsHitTesting)
                    .accessibilityHidden(staticControlVisibility.isAccessibilityHidden)
                }
                .frame(width: layout.maxChromeWidth)
                .opacity(verticalScrubVisibility.opacity)
                .allowsHitTesting(verticalScrubVisibility.allowsHitTesting)
                .accessibilityHidden(verticalScrubVisibility.isAccessibilityHidden)

                if progressChromePresentation.showsVerticalScrubber,
                   let progress = summary?.progress {
                    MangaReaderVerticalProgressControl(
                        progress: progress,
                        onPreviewChange: { activeVerticalProgressPreview = $0 },
                        onJumpToLocalPage: onJumpToLocalPage
                    )
                }
            }
            .readerChromeAnchoredPopupVisibility(isVisible)

            if let pageSummary = summary?.pageSummary {
                MangaReaderBottomPageSummary(text: pageSummary)
                    .readerChromeFadeVisibility(isVisible)
            }
        }
        .padding(.top, layout.bottomChromeTopPadding)
        .padding(.horizontal, 12)
        .padding(.bottom, layout.bottomPadding(forBottomInset: bottomInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .overlay {
            if let preview = centerProgressPreview {
                MangaReaderProgressImagePreview(
                    preview: preview,
                    page: summary?.pagePreviewTargets[preview.targetIndex],
                    imageLoader: imageLoader
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct MangaReaderBottomPageSummary: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .readerChromePanel(cornerRadius: 16, tint: readerChromePanelTint(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct MangaReaderDirectoryProgressControl: View {
    let progress: ReaderChromeProgress
    let progressChromePresentation: ReaderProgressChromePresentation
    let fillDirection: ReaderProgressFillDirection
    @Binding var scrubState: ReaderProgressScrubState
    let onShowDirectory: () -> Void
    let onJumpToLocalPage: (Int) -> Void

    @State private var scrubFeedback = ReaderProgressScrubFeedback()

    var body: some View {
        ReaderDirectoryProgressCapsule(
            title: progress.primaryText,
            progressFraction: displayedProgressFraction,
            fillDirection: fillDirection,
            showsFill: progressChromePresentation.showsHorizontalFill,
            supportsScrub: progressChromePresentation.supportsHorizontalScrub && sliderHasAvailableRange,
            isScrubbing: scrubState.phase == .scrubbing,
            ticks: progress.ticks,
            iconSystemName: progress.iconSystemName,
            onTapDirectory: onShowDirectory,
            onScrub: { locationX, width in
                handleHorizontalCapsuleScrub(locationX: locationX, width: width)
            },
            onEndScrub: {
                commitHorizontalCapsuleScrub()
            }
        )
    }

    private var sliderHasAvailableRange: Bool {
        progress.itemCount > 1
    }

    private var displayedProgressFraction: Double {
        guard scrubState.phase == .scrubbing else {
            return progress.progressFraction
        }
        return progress.positionFraction(forTargetIndex: scrubState.targetIndex)
    }

    private func handleHorizontalCapsuleScrub(locationX: CGFloat, width: CGFloat) {
        guard progressChromePresentation.supportsHorizontalScrub, width > 0 else { return }
        let fraction = min(max(locationX / width, 0), 1)
        var nextState = scrubState
        let update = nextState.update(value: Double(fraction), context: progress.scrubContext)
        scrubState = nextState
        triggerFeedback(update.haptics)
    }

    private func commitHorizontalCapsuleScrub() {
        guard scrubState.phase == .scrubbing else { return }
        var nextState = scrubState
        let update = nextState.end()
        scrubState = nextState
        triggerFeedback(update.haptics)
        if let target = update.committedTargetIndex {
            onJumpToLocalPage(target)
        }
        var resetState = scrubState
        resetState.reset()
        scrubState = resetState
    }

    private func triggerFeedback(_ haptics: [ReaderProgressScrubHaptic]) {
        scrubFeedback.trigger(haptics)
    }
}

private struct MangaReaderVerticalProgressControl: View {
    let progress: ReaderChromeProgress
    let onPreviewChange: (ReaderProgressScrubPreview?) -> Void
    let onJumpToLocalPage: (Int) -> Void

    var body: some View {
        ReaderVerticalProgressCapsule(
            restingProgressFraction: progress.progressFraction,
            scrubContext: progress.scrubContext,
            ticks: progress.ticks,
            previewSize: MangaReaderProgressImagePreview.previewSize,
            showsPreview: false,
            onPreviewChange: onPreviewChange,
            onBeginScrub: {},
            onCommit: onJumpToLocalPage,
            onEndScrub: {
                onPreviewChange(nil)
            }
        ) { _ in
            EmptyView()
        }
        .frame(width: ReaderBottomChromeLayoutPresentation().verticalScrubberWidth, alignment: .trailing)
    }
}

private struct MangaReaderProgressImagePreview: View {
    static let previewSize = CGSize(width: 184, height: 228)

    let preview: ReaderProgressScrubPreview
    let page: MangaReaderPageProjection?
    let imageLoader: MangaReaderPageImageLoader?

    @State private var loadedImage: UIImage?
    @State private var loadedPageID: String?
    @State private var loadingPageID: String?
    @State private var failedPageID: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let pageID = page?.id

        VStack(spacing: 8) {
            MangaReaderProgressPreviewImageArea(
                image: displayedImage,
                isLoading: loadingPageID == pageID,
                hasFailed: page == nil || failedPageID == pageID
            )

            MangaReaderProgressPreviewPageLabel(
                text: L10n.string("reader.page_number_spaced", preview.pageNumber)
            )
        }
        .padding(8)
        .frame(width: Self.previewSize.width, height: Self.previewSize.height)
        .readerChromePanel(cornerRadius: 18, tint: readerChromePanelTint(for: colorScheme))
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 5)
        .task(id: pageID) { @MainActor in
            await loadImage()
        }
    }

    private var displayedImage: UIImage? {
        guard let page else { return nil }
        if let cachedImage = imageLoader?.cachedImage(for: page) {
            return cachedImage
        }
        guard loadedPageID == page.id else { return nil }
        return loadedImage
    }

    @MainActor
    private func loadImage() async {
        guard let page, let imageLoader else {
            loadedImage = nil
            loadedPageID = nil
            loadingPageID = nil
            failedPageID = nil
            return
        }

        if let cachedImage = imageLoader.cachedImage(for: page) {
            loadedImage = cachedImage
            loadedPageID = page.id
            loadingPageID = nil
            failedPageID = nil
            return
        }

        loadingPageID = page.id
        failedPageID = nil

        do {
            let image = try await imageLoader.image(for: page)
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadedPageID = page.id
            loadingPageID = nil
            failedPageID = nil
        } catch {
            guard !Task.isCancelled else { return }
            if loadedPageID != page.id {
                loadedImage = nil
            }
            loadingPageID = nil
            failedPageID = page.id
        }
    }
}

private struct MangaReaderProgressPreviewImageArea: View {
    let image: UIImage?
    let isLoading: Bool
    let hasFailed: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.72))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else if isLoading {
                ReaderLoadStateView(status: .loading, tint: .white)
            } else {
                ReaderLoadStateView(
                    status: hasFailed
                        ? .failed(title: L10n.string("image.load_failed"), message: "")
                        : .loading,
                    tint: hasFailed ? Color.secondary : .white
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MangaReaderProgressPreviewPageLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
    }
}

private struct MangaReaderStaticActionControls: View {
    let colorScheme: ColorScheme
    let originalPostTitle: String
    let commentsTitle: String
    let settingsTitle: String
    let bookmarkTitle: String
    let cacheTitle: String
    let onOpenOriginalPost: () -> Void
    let onShowComments: () -> Void
    let onShowSettings: () -> Void
    let onShowCache: () -> Void
    let onShowLikes: () -> Void

    var body: some View {
        let layout = ReaderBottomChromeLayoutPresentation()

        ReaderChromeCapsuleButton(
            title: commentsTitle,
            systemName: "text.bubble",
            action: onShowComments
        )

        ReaderChromeCapsuleButton(
            title: settingsTitle,
            systemName: "gearshape",
            action: onShowSettings
        )

        HStack(spacing: 0) {
            bottomActionButton(
                title: originalPostTitle,
                systemName: "safari",
                handler: onOpenOriginalPost
            )
            Spacer(minLength: layout.actionButtonSpacing)
            bottomActionButton(
                title: bookmarkTitle,
                systemName: "heart",
                handler: onShowLikes
            )
            Spacer(minLength: layout.actionButtonSpacing)
            bottomActionButton(
                title: cacheTitle,
                systemName: "square.and.arrow.down",
                handler: onShowCache
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: layout.actionButtonRowHeight)
    }

    private func bottomActionButton(
        title: String,
        isEnabled: Bool = true,
        systemName: String,
        handler: @escaping () -> Void
    ) -> some View {
        let layout = ReaderBottomChromeLayoutPresentation()

        return Button(action: handler) {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: layout.actionButtonIconFrame, height: layout.actionButtonIconFrame)
        }
        .readerChromeButtonStyle(tint: readerChromeButtonTint(for: colorScheme))
        .opacity(isEnabled ? 1 : 0.34)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

private extension MangaReadingMode {
    var readerChromeReadingMode: ReaderReadingMode {
        switch self {
        case .paged:
            .paged
        case .vertical:
            .vertical
        }
    }
}

private extension MangaPageTurnDirection {
    var progressFillDirection: ReaderProgressFillDirection {
        switch self {
        case .rightToLeft:
            .rightToLeft
        case .leftToRight:
            .leftToRight
        }
    }
}
#endif

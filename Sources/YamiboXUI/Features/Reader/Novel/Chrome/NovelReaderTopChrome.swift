import SwiftUI
import YamiboXCore
import UIKit

struct NovelReaderTopChrome: View {
    private let pagedChapterTitleTopLift: CGFloat = 12

    let model: NovelReaderViewModel
    @ObservedObject var navigation: NovelReaderNavigationCoordinator
    let topInset: CGFloat
    let onNavigateBack: () -> Void
    let onNavigateForward: () -> Void
    let onClose: () -> Void
    let onRefresh: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let summary = ReaderChromeProgressSummary(
            chapterTitle: model.currentChapterTitle,
            progressText: model.progressText
        )

        VStack(spacing: 8) {
            ReaderGlassContainer(spacing: 12) {
                let chromeButtonSize: CGFloat = 44
                let historyButtonsUseGlassBackground = model.settings.readingMode == .vertical
                let historyIconSize = ReaderChromeHistoryButton.controlSize(
                    isGlassBacked: historyButtonsUseGlassBackground
                )
                let buttonSpacing: CGFloat = 8
                let leadingControlsWidth = navigation.canNavigateBack ? historyIconSize : 0
                let trailingControlsWidth = chromeButtonSize
                    + (navigation.canNavigateForward ? historyIconSize + buttonSpacing : 0)
                let titleSidePadding = max(leadingControlsWidth, trailingControlsWidth) + 16

                ZStack {
                    chapterTitleView(summary.chapterTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, titleSidePadding)
                        .offset(y: shouldLiftPagedChapterTitle ? -pagedChapterTitleTopLift : 0)

                    HStack(spacing: buttonSpacing) {
                        if navigation.canNavigateBack {
                            ReaderChromeHistoryButton(
                                direction: .back,
                                title: L10n.string("common.back"),
                                isGlassBacked: historyButtonsUseGlassBackground,
                                action: onNavigateBack
                            )
                        }

                        Spacer(minLength: 0)

                        if navigation.canNavigateForward {
                            ReaderChromeHistoryButton(
                                direction: .forward,
                                title: L10n.string("common.forward"),
                                isGlassBacked: historyButtonsUseGlassBackground,
                                action: onNavigateForward
                            )
                        }

                        ReaderChromeCircleButton(
                            systemName: "xmark",
                            title: L10n.string("common.close"),
                            tint: readerChromeButtonTint(for: colorScheme),
                            action: onClose
                        )
                        .frame(width: chromeButtonSize, height: chromeButtonSize)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: chromeButtonSize)
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
            .tint(readerChromeButtonTint(for: colorScheme))

            if model.context.isPreview {
                ReaderPreviewModeBadge()
            }
        }
        .padding(.top, max(topInset + 8, 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func chapterTitleView(_ title: String) -> some View {
        let text = Text(title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(.primary)

        if model.settings.readingMode == .vertical {
            text
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .readerChromePanel(cornerRadius: 18, tint: readerChromePanelTint(for: colorScheme))
        } else {
            // Same glass panel as vertical mode: a bare title floating over
            // page text near the top has no legibility guarantee.
            text
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .readerChromePanel(cornerRadius: 18, tint: readerChromePanelTint(for: colorScheme))
                .frame(maxWidth: .infinity)
        }
    }

    private var shouldLiftPagedChapterTitle: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && model.settings.readingMode == .paged
    }
}

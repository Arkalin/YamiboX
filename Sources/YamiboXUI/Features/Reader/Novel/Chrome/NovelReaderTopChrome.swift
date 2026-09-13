import SwiftUI
import YamiboXCore
import UIKit

struct NovelReaderTopChrome: View {
    private let pagedChapterTitleTopLift: CGFloat = 12

    let model: NovelReaderViewModel
    let isChromeVisible: Bool
    @ObservedObject var navigation: NovelReaderNavigationCoordinator
    let topInset: CGFloat
    let onNavigateBack: () -> Void
    let onNavigateForward: () -> Void
    let onClose: () -> Void
    let onRefresh: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        let summary = ReaderChromeProgressSummary(
            chapterTitle: model.currentChapterTitle,
            progressText: model.progressText
        )
        let information = ReaderPageInformationPresentation(
            isPaged: model.settings.readingMode == .paged,
            isImmersive: model.settings.isImmersiveModeEnabled,
            isChromeVisible: isChromeVisible
        )
        let titles = information.titles(
            work: model.isTwoPageSpreadActive ? model.title : nil,
            chapter: model.novelReaderSurfaces.isEmpty ? summary.chapterTitle : information.chapterText(
                title: summary.chapterTitle,
                remainingPages: model.chromeProgressSnapshot.remainingChapterPageCount
            ),
            isRightToLeft: model.settings.pageTurnDirection == .rightToLeft
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
                    Group {
                        if model.isTwoPageSpreadActive {
                            HStack(spacing: 0) {
                                ForEach(titles.indices, id: \.self) { index in
                                    chapterTitleView(titles[index])
                                        .padding(.horizontal, titleSidePadding + 16)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, -16)
                        } else {
                            chapterTitleView(titles[0])
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, titleSidePadding)
                        }
                    }
                    .offset(y: shouldLiftPagedChapterTitle ? -pagedChapterTitleTopLift : 0)
                    .allowsHitTesting(false)

                    if isChromeVisible {
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
                                tint: appTheme.controlAccent,
                                action: onClose
                            )
                            .frame(width: chromeButtonSize, height: chromeButtonSize)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: chromeButtonSize)
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
            .tint(appTheme.controlAccent)

            if model.context.isPreview {
                ReaderPreviewModeBadge()
                    .readerChromeFadeVisibility(isChromeVisible)
            }
        }
        .padding(.top, max(topInset + 8, 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .readerChromeFadeVisibility(information.isVisible)
    }

    @ViewBuilder
    private func chapterTitleView(_ title: String) -> some View {
        let text = Text(title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(model.settings.backgroundStyle == .quiet && model.settings.readingMode == .paged
                ? Color(uiColor: readerThemeTextUIColor(for: .quiet))
                : Color.primary)

        if model.settings.readingMode == .vertical {
            text
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .readerChromePanel(cornerRadius: 18, tint: readerChromePanelTint(for: colorScheme))
        } else {
            // Bare title, no glass panel: paged mode reserves a fixed top
            // band (`pagedTopBandHeight`) above the text, so the title sits
            // on the page background rather than over running text and needs
            // no backing plate of its own.
            text
                .frame(maxWidth: .infinity)
        }
    }

    private var shouldLiftPagedChapterTitle: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && model.settings.readingMode == .paged
    }
}

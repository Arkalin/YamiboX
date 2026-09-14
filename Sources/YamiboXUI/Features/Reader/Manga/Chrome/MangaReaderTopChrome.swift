import SwiftUI
import YamiboXCore

#if os(iOS)
struct MangaReaderTopChrome: View {
    let title: String?
    var spreadWorkTitle: String? = nil
    var isRightToLeft: Bool = false
    var isChromeVisible: Bool = true
    var showsPageInformation: Bool = true
    let topInset: CGFloat
    let isPreview: Bool
    let canNavigateBack: Bool
    let canNavigateForward: Bool
    let onNavigateBack: () -> Void
    let onNavigateForward: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(spacing: 8) {
            ReaderGlassContainer(spacing: 12) {
                let chromeButtonSize: CGFloat = 44
                let historyIconSize = ReaderChromeHistoryButton.controlSize(isGlassBacked: true)
                let buttonSpacing: CGFloat = 8
                let leadingControlsWidth = canNavigateBack ? historyIconSize : 0
                let trailingControlsWidth = chromeButtonSize
                    + (canNavigateForward ? historyIconSize + buttonSpacing : 0)
                let titleSidePadding = max(leadingControlsWidth, trailingControlsWidth) + 16

                ZStack {
                    if showsPageInformation, let spreadWorkTitle {
                        HStack(spacing: 0) {
                            MangaReaderTopChapterTitle(title: isRightToLeft ? title : spreadWorkTitle)
                                .padding(.horizontal, titleSidePadding + 16)
                                .frame(maxWidth: .infinity)
                            MangaReaderTopChapterTitle(title: isRightToLeft ? spreadWorkTitle : title)
                                .padding(.horizontal, titleSidePadding + 16)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, -16)
                        .allowsHitTesting(false)
                    } else if showsPageInformation {
                        MangaReaderTopChapterTitle(title: title)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, titleSidePadding)
                            .allowsHitTesting(false)
                    }

                    if isChromeVisible {
                        HStack(spacing: buttonSpacing) {
                            if canNavigateBack {
                                ReaderChromeHistoryButton(
                                    direction: .back,
                                    title: L10n.string("common.back"),
                                    isGlassBacked: true,
                                    action: onNavigateBack
                                )
                            }

                            Spacer(minLength: 0)

                            if canNavigateForward {
                                ReaderChromeHistoryButton(
                                    direction: .forward,
                                    title: L10n.string("common.forward"),
                                    isGlassBacked: true,
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

            if isPreview {
                ReaderPreviewModeBadge()
                    .readerChromeFadeVisibility(isChromeVisible)
            }
        }
        .padding(.top, max(topInset + 8, 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct MangaReaderTopChapterTitle: View {
    let title: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let title, !title.isEmpty {
            Text(title)
                .modifier(ReaderInformationFont())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .readerChromePanel(cornerRadius: 18, tint: readerChromePanelTint(for: colorScheme))
                .frame(maxWidth: .infinity)
        }
    }
}
#endif

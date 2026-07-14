import SwiftUI
import YamiboXCore

#if os(iOS)
struct MangaReaderTopChrome: View {
    let title: String?
    let topInset: CGFloat
    let isPreview: Bool
    let canNavigateBack: Bool
    let canNavigateForward: Bool
    let onNavigateBack: () -> Void
    let onNavigateForward: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

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
                    MangaReaderTopChapterTitle(title: title)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, titleSidePadding)

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

            if isPreview {
                ReaderPreviewModeBadge()
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
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .readerChromePanel(cornerRadius: 18, tint: readerChromePanelTint(for: colorScheme))
                .frame(maxWidth: .infinity)
        }
    }
}
#endif

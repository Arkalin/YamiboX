import SwiftUI
import YamiboXCore

#if os(iOS)

struct NovelReaderUnifiedSheetBackground: View {
    let palette: NovelReaderSheetPalette
    let heroHeight: CGFloat
    let heroWidth: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            palette.bodyBackground
                .ignoresSafeArea()

            palette.heroBackground
                .frame(width: heroWidth, height: heroHeight)
                .ignoresSafeArea(edges: .top)
        }
    }
}

struct NovelReaderHeroSection: View {
    let settings: NovelReaderAppearanceSettings
    let palette: NovelReaderSheetPalette
    let previewText: String
    let topInset: CGFloat
    let height: CGFloat
    let isCompact: Bool
    let onClose: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 24) {
            NovelReaderSettingsHeader(
                palette: palette,
                onClose: onClose,
                onConfirm: onConfirm
            )
            .padding(.horizontal, 16)

            NovelReaderPreviewMaskedContent(
                settings: settings,
                palette: palette,
                previewText: previewText
            )
        }
        .padding(.top, topInset + (isCompact ? 8 : 12))
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
    }
}

struct NovelReaderSettingsHeader: View {
    let palette: NovelReaderSheetPalette
    let onClose: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Text(L10n.string("settings.title"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.heroText)

            HStack {
                ReaderChromeCircleButton(
                    systemName: "xmark",
                    title: L10n.string("common.close"),
                    tint: palette.heroText,
                    action: onClose
                )
                Spacer()
                ReaderChromeCircleButton(
                    systemName: "checkmark",
                    title: L10n.string("common.done"),
                    tint: palette.confirmButtonBackground,
                    prominent: true,
                    action: onConfirm
                )
            }
        }
    }
}

struct NovelReaderPreviewMaskedContent: View {
    let settings: NovelReaderAppearanceSettings
    let palette: NovelReaderSheetPalette
    let previewText: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            NativeNovelTextSettingsPreviewView(
                surface: NovelTextSettingsPreviewSurface(
                    text: previewText,
                    settings: settings
                )
            )
            .padding(.top, 4)
            .padding(.horizontal, settings.horizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.78),
                    .init(color: .black.opacity(0.92), location: 0.86),
                    .init(color: .black.opacity(0.45), location: 0.94),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipped()
    }
}

#endif

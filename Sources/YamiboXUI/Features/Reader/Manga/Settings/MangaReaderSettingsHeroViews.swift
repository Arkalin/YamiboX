import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderSettingsBackground: View {
    let palette: MangaReaderSettingsPalette
    let heroHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            palette.bodyBackground
                .ignoresSafeArea()

            palette.heroBackground
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
    }
}

struct MangaReaderSettingsHero: View {
    let settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette
    let topInset: CGFloat
    let height: CGFloat
    let usesTwoPageSpread: Bool
    let readerViewportSize: CGSize
    let tapZonesPreviewRequestID: Int
    let onClose: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            MangaReaderSettingsPreviewSpread(
                settings: settings,
                palette: palette,
                usesTwoPageSpread: usesTwoPageSpread,
                readerViewportSize: readerViewportSize,
                height: height,
                contentTopPadding: topInset + 78,
                tapZonesPreviewRequestID: tapZonesPreviewRequestID
            )

            MangaReaderSettingsHeader(
                palette: palette,
                onClose: onClose,
                onConfirm: onConfirm
            )
            .padding(.horizontal, 16)
            .padding(.top, topInset + 12)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
    }
}

private struct MangaReaderSettingsHeader: View {
    let palette: MangaReaderSettingsPalette
    let onClose: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Text(L10n.string("settings.title"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            HStack {
                ReaderChromeCircleButton(
                    systemName: "xmark",
                    title: L10n.string("common.close"),
                    tint: palette.primaryText,
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

private struct MangaReaderSettingsPreviewSpread: View {
    let settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette
    let usesTwoPageSpread: Bool
    let readerViewportSize: CGSize
    let height: CGFloat
    let contentTopPadding: CGFloat
    let tapZonesPreviewRequestID: Int

    private var selectedMode: ReaderSettingsReadingModeOption {
        ReaderSettingsReadingModeOption(settings)
    }

    private var effectivePageScaleMode: MangaPageScaleMode {
        MangaPagedLayoutPolicy.effectivePageScaleMode(
            settings: settings,
            usesTwoPageSpread: usesTwoPageSpread
        )
    }

    private var previewAspectRatio: CGFloat {
        usesTwoPageSpread ? readerViewportSize.width / readerViewportSize.height : 0.72
    }

    private var frameCornerRadii: RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: 24,
            bottomLeading: 0,
            bottomTrailing: 0,
            topTrailing: 24
        )
    }

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(cornerRadii: frameCornerRadii, style: .continuous)
                .fill(palette.previewFrameBackground)

            if selectedMode == .scroll {
                MangaReaderScrollPreviewPages(palette: palette)
                    .padding(.top, contentTopPadding)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            } else {
                MangaReaderLayeredPagedPreview(
                    palette: palette,
                    usesTwoPageSpread: usesTwoPageSpread,
                    aspectRatio: previewAspectRatio,
                    scaleMode: effectivePageScaleMode,
                    edgeFillStyle: settings.pageEdgeFillStyle,
                    pageTurnDirection: settings.pageTurnDirection
                )
                .padding(.top, contentTopPadding)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
            }

            MangaReaderBrightnessPreviewOverlay(brightness: settings.brightness)

            if selectedMode != .scroll {
                MangaReaderSettingsPageTurnZonesPreview(
                    settings: settings,
                    aspectRatio: previewAspectRatio,
                    tapZonesPreviewRequestID: tapZonesPreviewRequestID
                )
                .padding(.top, contentTopPadding)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(UnevenRoundedRectangle(cornerRadii: frameCornerRadii, style: .continuous))
    }
}

private struct MangaReaderSettingsPageTurnZonesPreview: View {
    let settings: MangaReaderSettings
    let aspectRatio: CGFloat
    let tapZonesPreviewRequestID: Int

    var body: some View {
        GeometryReader { proxy in
            let size = MangaReaderSettingsPagedPreviewLayout.fittedSize(in: proxy.size, aspectRatio: aspectRatio)

            // Match the visible foreground spread, not the full-width hero or its duplicate sheets.
            ReaderSettingsPageTurnZonesPreview(
                direction: settings.pageTurnDirection == .leftToRight ? .leftToRight : .rightToLeft,
                swapped: settings.swapsPageTurnTapZones,
                requestID: tapZonesPreviewRequestID,
                isEnabled: settings.readingMode == .paged,
                usesCompactLabels: true
            )
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private enum MangaReaderSettingsPagedPreviewLayout {
    static func fittedSize(in container: CGSize, aspectRatio: CGFloat) -> CGSize {
        let height = max(0, min(container.height, container.width / aspectRatio))
        return CGSize(width: height * aspectRatio, height: height)
    }
}

private struct MangaReaderLayeredPagedPreview: View {
    let palette: MangaReaderSettingsPalette
    let usesTwoPageSpread: Bool
    let aspectRatio: CGFloat
    let scaleMode: MangaPageScaleMode
    let edgeFillStyle: MangaPageEdgeFillStyle
    let pageTurnDirection: MangaPageTurnDirection

    private var duplicateOffsetX: CGFloat {
        switch pageTurnDirection {
        case .leftToRight:
            14
        case .rightToLeft:
            -14
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = MangaReaderSettingsPagedPreviewLayout.fittedSize(in: proxy.size, aspectRatio: aspectRatio)

            ZStack {
                MangaReaderPagedPreviewCanvas(
                    palette: palette,
                    usesTwoPageSpread: usesTwoPageSpread,
                    scaleMode: scaleMode,
                    edgeFillStyle: edgeFillStyle,
                    pageTurnDirection: pageTurnDirection
                )
                .brightness(-0.08)
                .opacity(0.82)
                .offset(x: duplicateOffsetX)

                MangaReaderPagedPreviewCanvas(
                    palette: palette,
                    usesTwoPageSpread: usesTwoPageSpread,
                    scaleMode: scaleMode,
                    edgeFillStyle: edgeFillStyle,
                    pageTurnDirection: pageTurnDirection
                )
            }
            .frame(width: size.width, height: size.height)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct MangaReaderPagedPreviewCanvas: View {
    let palette: MangaReaderSettingsPalette
    let usesTwoPageSpread: Bool
    let scaleMode: MangaPageScaleMode
    let edgeFillStyle: MangaPageEdgeFillStyle
    let pageTurnDirection: MangaPageTurnDirection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if usesTwoPageSpread {
            // One reader viewport with two equal slots, not two independently layered cards.
            HStack(spacing: 0) {
                MangaReaderPagedSpreadPreviewPage(
                    palette: palette,
                    isTrailingPage: pageTurnDirection == .rightToLeft
                )
                MangaReaderPagedSpreadPreviewPage(
                    palette: palette,
                    isTrailingPage: pageTurnDirection == .leftToRight
                )
            }
            .environment(\.layoutDirection, .leftToRight)
            .background(edgeFillStyle.settingsPreviewColor(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        } else {
            MangaReaderPagedPreviewPage(
                palette: palette,
                isTrailingPage: false,
                scaleMode: scaleMode,
                edgeFillStyle: edgeFillStyle,
                pageTurnDirection: pageTurnDirection
            )
        }
    }
}

private struct MangaReaderPagedSpreadPreviewPage: View {
    let palette: MangaReaderSettingsPalette
    let isTrailingPage: Bool

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = 12
            let pageWidth = MangaReaderPagedPreviewArtworkMetrics.baseWidth + horizontalInset * 2
            let layout = MangaPagedImageSurfaceLayout(
                imageSize: CGSize(width: pageWidth, height: pageWidth / 0.72),
                containerSize: proxy.size,
                fitMode: .fitWidth,
                initialHorizontalAlignment: .left,
                zoomScale: 1
            )
            let imageSize = layout.fittedImageSize
            let scale = imageSize.width / pageWidth

            MangaReaderPagedPreviewArtwork(
                palette: palette,
                isTrailingPage: isTrailingPage,
                panelWidth: (MangaReaderPagedPreviewArtworkMetrics.baseWidth - 8) / 2 * scale,
                scale: scale
            )
            .frame(width: imageSize.width, height: imageSize.height)
            .background(palette.previewPageBackground)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct MangaReaderPagedPreviewPage: View {
    let palette: MangaReaderSettingsPalette
    let isTrailingPage: Bool
    let scaleMode: MangaPageScaleMode
    var edgeFillStyle: MangaPageEdgeFillStyle? = nil
    let pageTurnDirection: MangaPageTurnDirection

    @Environment(\.colorScheme) private var colorScheme

    private var edgeFillBackground: Color {
        edgeFillStyle?.settingsPreviewColor(for: colorScheme) ?? palette.previewPageBackground
    }

    private var previewBackground: Color {
        scaleMode == .fitWidth ? edgeFillBackground : palette.previewPageBackground
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(previewBackground)

            if scaleMode == .fitHeight {
                MangaReaderPagedPreviewFitHeightContent(
                    palette: palette,
                    isTrailingPage: isTrailingPage,
                    pageBackground: palette.previewPageBackground,
                    pageTurnDirection: pageTurnDirection
                )
            } else {
                MangaReaderPagedPreviewFitWidthContent(
                    palette: palette,
                    isTrailingPage: isTrailingPage,
                    pageBackground: palette.previewPageBackground
                )
            }
        }
        .aspectRatio(0.72, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
    }
}

private struct MangaReaderPagedPreviewFitWidthContent: View {
    let palette: MangaReaderSettingsPalette
    let isTrailingPage: Bool
    let pageBackground: Color

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = 12
            let verticalArtworkInset: CGFloat = 10
            let contentWidth = max(proxy.size.width - horizontalInset * 2, 1)
            let panelWidth = max((contentWidth - 8) / 2, 1)
            let artworkHeight = MangaReaderPagedPreviewArtworkMetrics.height(
                isTrailingPage: isTrailingPage,
                scale: 1
            )
            let contentHeight = artworkHeight + verticalArtworkInset * 2

            MangaReaderPagedPreviewArtwork(
                palette: palette,
                isTrailingPage: isTrailingPage,
                panelWidth: panelWidth,
                scale: 1
            )
            .frame(width: contentWidth, height: artworkHeight, alignment: .topLeading)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, verticalArtworkInset)
            .frame(width: proxy.size.width, height: contentHeight, alignment: .center)
            .background(pageBackground)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
    }
}

private struct MangaReaderPagedPreviewFitHeightContent: View {
    let palette: MangaReaderSettingsPalette
    let isTrailingPage: Bool
    let pageBackground: Color
    let pageTurnDirection: MangaPageTurnDirection

    private var contentAlignment: Alignment {
        switch pageTurnDirection {
        case .leftToRight:
            .leading
        case .rightToLeft:
            .trailing
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = 12
            let contentHeight = max(proxy.size.height, 1)
            let contentWidth = max(proxy.size.width - horizontalInset * 2, 1)
            let scale = contentHeight / MangaReaderPagedPreviewArtworkMetrics.height(
                isTrailingPage: isTrailingPage,
                scale: 1
            )
            let scaledPanelWidth = (MangaReaderPagedPreviewArtworkMetrics.baseWidth - 8) / 2 * scale

            MangaReaderPagedPreviewArtwork(
                palette: palette,
                isTrailingPage: isTrailingPage,
                panelWidth: scaledPanelWidth,
                scale: scale
            )
            .frame(
                width: contentWidth,
                height: contentHeight,
                alignment: contentAlignment
            )
            .background(pageBackground)
            .clipped()
            .padding(.horizontal, horizontalInset)
        }
    }
}

private enum MangaReaderPagedPreviewArtworkMetrics {
    static let baseWidth: CGFloat = 156

    static func height(isTrailingPage: Bool, scale: CGFloat) -> CGFloat {
        let topRowHeight: CGFloat = isTrailingPage ? 54 : 50
        let middleRowHeight: CGFloat = isTrailingPage ? 38 : 34
        let bottomRowHeight: CGFloat = isTrailingPage ? 34 : 30
        let rowSpacing: CGFloat = 8

        return (topRowHeight + rowSpacing + middleRowHeight + rowSpacing + bottomRowHeight) * scale
    }
}

private struct MangaReaderPagedPreviewArtwork: View {
    let palette: MangaReaderSettingsPalette
    let isTrailingPage: Bool
    let panelWidth: CGFloat
    let scale: CGFloat

    private var rowSpacing: CGFloat {
        8 * scale
    }

    private var topLeadingPanelWidth: CGFloat {
        panelWidth * (isTrailingPage ? 0.86 : 1)
    }

    private var topTrailingPanelWidth: CGFloat {
        panelWidth * (isTrailingPage ? 1.14 : 1)
    }

    private var bottomLeadingPanelWidth: CGFloat {
        panelWidth * (isTrailingPage ? 1.16 : 1)
    }

    private var bottomTrailingPanelWidth: CGFloat {
        panelWidth * (isTrailingPage ? 0.84 : 1)
    }

    private var topLeadingPanelHeight: CGFloat {
        (isTrailingPage ? 44 : 50) * scale
    }

    private var topTrailingPanelHeight: CGFloat {
        (isTrailingPage ? 54 : 50) * scale
    }

    private var middlePanelHeight: CGFloat {
        (isTrailingPage ? 38 : 34) * scale
    }

    private var bottomLeadingPanelHeight: CGFloat {
        (isTrailingPage ? 28 : 30) * scale
    }

    private var bottomTrailingPanelHeight: CGFloat {
        (isTrailingPage ? 34 : 30) * scale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(alignment: .top, spacing: rowSpacing) {
                MangaReaderPreviewPanel(
                    color: isTrailingPage ? palette.coolPanel : palette.warmPanel,
                    height: topLeadingPanelHeight,
                    width: topLeadingPanelWidth
                )
                MangaReaderPreviewPanel(
                    color: palette.neutralPanel,
                    height: topTrailingPanelHeight,
                    width: topTrailingPanelWidth
                )
            }

            MangaReaderPreviewPanel(
                color: isTrailingPage ? palette.neutralPanel : palette.coolPanel,
                height: middlePanelHeight,
                width: panelWidth * 2 + rowSpacing
            )

            HStack(alignment: .top, spacing: rowSpacing) {
                MangaReaderPreviewPanel(
                    color: palette.neutralPanel,
                    height: bottomLeadingPanelHeight,
                    width: bottomLeadingPanelWidth
                )
                MangaReaderPreviewPanel(
                    color: isTrailingPage ? palette.warmPanel : palette.neutralPanel,
                    height: bottomTrailingPanelHeight,
                    width: bottomTrailingPanelWidth
                )
            }
        }
    }
}

private struct MangaReaderScrollPreviewPages: View {
    let palette: MangaReaderSettingsPalette

    var body: some View {
        GeometryReader { proxy in
            let pageHeight = min(proxy.size.height, proxy.size.width / 0.72)
            let pageWidth = pageHeight * 0.72
            let visiblePageHeight = min(pageHeight * 0.48, proxy.size.height * 0.44)
            let topPageOffset = visiblePageHeight - pageHeight
            let bottomPageOffset = proxy.size.height - visiblePageHeight

            ZStack(alignment: .top) {
                MangaReaderVerticalPagedPreviewPair(
                    palette: palette,
                    pageWidth: pageWidth,
                    pageHeight: pageHeight,
                    containerWidth: proxy.size.width,
                    topPageOffset: topPageOffset,
                    bottomPageOffset: bottomPageOffset
                )

                MangaReaderVerticalPagedPreviewPair(
                    palette: palette,
                    pageWidth: pageWidth,
                    pageHeight: pageHeight,
                    containerWidth: proxy.size.width,
                    topPageOffset: topPageOffset,
                    bottomPageOffset: bottomPageOffset
                )
                .blur(radius: 7)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .mask(MangaReaderScrollPreviewEdgeBlurMask())
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .mask(MangaReaderScrollPreviewEdgeFade())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MangaReaderVerticalPagedPreviewPair: View {
    let palette: MangaReaderSettingsPalette
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    let containerWidth: CGFloat
    let topPageOffset: CGFloat
    let bottomPageOffset: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            MangaReaderPagedPreviewPage(
                palette: palette,
                isTrailingPage: false,
                scaleMode: .fitWidth,
                pageTurnDirection: .rightToLeft
            )
            .frame(width: pageWidth, height: pageHeight)
            .offset(y: topPageOffset)

            MangaReaderPagedPreviewPage(
                palette: palette,
                isTrailingPage: false,
                scaleMode: .fitWidth,
                pageTurnDirection: .rightToLeft
            )
            .frame(width: pageWidth, height: pageHeight)
            .offset(y: bottomPageOffset)
        }
        .frame(width: containerWidth, height: pageHeight, alignment: .top)
    }
}

private struct MangaReaderScrollPreviewEdgeFade: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black.opacity(0.35), location: 0.08),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 0.78),
                .init(color: .black.opacity(0.35), location: 0.92),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct MangaReaderScrollPreviewEdgeBlurMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.14),
                .init(color: .clear, location: 0.30),
                .init(color: .clear, location: 0.70),
                .init(color: .black, location: 0.86),
                .init(color: .black, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct MangaReaderPreviewPanel: View {
    let color: Color
    let height: CGFloat
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color)
            .frame(width: width)
            .frame(height: height)
    }
}

private struct MangaReaderBrightnessPreviewOverlay: View {
    let brightness: Double

    var body: some View {
        let delta = brightness - 1

        if delta < 0 {
            Color.black.opacity(min(0.7, abs(delta)))
                .allowsHitTesting(false)
        } else if delta > 0 {
            Color.white.opacity(min(0.18, delta * 0.18))
                .allowsHitTesting(false)
        }
    }
}
#endif

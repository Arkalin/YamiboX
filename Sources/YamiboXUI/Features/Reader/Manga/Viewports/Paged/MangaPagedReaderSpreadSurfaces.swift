import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

extension ReaderPagedPageTurnCell {
    func configure(
        spreadID: String,
        usesTwoPageSpread: Bool,
        leftPageSurface: MangaPagedReaderSpreadPageSurface?,
        rightPageSurface: MangaPagedReaderSpreadPageSurface?,
        imageLoader: MangaReaderPageImageLoader,
        pageScaleMode: MangaPageScaleMode,
        pageEdgeFillStyle: MangaPageEdgeFillStyle,
        isChromeVisible: Bool,
        zoomEnabled: Bool,
        allowsUnzoomedSurfacePan: Bool,
        spreadSurfaceInteraction: MangaPagedReaderPageSurfaceInteraction,
        likedPageIDs: Set<String>,
        colorScheme: ColorScheme
    ) {
        let pageEdgeFillColor = pageEdgeFillStyle.uiColor(for: colorScheme)
        backgroundColor = pageEdgeFillColor
        contentView.backgroundColor = pageEdgeFillColor
        contentConfiguration = UIHostingConfiguration {
            MangaPagedReaderSpreadSurface(
                spreadID: spreadID,
                usesTwoPageSpread: usesTwoPageSpread,
                leftPageSurface: leftPageSurface,
                rightPageSurface: rightPageSurface,
                imageLoader: imageLoader,
                pageScaleMode: pageScaleMode,
                pageEdgeFillStyle: pageEdgeFillStyle,
                isChromeVisible: isChromeVisible,
                zoomEnabled: zoomEnabled,
                allowsUnzoomedSurfacePan: allowsUnzoomedSurfacePan,
                spreadSurfaceInteraction: spreadSurfaceInteraction,
                likedPageIDs: likedPageIDs
            )
            .ignoresSafeArea(
                .container,
                edges: UIDevice.current.userInterfaceIdiom == .pad ? .vertical : .bottom
            )
        }
        .margins(.all, 0)
    }
}

private struct MangaPagedReaderSpreadSurface: View {
    let spreadID: String
    let usesTwoPageSpread: Bool
    let leftPageSurface: MangaPagedReaderSpreadPageSurface?
    let rightPageSurface: MangaPagedReaderSpreadPageSurface?
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let allowsUnzoomedSurfacePan: Bool
    let spreadSurfaceInteraction: MangaPagedReaderPageSurfaceInteraction
    let likedPageIDs: Set<String>

    var body: some View {
        ZStack {
            pageEdgeFillStyle.color(for: colorScheme)

            if usesTwoPageSpread {
                MangaPagedReaderZoomableSpreadSurface(
                    spreadID: spreadID,
                    leftPageSurface: leftPageSurface,
                    rightPageSurface: rightPageSurface,
                    imageLoader: imageLoader,
                    pageScaleMode: pageScaleMode,
                    pageEdgeFillStyle: pageEdgeFillStyle,
                    isChromeVisible: isChromeVisible,
                    isZoomInteractionEnabled: !isChromeVisible && zoomEnabled,
                    spreadSurfaceInteraction: spreadSurfaceInteraction,
                    likedPageIDs: likedPageIDs
                )
            } else {
                MangaPagedReaderPageSlot(
                    surface: leftPageSurface ?? rightPageSurface,
                    imageLoader: imageLoader,
                    pageScaleMode: pageScaleMode,
                    pageEdgeFillStyle: pageEdgeFillStyle,
                    isChromeVisible: isChromeVisible,
                    zoomEnabled: zoomEnabled,
                    allowsUnzoomedSurfacePan: allowsUnzoomedSurfacePan,
                    isPageZoomEnabled: true,
                    likedPageIDs: likedPageIDs
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @Environment(\.colorScheme) private var colorScheme
}

struct MangaPagedReaderPageSlot: View {
    let surface: MangaPagedReaderSpreadPageSurface?
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let allowsUnzoomedSurfacePan: Bool
    let isPageZoomEnabled: Bool
    let likedPageIDs: Set<String>

    var body: some View {
        ZStack {
            pageEdgeFillStyle.color(for: colorScheme)
            if let surface {
                MangaPagedReaderPageSurface(
                    page: surface.page,
                    surfaceIdentity: surface.surfaceIdentity,
                    imageLoader: imageLoader,
                    pageScaleMode: pageScaleMode,
                    initialHorizontalAlignment: surface.initialHorizontalAlignment,
                    pageEdgeFillStyle: pageEdgeFillStyle,
                    isChromeVisible: isChromeVisible,
                    zoomEnabled: zoomEnabled && isPageZoomEnabled,
                    allowsUnzoomedSurfacePan: allowsUnzoomedSurfacePan && isPageZoomEnabled,
                    surfaceInteraction: surface.surfaceInteraction,
                    likedPageIDs: likedPageIDs,
                    onLongPress: surface.onLongPress
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @Environment(\.colorScheme) private var colorScheme
}

extension MangaPageEdgeFillStyle {
    func color(for colorScheme: ColorScheme) -> Color {
        Color(uiColor: uiColor(for: colorScheme))
    }

    func uiColor(for colorScheme: ColorScheme) -> UIColor {
        switch self {
        case .white:
            .white
        case .black:
            .black
        case .system:
            colorScheme == .dark ? .black : .white
        }
    }

    func progressTint(for colorScheme: ColorScheme) -> Color {
        usesLightFill(for: colorScheme) ? .black : .white
    }

    func placeholderForeground(for colorScheme: ColorScheme) -> Color {
        usesLightFill(for: colorScheme) ? Color.black.opacity(0.62) : Color.white.opacity(0.68)
    }

    private func usesLightFill(for colorScheme: ColorScheme) -> Bool {
        switch self {
        case .white:
            true
        case .black:
            false
        case .system:
            colorScheme != .dark
        }
    }
}

extension MangaPageTurnDirection {
    var horizontalNavigationDirection: ReaderPagedHorizontalNavigationDirection {
        switch self {
        case .rightToLeft:
            .rightSwipeAdvances
        case .leftToRight:
            .leftSwipeAdvances
        }
    }
}
#endif

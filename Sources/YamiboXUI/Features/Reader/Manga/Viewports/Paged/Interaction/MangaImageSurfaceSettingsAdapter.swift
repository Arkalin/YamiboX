import CoreGraphics
import YamiboXCore

extension MangaSurfaceFit {
    init(_ mode: MangaPageScaleMode) {
        self = mode == .fitHeight ? .fitHeight : .fitWidth
    }
}

extension MangaPagedImageSurfaceLayout {
    init(
        imageSize: CGSize,
        containerSize: CGSize,
        pageScaleMode: MangaPageScaleMode,
        initialHorizontalAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment,
        zoomScale: CGFloat
    ) {
        self.init(
            imageSize: imageSize,
            containerSize: containerSize,
            fitMode: MangaSurfaceFit(pageScaleMode),
            initialHorizontalAlignment: initialHorizontalAlignment,
            zoomScale: zoomScale
        )
    }
}

extension MangaPagedImageSurfaceInitialHorizontalAlignment {
    init(pageTurnDirection: MangaPageTurnDirection) {
        switch pageTurnDirection {
        case .leftToRight:
            self = .left
        case .rightToLeft:
            self = .right
        }
    }

    static func enteringPage(
        pageTurnDirection: MangaPageTurnDirection,
        pageScaleMode: MangaPageScaleMode,
        currentPageIndex: Int?,
        targetPageIndex: Int
    ) -> Self {
        let defaultAlignment = Self(pageTurnDirection: pageTurnDirection)
        guard pageScaleMode == .fitHeight,
              let currentPageIndex,
              abs(targetPageIndex - currentPageIndex) == 1 else {
            return defaultAlignment
        }
        return targetPageIndex < currentPageIndex ? defaultAlignment.opposite : defaultAlignment
    }

    private var opposite: Self {
        switch self {
        case .left:
            .right
        case .right:
            .left
        }
    }
}

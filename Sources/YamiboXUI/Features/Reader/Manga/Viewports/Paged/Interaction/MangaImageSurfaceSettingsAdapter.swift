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
}

import Foundation

enum MangaSurfaceGeometry: Equatable {
    case image(size: CGSize, viewport: CGSize, fit: MangaSurfaceFit, alignment: MangaPagedImageSurfaceInitialHorizontalAlignment)
    case spread(viewport: CGSize)

    var viewport: CGSize {
        switch self {
        case let .image(_, viewport, _, _), let .spread(viewport): viewport
        }
    }

    func hiddenEdges(_ transform: MangaSurfaceTransform) -> Set<MangaPagedImageSurfaceHorizontalEdge> {
        Set(MangaPagedImageSurfaceHorizontalEdge.allCases.filter { reveal($0, transform: transform) != nil })
    }

    func reveal(_ edge: MangaPagedImageSurfaceHorizontalEdge, transform: MangaSurfaceTransform) -> CGSize? {
        switch self {
        case let .image(size, viewport, fit, alignment):
            MangaPagedImageSurfaceLayout(imageSize: size, containerSize: viewport, fitMode: fit,
                initialHorizontalAlignment: alignment, zoomScale: transform.scale)
                .userOffsetRevealingContent(on: edge, fromUserOffset: transform.offset)
        case let .spread(viewport):
            MangaPagedSpreadSurfaceZoomLayout(containerSize: viewport, zoomScale: transform.scale)
                .userOffsetRevealingContent(on: edge, fromUserOffset: transform.offset)
        }
    }

}

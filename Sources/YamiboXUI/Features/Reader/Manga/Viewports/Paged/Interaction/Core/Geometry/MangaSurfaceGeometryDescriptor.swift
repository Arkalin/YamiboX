import Foundation

enum MangaSurfaceGeometry: Equatable {
    case image(size: CGSize, viewport: CGSize, fit: MangaSurfaceFit, alignment: MangaPagedImageSurfaceInitialHorizontalAlignment)
    case spread(viewport: CGSize)

    var viewport: CGSize {
        switch self {
        case let .image(_, viewport, _, _), let .spread(viewport): viewport
        }
    }

    func clamp(_ transform: MangaSurfaceTransform) -> MangaSurfaceTransform {
        var result = transform
        result.scale = MangaPageZoomPolicy.clampedScale(result.scale)
        switch self {
        case let .image(size, viewport, fit, alignment):
            result.offset = MangaPagedImageSurfaceLayout(imageSize: size, containerSize: viewport, fitMode: fit,
                initialHorizontalAlignment: alignment, zoomScale: result.scale).clampedUserOffset(result.offset)
        case let .spread(viewport):
            result.offset = MangaPagedSpreadSurfaceZoomLayout(containerSize: viewport, zoomScale: result.scale)
                .clampedUserOffset(result.offset)
        }
        return result
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

    func zoomed(at point: CGPoint) -> MangaSurfaceTransform {
        let scale = MangaPageZoomPolicy.doubleTapTargetScale
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let point = CGRect(origin: .zero, size: viewport).contains(point) ? point : center
        var offset = CGSize(width: -(point.x - center.x) * scale, height: -(point.y - center.y) * scale)
        if case let .image(size, viewport, fit, alignment) = self {
            let resting = MangaPagedImageSurfaceLayout(imageSize: size, containerSize: viewport, fitMode: fit,
                initialHorizontalAlignment: alignment, zoomScale: scale).restingOffset
            offset.width -= resting.width
            offset.height -= resting.height
        }
        return clamp(MangaSurfaceTransform(scale: scale, offset: offset))
    }
}

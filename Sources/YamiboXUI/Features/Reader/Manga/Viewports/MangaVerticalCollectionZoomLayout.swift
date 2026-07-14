import CoreGraphics

struct MangaVerticalCollectionZoomInsets: Equatable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat

    static let zero = MangaVerticalCollectionZoomInsets(top: 0, left: 0, bottom: 0, right: 0)
}

struct MangaVerticalCollectionZoomLayout: Equatable {
    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        MangaPageZoomPolicy.clampedScale(scale)
    }

    static func doubleTapTargetScale(from scale: CGFloat) -> CGFloat {
        if MangaPageZoomPolicy.isZoomedForDoubleTapReset(scale) {
            return MangaPageZoomPolicy.minimumScale
        }
        return MangaPageZoomPolicy.doubleTapTargetScale
    }

    static func itemWidth(viewportWidth: CGFloat, zoomScale: CGFloat) -> CGFloat {
        max(viewportWidth * clampedScale(zoomScale), 1)
    }

    static func estimatedItemHeight(baseHeight: CGFloat, zoomScale: CGFloat) -> CGFloat {
        max(baseHeight * clampedScale(zoomScale), 1)
    }

    static func projectedContentSize(
        currentContentSize: CGSize,
        viewportSize: CGSize,
        oldScale: CGFloat,
        newScale: CGFloat
    ) -> CGSize {
        let ratio = clampedScale(newScale) / max(clampedScale(oldScale), 0.001)
        return CGSize(
            width: max(viewportSize.width, currentContentSize.width * ratio),
            height: max(viewportSize.height, currentContentSize.height * ratio)
        )
    }

    static func anchoredContentOffset(
        currentOffset: CGPoint,
        visibleAnchor: CGPoint,
        oldScale: CGFloat,
        newScale: CGFloat,
        targetContentSize: CGSize,
        viewportSize: CGSize,
        adjustedContentInset: MangaVerticalCollectionZoomInsets = .zero
    ) -> CGPoint {
        let ratio = clampedScale(newScale) / max(clampedScale(oldScale), 0.001)
        let rawOffset = CGPoint(
            x: (currentOffset.x + visibleAnchor.x) * ratio - visibleAnchor.x,
            y: (currentOffset.y + visibleAnchor.y) * ratio - visibleAnchor.y
        )
        return clampedContentOffset(
            rawOffset,
            contentSize: targetContentSize,
            viewportSize: viewportSize,
            adjustedContentInset: adjustedContentInset
        )
    }

    static func clampedContentOffset(
        _ offset: CGPoint,
        contentSize: CGSize,
        viewportSize: CGSize,
        adjustedContentInset: MangaVerticalCollectionZoomInsets = .zero
    ) -> CGPoint {
        let minX = -adjustedContentInset.left
        let minY = -adjustedContentInset.top
        let maxX = max(minX, contentSize.width - viewportSize.width + adjustedContentInset.right)
        let maxY = max(minY, contentSize.height - viewportSize.height + adjustedContentInset.bottom)
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY)
        )
    }
}

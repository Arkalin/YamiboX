import CoreGraphics

enum MangaPageZoomPolicy {
    static let minimumScale: CGFloat = 1
    static let doubleTapScale: CGFloat = 2
    static let maximumScale: CGFloat = 4
    static let resetThreshold: CGFloat = 1.05
    static let activeThreshold: CGFloat = 1.01

    static var doubleTapTargetScale: CGFloat {
        min(maximumScale, doubleTapScale)
    }

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, scale))
    }

    static func isZoomedForDoubleTapReset(_ scale: CGFloat) -> Bool {
        scale > resetThreshold
    }

    static func isActive(_ scale: CGFloat) -> Bool {
        scale > activeThreshold
    }
}

enum MangaPageLongPressHitTesting {
    static func acceptsPageLongPress(
        at point: CGPoint,
        in pageBounds: CGRect,
        imageFrame: CGRect
    ) -> Bool {
        contains(point, in: allowedFrame(in: pageBounds, imageFrame: imageFrame))
    }

    static func allowedFrame(in pageBounds: CGRect, imageFrame: CGRect) -> CGRect {
        guard pageBounds.width > 0,
              pageBounds.height > 0,
              imageFrame.width > 0,
              imageFrame.height > 0 else {
            return .zero
        }

        let frame = centerThirdFrame(in: pageBounds).intersection(imageFrame)
        guard !frame.isNull, !frame.isEmpty else { return .zero }
        return frame
    }

    static func centerThirdFrame(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let thirdWidth = bounds.width / 3
        return CGRect(
            x: bounds.minX + thirdWidth,
            y: bounds.minY,
            width: thirdWidth,
            height: bounds.height
        )
    }

    private static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        return point.x >= rect.minX &&
            point.x <= rect.maxX &&
            point.y >= rect.minY &&
            point.y <= rect.maxY
    }
}

enum MangaSurfaceFit: Equatable { case fitWidth, fitHeight }

enum MangaPagedImageSurfaceHorizontalEdge: CaseIterable, Hashable, Sendable { case left, right }

enum MangaPagedImageSurfaceInitialHorizontalAlignment: Hashable, Sendable { case left, right }

struct MangaPagedImageSurfaceLayout: Equatable {
    private static let edgeVisibilityTolerance: CGFloat = 0.5

    let imageSize: CGSize
    let containerSize: CGSize
    let fitMode: MangaSurfaceFit
    let initialHorizontalAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment
    let zoomScale: CGFloat

    var fittedImageSize: CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = switch fitMode {
        case .fitWidth:
            containerSize.width / imageSize.width
        case .fitHeight:
            containerSize.height / imageSize.height
        }
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    var contentSize: CGSize {
        let fittedSize = fittedImageSize
        let scale = max(1, zoomScale)
        return CGSize(width: fittedSize.width * scale, height: fittedSize.height * scale)
    }

    var restingOffset: CGSize {
        guard fitMode == .fitHeight else { return .zero }
        let horizontalOverflow = overflowBounds.width
        guard horizontalOverflow > 0 else { return .zero }

        return CGSize(
            width: initialHorizontalAlignment == .right ? -horizontalOverflow : horizontalOverflow,
            height: 0
        )
    }

    func clampedUserOffset(_ proposed: CGSize) -> CGSize {
        let bounds = overflowBounds
        let restingOffset = restingOffset
        return CGSize(
            width: proposed.width.clamped(
                lower: -bounds.width - restingOffset.width,
                upper: bounds.width - restingOffset.width
            ),
            height: proposed.height.clamped(lower: -bounds.height, upper: bounds.height)
        )
    }

    func displayOffset(forUserOffset userOffset: CGSize) -> CGSize {
        let clampedUserOffset = clampedUserOffset(userOffset)
        let restingOffset = restingOffset
        return CGSize(
            width: restingOffset.width + clampedUserOffset.width,
            height: restingOffset.height + clampedUserOffset.height
        )
    }

    func displayedImageFrame(forUserOffset userOffset: CGSize) -> CGRect {
        let offset = displayOffset(forUserOffset: userOffset)
        return CGRect(
            x: (containerSize.width - contentSize.width) / 2 + offset.width,
            y: (containerSize.height - contentSize.height) / 2 + offset.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    func hasHiddenContent(
        on edge: MangaPagedImageSurfaceHorizontalEdge,
        fromUserOffset userOffset: CGSize
    ) -> Bool {
        guard fitMode == .fitHeight else { return false }
        let horizontalOverflow = overflowBounds.width
        guard horizontalOverflow > Self.edgeVisibilityTolerance else { return false }

        let displayOffsetX = displayOffset(forUserOffset: userOffset).width
        switch edge {
        case .left:
            return displayOffsetX < horizontalOverflow - Self.edgeVisibilityTolerance
        case .right:
            return displayOffsetX > -horizontalOverflow + Self.edgeVisibilityTolerance
        }
    }

    func userOffsetRevealingContent(
        on edge: MangaPagedImageSurfaceHorizontalEdge,
        fromUserOffset userOffset: CGSize
    ) -> CGSize? {
        guard hasHiddenContent(on: edge, fromUserOffset: userOffset) else { return nil }
        let horizontalOverflow = overflowBounds.width
        let targetDisplayOffsetX = switch edge {
        case .left:
            horizontalOverflow
        case .right:
            -horizontalOverflow
        }
        return clampedUserOffset(
            CGSize(
                width: targetDisplayOffsetX - restingOffset.width,
                height: userOffset.height
            )
        )
    }

    private var overflowBounds: CGSize {
        CGSize(
            width: max(0, (contentSize.width - containerSize.width) / 2),
            height: max(0, (contentSize.height - containerSize.height) / 2)
        )
    }
}

struct MangaPagedSpreadSurfaceZoomLayout: Equatable {
    private static let edgeVisibilityTolerance: CGFloat = 0.5

    let containerSize: CGSize
    let zoomScale: CGFloat

    var contentSize: CGSize {
        let scale = max(1, zoomScale)
        return CGSize(width: containerSize.width * scale, height: containerSize.height * scale)
    }

    func clampedUserOffset(_ proposed: CGSize) -> CGSize {
        let bounds = overflowBounds
        return CGSize(
            width: proposed.width.clamped(lower: -bounds.width, upper: bounds.width),
            height: proposed.height.clamped(lower: -bounds.height, upper: bounds.height)
        )
    }

    func displayOffset(forUserOffset userOffset: CGSize) -> CGSize {
        clampedUserOffset(userOffset)
    }

    func userOffsetAnchoring(_ location: CGPoint) -> CGSize {
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        let targetLocation = CGRect(origin: .zero, size: containerSize).contains(location)
            ? location
            : center
        let scale = max(1, zoomScale)
        return clampedUserOffset(
            CGSize(
                width: -(targetLocation.x - center.x) * scale,
                height: -(targetLocation.y - center.y) * scale
            )
        )
    }

    func hasHiddenContent(
        on edge: MangaPagedImageSurfaceHorizontalEdge,
        fromUserOffset userOffset: CGSize
    ) -> Bool {
        let horizontalOverflow = overflowBounds.width
        guard horizontalOverflow > Self.edgeVisibilityTolerance else { return false }

        let displayOffsetX = displayOffset(forUserOffset: userOffset).width
        switch edge {
        case .left:
            return displayOffsetX < horizontalOverflow - Self.edgeVisibilityTolerance
        case .right:
            return displayOffsetX > -horizontalOverflow + Self.edgeVisibilityTolerance
        }
    }

    func userOffsetRevealingContent(
        on edge: MangaPagedImageSurfaceHorizontalEdge,
        fromUserOffset userOffset: CGSize
    ) -> CGSize? {
        guard hasHiddenContent(on: edge, fromUserOffset: userOffset) else { return nil }
        let horizontalOverflow = overflowBounds.width
        let targetDisplayOffsetX = switch edge {
        case .left:
            horizontalOverflow
        case .right:
            -horizontalOverflow
        }
        return clampedUserOffset(CGSize(width: targetDisplayOffsetX, height: userOffset.height))
    }

    private var overflowBounds: CGSize {
        CGSize(
            width: max(0, (contentSize.width - containerSize.width) / 2),
            height: max(0, (contentSize.height - containerSize.height) / 2)
        )
    }
}

private extension CGFloat {
    func clamped(lower: CGFloat, upper: CGFloat) -> CGFloat {
        Swift.min(upper, Swift.max(lower, self))
    }
}

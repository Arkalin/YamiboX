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

enum MangaPagedCenterTapHitTesting {
    static func acceptsCenterTap(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard bounds.width > 0,
              bounds.height > 0,
              bounds.contains(point) else {
            return false
        }
        return ReaderPagedTapZone.zone(for: point, in: bounds) == .toggleChrome
    }
}

enum MangaPagedSurfaceDragIntent {
    static func isSurfacePanEnabled(
        isInteractionEnabled: Bool,
        allowsUnzoomedSurfacePan: Bool,
        isZoomActive: Bool,
        hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge>
    ) -> Bool {
        guard isInteractionEnabled else { return false }
        return isZoomActive || (allowsUnzoomedSurfacePan && !hiddenEdges.isEmpty)
    }

    static func physicalEdge(
        forPanTranslation translation: CGSize,
        velocity: CGSize
    ) -> MangaPagedImageSurfaceHorizontalEdge? {
        MangaInteractionPolicy.dragEdge(translation: translation, velocity: velocity)
    }

    static func unzoomedSurfaceTranslation(_ translation: CGSize) -> CGSize {
        CGSize(width: translation.width, height: 0)
    }

    static func shouldBeginSurfacePan(
        isInteractionEnabled: Bool,
        allowsUnzoomedSurfacePan: Bool,
        isZoomActive: Bool,
        hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge>,
        translation: CGSize,
        velocity: CGSize = .zero
    ) -> Bool {
        guard isSurfacePanEnabled(
            isInteractionEnabled: isInteractionEnabled,
            allowsUnzoomedSurfacePan: allowsUnzoomedSurfacePan,
            isZoomActive: isZoomActive,
            hiddenEdges: hiddenEdges
        ) else {
            return false
        }
        if isZoomActive {
            return true
        }
        guard let physicalEdge = physicalEdge(forPanTranslation: translation, velocity: velocity) else {
            return false
        }
        return hiddenEdges.contains(physicalEdge)
    }

    static func shouldResetOffsetWhenInteractionDisables(zoomScale: CGFloat) -> Bool {
        MangaPageZoomPolicy.isActive(zoomScale)
    }
}

enum MangaPagedSurfaceEdgeInteraction {
    static func physicalEdge(forTapZone zone: ReaderPagedTapZone) -> MangaPagedImageSurfaceHorizontalEdge? {
        switch zone {
        case .previous:
            .left
        case .next:
            .right
        case .toggleChrome:
            nil
        }
    }

    static func physicalEdge(
        horizontalVelocityX: CGFloat,
        horizontalTranslationX: CGFloat
    ) -> MangaPagedImageSurfaceHorizontalEdge? {
        if horizontalVelocityX != 0 {
            return horizontalVelocityX < 0 ? .right : .left
        }

        guard horizontalTranslationX != 0 else { return nil }
        return horizontalTranslationX < 0 ? .right : .left
    }

    static func shouldRevealHiddenContent(
        on edge: MangaPagedImageSurfaceHorizontalEdge,
        hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge>
    ) -> Bool {
        hiddenEdges.contains(edge)
    }

    static func shouldDeferPageTurnPanToSurfaceContent(
        zoomEnabled: Bool,
        allowsUnzoomedSurfacePan: Bool,
        isZoomActive: Bool,
        hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge>,
        physicalEdge: MangaPagedImageSurfaceHorizontalEdge?
    ) -> Bool {
        MangaPagedPageTurnPanPolicy.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: zoomEnabled,
            allowsUnzoomedSurfacePan: allowsUnzoomedSurfacePan,
            isZoomActive: isZoomActive,
            hiddenEdges: hiddenEdges,
            physicalEdge: physicalEdge
        )
    }
}

enum MangaPagedPageTurnPanPolicy {
    static func shouldDeferPageTurnPanToSurfaceContent(
        zoomEnabled: Bool,
        allowsUnzoomedSurfacePan: Bool,
        isZoomActive: Bool,
        hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge>,
        physicalEdge: MangaPagedImageSurfaceHorizontalEdge?
    ) -> Bool {
        if isZoomActive {
            return zoomEnabled
        }
        guard allowsUnzoomedSurfacePan,
              let physicalEdge else {
            return false
        }
        return MangaPagedSurfaceEdgeInteraction.shouldRevealHiddenContent(
            on: physicalEdge,
            hiddenEdges: hiddenEdges
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

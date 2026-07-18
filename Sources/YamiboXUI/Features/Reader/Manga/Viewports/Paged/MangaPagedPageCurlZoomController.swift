import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedPageCurlZoomController {
    private unowned let coordinator: MangaPagedPageCurlCoordinator

    private var pageCurlSpreadHiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge> = []
    private var pageCurlSteadyScale: CGFloat = 1
    private var pageCurlGestureScale: CGFloat = 1
    private var pageCurlSteadyUserOffset: CGSize = .zero
    private var pageCurlGestureUserOffset: CGSize = .zero
    private var pageCurlPinchStartScale: CGFloat?
    private var pageCurlPinchStartDisplayOffset: CGSize?
    private var pageCurlPinchAnchor: CGPoint?

    private var parent: MangaPagedPageCurlReaderViewport {
        coordinator.parent
    }

    private var pageCurlZoomScale: CGFloat {
        // `pageCurlGestureScale` is maintained pre-attenuated (rubber-banded)
        // by the live pinch; the steady scale is hard-clamped on settle.
        pageCurlSteadyScale * pageCurlGestureScale
    }

    /// How a transform update should animate: not at all (live gesture
    /// tracking), with the critically damped settle spring (discrete changes),
    /// or continuing a released gesture at its relative velocity.
    private enum SpreadZoomAnimation {
        case none
        case settle
        case momentum(CGFloat)
    }

    init(coordinator: MangaPagedPageCurlCoordinator) {
        self.coordinator = coordinator
    }

    func handleSpreadPinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let containerViewController = coordinator.activeContainerViewController,
              isPageCurlSpreadZoomInteractionEnabled(in: containerViewController) else {
            return
        }
        switch recognizer.state {
        case .began:
            pageCurlPinchStartScale = pageCurlSteadyScale
            let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: pageCurlSteadyScale)
            pageCurlPinchStartDisplayOffset = layout.liveDisplayOffset(forUserOffset: pageCurlSteadyUserOffset)
            pageCurlPinchAnchor = recognizer.location(in: containerViewController.view)
        case .changed:
            let startScale = pageCurlPinchStartScale ?? pageCurlSteadyScale
            let displayScale = MangaPageZoomPolicy.rubberBandedScale(startScale * recognizer.scale)
            pageCurlGestureScale = displayScale / max(pageCurlSteadyScale, 0.001)
            pageCurlSteadyUserOffset = focalPageCurlUserOffset(
                displayScale: displayScale,
                in: containerViewController
            )
            applyPageCurlSpreadZoomTransform(in: containerViewController, animation: .none)
        case .ended, .cancelled, .failed:
            let startScale = pageCurlPinchStartScale ?? pageCurlSteadyScale
            let displayScale = MangaPageZoomPolicy.rubberBandedScale(startScale * recognizer.scale)
            let settleScale = MangaPageZoomPolicy.clampedScale(startScale * recognizer.scale)
            pageCurlPinchStartScale = nil
            pageCurlPinchStartDisplayOffset = nil
            pageCurlPinchAnchor = nil
            // Freeze the on-screen scale, then spring overshoot to the bound.
            pageCurlSteadyScale = displayScale
            pageCurlGestureScale = 1
            if MangaPageZoomPolicy.isActive(settleScale) {
                pageCurlSteadyScale = settleScale
                clampPageCurlSteadyUserOffset(in: containerViewController)
                applyPageCurlSpreadZoomTransform(in: containerViewController, animation: .settle)
            } else {
                resetPageCurlSpreadZoom(in: containerViewController, animated: true)
            }
        default:
            break
        }
    }

    func handleSpreadPan(_ recognizer: UIPanGestureRecognizer) {
        guard let containerViewController = coordinator.activeContainerViewController,
              isPageCurlSpreadPanEnabled(in: containerViewController) else {
            pageCurlGestureUserOffset = .zero
            return
        }
        let translation = recognizer.translation(in: containerViewController.view)
        switch recognizer.state {
        case .began, .changed:
            let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: pageCurlZoomScale)
            let proposed = CGSize(
                width: pageCurlSteadyUserOffset.width + translation.x,
                height: pageCurlSteadyUserOffset.height + translation.y
            )
            let banded = layout.rubberBandedUserOffset(proposed)
            pageCurlGestureUserOffset = CGSize(
                width: banded.width - pageCurlSteadyUserOffset.width,
                height: banded.height - pageCurlSteadyUserOffset.height
            )
            applyPageCurlSpreadZoomTransform(in: containerViewController, animation: .none)
        case .ended, .cancelled, .failed:
            let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: pageCurlSteadyScale)
            let velocity = recognizer.velocity(in: containerViewController.view)
            let current = layout.rubberBandedUserOffset(
                CGSize(
                    width: pageCurlSteadyUserOffset.width + translation.x,
                    height: pageCurlSteadyUserOffset.height + translation.y
                )
            )
            let projection = GesturePhysics.project(CGSize(width: velocity.x, height: velocity.y))
            let target = layout.clampedUserOffset(
                CGSize(
                    width: current.width + projection.width,
                    height: current.height + projection.height
                )
            )
            let initialVelocity = GesturePhysics.relativeVelocity(
                CGSize(width: velocity.x, height: velocity.y),
                from: current,
                to: target
            )
            pageCurlSteadyUserOffset = target
            pageCurlGestureUserOffset = .zero
            applyPageCurlSpreadZoomTransform(
                in: containerViewController,
                animation: .momentum(initialVelocity)
            )
        default:
            break
        }
    }

    /// Keeps the content point under the pinch's start centroid fixed while
    /// the scale changes, so the detail being inspected doesn't drift toward
    /// the container center.
    private func focalPageCurlUserOffset(
        displayScale: CGFloat,
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) -> CGSize {
        let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: displayScale)
        guard let pinchStartScale = pageCurlPinchStartScale,
              let pinchStartDisplayOffset = pageCurlPinchStartDisplayOffset,
              let anchor = pageCurlPinchAnchor,
              pinchStartScale > 0 else {
            return layout.rubberBandedUserOffset(pageCurlSteadyUserOffset)
        }
        let bounds = containerViewController.view.bounds
        let ratio = displayScale / pinchStartScale
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return layout.rubberBandedUserOffset(
            CGSize(
                width: (anchor.x - center.x) * (1 - ratio) + pinchStartDisplayOffset.width * ratio,
                height: (anchor.y - center.y) * (1 - ratio) + pinchStartDisplayOffset.height * ratio
            )
        )
    }

    func pageCurlContainerDidLayout(_ containerViewController: MangaPagedPageCurlContainerViewController) {
        guard parent.sequence.usesTwoPageSpread else {
            resetPageCurlSpreadZoom(in: containerViewController, animated: false)
            return
        }
        clampPageCurlSteadyUserOffset(in: containerViewController)
        applyPageCurlSpreadZoomTransform(in: containerViewController, animated: false)
    }

    func updatePageCurlSpreadZoomAvailability(
        in containerViewController: MangaPagedPageCurlContainerViewController,
        animated: Bool
    ) {
        guard isPageCurlSpreadZoomInteractionEnabled(in: containerViewController) else {
            resetPageCurlSpreadZoom(in: containerViewController, animated: animated)
            return
        }
        clampPageCurlSteadyUserOffset(in: containerViewController)
        applyPageCurlSpreadZoomTransform(in: containerViewController, animated: false)
    }

    func consumePageCurlSpreadEdgeTap(
        for zone: ReaderPagedTapZone,
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) -> Bool {
        guard parent.sequence.usesTwoPageSpread,
              let physicalEdge = MangaPagedSurfaceEdgeInteraction.physicalEdge(forTapZone: zone),
              MangaPagedSurfaceEdgeInteraction.shouldRevealHiddenContent(
                  on: physicalEdge,
                  hiddenEdges: pageCurlSpreadHiddenEdges
              ) else {
            return false
        }
        revealPageCurlSpreadHiddenContent(on: physicalEdge, in: containerViewController)
        return true
    }

    func shouldDeferPageCurlPanToSpreadContent(
        _ recognizer: UIPanGestureRecognizer,
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) -> Bool {
        guard parent.sequence.usesTwoPageSpread else { return false }
        let velocity = recognizer.velocity(in: containerViewController.view)
        let translation = recognizer.translation(in: containerViewController.view)
        let physicalEdge = MangaPagedSurfaceEdgeInteraction.physicalEdge(
            horizontalVelocityX: velocity.x,
            horizontalTranslationX: translation.x
        )
        return MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: parent.zoomEnabled,
            isZoomActive: MangaPageZoomPolicy.isActive(pageCurlZoomScale),
            hiddenEdges: pageCurlSpreadHiddenEdges,
            physicalEdge: physicalEdge
        )
    }

    func togglePageCurlSpreadZoom(
        at location: CGPoint,
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) {
        if MangaPageZoomPolicy.isZoomedForDoubleTapReset(pageCurlSteadyScale) {
            resetPageCurlSpreadZoom(in: containerViewController, animated: true)
        } else {
            zoomInPageCurlSpread(to: location, in: containerViewController)
        }
    }

    func resetPageCurlSpreadZoom(
        in containerViewController: MangaPagedPageCurlContainerViewController,
        animated: Bool
    ) {
        pageCurlSteadyScale = 1
        pageCurlGestureScale = 1
        pageCurlSteadyUserOffset = .zero
        pageCurlGestureUserOffset = .zero
        pageCurlPinchStartScale = nil
        pageCurlPinchStartDisplayOffset = nil
        pageCurlPinchAnchor = nil
        applyPageCurlSpreadZoomTransform(in: containerViewController, animated: animated)
    }

    func isPageCurlSpreadZoomInteractionEnabled(
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) -> Bool {
        parent.sequence.usesTwoPageSpread &&
            parent.zoomEnabled &&
            !parent.isChromeVisible &&
            containerViewController.view.bounds.width > 0 &&
            containerViewController.view.bounds.height > 0
    }

    func isPageCurlSpreadPanEnabled(
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) -> Bool {
        isPageCurlSpreadZoomInteractionEnabled(in: containerViewController) &&
            MangaPageZoomPolicy.isActive(pageCurlZoomScale)
    }

    private func zoomInPageCurlSpread(
        to location: CGPoint,
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) {
        let targetScale = MangaPageZoomPolicy.doubleTapTargetScale
        let targetLayout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: targetScale)
        pageCurlSteadyScale = targetScale
        pageCurlGestureScale = 1
        pageCurlSteadyUserOffset = targetLayout.userOffsetAnchoring(location)
        pageCurlGestureUserOffset = .zero
        applyPageCurlSpreadZoomTransform(in: containerViewController, animated: true)
    }

    private func revealPageCurlSpreadHiddenContent(
        on edge: MangaPagedImageSurfaceHorizontalEdge,
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) {
        let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: pageCurlZoomScale)
        let userOffset = proposedPageCurlSpreadUserOffset(layout: layout)
        guard let targetUserOffset = layout.userOffsetRevealingContent(on: edge, fromUserOffset: userOffset) else {
            updatePageCurlSpreadHiddenEdges(in: containerViewController)
            return
        }
        pageCurlSteadyUserOffset = targetUserOffset
        pageCurlGestureUserOffset = .zero
        applyPageCurlSpreadZoomTransform(in: containerViewController, animated: true)
    }

    private func clampPageCurlSteadyUserOffset(
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) {
        clampPageCurlSteadyUserOffset(in: containerViewController, scale: pageCurlSteadyScale)
    }

    private func clampPageCurlSteadyUserOffset(
        in containerViewController: MangaPagedPageCurlContainerViewController,
        scale: CGFloat
    ) {
        let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: scale)
        pageCurlSteadyUserOffset = layout.clampedUserOffset(pageCurlSteadyUserOffset)
        pageCurlGestureUserOffset = .zero
    }

    private func applyPageCurlSpreadZoomTransform(
        in containerViewController: MangaPagedPageCurlContainerViewController,
        animated: Bool
    ) {
        applyPageCurlSpreadZoomTransform(
            in: containerViewController,
            animation: animated ? .settle : .none
        )
    }

    private func applyPageCurlSpreadZoomTransform(
        in containerViewController: MangaPagedPageCurlContainerViewController,
        animation: SpreadZoomAnimation
    ) {
        let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: pageCurlZoomScale)
        let userOffset = proposedPageCurlSpreadUserOffset(layout: layout)
        let displayOffset = layout.liveDisplayOffset(forUserOffset: userOffset)
        let pageViewController = containerViewController.pageViewController
        let updates = {
            pageViewController.view.transform = CGAffineTransform(translationX: displayOffset.width, y: displayOffset.height).scaledBy(
                x: self.pageCurlZoomScale,
                y: self.pageCurlZoomScale
            )
        }
        switch animation {
        case .none:
            updates()
        case .settle:
            UIView.animate(
                withDuration: 0.38,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: updates
            )
        case .momentum(let initialVelocity):
            UIView.animate(
                withDuration: 0.4,
                delay: 0,
                usingSpringWithDamping: 0.86,
                initialSpringVelocity: initialVelocity,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: updates
            )
        }
        pageCurlSpreadHiddenEdges = hiddenPageCurlSpreadHorizontalEdges(layout: layout, userOffset: userOffset)
        coordinator.gestures.updatePageCurlContainerGestureState(in: containerViewController)
    }

    private func updatePageCurlSpreadHiddenEdges(
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) {
        let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: pageCurlZoomScale)
        let userOffset = proposedPageCurlSpreadUserOffset(layout: layout)
        pageCurlSpreadHiddenEdges = hiddenPageCurlSpreadHorizontalEdges(layout: layout, userOffset: userOffset)
    }

    private func proposedPageCurlSpreadUserOffset(layout: MangaPagedSpreadSurfaceZoomLayout) -> CGSize {
        // Already rubber-banded when written by the live gesture; clamping
        // here would flatten the overshoot mid-drag.
        CGSize(
            width: pageCurlSteadyUserOffset.width + pageCurlGestureUserOffset.width,
            height: pageCurlSteadyUserOffset.height + pageCurlGestureUserOffset.height
        )
    }

    private func hiddenPageCurlSpreadHorizontalEdges(
        layout: MangaPagedSpreadSurfaceZoomLayout,
        userOffset: CGSize
    ) -> Set<MangaPagedImageSurfaceHorizontalEdge> {
        Set(
            MangaPagedImageSurfaceHorizontalEdge.allCases.filter { edge in
                layout.hasHiddenContent(on: edge, fromUserOffset: userOffset)
            }
        )
    }

    private func pageCurlSpreadSurfaceLayout(
        in containerViewController: MangaPagedPageCurlContainerViewController,
        scale: CGFloat
    ) -> MangaPagedSpreadSurfaceZoomLayout {
        MangaPagedSpreadSurfaceZoomLayout(
            containerSize: containerViewController.view.bounds.size,
            zoomScale: scale
        )
    }
}
#endif

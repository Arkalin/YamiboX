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

    private var parent: MangaPagedPageCurlReaderViewport {
        coordinator.parent
    }

    private var pageCurlZoomScale: CGFloat {
        MangaPageZoomPolicy.clampedScale(pageCurlSteadyScale * pageCurlGestureScale)
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
        case .changed:
            let startScale = pageCurlPinchStartScale ?? pageCurlSteadyScale
            let targetScale = MangaPageZoomPolicy.clampedScale(startScale * recognizer.scale)
            pageCurlGestureScale = targetScale / max(pageCurlSteadyScale, 0.001)
            clampPageCurlSteadyUserOffset(in: containerViewController, scale: targetScale)
            applyPageCurlSpreadZoomTransform(in: containerViewController, animated: false)
        case .ended, .cancelled, .failed:
            let startScale = pageCurlPinchStartScale ?? pageCurlSteadyScale
            let targetScale = MangaPageZoomPolicy.clampedScale(startScale * recognizer.scale)
            pageCurlPinchStartScale = nil
            pageCurlSteadyScale = targetScale
            pageCurlGestureScale = 1
            if MangaPageZoomPolicy.isActive(targetScale) {
                clampPageCurlSteadyUserOffset(in: containerViewController)
                applyPageCurlSpreadZoomTransform(in: containerViewController, animated: true)
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
            let clamped = layout.clampedUserOffset(proposed)
            pageCurlGestureUserOffset = CGSize(
                width: clamped.width - pageCurlSteadyUserOffset.width,
                height: clamped.height - pageCurlSteadyUserOffset.height
            )
            applyPageCurlSpreadZoomTransform(in: containerViewController, animated: false)
        case .ended, .cancelled, .failed:
            let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: pageCurlSteadyScale)
            let proposed = CGSize(
                width: pageCurlSteadyUserOffset.width + translation.x,
                height: pageCurlSteadyUserOffset.height + translation.y
            )
            pageCurlSteadyUserOffset = layout.clampedUserOffset(proposed)
            pageCurlGestureUserOffset = .zero
            applyPageCurlSpreadZoomTransform(in: containerViewController, animated: false)
        default:
            break
        }
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
        let layout = pageCurlSpreadSurfaceLayout(in: containerViewController, scale: pageCurlZoomScale)
        let userOffset = proposedPageCurlSpreadUserOffset(layout: layout)
        let displayOffset = layout.displayOffset(forUserOffset: userOffset)
        let pageViewController = containerViewController.pageViewController
        let updates = {
            pageViewController.view.transform = CGAffineTransform(translationX: displayOffset.width, y: displayOffset.height).scaledBy(
                x: self.pageCurlZoomScale,
                y: self.pageCurlZoomScale
            )
        }
        if animated {
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction],
                animations: updates
            )
        } else {
            updates()
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
        layout.clampedUserOffset(
            CGSize(
                width: pageCurlSteadyUserOffset.width + pageCurlGestureUserOffset.width,
                height: pageCurlSteadyUserOffset.height + pageCurlGestureUserOffset.height
            )
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

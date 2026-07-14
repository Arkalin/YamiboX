import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedPageCurlGestureController: NSObject, UIGestureRecognizerDelegate {
    private weak var coordinator: MangaPagedPageCurlCoordinator?

    private(set) lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    private(set) lazy var doubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        recognizer.numberOfTapsRequired = 2
        return recognizer
    }()
    private(set) lazy var boundaryPageTurnPanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleBoundaryPageTurnPan(_:))
    )
    private(set) lazy var spreadPinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handleSpreadPinch(_:)))
    private(set) lazy var spreadPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleSpreadPan(_:)))

    init(coordinator: MangaPagedPageCurlCoordinator) {
        self.coordinator = coordinator
    }

    func configureContainerGestures(in containerViewController: MangaPagedPageCurlContainerViewController) {
        guard let coordinator else { return }
        coordinator.activeContainerViewController = containerViewController
        if tapGesture.view !== containerViewController.view {
            tapGesture.cancelsTouchesInView = false
            tapGesture.delegate = self
            tapGesture.require(toFail: doubleTapGesture)
            containerViewController.view.addGestureRecognizer(tapGesture)
        }
        if doubleTapGesture.view !== containerViewController.view {
            doubleTapGesture.cancelsTouchesInView = false
            doubleTapGesture.delegate = self
            containerViewController.view.addGestureRecognizer(doubleTapGesture)
        }
        if spreadPinchGesture.view !== containerViewController.view {
            spreadPinchGesture.cancelsTouchesInView = false
            spreadPinchGesture.delegate = self
            containerViewController.view.addGestureRecognizer(spreadPinchGesture)
        }
        if spreadPanGesture.view !== containerViewController.view {
            spreadPanGesture.cancelsTouchesInView = false
            spreadPanGesture.delegate = self
            containerViewController.view.addGestureRecognizer(spreadPanGesture)
        }
        updatePageCurlContainerGestureState(in: containerViewController)
    }

    func configureGestures(in pageViewController: UIPageViewController) {
        guard let coordinator else { return }
        coordinator.activePageViewController = pageViewController
        if boundaryPageTurnPanGesture.view !== pageViewController.view {
            boundaryPageTurnPanGesture.delegate = self
            pageViewController.view.addGestureRecognizer(boundaryPageTurnPanGesture)
        }
        for recognizer in pageViewController.gestureRecognizers {
            if recognizer is UITapGestureRecognizer {
                recognizer.isEnabled = false
            } else if recognizer is UIPanGestureRecognizer {
                recognizer.delegate = self
                recognizer.isEnabled = !coordinator.parent.isChromeVisible
            }
        }
    }

    func updatePageCurlContainerGestureState(in containerViewController: MangaPagedPageCurlContainerViewController) {
        doubleTapGesture.isEnabled = true
        guard let coordinator else {
            spreadPinchGesture.isEnabled = false
            spreadPanGesture.isEnabled = false
            return
        }
        spreadPinchGesture.isEnabled = coordinator.zoom.isPageCurlSpreadZoomInteractionEnabled(in: containerViewController)
        spreadPanGesture.isEnabled = coordinator.zoom.isPageCurlSpreadPanEnabled(in: containerViewController)
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let coordinator,
              let containerViewController = coordinator.activeContainerViewController,
              let pageViewController = coordinator.activePageViewController else {
            return
        }
        let parent = coordinator.parent
        if parent.isChromeVisible {
            let onTap = parent.onTap
            coordinator.callbackScheduler.publish {
                onTap()
            }
            return
        }

        let zone = ReaderPagedTapZone.zone(
            for: recognizer.location(in: containerViewController.view),
            in: containerViewController.view.bounds
        )
        if coordinator.zoom.consumePageCurlSpreadEdgeTap(for: zone, in: containerViewController) ||
            consumeSurfaceEdgeTap(for: zone, in: pageViewController) {
            return
        }
        switch directionalTapZone(for: zone) {
        case .previous:
            coordinator.animateAdjacentSelection(delta: -1, in: pageViewController)
        case .next:
            coordinator.animateAdjacentSelection(delta: 1, in: pageViewController)
        case .toggleChrome:
            let onTap = parent.onTap
            coordinator.callbackScheduler.publish {
                onTap()
            }
        }
    }

    @objc
    private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let coordinator,
              let containerViewController = coordinator.activeContainerViewController else {
            return
        }
        let parent = coordinator.parent
        let location = recognizer.location(in: containerViewController.view)
        guard MangaPagedCenterTapHitTesting.acceptsCenterTap(
            at: location,
            in: containerViewController.view.bounds
        ) else {
            return
        }

        if parent.isChromeVisible {
            let onTap = parent.onTap
            coordinator.callbackScheduler.publish {
                onTap()
            }
            return
        }

        guard parent.zoomEnabled else { return }
        if parent.sequence.usesTwoPageSpread {
            coordinator.zoom.togglePageCurlSpreadZoom(at: location, in: containerViewController)
        } else {
            requestPageCurlPageZoomToggle(at: location, in: containerViewController)
        }
    }

    @objc
    private func handleSpreadPinch(_ recognizer: UIPinchGestureRecognizer) {
        coordinator?.zoom.handleSpreadPinch(recognizer)
    }

    @objc
    private func handleSpreadPan(_ recognizer: UIPanGestureRecognizer) {
        coordinator?.zoom.handleSpreadPan(recognizer)
    }

    @objc
    private func handleBoundaryPageTurnPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended,
              let coordinator,
              !coordinator.parent.isChromeVisible,
              let view = recognizer.view else {
            return
        }
        let parent = coordinator.parent
        guard let delta = ReaderPagedBoundaryPageTurn.boundaryDelta(
            selectionIndex: parent.selectionIndex,
            itemCount: parent.sequence.pageCount,
            translation: recognizer.translation(in: view),
            velocity: recognizer.velocity(in: view),
            viewportWidth: view.bounds.width,
            horizontalNavigationDirection: parent.settings.pageTurnDirection.horizontalNavigationDirection,
            canBoundaryPageTurn: parent.canBoundaryPageTurn
        ) else {
            return
        }
        let onBoundaryPageTurn = parent.onBoundaryPageTurn
        coordinator.callbackScheduler.publish {
            onBoundaryPageTurn(delta)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard touch.view?.isDescendant(ofType: UIControl.self) != true else {
            return false
        }
        guard gestureRecognizer === doubleTapGesture,
              let containerViewController = coordinator?.activeContainerViewController else {
            return true
        }
        return MangaPagedCenterTapHitTesting.acceptsCenterTap(
            at: touch.location(in: containerViewController.view),
            in: containerViewController.view.bounds
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is UIPanGestureRecognizer ||
            otherGestureRecognizer is UIPanGestureRecognizer ||
            gestureRecognizer is UIPinchGestureRecognizer ||
            otherGestureRecognizer is UIPinchGestureRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === spreadPinchGesture {
            guard let coordinator,
                  let containerViewController = coordinator.activeContainerViewController else {
                return false
            }
            return coordinator.zoom.isPageCurlSpreadZoomInteractionEnabled(in: containerViewController)
        }
        if gestureRecognizer === spreadPanGesture {
            guard let coordinator,
                  let containerViewController = coordinator.activeContainerViewController else {
                return false
            }
            return coordinator.zoom.isPageCurlSpreadPanEnabled(in: containerViewController)
        }
        if gestureRecognizer === boundaryPageTurnPanGesture {
            guard let coordinator,
                  let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer,
                  !coordinator.parent.isChromeVisible,
                  let view = panRecognizer.view else {
                return false
            }
            let parent = coordinator.parent
            let velocity = panRecognizer.velocity(in: view)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
            let physicalDelta = velocity.x < 0 ? 1 : -1
            let delta = ReaderPagedBoundaryPageTurn.directionalDelta(
                physicalDelta,
                direction: parent.settings.pageTurnDirection.horizontalNavigationDirection
            )
            let targetSelectionIndex = parent.selectionIndex + delta
            guard targetSelectionIndex < 0 || targetSelectionIndex >= parent.sequence.pageCount else {
                return false
            }
            return parent.canBoundaryPageTurn(delta)
        }
        guard let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer,
              gestureRecognizer !== spreadPanGesture,
              gestureRecognizer !== boundaryPageTurnPanGesture,
              let coordinator,
              let pageViewController = coordinator.activePageViewController,
              pageViewController.gestureRecognizers.contains(where: { $0 === gestureRecognizer }) else {
            return true
        }
        guard !coordinator.parent.isChromeVisible else {
            return false
        }
        guard canBeginPageCurlPan(panRecognizer, in: pageViewController) else {
            return false
        }
        if let containerViewController = coordinator.activeContainerViewController,
           coordinator.zoom.shouldDeferPageCurlPanToSpreadContent(panRecognizer, in: containerViewController) {
            return false
        }
        if shouldDeferPageCurlPanToSurfaceContent(panRecognizer, in: pageViewController) {
            return false
        }
        return true
    }

    /// Non-touch equivalent of the edge-zone tap check in `handleTap`: `delta`
    /// is a reading-order step (+1 next/-1 previous), translated to a
    /// physical edge the same way a tap zone is, so a keyboard/gamepad/Pencil
    /// page turn defers to revealing hidden fit-height/zoomed content before
    /// it's allowed to actually turn the page.
    func attemptControlPageTurnEdgeReveal(
        delta: Int,
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) -> Bool {
        let readingZone: ReaderPagedTapZone = delta > 0 ? .next : .previous
        let physicalZone = directionalTapZone(for: readingZone)
        return coordinator?.zoom.consumePageCurlSpreadEdgeTap(for: physicalZone, in: containerViewController) == true ||
            consumeSurfaceEdgeTap(for: physicalZone, in: containerViewController.pageViewController)
    }

    private func consumeSurfaceEdgeTap(for zone: ReaderPagedTapZone, in pageViewController: UIPageViewController) -> Bool {
        guard let coordinator,
              !coordinator.parent.sequence.usesTwoPageSpread,
              let physicalEdge = MangaPagedSurfaceEdgeInteraction.physicalEdge(forTapZone: zone),
              let surfaceInteraction = pageCurlSurfaceInteraction(
                  onPhysicalEdge: physicalEdge,
                  in: pageViewController
              ),
              MangaPagedSurfaceEdgeInteraction.shouldRevealHiddenContent(
                  on: physicalEdge,
                  hiddenEdges: surfaceInteraction.hiddenEdges
              ) else {
            return false
        }
        return surfaceInteraction.consumeTap(onPhysicalEdge: physicalEdge)
    }

    private func shouldDeferPageCurlPanToSurfaceContent(
        _ recognizer: UIPanGestureRecognizer,
        in pageViewController: UIPageViewController
    ) -> Bool {
        guard let coordinator,
              !coordinator.parent.sequence.usesTwoPageSpread,
              let surfaceInteraction = currentPageCurlSurfaceInteraction(in: pageViewController) else {
            return false
        }
        let velocity = recognizer.velocity(in: pageViewController.view)
        let translation = recognizer.translation(in: pageViewController.view)
        let physicalEdge = MangaPagedSurfaceEdgeInteraction.physicalEdge(
            horizontalVelocityX: velocity.x,
            horizontalTranslationX: translation.x
        )
        return MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: coordinator.parent.zoomEnabled,
            isZoomActive: surfaceInteraction.isZoomActive,
            hiddenEdges: surfaceInteraction.hiddenEdges,
            physicalEdge: physicalEdge
        )
    }

    private enum PageCurlPanDirection {
        case before
        case after
    }

    private func canBeginPageCurlPan(
        _ recognizer: UIPanGestureRecognizer,
        in pageViewController: UIPageViewController
    ) -> Bool {
        guard let coordinator else { return false }
        let parent = coordinator.parent
        let visibleLeafIndexes = (pageViewController.viewControllers ?? [])
            .compactMap { ($0 as? MangaPagedPageCurlHostingController)?.leaf }
            .compactMap(parent.sequence.leafIndex(matching:))
        guard !visibleLeafIndexes.isEmpty else { return false }

        switch pageCurlPanDirection(for: recognizer, in: pageViewController) {
        case .before:
            guard let firstLeafIndex = visibleLeafIndexes.min() else { return false }
            return parent.sequence.leafIndex(before: firstLeafIndex) != nil
        case .after:
            guard let lastLeafIndex = visibleLeafIndexes.max() else { return false }
            return parent.sequence.leafIndex(after: lastLeafIndex) != nil
        }
    }

    private func pageCurlPanDirection(
        for recognizer: UIPanGestureRecognizer,
        in pageViewController: UIPageViewController
    ) -> PageCurlPanDirection {
        let velocity = recognizer.velocity(in: pageViewController.view)
        if abs(velocity.x) > 1 {
            return velocity.x < 0 ? .after : .before
        }

        let translation = recognizer.translation(in: pageViewController.view)
        if abs(translation.x) > 1 {
            return translation.x < 0 ? .after : .before
        }

        let location = recognizer.location(in: pageViewController.view)
        return location.x >= pageViewController.view.bounds.midX ? .after : .before
    }

    private func currentPageCurlSurfaceInteraction(
        in pageViewController: UIPageViewController
    ) -> MangaPagedReaderPageSurfaceInteraction? {
        guard let coordinator else { return nil }
        let targetController = (pageViewController.viewControllers ?? [])
            .compactMap { $0 as? MangaPagedPageCurlHostingController }
            .sorted { $0.leaf.index < $1.leaf.index }
            .first
        guard let pageIndex = targetController?.leaf.pageIndex,
              let page = coordinator.parent.plan.page(at: pageIndex) else {
            return nil
        }
        return coordinator.pageSurfaceInteractions[page.id]
    }

    private func pageCurlSurfaceInteraction(
        onPhysicalEdge edge: MangaPagedImageSurfaceHorizontalEdge,
        in pageViewController: UIPageViewController
    ) -> MangaPagedReaderPageSurfaceInteraction? {
        guard let coordinator else { return nil }
        let parent = coordinator.parent
        let controllers = (pageViewController.viewControllers ?? [])
            .compactMap { $0 as? MangaPagedPageCurlHostingController }
            .sorted { $0.leaf.index < $1.leaf.index }
        let targetController: MangaPagedPageCurlHostingController?
        if parent.sequence.usesTwoPageSpread {
            targetController = switch edge {
            case .left:
                controllers.first
            case .right:
                controllers.last
            }
        } else {
            targetController = controllers.first
        }
        guard let pageIndex = targetController?.leaf.pageIndex,
              let page = parent.plan.page(at: pageIndex) else {
            return nil
        }
        return coordinator.pageSurfaceInteractions[page.id]
    }

    private func requestPageCurlPageZoomToggle(
        at location: CGPoint,
        in containerViewController: MangaPagedPageCurlContainerViewController
    ) {
        guard let coordinator,
              let targetController = (containerViewController.pageViewController.viewControllers ?? [])
              .compactMap({ $0 as? MangaPagedPageCurlHostingController })
              .first,
              let pageIndex = targetController.leaf.pageIndex,
              let page = coordinator.parent.plan.page(at: pageIndex),
              let surfaceInteraction = coordinator.pageSurfaceInteractions[page.id] else {
            return
        }
        let targetLocation = containerViewController.view.convert(location, to: targetController.view)
        surfaceInteraction.requestZoomToggle(at: targetLocation)
    }

    private func directionalTapZone(for zone: ReaderPagedTapZone) -> ReaderPagedTapZone {
        guard coordinator?.parent.settings.pageTurnDirection == .rightToLeft else {
            return zone
        }
        switch zone {
        case .previous:
            return .next
        case .next:
            return .previous
        case .toggleChrome:
            return .toggleChrome
        }
    }
}
#endif

import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedScrollGestureController: NSObject, UIGestureRecognizerDelegate {
    private weak var coordinator: MangaPagedScrollCoordinator?

    private(set) lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    private(set) lazy var doubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        recognizer.numberOfTapsRequired = 2
        return recognizer
    }()
    private(set) lazy var quickFadePanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleQuickFadePan(_:)))

    init(coordinator: MangaPagedScrollCoordinator) {
        self.coordinator = coordinator
    }

    func install(in collectionView: MangaPagedReaderCollectionView) {
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        tapGesture.require(toFail: doubleTapGesture)
        collectionView.addGestureRecognizer(tapGesture)
        doubleTapGesture.cancelsTouchesInView = false
        doubleTapGesture.delegate = self
        collectionView.addGestureRecognizer(doubleTapGesture)
        quickFadePanGesture.delegate = self
        collectionView.addGestureRecognizer(quickFadePanGesture)
        collectionView.shouldBeginPanGesture = { [weak self, weak collectionView] recognizer in
            guard let self,
                  let collectionView else {
                return true
            }
            return self.collectionViewPanShouldBegin(recognizer, in: collectionView)
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let collectionView = recognizer.view as? UICollectionView,
              let coordinator else {
            return
        }
        let parent = coordinator.parent
        let zone = ReaderPagedTapZone.zone(
            for: recognizer.location(in: collectionView),
            in: collectionView.bounds
        )
        if parent.isChromeVisible {
            let onTap = parent.onTap
            coordinator.callbackScheduler.publish {
                onTap()
            }
            return
        }
        if consumeSurfaceEdgeTap(for: zone, in: collectionView) {
            return
        }
        let directionalZone = directionalTapZone(for: zone)
        if coordinator.pagingDriver.animateAdjacentSelection(
            for: directionalZone,
            in: collectionView,
            inputs: coordinator.pagingInputs
        ) {
            return
        }
        guard directionalZone == .toggleChrome else {
            return
        }
        let onTap = parent.onTap
        coordinator.callbackScheduler.publish {
            onTap()
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let collectionView = recognizer.view as? UICollectionView,
              let coordinator else {
            return
        }
        let parent = coordinator.parent
        let location = recognizer.location(in: collectionView)
        guard MangaPagedCenterTapHitTesting.acceptsCenterTap(at: location, in: collectionView.bounds) else {
            return
        }

        if parent.isChromeVisible {
            let onTap = parent.onTap
            coordinator.callbackScheduler.publish {
                onTap()
            }
            return
        }

        guard parent.zoomEnabled else {
            return
        }
        if parent.plan.usesTwoPageSpread {
            requestSpreadZoomToggle(at: location, in: collectionView)
            return
        }

        guard let pageIndex = pageIndex(at: location, in: collectionView),
              let page = parent.plan.page(at: pageIndex),
              let surfaceInteraction = coordinator.pageSurfaceInteractions[page.id] else {
            return
        }
        surfaceInteraction.requestZoomToggle(at: surfaceLocation(for: pageIndex, location: location, in: collectionView))
    }

    @objc private func handleQuickFadePan(_ recognizer: UIPanGestureRecognizer) {
        guard let coordinator,
              !coordinator.parent.isChromeVisible else {
            return
        }
        coordinator.pagingDriver.handleQuickFadePan(recognizer, inputs: coordinator.pagingInputs)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard touch.view?.isDescendant(ofType: UIControl.self) != true else {
            return false
        }
        guard gestureRecognizer === doubleTapGesture,
              let collectionView = gestureRecognizer.view as? UICollectionView else {
            return true
        }
        return MangaPagedCenterTapHitTesting.acceptsCenterTap(
            at: touch.location(in: collectionView),
            in: collectionView.bounds
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === quickFadePanGesture,
              let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        guard let coordinator,
              !coordinator.parent.isChromeVisible,
              let collectionView = panRecognizer.view as? UICollectionView,
              coordinator.pagingDriver.quickFadePanShouldBegin(panRecognizer, inputs: coordinator.pagingInputs) else {
            return false
        }
        if shouldDeferPageTurnPanToSurfaceContent(panRecognizer, in: collectionView) {
            return false
        }
        return true
    }

    func collectionViewPanShouldBegin(
        _ panRecognizer: UIPanGestureRecognizer,
        in collectionView: UICollectionView
    ) -> Bool {
        guard let coordinator else {
            return true
        }
        guard !coordinator.parent.isChromeVisible,
              coordinator.parent.settings.pagedTurnStyle != .quickFade else {
            return false
        }
        if shouldDeferPageTurnPanToSurfaceContent(panRecognizer, in: collectionView) {
            return false
        }
        return true
    }

    private func shouldDeferPageTurnPanToSurfaceContent(
        _ recognizer: UIPanGestureRecognizer,
        in collectionView: UICollectionView
    ) -> Bool {
        guard let coordinator else {
            return false
        }
        let parent = coordinator.parent
        let surfaceInteraction: MangaPagedReaderPageSurfaceInteraction?
        if parent.plan.usesTwoPageSpread {
            surfaceInteraction = currentSpreadSurfaceInteraction(in: collectionView)
        } else {
            surfaceInteraction = currentPageSurfaceInteraction(in: collectionView)
        }
        guard let surfaceInteraction else {
            return false
        }
        let velocity = recognizer.velocity(in: collectionView)
        let translation = recognizer.translation(in: collectionView)
        let physicalEdge = MangaPagedSurfaceEdgeInteraction.physicalEdge(
            horizontalVelocityX: velocity.x,
            horizontalTranslationX: translation.x
        )
        return MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: parent.zoomEnabled,
            isZoomActive: surfaceInteraction.isZoomActive,
            hiddenEdges: surfaceInteraction.hiddenEdges,
            physicalEdge: physicalEdge
        )
    }

    /// Non-touch equivalent of the edge-zone tap check in `handleTap`: `delta`
    /// is a reading-order step (+1 next/-1 previous), translated to a
    /// physical edge the same way a tap zone is, so a keyboard/gamepad/Pencil
    /// page turn defers to revealing hidden fit-height/zoomed content before
    /// it's allowed to actually turn the page.
    func attemptControlPageTurnEdgeReveal(delta: Int, in collectionView: UICollectionView) -> Bool {
        let readingZone: ReaderPagedTapZone = delta > 0 ? .next : .previous
        return consumeSurfaceEdgeTap(for: directionalTapZone(for: readingZone), in: collectionView)
    }

    private func consumeSurfaceEdgeTap(for zone: ReaderPagedTapZone, in collectionView: UICollectionView) -> Bool {
        guard let coordinator,
              let physicalEdge = MangaPagedSurfaceEdgeInteraction.physicalEdge(forTapZone: zone) else {
            return false
        }
        let parent = coordinator.parent
        let surfaceInteraction: MangaPagedReaderPageSurfaceInteraction?
        if parent.plan.usesTwoPageSpread {
            surfaceInteraction = currentSpreadSurfaceInteraction(in: collectionView)
        } else if let pageIndex = pageIndex(forPhysicalEdge: physicalEdge, in: collectionView),
                  let page = parent.plan.page(at: pageIndex) {
            surfaceInteraction = coordinator.pageSurfaceInteractions[page.id]
        } else {
            surfaceInteraction = nil
        }
        guard let surfaceInteraction,
              MangaPagedSurfaceEdgeInteraction.shouldRevealHiddenContent(
                  on: physicalEdge,
                  hiddenEdges: surfaceInteraction.hiddenEdges
              ) else {
            return false
        }
        return surfaceInteraction.consumeTap(onPhysicalEdge: physicalEdge)
    }

    private func requestSpreadZoomToggle(at location: CGPoint, in collectionView: UICollectionView) {
        guard let coordinator,
              let spreadIndex = coordinator.currentSpreadIndex(in: collectionView),
              let spread = coordinator.parent.plan.spread(at: spreadIndex),
              let surfaceInteraction = coordinator.spreadSurfaceInteractions[spread.id] else {
            return
        }
        surfaceInteraction.requestZoomToggle(at: spreadLocation(for: spreadIndex, location: location, in: collectionView))
    }

    private func currentSpreadSurfaceInteraction(
        in collectionView: UICollectionView
    ) -> MangaPagedReaderPageSurfaceInteraction? {
        guard let coordinator,
              let spreadIndex = coordinator.currentSpreadIndex(in: collectionView),
              let spread = coordinator.parent.plan.spread(at: spreadIndex) else {
            return nil
        }
        return coordinator.spreadSurfaceInteractions[spread.id]
    }

    private func currentPageSurfaceInteraction(
        in collectionView: UICollectionView
    ) -> MangaPagedReaderPageSurfaceInteraction? {
        guard let coordinator,
              let pageIndex = currentPageIndex(in: collectionView),
              let page = coordinator.parent.plan.page(at: pageIndex) else {
            return nil
        }
        return coordinator.pageSurfaceInteractions[page.id]
    }

    private func surfaceLocation(
        for pageIndex: Int,
        location: CGPoint,
        in collectionView: UICollectionView
    ) -> CGPoint {
        guard let coordinator else {
            return CGPoint(
                x: location.x - collectionView.bounds.minX,
                y: location.y - collectionView.bounds.minY
            )
        }
        let parent = coordinator.parent
        let spreadIndex = parent.plan.spreadIndex(forPageAt: pageIndex) ?? 0
        let indexPath = IndexPath(item: coordinator.viewportIndex(forSpreadIndex: spreadIndex), section: 0)
        if let cell = collectionView.cellForItem(at: indexPath) {
            var cellLocation = collectionView.convert(location, to: cell.contentView)
            if parent.plan.usesTwoPageSpread,
               let spread = parent.plan.spread(at: spreadIndex) {
                let slotWidth = max(cell.contentView.bounds.width / 2, 1)
                if spread.rightPageIndex == pageIndex {
                    cellLocation.x -= slotWidth
                }
                cellLocation.x = min(max(cellLocation.x, 0), slotWidth)
            }
            return cellLocation
        }
        return CGPoint(
            x: location.x - collectionView.bounds.minX,
            y: location.y - collectionView.bounds.minY
        )
    }

    private func spreadLocation(
        for spreadIndex: Int,
        location: CGPoint,
        in collectionView: UICollectionView
    ) -> CGPoint {
        guard let coordinator else {
            return CGPoint(
                x: location.x - collectionView.bounds.minX,
                y: location.y - collectionView.bounds.minY
            )
        }
        let indexPath = IndexPath(item: coordinator.viewportIndex(forSpreadIndex: spreadIndex), section: 0)
        if let cell = collectionView.cellForItem(at: indexPath) {
            let cellLocation = collectionView.convert(location, to: cell.contentView)
            return CGPoint(
                x: min(max(cellLocation.x, 0), max(cell.contentView.bounds.width, 1)),
                y: min(max(cellLocation.y, 0), max(cell.contentView.bounds.height, 1))
            )
        }
        return CGPoint(
            x: location.x - collectionView.bounds.minX,
            y: location.y - collectionView.bounds.minY
        )
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

    private func currentPageIndex(in collectionView: UICollectionView) -> Int? {
        guard let coordinator else { return nil }
        return coordinator.currentSpreadIndex(in: collectionView)
            .flatMap(coordinator.parent.plan.pageIndex(forSpreadAt:))
    }

    private func pageIndex(at location: CGPoint, in collectionView: UICollectionView) -> Int? {
        guard let coordinator else { return nil }
        let parent = coordinator.parent
        guard let spreadIndex = coordinator.currentSpreadIndex(in: collectionView),
              let spread = parent.plan.spread(at: spreadIndex) else {
            return parent.plan.currentPageIndex
        }
        guard parent.plan.usesTwoPageSpread else {
            return spread.preferredPageIndex
        }
        return spread.pageIndexForHorizontalLocation(location.x, width: collectionView.bounds.width)
    }

    private func pageIndex(
        forPhysicalEdge edge: MangaPagedImageSurfaceHorizontalEdge,
        in collectionView: UICollectionView
    ) -> Int? {
        guard let coordinator else { return nil }
        let parent = coordinator.parent
        guard let spreadIndex = coordinator.currentSpreadIndex(in: collectionView),
              let spread = parent.plan.spread(at: spreadIndex) else {
            return parent.plan.currentPageIndex
        }
        guard parent.plan.usesTwoPageSpread else {
            return spread.preferredPageIndex
        }
        switch edge {
        case .left:
            return spread.leftPageIndex
        case .right:
            return spread.rightPageIndex
        }
    }
}
#endif

import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedScrollNavigationAdapter: NSObject {
    private weak var coordinator: MangaPagedScrollCoordinator?

    let input = MangaNavigationInput()
    var tapGesture: UITapGestureRecognizer { input.tap }
    var doubleTapGesture: UITapGestureRecognizer { input.doubleTap }
    var quickFadePanGesture: UIPanGestureRecognizer { input.navigationPan }

    init(coordinator: MangaPagedScrollCoordinator) {
        self.coordinator = coordinator
        super.init()
        input.generation = { [weak coordinator] in coordinator?.interactionRuntime.navigationGeneration ?? 0 }
        input.permits = { [weak self] in self?.gestureRecognizerShouldBegin($0) ?? false }
        input.receives = { [weak self] in self?.gestureRecognizer($0, shouldReceive: $1) ?? false }
        input.onEvent = { [weak self] role, recognizer in
            switch role {
            case .tap: if let tap = recognizer as? UITapGestureRecognizer { self?.handleTap(tap) }
            case .doubleTap: if let tap = recognizer as? UITapGestureRecognizer { self?.handleDoubleTap(tap) }
            case .navigationPan: if let pan = recognizer as? UIPanGestureRecognizer { self?.handleQuickFadePan(pan) }
            case .surfacePan: break
            case .surfacePinch: break
            }
        }
    }

    func install(in collectionView: MangaPagedReaderCollectionView) {
        tapGesture.cancelsTouchesInView = false
        tapGesture.require(toFail: doubleTapGesture)
        input.install(tapGesture, in: collectionView)
        doubleTapGesture.cancelsTouchesInView = false
        input.install(doubleTapGesture, in: collectionView)
        input.install(quickFadePanGesture, in: collectionView)
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
        return surfaceInteraction.runtime.decision(.pan(
            translation: CGSize(width: translation.x, height: translation.y),
            velocity: CGSize(width: velocity.x, height: velocity.y)
        )) == .panImage
    }

    func routeControl(_ step: NavigationStep, in collectionView: UICollectionView) {
        guard let coordinator else { return }
        let zone: ReaderPagedTapZone = step == .forward ? .next : .previous
        guard let edge = MangaPagedSurfaceEdgeInteraction.physicalEdge(forTapZone: directionalTapZone(for: zone)) else { return }
        let surface = coordinator.parent.plan.usesTwoPageSpread
            ? currentSpreadSurfaceInteraction(in: collectionView) : currentPageSurfaceInteraction(in: collectionView)
        let decision = surface?.runtime.perform(.control(edge)) ?? .navigate(edge)
        if case .navigate = decision {
            let inputs = coordinator.pagingInputs
            let target = inputs.selectionIndex + step.rawValue
            if target < 0 || target >= inputs.itemCount {
                guard inputs.canBoundaryPageTurn(step.rawValue) else { return }
                let generation = coordinator.interactionRuntime.navigationGeneration
                coordinator.callbackScheduler.publish { [weak coordinator] in
                    guard coordinator?.interactionRuntime.navigationGeneration == generation else { return }
                    inputs.onBoundaryPageTurn(step.rawValue)
                }
            } else {
                _ = coordinator.pagingDriver.animateAdjacentSelection(for: zone, in: collectionView, inputs: inputs)
            }
        }
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

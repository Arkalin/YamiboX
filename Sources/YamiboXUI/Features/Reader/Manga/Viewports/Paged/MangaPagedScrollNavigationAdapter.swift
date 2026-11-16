import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedScrollNavigationAdapter {
    private weak var coordinator: MangaPagedScrollCoordinator?
    let input: MangaNavigationInput
    var discretePagePanGesture: UIPanGestureRecognizer { input.navigationPan }

    init(coordinator: MangaPagedScrollCoordinator, input: MangaNavigationInput = MangaNavigationInput()) {
        self.coordinator = coordinator
        self.input = input
        input.navigationContext = { [weak self] in
            guard let self, let coordinator = self.coordinator,
                  let index = coordinator.currentSpreadIndex else { return nil }
            return coordinator.interactionRuntime.navigationContext(selectionIndex: index,
                surface: self.currentSurface(), configuration: self.configuration)
        }
        input.onNavigationPanInvalidated = { [weak coordinator] in
            coordinator?.finishDiscretePan(delta: nil)
        }
        input.permits = { [weak self] recognizer in
            guard let self, let coordinator = self.coordinator, let collection = recognizer.view as? UICollectionView else { return false }
            if recognizer === self.input.navigationPan, let pan = recognizer as? UIPanGestureRecognizer {
                guard coordinator.parent.settings.pagedTurnStyle.usesDiscretePageTurns else { return false }
                return coordinator.canBeginPagePan(in: collection) && self.admitsNavigation(for: pan, in: collection)
            }
            return true
        }
        input.receives = { [weak self] recognizer, touch in
            guard let self, let collection = recognizer.view as? UICollectionView else { return false }
            guard recognizer === self.input.doubleTap else { return true }
            return self.configuration.allowsDoubleTap(at: touch.location(in: collection), in: collection.bounds)
        }
        input.onEvent = { [weak self] role, recognizer in
            guard let self, let collection = recognizer.view as? UICollectionView else { return }
            switch role {
            case .tap, .doubleTap:
                guard recognizer.state == .ended else { return }
                let point = recognizer.location(in: collection)
                guard let request: MangaNavigationRequest = role == .tap ?
                    self.configuration.tap(at: point, in: collection.bounds) :
                    .doubleTap(self.surfaceLocation(point, in: collection)) else { return }
                self.route(request)
            case .navigationPan:
                guard let pan = recognizer as? UIPanGestureRecognizer, let coordinator = self.coordinator else { return }
                switch pan.state {
                case .began:
                    coordinator.beginDiscretePan()
                case .ended:
                    let delta = ReaderPagedBoundaryPageTurn.horizontalDelta(
                        translation: pan.translation(in: collection), velocity: pan.velocity(in: collection),
                        viewportWidth: collection.bounds.width
                    ).map {
                        ReaderPagedBoundaryPageTurn.directionalDelta(
                            $0, direction: coordinator.parent.settings.pageTurnDirection.horizontalNavigationDirection
                        )
                    }
                    coordinator.finishDiscretePan(delta: delta)
                case .cancelled, .failed:
                    coordinator.finishDiscretePan(delta: nil)
                default: break
                }
            }
        }
    }

    func install(in collection: MangaPagedReaderCollectionView) {
        input.install(input.tap, in: collection)
        input.install(input.doubleTap, in: collection)
        input.install(input.navigationPan, in: collection)
        collection.shouldBeginPanGesture = { [weak self, weak collection] pan in
            guard let self, let collection, let coordinator = self.coordinator,
                  !coordinator.parent.settings.pagedTurnStyle.usesDiscretePageTurns,
                  coordinator.canBeginPagePan(in: collection),
                  self.admitsNavigation(for: pan, in: collection) else { return false }
            coordinator.admitNativePan()
            return true
        }
        collection.accessibilityPageTurn = { [weak self] direction in
            guard let self, let coordinator = self.coordinator, coordinator.acceptsNavigationInput else { return false }
            let step: NavigationStep
            switch direction {
            case .next: step = .forward
            case .previous: step = .backward
            case .left: step = self.configuration.direction.step(toward: .right)
            case .right: step = self.configuration.direction.step(toward: .left)
            default: return false
            }
            coordinator.navigate(step)
            return true
        }
    }

    func routeControl(_ step: NavigationStep) {
        route(.control(step))
    }

    private func admitsNavigation(for pan: UIPanGestureRecognizer, in collection: UICollectionView) -> Bool {
        guard let coordinator, pan.numberOfTouches <= 1 else { return false }
        let translation = pan.translation(in: collection)
        let velocity = pan.velocity(in: collection)
        let decision = coordinator.interactionRuntime.navigationDecision(
            .pan(translation: CGSize(width: translation.x, height: translation.y), velocity: CGSize(width: velocity.x, height: velocity.y)),
            surface: currentSurface(), configuration: configuration)
        if case .navigate = decision { return true }
        return false
    }

    private func route(_ request: MangaNavigationRequest) {
        guard let coordinator, coordinator.acceptsNavigationInput else { return }
        let decision = withAnimation(.easeOut(duration: 0.2)) {
            coordinator.interactionRuntime.handleNavigation(request, surface: currentSurface(), configuration: configuration)
        }
        switch decision {
        case let .navigate(edge):
            coordinator.navigate(configuration.direction.step(toward: edge))
        case .toggleChrome:
            coordinator.callbackScheduler.publish { [weak coordinator] in coordinator?.parent.onTap() }
        default: break
        }
    }

    private var configuration: MangaNavigationConfiguration {
        guard let parent = coordinator?.parent else {
            return MangaNavigationConfiguration(direction: .leftToRight, surface: MangaInteractionConfiguration(chromeVisible: true))
        }
        return MangaNavigationConfiguration(settings: parent.settings, chromeVisible: parent.isChromeVisible,
            zoomEnabled: parent.zoomEnabled, usesTwoPages: parent.plan.usesTwoPageSpread)
    }

    func currentSurface() -> MangaSurfaceRuntime? {
        guard let coordinator, let index = coordinator.currentSpreadIndex else { return nil }
        return coordinator.surface(forSpreadAt: index)
    }

    private func surfaceLocation(_ point: CGPoint, in collection: UICollectionView) -> CGPoint {
        guard let coordinator, let spreadIndex = coordinator.currentSpreadIndex else { return .zero }
        let indexPath = IndexPath(item: coordinator.viewportIndex(forSpreadIndex: spreadIndex), section: 0)
        guard let cell = collection.cellForItem(at: indexPath) else {
            return CGPoint(x: point.x - collection.bounds.minX, y: point.y - collection.bounds.minY)
        }
        return collection.convert(point, to: cell.contentView)
    }
}
#endif

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
                  let collection = self.input.navigationPan.view as? UICollectionView else { return nil }
            return coordinator.interactionRuntime.navigationContext(selectionIndex: coordinator.pagingInputs.selectionIndex,
                surface: self.currentSurface(in: collection), configuration: self.configuration)
        }
        input.permits = { [weak self] recognizer in
            guard let self, let coordinator = self.coordinator, let collection = recognizer.view as? UICollectionView else { return false }
            if recognizer === self.input.navigationPan, let pan = recognizer as? UIPanGestureRecognizer {
                guard coordinator.parent.settings.pagedTurnStyle.usesDiscretePageTurns else { return false }
                return self.navigationStep(for: pan, in: collection) != nil
            }
            return true
        }
        input.receives = { [weak self] recognizer, touch in
            guard let self, let collection = recognizer.view as? UICollectionView else { return false }
            return recognizer !== self.input.doubleTap ||
                PhysicalZone.at(touch.location(in: collection), in: collection.bounds) == .center
        }
        input.onEvent = { [weak self] role, recognizer in
            guard let self, let collection = recognizer.view as? UICollectionView else { return }
            switch role {
            case .tap, .doubleTap:
                guard recognizer.state == .ended else { return }
                let point = recognizer.location(in: collection)
                let zone = PhysicalZone.at(point, in: collection.bounds)
                let request: MangaNavigationRequest = role == .tap ? .tap(zone) :
                    .doubleTap(zone: zone, location: self.surfaceLocation(point, in: collection))
                self.route(request, in: collection)
            case .navigationPan:
                guard let pan = recognizer as? UIPanGestureRecognizer, let coordinator = self.coordinator else { return }
                coordinator.pagingDriver.handleDiscretePagePan(pan, inputs: coordinator.pagingInputs)
            }
        }
    }

    func install(in collection: MangaPagedReaderCollectionView) {
        input.install(input.tap, in: collection)
        input.install(input.doubleTap, in: collection)
        input.install(input.navigationPan, in: collection)
        collection.shouldBeginPanGesture = { [weak self, weak collection] pan in
            guard let self, let collection, let coordinator = self.coordinator,
                  !coordinator.parent.settings.pagedTurnStyle.usesDiscretePageTurns else { return false }
            return self.navigationStep(for: pan, in: collection) != nil
        }
    }

    func routeControl(_ step: NavigationStep, in collection: UICollectionView) {
        route(.control(step), in: collection)
    }

    private func navigationStep(for pan: UIPanGestureRecognizer, in collection: UICollectionView) -> NavigationStep? {
        guard let coordinator, !coordinator.parent.plan.spreads.isEmpty, pan.numberOfTouches <= 1 else { return nil }
        let translation = pan.translation(in: collection)
        let velocity = pan.velocity(in: collection)
        let decision = coordinator.interactionRuntime.navigationDecision(
            .pan(translation: CGSize(width: translation.x, height: translation.y), velocity: CGSize(width: velocity.x, height: velocity.y)),
            surface: currentSurface(in: collection), configuration: configuration)
        guard case let .navigate(edge) = decision else { return nil }
        return configuration.direction.step(toward: edge)
    }

    private func route(_ request: MangaNavigationRequest, in collection: UICollectionView) {
        guard let coordinator else { return }
        let decision = withAnimation(.easeOut(duration: 0.2)) {
            coordinator.interactionRuntime.handleNavigation(request, surface: currentSurface(in: collection), configuration: configuration)
        }
        switch decision {
        case let .navigate(edge):
            guard !coordinator.pagingDriver.isPerformingSlideTransition else { return }
            let step = configuration.direction.step(toward: edge)
            let inputs = coordinator.pagingInputs
            let target = inputs.selectionIndex + step.rawValue
            if target < 0 || target >= inputs.itemCount {
                guard inputs.itemCount > 0 else { return }
                let generation = coordinator.interactionRuntime.navigationGeneration
                coordinator.callbackScheduler.publish { [weak coordinator] in
                    guard coordinator?.interactionRuntime.navigationGeneration == generation else { return }
                    if inputs.canBoundaryPageTurn(step.rawValue) {
                        inputs.onBoundaryPageTurn(step.rawValue)
                    } else {
                        inputs.onBoundaryPageTurnRejected(step.rawValue)
                    }
                }
            } else {
                _ = coordinator.pagingDriver.animateAdjacentSelection(for: step.readerTapZone, in: collection, inputs: inputs)
            }
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

    private func currentSurface(in collection: UICollectionView) -> MangaSurfaceRuntime? {
        guard let coordinator, let index = coordinator.currentSpreadIndex(in: collection),
              let spread = coordinator.parent.plan.spread(at: index) else { return nil }
        return coordinator.parent.plan.usesTwoPageSpread
            ? coordinator.spreadSurfaceInteractions[spread.id]?.runtime
            : coordinator.pageSurfaceInteractions[spread.preferredPage.id]?.runtime
    }

    private func surfaceLocation(_ point: CGPoint, in collection: UICollectionView) -> CGPoint {
        guard let coordinator, let spreadIndex = coordinator.currentSpreadIndex(in: collection) else { return .zero }
        let indexPath = IndexPath(item: coordinator.viewportIndex(forSpreadIndex: spreadIndex), section: 0)
        guard let cell = collection.cellForItem(at: indexPath) else {
            return CGPoint(x: point.x - collection.bounds.minX, y: point.y - collection.bounds.minY)
        }
        return collection.convert(point, to: cell.contentView)
    }
}
#endif

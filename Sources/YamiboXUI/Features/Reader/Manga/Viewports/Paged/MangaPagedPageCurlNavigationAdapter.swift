import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedPageCurlNavigationAdapter {
    private weak var coordinator: MangaPagedPageCurlCoordinator?
    private var nativePanAdmissions: [ObjectIdentifier: MangaNativePanAdmission] = [:]
    let input: MangaNavigationInput
    var spreadPanGesture: UIPanGestureRecognizer { input.surfacePan }
    var spreadPinchGesture: UIPinchGestureRecognizer { input.surfacePinch }

    init(coordinator: MangaPagedPageCurlCoordinator, input: MangaNavigationInput = MangaNavigationInput()) {
        self.coordinator = coordinator
        self.input = input
        input.navigationContext = { [weak self] in
            guard let self, let coordinator = self.coordinator else { return nil }
            return coordinator.interactionRuntime.navigationContext(selectionIndex: coordinator.parent.selectionIndex,
                surface: self.currentSurface, configuration: self.configuration)
        }
        input.permits = { [weak self] recognizer in self?.permits(recognizer) ?? false }
        input.receives = { [weak self] recognizer, touch in
            guard let self, let container = self.coordinator?.activeContainerViewController else { return false }
            return recognizer !== self.input.doubleTap ||
                PhysicalZone.at(touch.location(in: container.view), in: container.view.bounds) == .center
        }
        input.onEvent = { [weak self] role, recognizer in
            guard let self, let coordinator = self.coordinator,
                  let container = coordinator.activeContainerViewController else { return }
            switch role {
            case .tap, .doubleTap:
                guard recognizer.state == .ended else { return }
                let point = recognizer.location(in: container.view)
                let zone = PhysicalZone.at(point, in: container.view.bounds)
                let request: MangaNavigationRequest = role == .tap ? .tap(zone) :
                    .doubleTap(zone: zone, location: self.surfaceLocation(point, in: container))
                self.route(request, in: container, allowsBoundary: false)
            case .navigationPan:
                if let pan = recognizer as? UIPanGestureRecognizer { self.finishBoundaryPan(pan) }
            case .surfacePan:
                if let pan = recognizer as? UIPanGestureRecognizer { coordinator.zoom.handleSpreadPan(pan) }
            case .surfacePinch:
                if let pinch = recognizer as? UIPinchGestureRecognizer { coordinator.zoom.handleSpreadPinch(pinch) }
            }
        }
    }

    func configureContainerGestures(in container: MangaPagedPageCurlContainerViewController) {
        coordinator?.activeContainerViewController = container
        for recognizer in [input.tap, input.doubleTap, input.surfacePan, input.surfacePinch] {
            input.install(recognizer, in: container.view)
        }
        coordinator?.zoom.updateInputAvailability()
    }

    func configureGestures(in pageController: UIPageViewController) {
        guard let coordinator else { return }
        coordinator.activePageViewController = pageController
        input.install(input.navigationPan, in: pageController.view)
        let current = Set(pageController.gestureRecognizers.compactMap { ($0 as? UIPanGestureRecognizer).map(ObjectIdentifier.init) })
        for id in Array(nativePanAdmissions.keys) where !current.contains(id) {
            nativePanAdmissions.removeValue(forKey: id)?.detach()
        }
        for recognizer in pageController.gestureRecognizers {
            if recognizer is UITapGestureRecognizer {
                recognizer.isEnabled = false
            } else if let pan = recognizer as? UIPanGestureRecognizer {
                let id = ObjectIdentifier(pan)
                if nativePanAdmissions[id] == nil {
                    nativePanAdmissions[id] = MangaNativePanAdmission(pan) { [weak self] in self?.permits($0) ?? false }
                }
                pan.isEnabled = !coordinator.parent.isChromeVisible
            }
        }
    }

    func detach() {
        nativePanAdmissions.values.forEach { $0.detach() }
        nativePanAdmissions.removeAll()
        input.detach()
    }

    func routeControl(_ step: NavigationStep, in container: MangaPagedPageCurlContainerViewController) {
        route(.control(step), in: container, allowsBoundary: true)
    }

    private func permits(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let coordinator, let container = coordinator.activeContainerViewController else { return false }
        if recognizer === input.surfacePinch { return coordinator.zoom.runtime.canPinch }
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let translation = pan.translation(in: container.view)
        let velocity = pan.velocity(in: container.view)
        let decision = coordinator.interactionRuntime.navigationDecision(
            .pan(translation: CGSize(width: translation.x, height: translation.y), velocity: CGSize(width: velocity.x, height: velocity.y)),
            surface: currentSurface, configuration: configuration)
        if recognizer === input.surfacePan {
            return coordinator.parent.sequence.usesTwoPageSpread && decision == .panImage
        }
        guard case let .navigate(edge) = decision else { return false }
        let step = configuration.direction.step(toward: edge)
        if recognizer === input.navigationPan {
            let target = coordinator.parent.selectionIndex + step.rawValue
            return (target < 0 || target >= coordinator.parent.sequence.pageCount) && coordinator.parent.canBoundaryPageTurn(step.rawValue)
        }
        guard let pageController = coordinator.activePageViewController,
              pageController.gestureRecognizers.contains(where: { $0 === recognizer }) else { return false }
        let indexes = (pageController.viewControllers ?? []).compactMap { ($0 as? MangaPagedPageCurlHostingController)?.leaf }
            .compactMap(coordinator.parent.sequence.leafIndex(matching:))
        // Leaf ordering is physical; reading-order conversion has already happened in Core.
        if edge == .left, let first = indexes.min() { return coordinator.parent.sequence.leafIndex(before: first) != nil }
        if edge == .right, let last = indexes.max() { return coordinator.parent.sequence.leafIndex(after: last) != nil }
        return false
    }

    private func finishBoundaryPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended, let coordinator, let view = recognizer.view else { return }
        let parent = coordinator.parent
        // Admission was decided at began. Completion retains the native distance/velocity thresholds.
        guard let delta = ReaderPagedBoundaryPageTurn.boundaryDelta(selectionIndex: parent.selectionIndex,
            itemCount: parent.sequence.pageCount, translation: recognizer.translation(in: view), velocity: recognizer.velocity(in: view),
            viewportWidth: view.bounds.width, horizontalNavigationDirection: parent.settings.pageTurnDirection.horizontalNavigationDirection,
            canBoundaryPageTurn: parent.canBoundaryPageTurn) else { return }
        publishBoundary(delta)
    }

    private func route(_ request: MangaNavigationRequest, in container: MangaPagedPageCurlContainerViewController, allowsBoundary: Bool) {
        guard let coordinator else { return }
        let decision = withAnimation(.easeOut(duration: 0.2)) {
            coordinator.interactionRuntime.handleNavigation(request, surface: currentSurface, configuration: configuration)
        }
        switch decision {
        case let .navigate(edge):
            let step = configuration.direction.step(toward: edge)
            let target = coordinator.parent.selectionIndex + step.rawValue
            if target < 0 || target >= coordinator.parent.sequence.pageCount {
                if allowsBoundary && coordinator.parent.canBoundaryPageTurn(step.rawValue) { publishBoundary(step.rawValue) }
            } else {
                coordinator.animateAdjacentSelection(delta: step.rawValue, in: container.pageViewController)
            }
        case .toggleChrome:
            coordinator.callbackScheduler.publish { [weak coordinator] in coordinator?.parent.onTap() }
        case .reveal, .zoom:
            if coordinator.parent.sequence.usesTwoPageSpread { coordinator.zoom.render(animated: true) }
        default: break
        }
    }

    private func publishBoundary(_ delta: Int) {
        guard let coordinator else { return }
        let generation = coordinator.interactionRuntime.navigationGeneration
        coordinator.callbackScheduler.publish { [weak coordinator] in
            guard let coordinator, coordinator.interactionRuntime.navigationGeneration == generation else { return }
            coordinator.parent.onBoundaryPageTurn(delta)
        }
    }

    private var configuration: MangaNavigationConfiguration {
        guard let parent = coordinator?.parent else {
            return MangaNavigationConfiguration(direction: .leftToRight, surface: MangaInteractionConfiguration(chromeVisible: true))
        }
        return MangaNavigationConfiguration(settings: parent.settings, chromeVisible: parent.isChromeVisible,
            zoomEnabled: parent.zoomEnabled, usesTwoPages: parent.sequence.usesTwoPageSpread)
    }

    private var currentSurface: MangaSurfaceRuntime? {
        guard let coordinator else { return nil }
        if coordinator.parent.sequence.usesTwoPageSpread { return coordinator.zoom.runtime }
        guard let pageID = currentPageController?.leaf.pageID else { return nil }
        return coordinator.pageSurfaceInteractions[pageID]?.runtime
    }

    private var currentPageController: MangaPagedPageCurlHostingController? {
        (coordinator?.activePageViewController?.viewControllers ?? []).compactMap { $0 as? MangaPagedPageCurlHostingController }
            .min { $0.leaf.index < $1.leaf.index }
    }

    private func surfaceLocation(_ point: CGPoint, in container: MangaPagedPageCurlContainerViewController) -> CGPoint {
        guard coordinator?.parent.sequence.usesTwoPageSpread == false, let target = currentPageController else { return point }
        return container.view.convert(point, to: target.view)
    }
}
#endif

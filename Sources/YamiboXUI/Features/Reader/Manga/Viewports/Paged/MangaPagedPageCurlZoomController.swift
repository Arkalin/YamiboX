import SwiftUI
import YamiboXCore
import Observation

#if os(iOS)
import UIKit

/// Backend adapter: UIKit spread transforms use the same transaction as SwiftUI spreads.
@MainActor
final class MangaPagedPageCurlZoomController {
    private unowned let coordinator: MangaPagedPageCurlCoordinator
    private let runtime: MangaSurfaceRuntime
    private let registry = MangaSurfaceGestureRegistry()
    private lazy var panInput = MangaSurfaceGestureInput(runtime: runtime, registry: registry, role: .pan)
    private lazy var pinchInput = MangaSurfaceGestureInput(runtime: runtime, registry: registry, role: .pinch)
    private var observationRevision: UInt64 = 0

    init(coordinator: MangaPagedPageCurlCoordinator) {
        self.coordinator = coordinator
        runtime = coordinator.interactionRuntime.surface(SurfaceID(value: "curl-spread"))
    }

    func handleSpreadPinch(_ recognizer: UIPinchGestureRecognizer) {
        pinchInput.handle(recognizer, localTranslation: nil)
        render(animated: false)
    }

    func control(_ edge: MangaPagedImageSurfaceHorizontalEdge) -> MangaInteractionDecision {
        let decision = runtime.perform(.control(edge))
        render(animated: true)
        return decision
    }

    func handleSpreadPan(_ recognizer: UIPanGestureRecognizer) {
        panInput.handle(recognizer, localTranslation: recognizer.translation(in: coordinator.activeContainerViewController?.view))
        render(animated: false)
    }

    func pageCurlContainerDidLayout(_ container: MangaPagedPageCurlContainerViewController) {
        updatePageCurlSpreadZoomAvailability(in: container, animated: false)
    }

    func updatePageCurlSpreadZoomAvailability(in container: MangaPagedPageCurlContainerViewController, animated: Bool) {
        let parent = coordinator.parent
        let generation = runtime.generation
        runtime.configure(MangaInteractionConfiguration(chromeVisible: parent.isChromeVisible,
            zoomEnabled: parent.zoomEnabled && parent.sequence.usesTwoPageSpread, allowsUnzoomedPan: false),
            geometry: .spread(viewport: container.view.bounds.size), imageLoaded: parent.sequence.usesTwoPageSpread &&
                coordinator.pageSurfaceInteractions.values.contains { $0.runtime.imageLoaded })
        if generation != runtime.generation {
            let gestures = coordinator.gestures
            for recognizer in [gestures.spreadPanGesture, gestures.spreadPinchGesture] as [UIGestureRecognizer] {
                recognizer.isEnabled = false
            }
        }
        render(animated: animated)
        observationRevision &+= 1
        let revision = observationRevision
        withObservationTracking {
            for surface in coordinator.pageSurfaceInteractions.values { _ = surface.runtime.imageLoaded }
        } onChange: { [weak self, weak container] in
            Task { @MainActor in
                guard let self, let container, self.observationRevision == revision else { return }
                self.updatePageCurlSpreadZoomAvailability(in: container, animated: false)
            }
        }
    }

    func consumePageCurlSpreadEdgeTap(for zone: ReaderPagedTapZone, in container: MangaPagedPageCurlContainerViewController) -> Bool {
        guard coordinator.parent.sequence.usesTwoPageSpread,
              let edge = MangaPagedSurfaceEdgeInteraction.physicalEdge(forTapZone: zone),
              runtime.decision(.edge(edge)) == .reveal(edge) else { return false }
        runtime.perform(.edge(edge))
        render(animated: true)
        return true
    }

    func shouldDeferPageCurlPanToSpreadContent(_ recognizer: UIPanGestureRecognizer,
        in container: MangaPagedPageCurlContainerViewController) -> Bool {
        guard coordinator.parent.sequence.usesTwoPageSpread else { return false }
        let translation = recognizer.translation(in: container.view)
        let velocity = recognizer.velocity(in: container.view)
        return runtime.decision(.pan(translation: CGSize(width: translation.x, height: translation.y),
            velocity: CGSize(width: velocity.x, height: velocity.y))) == .panImage
    }

    func togglePageCurlSpreadZoom(at location: CGPoint, in container: MangaPagedPageCurlContainerViewController) {
        runtime.perform(.doubleTap(location))
        render(animated: true)
    }

    func resetPageCurlSpreadZoom(in container: MangaPagedPageCurlContainerViewController, animated: Bool) {
        runtime.invalidate(reset: true)
        render(animated: animated)
    }

    func isPageCurlSpreadZoomInteractionEnabled(in container: MangaPagedPageCurlContainerViewController) -> Bool {
        coordinator.parent.sequence.usesTwoPageSpread && coordinator.parent.zoomEnabled &&
            !coordinator.parent.isChromeVisible && container.view.bounds.width > 0 && container.view.bounds.height > 0 &&
            coordinator.pageSurfaceInteractions.values.contains { $0.runtime.imageLoaded }
    }

    func isPageCurlSpreadPanEnabled(in container: MangaPagedPageCurlContainerViewController) -> Bool {
        isPageCurlSpreadZoomInteractionEnabled(in: container) && (runtime.isZoomActive || runtime.isManipulating)
    }

    private func render(animated: Bool) {
        guard let container = coordinator.activeContainerViewController else { return }
        let transform = runtime.transform
        let updates = {
            container.pageViewController.view.transform = CGAffineTransform(
                translationX: transform.offset.width, y: transform.offset.height)
                .scaledBy(x: transform.scale, y: transform.scale)
        }
        if animated { UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: updates) }
        else { updates() }
        coordinator.gestures.updatePageCurlContainerGestureState(in: container)
    }
}
#endif

import Observation

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedPageCurlZoomController {
    private unowned let coordinator: MangaPagedPageCurlCoordinator
    let runtime: MangaSurfaceRuntime
    private var observationRevision: UInt64 = 0

    init(coordinator: MangaPagedPageCurlCoordinator) {
        self.coordinator = coordinator
        runtime = coordinator.interactionRuntime.surface(SurfaceID(value: "curl-spread"))
        runtime.permitsInteraction = { [weak coordinator] in coordinator?.isPageTurnInProgress == false }
    }

    func pageCurlContainerDidLayout(_ container: MangaPagedPageCurlContainerViewController) {
        updatePageCurlSpreadZoomAvailability(in: container)
    }

    func updatePageCurlSpreadZoomAvailability(in container: MangaPagedPageCurlContainerViewController) {
        let parent = coordinator.parent
        let spread = parent.plan.spread(at: coordinator.selectionIndex)
        let spreadPageIDs = [spread?.leftPage?.id, spread?.rightPage?.id].compactMap { $0 }
        container.zoomView.restoreFocus = {
            if let id = spread?.leftPage?.id, let focus = parent.handoff?.takeFocus(for: id, horizontalHalf: 0) { return focus }
            if let id = spread?.rightPage?.id { return parent.handoff?.takeFocus(for: id, horizontalHalf: 1) }
            return nil
        }
        container.zoomView.configure(runtime: runtime,
            configuration: MangaInteractionConfiguration(chromeVisible: parent.isChromeVisible,
                zoomEnabled: parent.zoomEnabled && parent.sequence.usesTwoPageSpread, allowsUnzoomedPan: false),
            geometry: .spread(viewport: container.view.bounds.size),
            imageLoaded: parent.sequence.usesTwoPageSpread && spreadPageIDs.contains {
                coordinator.pageSurfaceInteractions[$0]?.runtime.imageLoaded == true
            })
        observationRevision &+= 1
        let revision = observationRevision
        withObservationTracking {
            for surface in coordinator.pageSurfaceInteractions.values { _ = surface.runtime.imageLoaded }
        } onChange: { [weak self, weak container] in
            Task { @MainActor in
                guard let self, let container, self.observationRevision == revision else { return }
                self.updatePageCurlSpreadZoomAvailability(in: container)
            }
        }
    }

    func reset() {
        runtime.invalidate(reset: true)
    }

    func detach(from container: MangaPagedPageCurlContainerViewController) {
        observationRevision &+= 1
        container.onLayoutSubviews = nil
        container.zoomView.detach()
    }
}
#endif

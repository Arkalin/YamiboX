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
        container.zoomView.configure(runtime: runtime,
            configuration: MangaInteractionConfiguration(chromeVisible: parent.isChromeVisible,
                zoomEnabled: parent.zoomEnabled && parent.sequence.usesTwoPageSpread, allowsUnzoomedPan: false),
            geometry: .spread(viewport: container.view.bounds.size),
            imageLoaded: parent.sequence.usesTwoPageSpread && coordinator.pageSurfaceInteractions.values.contains { $0.runtime.imageLoaded })
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

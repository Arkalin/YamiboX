import Foundation

@MainActor
final class MangaPagedZoomSession {
    private weak var current: MangaSurfaceRuntime?
    private(set) var factor = MangaPageZoomPolicy.minimumScale

    func activate(_ surface: MangaSurfaceRuntime) {
        current = surface
    }

    func deactivate(_ surface: MangaSurfaceRuntime) {
        if current === surface { current = nil }
    }

    func owns(_ surface: MangaSurfaceRuntime) -> Bool {
        current === surface
    }

    func record(_ factor: CGFloat, from surface: MangaSurfaceRuntime) {
        guard owns(surface), factor.isFinite else { return }
        self.factor = MangaPageZoomPolicy.clampedScale(factor)
    }

    func resetFactor() {
        factor = MangaPageZoomPolicy.minimumScale
    }
}

@MainActor
final class MangaPagedInteractionRuntime {
    func navigationContext(
        selectionIndex: Int,
        surface: MangaSurfaceRuntime?,
        configuration: MangaNavigationConfiguration
    ) -> MangaNavigationSession.Context {
        MangaNavigationSession.Context(viewportGeneration: navigationGeneration,
            selectionIndex: selectionIndex, configuration: configuration,
            surfaceIdentity: surface.map(ObjectIdentifier.init), surfaceGeneration: surface?.generation)
    }

    func navigationDecision(
        _ request: MangaNavigationRequest,
        surface: MangaSurfaceRuntime?,
        configuration: MangaNavigationConfiguration
    ) -> MangaInteractionDecision {
        guard let intent = request.intent(direction: configuration.direction) else { return .ignore }
        let decision = MangaInteractionPolicy.decide(intent, configuration: configuration.surface,
            scale: surface?.transform.scale ?? 1, hiddenEdges: surface?.hiddenEdges ?? [],
            menuFrame: surface?.menuFrame ?? .zero, imageLoaded: surface?.imageLoaded ?? false)
        // Swap only page-turn taps, not image-edge reveals, pans, or peripheral controls.
        if configuration.swapsPageTurnTapZones, case .tap = request, case let .navigate(edge) = decision {
            return .navigate(edge == .left ? .right : .left)
        }
        return decision
    }

    @discardableResult
    func handleNavigation(
        _ request: MangaNavigationRequest,
        surface: MangaSurfaceRuntime?,
        configuration: MangaNavigationConfiguration
    ) -> MangaInteractionDecision {
        let decision = navigationDecision(request, surface: surface, configuration: configuration)
        surface?.apply(decision)
        return decision
    }

    private var surfaces: [SurfaceID: MangaSurfaceRuntime] = [:]
    private var active: (surfaceID: SurfaceID, selectionID: String)?
    private(set) var navigationGeneration: UInt64 = 0
    private let zoomSession: MangaPagedZoomSession
    private let shouldAnimateZoom: () -> Bool

    init(zoomSession: MangaPagedZoomSession, shouldAnimateZoom: @escaping () -> Bool) {
        self.zoomSession = zoomSession
        self.shouldAnimateZoom = shouldAnimateZoom
    }

    func surface(_ id: SurfaceID) -> MangaSurfaceRuntime {
        if let existing = surfaces[id] { return existing }
        let surface = MangaSurfaceRuntime(shouldAnimateZoom: shouldAnimateZoom)
        surfaces[id] = surface
        return surface
    }

    func prepare(_ id: SurfaceID, alignment: MangaPagedImageSurfaceInitialHorizontalAlignment) {
        guard active?.surfaceID != id else { return }
        surface(id).preparePageEntry(factor: zoomSession.factor, alignment: alignment)
    }

    func activate(_ id: SurfaceID, selectionID: String, alignment: MangaPagedImageSurfaceInitialHorizontalAlignment,
                  applyImmediately: Bool = true) {
        guard active?.surfaceID != id || active?.selectionID != selectionID else { return }
        navigationGeneration &+= 1
        deactivate()
        active = (id, selectionID)
        let runtime = surface(id)
        runtime.zoomSession = zoomSession
        zoomSession.activate(runtime)
        runtime.preparePageEntry(factor: zoomSession.factor, alignment: alignment, applyImmediately: applyImmediately)
    }

    private func deactivate() {
        guard let active, let surface = surfaces[active.surfaceID] else { return }
        zoomSession.deactivate(surface)
        surface.endPageEntry()
        self.active = nil
    }

    func reset(keeping ids: Set<SurfaceID> = []) {
        navigationGeneration &+= 1
        deactivate()
        for surface in surfaces.values { surface.invalidate(reset: true) }
        surfaces = surfaces.filter { ids.contains($0.key) }
    }
}

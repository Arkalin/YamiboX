import Foundation

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
        return MangaInteractionPolicy.decide(intent, configuration: configuration.surface,
            scale: surface?.transform.scale ?? 1, hiddenEdges: surface?.hiddenEdges ?? [],
            menuFrame: surface?.menuFrame ?? .zero, imageLoaded: surface?.imageLoaded ?? false)
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
    private(set) var activeSurface: SurfaceID?
    private(set) var navigationGeneration: UInt64 = 0

    func surface(_ id: SurfaceID) -> MangaSurfaceRuntime {
        if let existing = surfaces[id] { return existing }
        let surface = MangaSurfaceRuntime()
        surfaces[id] = surface
        return surface
    }

    func activate(_ id: SurfaceID) {
        guard activeSurface != id else { return }
        navigationGeneration &+= 1
        if let activeSurface { surfaces[activeSurface]?.invalidate(reset: true) }
        activeSurface = id
    }

    func reset(keeping ids: Set<SurfaceID> = []) {
        navigationGeneration &+= 1
        for surface in surfaces.values { surface.invalidate(reset: true) }
        surfaces = surfaces.filter { ids.contains($0.key) }
        activeSurface = nil
    }
}

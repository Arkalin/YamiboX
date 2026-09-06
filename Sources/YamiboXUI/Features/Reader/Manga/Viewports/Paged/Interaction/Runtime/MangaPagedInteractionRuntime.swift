import Foundation

@MainActor
final class MangaPagedInteractionRuntime {
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

import Foundation

@MainActor
final class MangaPagedInteractionRuntime {
    private var surfaces: [SurfaceID: MangaSurfaceRuntime] = [:]
    private(set) var activeSurface: SurfaceID?

    func surface(_ id: SurfaceID) -> MangaSurfaceRuntime {
        if let existing = surfaces[id] { return existing }
        let surface = MangaSurfaceRuntime()
        surfaces[id] = surface
        return surface
    }

    func activate(_ id: SurfaceID) {
        guard activeSurface != id else { return }
        if let activeSurface { surfaces[activeSurface]?.invalidate(reset: true) }
        activeSurface = id
    }

    func reset() {
        for surface in surfaces.values { surface.invalidate(reset: true) }
        surfaces.removeAll()
        activeSurface = nil
    }
}

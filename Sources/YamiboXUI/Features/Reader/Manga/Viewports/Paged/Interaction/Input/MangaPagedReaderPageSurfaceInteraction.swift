import SwiftUI

#if os(iOS)
@MainActor
final class MangaPagedReaderPageSurfaceInteraction {
    let runtime: MangaSurfaceRuntime
    let gestures = MangaSurfaceGestureRegistry()

    init(runtime: MangaSurfaceRuntime = MangaSurfaceRuntime()) { self.runtime = runtime }

    var hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge> { runtime.hiddenEdges }
    var isZoomActive: Bool { runtime.isZoomActive }

    func hasHiddenContent(onPhysicalEdge edge: MangaPagedImageSurfaceHorizontalEdge) -> Bool {
        runtime.hiddenEdges.contains(edge)
    }

    func consumeTap(onPhysicalEdge edge: MangaPagedImageSurfaceHorizontalEdge) -> Bool {
        guard runtime.decision(.edge(edge)) == .reveal(edge) else { return false }
        withAnimation(.easeOut(duration: 0.2)) { runtime.perform(.edge(edge)) }
        gestures.cancel()
        return true
    }

    func requestZoomToggle(at location: CGPoint) {
        withAnimation(.easeOut(duration: 0.2)) { runtime.perform(.doubleTap(location)) }
        gestures.cancel()
    }
}
#endif

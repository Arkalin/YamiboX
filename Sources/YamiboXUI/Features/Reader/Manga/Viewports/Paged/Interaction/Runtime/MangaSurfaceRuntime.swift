import Foundation
import Observation

@MainActor @Observable
final class MangaSurfaceRuntime {
    private(set) var transform = MangaSurfaceTransform()
    private(set) var configuration = MangaInteractionConfiguration()
    private(set) var geometry: MangaSurfaceGeometry = .spread(viewport: .zero)
    private(set) var generation: UInt64 = 0
    private(set) var imageLoaded = false
    private(set) var menuFrame: CGRect = .zero
    private var committed = MangaSurfaceTransform()
    private var session: MangaInteractionSession?
    private var mountingInstance: UUID?

    func mount(_ instance: UUID) {
        guard mountingInstance != instance else { return }
        invalidate(reset: true)
        mountingInstance = instance
    }

    func unmount(_ instance: UUID) {
        guard mountingInstance == instance else { return }
        invalidate()
        imageLoaded = false
    }

    func isMounted(_ instance: UUID) -> Bool { mountingInstance == instance }

    var hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge> { geometry.hiddenEdges(transform) }
    var isZoomActive: Bool { MangaPageZoomPolicy.isActive(transform.scale) }
    var isManipulating: Bool { session != nil }

    func decision(_ intent: MangaInteractionIntent) -> MangaInteractionDecision {
        MangaInteractionPolicy.decide(intent, configuration: configuration, scale: transform.scale,
            hiddenEdges: hiddenEdges, menuFrame: menuFrame, imageLoaded: imageLoaded)
    }

    func configure(_ configuration: MangaInteractionConfiguration, geometry: MangaSurfaceGeometry, imageLoaded: Bool) {
        guard self.configuration != configuration || self.geometry != geometry || self.imageLoaded != imageLoaded else { return }
        invalidate()
        let geometryChanged = self.geometry != geometry
        let onlyResized = self.geometry.replacingViewport(geometry.viewport) == geometry
        if geometryChanged && !onlyResized {
            committed = MangaSurfaceTransform()
        } else if (!configuration.zoomEnabled || configuration.chromeVisible) && MangaPageZoomPolicy.isActive(committed.scale) {
            committed = MangaSurfaceTransform()
        }
        self.configuration = configuration
        self.geometry = geometry
        self.imageLoaded = imageLoaded
        committed = geometry.clamp(committed)
        transform = committed
    }

    func setMenuFrame(_ frame: CGRect) { menuFrame = frame }

    @discardableResult
    func begin(_ input: MangaContinuousInput) -> UInt64? {
        guard imageLoaded, !configuration.chromeVisible else { return nil }
        if input == .pinch && !configuration.zoomEnabled { return nil }
        if session == nil {
            generation &+= 1
            session = MangaInteractionSession(generation: generation, snapshot: committed)
        }
        guard session?.begin(input) == true else { return nil }
        return generation
    }

    func changePan(_ translation: CGSize, token: UInt64) {
        guard session?.generation == token else { return }
        session?.pan(translation)
        refresh()
    }

    func changePinch(_ scale: CGFloat, token: UInt64) {
        guard session?.generation == token else { return }
        session?.pinch(scale)
        refresh()
    }

    func end(_ input: MangaContinuousInput, token: UInt64, cancelled: Bool) {
        guard session?.generation == token, session?.members.contains(input) == true else { return }
        if cancelled { invalidate(); return }
        session?.end(input)
        if session?.members.isEmpty == true {
            committed = session?.joined.contains(.pinch) == true && !MangaPageZoomPolicy.isActive(transform.scale)
                ? MangaSurfaceTransform() : transform
            transform = committed
            session = nil
        }
    }

    func invalidate(reset: Bool = false) {
        generation &+= 1
        session = nil
        if reset { committed = MangaSurfaceTransform() }
        transform = committed
    }

    @discardableResult
    func perform(_ intent: MangaInteractionIntent) -> MangaInteractionDecision {
        let result = decision(intent)
        switch result {
        case let .reveal(edge):
            invalidate()
            if let offset = geometry.reveal(edge, transform: committed) { committed.offset = offset }
            transform = committed
        case let .zoom(point):
            invalidate()
            committed = MangaPageZoomPolicy.isZoomedForDoubleTapReset(committed.scale)
                ? MangaSurfaceTransform() : geometry.zoomed(at: point)
            transform = committed
        default: break
        }
        return result
    }

    private func refresh() {
        guard let session else { return }
        transform = geometry.clamp(session.proposed)
    }
}

private extension MangaSurfaceGeometry {
    func replacingViewport(_ viewport: CGSize) -> Self {
        switch self {
        case let .image(size, _, fit, alignment): .image(size: size, viewport: viewport, fit: fit, alignment: alignment)
        case .spread: .spread(viewport: viewport)
        }
    }
}

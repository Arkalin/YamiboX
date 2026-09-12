import Foundation
import Observation

@MainActor
protocol MangaNativeSurfaceControlling: AnyObject {
    func applyNative(_ decision: MangaInteractionDecision, animated: Bool)
    func cancelNative(reset: Bool)
}

@MainActor @Observable
final class MangaSurfaceRuntime {
    // Paging queries these snapshots; SwiftUI does not render native motion.
    @ObservationIgnored private(set) var transform = MangaSurfaceTransform()
    @ObservationIgnored private(set) var configuration = MangaInteractionConfiguration()
    @ObservationIgnored private(set) var geometry: MangaSurfaceGeometry = .spread(viewport: .zero)
    @ObservationIgnored private(set) var generation: UInt64 = 0
    private(set) var imageLoaded = false
    @ObservationIgnored private(set) var menuFrame: CGRect = .zero
    @ObservationIgnored private var mountingInstance: UUID?
    @ObservationIgnored private weak var nativeSurface: (any MangaNativeSurfaceControlling)?
    @ObservationIgnored private(set) var nativeIsInteracting = false
    @ObservationIgnored var permitsInteraction: () -> Bool = { true }

    func mount(_ instance: UUID) {
        guard mountingInstance != instance else { return }
        invalidate(reset: true)
        mountingInstance = instance
    }

    func unmount(_ instance: UUID) {
        guard mountingInstance == instance else { return }
        invalidate()
        imageLoaded = false
        mountingInstance = nil
        nativeSurface = nil
    }

    func attachNative(_ surface: any MangaNativeSurfaceControlling, instance: UUID) {
        mount(instance)
        nativeSurface = surface
    }

    func receiveNative(_ transform: MangaSurfaceTransform, interacting: Bool, instance: UUID) {
        guard isMounted(instance) else { return }
        if interacting && !nativeIsInteracting { generation &+= 1 }
        nativeIsInteracting = interacting
        self.transform = transform
    }

    func isMounted(_ instance: UUID) -> Bool { mountingInstance == instance }

    var hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge> { geometry.hiddenEdges(transform) }
    var isManipulating: Bool { nativeIsInteracting }
    var canPinch: Bool { availableInputs.contains(.pinch) }
    var canPan: Bool { availableInputs.contains(.pan) }

    private var availableInputs: Set<MangaContinuousInput> {
        MangaInteractionPolicy.availableInputs(configuration: configuration, scale: transform.scale, hiddenEdges: hiddenEdges,
            imageLoaded: imageLoaded && geometry.viewport.width > 0 && geometry.viewport.height > 0, isManipulating: isManipulating)
    }

    func decision(_ intent: MangaInteractionIntent) -> MangaInteractionDecision {
        MangaInteractionPolicy.decide(intent, configuration: configuration, scale: transform.scale,
            hiddenEdges: hiddenEdges, menuFrame: menuFrame, imageLoaded: imageLoaded)
    }

    func configure(_ configuration: MangaInteractionConfiguration, geometry: MangaSurfaceGeometry, imageLoaded: Bool) {
        guard self.configuration != configuration || self.geometry != geometry || self.imageLoaded != imageLoaded else { return }
        let chromeOnly = self.geometry == geometry && self.imageLoaded == imageLoaded
            && self.configuration.zoomEnabled == configuration.zoomEnabled
            && self.configuration.allowsUnzoomedPan == configuration.allowsUnzoomedPan
        if chromeOnly {
            self.configuration = configuration
            return
        }
        let disablesZoom = self.configuration.zoomEnabled && !configuration.zoomEnabled
        self.configuration = configuration
        self.geometry = geometry
        self.imageLoaded = imageLoaded
        if disablesZoom { invalidate(reset: true) }
    }

    func setMenuFrame(_ frame: CGRect) { menuFrame = frame }

    func setChromeVisible(_ visible: Bool) { configuration.chromeVisible = visible }

    func invalidate(reset: Bool = false) {
        generation &+= 1
        nativeIsInteracting = false
        if let nativeSurface {
            nativeSurface.cancelNative(reset: reset)
            return
        }
        if reset { transform = MangaSurfaceTransform() }
    }

    @discardableResult
    func perform(_ intent: MangaInteractionIntent, animated: Bool = true) -> MangaInteractionDecision {
        let result = decision(intent)
        apply(result, animated: animated)
        return result
    }

    func apply(_ result: MangaInteractionDecision, animated: Bool = true) {
        nativeSurface?.applyNative(result, animated: animated)
    }
}

import Foundation
import Testing
@testable import YamiboXUI

@MainActor @Suite("Paged navigation policy")
struct MangaNavigationPolicyTests {
    @Test(arguments: [false, true], [false, true])
    func availabilityUsesSurfaceCapabilities(zoomEnabled: Bool, allowsUnzoomedPan: Bool) {
        let surface = MangaSurfaceRuntime()
        var configuration = MangaInteractionConfiguration(zoomEnabled: zoomEnabled, allowsUnzoomedPan: allowsUnzoomedPan)
        let geometry = MangaSurfaceGeometry.image(size: CGSize(width: 800, height: 800),
            viewport: CGSize(width: 400, height: 800), fit: .fitHeight, alignment: .left)
        surface.configure(configuration, geometry: geometry, imageLoaded: true)
        #expect(surface.canPan == allowsUnzoomedPan)
        #expect(surface.canPinch == zoomEnabled)
        configuration.chromeVisible = true
        surface.configure(configuration, geometry: geometry, imageLoaded: true)
        #expect(!surface.canPan)
        #expect(!surface.canPinch)
        configuration.chromeVisible = false
        surface.configure(configuration, geometry: geometry, imageLoaded: false)
        #expect(!surface.canPan)
        #expect(!surface.canPinch)
    }

    @Test func zoomedVerticalPanStillBelongsToImage() {
        let runtime = MangaPagedInteractionRuntime()
        let surface = runtime.surface(SurfaceID(value: "spread"))
        let configuration = MangaNavigationConfiguration(direction: .leftToRight,
            surface: MangaInteractionConfiguration(allowsUnzoomedPan: false))
        surface.configure(configuration.surface, geometry: .spread(viewport: CGSize(width: 1000, height: 700)), imageLoaded: true)
        #expect(!surface.canPan)
        runtime.handleNavigation(.doubleTap(zone: .center, location: CGPoint(x: 500, y: 350)), surface: surface, configuration: configuration)
        #expect(surface.canPan)
        #expect(runtime.navigationDecision(.pan(translation: CGSize(width: 2, height: 30), velocity: .zero),
            surface: surface, configuration: configuration) == .panImage)
    }

    @Test(arguments: [CGSize(width: 2, height: 80), CGSize(width: -80, height: 80), CGSize(width: 0, height: 40)])
    func obliqueAndVerticalVectorsCannotStartNavigation(velocity: CGSize) {
        let runtime = MangaPagedInteractionRuntime()
        let configuration = MangaNavigationConfiguration(direction: .leftToRight, surface: MangaInteractionConfiguration())
        #expect(runtime.navigationDecision(.pan(translation: CGSize(width: -40, height: 0), velocity: velocity),
            surface: nil, configuration: configuration) == .ignore)
    }

    @Test(arguments: [MangaReadingDirection.leftToRight, .rightToLeft], [false, true])
    func tapControlAndSwipeShareContentPriority(direction: MangaReadingDirection, zoomEnabled: Bool) {
        let runtime = MangaPagedInteractionRuntime()
        let surface = runtime.surface(SurfaceID(value: "page"))
        let configuration = MangaNavigationConfiguration(direction: direction,
            surface: MangaInteractionConfiguration(zoomEnabled: zoomEnabled))
        surface.configure(configuration.surface, geometry: .image(size: CGSize(width: 800, height: 800),
            viewport: CGSize(width: 400, height: 800), fit: .fitHeight, alignment: .left), imageLoaded: true)
        let step = direction.step(toward: .right)
        #expect(runtime.navigationDecision(.tap(.right), surface: surface, configuration: configuration) == .reveal(.right))
        #expect(runtime.navigationDecision(.control(step), surface: surface, configuration: configuration) == .reveal(.right))
        #expect(runtime.navigationDecision(.pan(translation: CGSize(width: -2, height: 0), velocity: .zero),
            surface: surface, configuration: configuration) == .panImage)
        #expect(surface.transform.offset == .zero)
        #expect(runtime.handleNavigation(.control(step), surface: surface, configuration: configuration) == .reveal(.right))
        #expect(runtime.navigationDecision(.tap(.right), surface: surface, configuration: configuration) == .navigate(.right))
        #expect(runtime.navigationDecision(.pan(translation: CGSize(width: -2, height: 0), velocity: .zero),
            surface: surface, configuration: configuration) == .navigate(.right))
    }

    @Test func unloadedPageStillUsesChromeAndNavigationRules() {
        let runtime = MangaPagedInteractionRuntime()
        let configuration = MangaNavigationConfiguration(direction: .rightToLeft,
            surface: MangaInteractionConfiguration(chromeVisible: true))
        #expect(runtime.handleNavigation(.tap(.left), surface: nil, configuration: configuration) == .toggleChrome)
        #expect(runtime.handleNavigation(.doubleTap(zone: .center, location: .zero), surface: nil,
            configuration: configuration) == .toggleChrome)
        #expect(runtime.handleNavigation(.doubleTap(zone: .left, location: .zero), surface: nil,
            configuration: configuration) == .ignore)
        #expect(runtime.handleNavigation(.control(.forward), surface: nil, configuration: configuration) == .navigate(.left))
        #expect(runtime.navigationDecision(.pan(translation: CGSize(width: 40, height: 0), velocity: .zero),
            surface: nil, configuration: configuration) == .ignore)
    }

    @Test func viewportZonesArePhysicalAndRespectBounds() {
        let bounds = CGRect(x: 20, y: 40, width: 360, height: 720)
        #expect(PhysicalZone.at(CGPoint(x: 139.9, y: 400), in: bounds) == .left)
        #expect(PhysicalZone.at(CGPoint(x: 140, y: 400), in: bounds) == .center)
        #expect(PhysicalZone.at(CGPoint(x: 260, y: 400), in: bounds) == .center)
        #expect(PhysicalZone.at(CGPoint(x: 260.1, y: 400), in: bounds) == .right)
        #expect(PhysicalZone.at(CGPoint(x: 200, y: 760), in: bounds) == nil)
        #expect(PhysicalZone.at(.zero, in: .zero) == nil)
    }

    @Test(arguments: [MangaReadingDirection.leftToRight, .rightToLeft])
    func readingOrderRoundTripsPhysicalEdges(direction: MangaReadingDirection) {
        for edge in MangaPagedImageSurfaceHorizontalEdge.allCases {
            #expect(direction.edge(for: direction.step(toward: edge)) == edge)
        }
    }
}

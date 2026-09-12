import Foundation
import Testing
@testable import YamiboXUI

@Suite("Paged interaction core")
struct MangaInteractionTests {
    @MainActor @Test func nativeSnapshotsAreReadOnlyAndChromeDoesNotCancelMotion() {
        let runtime = MangaSurfaceRuntime()
        let host = NativeHost()
        let instance = UUID()
        runtime.attachNative(host, instance: instance)
        runtime.configure(MangaInteractionConfiguration(), geometry: .spread(viewport: CGSize(width: 400, height: 800)), imageLoaded: true)
        let snapshot = MangaSurfaceTransform(scale: 2, offset: CGSize(width: -30, height: 10))
        runtime.receiveNative(snapshot, interacting: true, instance: instance)
        let generation = runtime.generation
        let cancellations = host.cancellations.count
        for chrome in [true, false, true] {
            runtime.configure(MangaInteractionConfiguration(chromeVisible: chrome), geometry: runtime.geometry, imageLoaded: true)
            #expect(runtime.generation == generation)
            #expect(runtime.isManipulating)
            #expect(runtime.transform == snapshot)
            #expect(host.cancellations.count == cancellations)
            #expect(runtime.canPinch)
            #expect(runtime.canPan)
        }
        #expect(host.commands.isEmpty)
        runtime.receiveNative(snapshot, interacting: false, instance: instance)
        #expect(!runtime.isManipulating)
    }

    @MainActor @Test func replacementRejectsOldSnapshotsAndExit() {
        let runtime = MangaSurfaceRuntime()
        let oldHost = NativeHost()
        let newHost = NativeHost()
        let old = UUID()
        let replacement = UUID()
        runtime.attachNative(oldHost, instance: old)
        runtime.attachNative(newHost, instance: replacement)
        runtime.configure(MangaInteractionConfiguration(), geometry: .spread(viewport: CGSize(width: 400, height: 800)), imageLoaded: true)
        let snapshot = MangaSurfaceTransform(scale: 2)
        runtime.receiveNative(snapshot, interacting: false, instance: replacement)
        runtime.receiveNative(MangaSurfaceTransform(scale: 4), interacting: true, instance: old)
        runtime.unmount(old)
        #expect(runtime.isMounted(replacement))
        #expect(runtime.imageLoaded)
        #expect(runtime.transform == snapshot)
        #expect(!runtime.isManipulating)
    }

    @MainActor @Test func discreteCommandsGoToNativeHostWithoutSyntheticTransforms() {
        let runtime = MangaSurfaceRuntime()
        let host = NativeHost()
        let instance = UUID()
        runtime.attachNative(host, instance: instance)
        runtime.configure(MangaInteractionConfiguration(), geometry: .spread(viewport: CGSize(width: 400, height: 800)), imageLoaded: true)
        #expect(runtime.perform(.doubleTap(CGPoint(x: 200, y: 400))) == .zoom(CGPoint(x: 200, y: 400)))
        #expect(runtime.transform.scale == 1)
        runtime.receiveNative(MangaSurfaceTransform(scale: 2), interacting: false, instance: instance)
        #expect(runtime.perform(.control(.right)) == .reveal(.right))
        #expect(host.commands == [.zoom(CGPoint(x: 200, y: 400)), .reveal(.right)])
        runtime.configure(MangaInteractionConfiguration(zoomEnabled: false), geometry: runtime.geometry, imageLoaded: true)
        #expect(host.cancellations.last == true)
    }

    @Test(arguments: [CGFloat(1), 1.01, 1.0101, 2], [false, true])
    func scaleThresholdAndEdgeOwnershipAgree(scale: CGFloat, zoomEnabled: Bool) {
        let decision = MangaInteractionPolicy.decide(.pan(translation: CGSize(width: -2, height: 0), velocity: .zero),
            configuration: MangaInteractionConfiguration(zoomEnabled: zoomEnabled), scale: scale,
            hiddenEdges: [], menuFrame: .zero, imageLoaded: true)
        #expect(decision == (scale > 1.01 ? .panImage : .navigate(.right)))
    }

    @Test(arguments: [CGFloat(0), 2, 8, 11, 12, 40], [false, true])
    func croppedPanHasNoDistanceGate(distance: CGFloat, zoomEnabled: Bool) {
        for edge in MangaPagedImageSurfaceHorizontalEdge.allCases {
            let sign: CGFloat = edge == .right ? -1 : 1
            let result = MangaInteractionPolicy.decide(.pan(translation: CGSize(width: sign * distance, height: 0), velocity: .zero),
                configuration: MangaInteractionConfiguration(zoomEnabled: zoomEnabled), scale: 1,
                hiddenEdges: [edge], menuFrame: .zero, imageLoaded: true)
            #expect(result == (distance == 0 ? .ignore : .panImage))
        }
    }

    @Test func directionUsesOneVector() {
        #expect(MangaInteractionPolicy.dragEdge(translation: CGSize(width: 40, height: 0), velocity: CGSize(width: -2, height: 1)) == .right)
        #expect(MangaInteractionPolicy.dragEdge(translation: CGSize(width: 40, height: 0), velocity: CGSize(width: 0, height: 1)) == nil)
        #expect(MangaInteractionPolicy.dragEdge(translation: CGSize(width: 2, height: 2), velocity: .zero) == nil)
    }

    @MainActor @Test func noImageDoesNotBlockNavigationOrChrome() {
        let runtime = MangaSurfaceRuntime()
        #expect(runtime.decision(.edge(.right)) == .navigate(.right))
        #expect(runtime.decision(.centerTap) == .toggleChrome)
        #expect(runtime.decision(.longPress(CGPoint(x: 200, y: 400))) == .ignore)
    }

    @MainActor private final class NativeHost: MangaNativeSurfaceControlling {
        var commands: [MangaInteractionDecision] = []
        var cancellations: [Bool] = []
        func applyNative(_ decision: MangaInteractionDecision, animated: Bool) { commands.append(decision) }
        func cancelNative(reset: Bool) { cancellations.append(reset) }
    }
}

import Foundation
import Testing
@testable import YamiboXUI

@Suite("Paged interaction core")
struct MangaInteractionTests {
    @MainActor @Test func zoomedFitWidthRevealsEdgeBeforeExternalNavigation() {
        let runtime = MangaSurfaceRuntime()
        runtime.configure(MangaInteractionConfiguration(), geometry: .image(size: CGSize(width: 800, height: 800),
            viewport: CGSize(width: 400, height: 800), fit: .fitWidth, alignment: .left), imageLoaded: true)
        runtime.perform(.doubleTap(CGPoint(x: 200, y: 400)))
        #expect(runtime.perform(.control(.right)) == .reveal(.right))
        #expect(runtime.transform.offset.width == -200)
        #expect(runtime.decision(.control(.right)) == .navigate(.right))
        #expect(runtime.decision(.pan(translation: CGSize(width: -8, height: 0), velocity: .zero)) == .panImage)
    }
    @MainActor @Test func oldViewExitCannotClearReplacementRegistration() {
        let runtime = makeRuntime()
        let old = UUID()
        let replacement = UUID()
        runtime.mount(old)
        runtime.mount(replacement)
        runtime.configure(runtime.configuration, geometry: runtime.geometry, imageLoaded: true)
        runtime.perform(.control(.right))
        let before = runtime.transform
        runtime.unmount(old)
        #expect(runtime.isMounted(replacement))
        #expect(runtime.imageLoaded)
        #expect(runtime.transform == before)
    }

    @MainActor @Test func repeatedConfigurationDoesNotCancelOrResetForUnrelatedUpdates() throws {
        let runtime = makeRuntime()
        let token = try #require(runtime.begin(.pan))
        runtime.changePan(CGSize(width: -20, height: 0), token: token)
        runtime.configure(runtime.configuration, geometry: runtime.geometry, imageLoaded: true)
        #expect(runtime.generation == token)
        #expect(runtime.isManipulating)
        #expect(runtime.transform.offset.width == -20)
    }

    @MainActor @Test func resizedViewportCancelsTemporaryMotionAndClampsCommittedPosition() throws {
        let runtime = makeRuntime()
        runtime.perform(.control(.right))
        let token = try #require(runtime.begin(.pan))
        runtime.changePan(CGSize(width: 50, height: 0), token: token)
        runtime.configure(runtime.configuration, geometry: .image(size: CGSize(width: 800, height: 800),
            viewport: CGSize(width: 600, height: 800), fit: .fitHeight, alignment: .left), imageLoaded: true)
        #expect(!runtime.isManipulating)
        #expect(runtime.transform.offset.width == -200)
        runtime.end(.pan, token: token, cancelled: false)
        #expect(runtime.transform.offset.width == -200)
    }

    @MainActor @Test func pinchReturningBelowActiveThresholdResetsOnce() throws {
        let runtime = makeRuntime()
        runtime.perform(.doubleTap(CGPoint(x: 200, y: 400)))
        let token = try #require(runtime.begin(.pinch))
        runtime.changePinch(0.505, token: token)
        runtime.end(.pinch, token: token, cancelled: false)
        #expect(runtime.transform == MangaSurfaceTransform())
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
        let config = MangaInteractionConfiguration(zoomEnabled: zoomEnabled)
        for edge in MangaPagedImageSurfaceHorizontalEdge.allCases {
            let sign: CGFloat = edge == .right ? -1 : 1
            let result = MangaInteractionPolicy.decide(.pan(translation: CGSize(width: sign * distance, height: 0), velocity: .zero),
                configuration: config, scale: 1, hiddenEdges: [edge], menuFrame: .zero, imageLoaded: true)
            #expect(result == (distance == 0 ? .ignore : .panImage))
        }
    }

    @Test func directionUsesOneVector() {
        #expect(MangaInteractionPolicy.dragEdge(translation: CGSize(width: 40, height: 0),
            velocity: CGSize(width: -2, height: 1)) == .right)
        #expect(MangaInteractionPolicy.dragEdge(translation: CGSize(width: 40, height: 0),
            velocity: CGSize(width: 0, height: 1)) == nil)
        #expect(MangaInteractionPolicy.dragEdge(translation: CGSize(width: 2, height: 2), velocity: .zero) == nil)
    }

    @MainActor @Test func simultaneousCancellationRollsBackEndedMemberAndRejectsLateEvents() throws {
        let runtime = makeRuntime()
        let pan = try #require(runtime.begin(.pan))
        runtime.changePan(CGSize(width: -20, height: 0), token: pan)
        let pinch = try #require(runtime.begin(.pinch))
        #expect(pan == pinch)
        runtime.changePinch(2, token: pinch)
        runtime.end(.pan, token: pan, cancelled: false)
        #expect(runtime.isManipulating)
        runtime.end(.pinch, token: pinch, cancelled: true)
        #expect(runtime.transform == MangaSurfaceTransform())
        runtime.changePan(CGSize(width: -200, height: 0), token: pan)
        runtime.end(.pan, token: pan, cancelled: false)
        #expect(runtime.transform == MangaSurfaceTransform())
    }

    @MainActor @Test(arguments: [false, true])
    func simultaneousCommitIsIndependentOfEndOrder(pinchFirst: Bool) throws {
        let runtime = makeRuntime()
        let token = try #require(runtime.begin(.pan))
        #expect(runtime.begin(.pinch) == token)
        runtime.changePan(CGSize(width: -30, height: 10), token: token)
        runtime.changePinch(2, token: token)
        runtime.end(pinchFirst ? .pinch : .pan, token: token, cancelled: false)
        #expect(runtime.isManipulating)
        runtime.end(pinchFirst ? .pan : .pinch, token: token, cancelled: false)
        #expect(!runtime.isManipulating)
        #expect(runtime.transform.scale == 2)
        #expect(runtime.transform.offset.width == -30)
        runtime.invalidate()
        #expect(runtime.transform.scale == 2)
    }

    @MainActor @Test func panRemainsContinuousAcrossOriginAndClamp() throws {
        let runtime = makeRuntime()
        let token = try #require(runtime.begin(.pan))
        for distance: CGFloat in [-2, -8, -11, -600, -20, 0, -8] {
            runtime.changePan(CGSize(width: distance, height: 40), token: token)
            #expect(runtime.transform.offset.width == max(-400, distance))
            #expect(runtime.transform.offset.height == 0)
        }
    }

    @MainActor @Test func configurationCancelsBeforeApplyingResetRules() throws {
        let runtime = makeRuntime()
        let token = try #require(runtime.begin(.pan))
        runtime.changePan(CGSize(width: -40, height: 0), token: token)
        runtime.end(.pan, token: token, cancelled: false)
        let old = try #require(runtime.begin(.pan))
        runtime.changePan(CGSize(width: -80, height: 0), token: old)
        runtime.configure(MangaInteractionConfiguration(zoomEnabled: false), geometry: runtime.geometry, imageLoaded: true)
        #expect(runtime.transform.offset.width == -40)
        runtime.end(.pan, token: old, cancelled: false)
        #expect(runtime.transform.offset.width == -40)
    }

    @MainActor @Test func externalEdgeAndSwipeDifferWhileZoomed() {
        let runtime = makeRuntime()
        runtime.perform(.doubleTap(CGPoint(x: 200, y: 400)))
        runtime.perform(.edge(.right))
        #expect(runtime.decision(.edge(.right)) == .navigate(.right))
        #expect(runtime.decision(.pan(translation: CGSize(width: -40, height: 0), velocity: .zero)) == .panImage)
    }

    @MainActor @Test func noImageDoesNotBlockNavigationOrChrome() {
        let runtime = MangaSurfaceRuntime()
        #expect(runtime.decision(.edge(.right)) == .navigate(.right))
        #expect(runtime.decision(.centerTap) == .toggleChrome)
        #expect(runtime.decision(.longPress(CGPoint(x: 200, y: 400))) == .ignore)
    }

    @MainActor private func makeRuntime() -> MangaSurfaceRuntime {
        let runtime = MangaSurfaceRuntime()
        runtime.configure(MangaInteractionConfiguration(), geometry: .image(size: CGSize(width: 800, height: 800),
            viewport: CGSize(width: 400, height: 800), fit: .fitHeight, alignment: .left), imageLoaded: true)
        return runtime
    }
}

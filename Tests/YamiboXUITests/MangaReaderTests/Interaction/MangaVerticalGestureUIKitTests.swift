#if os(iOS)
import Testing
import UIKit
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite("Vertical manga gesture arbitration", .serialized)
struct MangaVerticalGestureUIKitTests {
    @Test(arguments: [false, true])
    func brakingTouchIsRejectedBeforeDoubleTapWait(doubleTap: Bool) throws {
        let fixture = try makeFixture()
        let recognizer = doubleTap ? fixture.owner.doubleTapGesture : fixture.owner.tapGesture
        fixture.owner.scrollViewDidScroll(fixture.collection)
        fixture.state.time += 0.05

        // UIKit may already have stopped decelerating before admission.
        #expect(!fixture.collection.isDecelerating)
        let admitted = fixture.owner.gestureRecognizer(recognizer, shouldReceive: UITouch())
        fixture.state.time += 0.5

        // A delayed recognition must never get this first touch; a fresh tap
        // after settling is independent and must remain available.
        #expect(!admitted)
        #expect(fixture.owner.gestureRecognizer(recognizer, shouldReceive: UITouch()))
    }

    @Test(arguments: [false, true], [false, true])
    func activeMotionRejectsTouchesEvenWithoutRecentOffsetChanges(doubleTap: Bool, decelerating: Bool) throws {
        let fixture = try makeFixture()
        let scrollView = MotionScrollView()
        let recognizer = doubleTap ? fixture.owner.doubleTapGesture : fixture.owner.tapGesture
        scrollView.addGestureRecognizer(recognizer)
        scrollView.simulatedDragging = !decelerating
        scrollView.simulatedDecelerating = decelerating
        fixture.state.time += 10

        #expect(!fixture.owner.gestureRecognizer(recognizer, shouldReceive: UITouch()))

        scrollView.simulatedDragging = false
        scrollView.simulatedDecelerating = false
        #expect(fixture.owner.gestureRecognizer(recognizer, shouldReceive: UITouch()))
    }

    @Test(arguments: [false, true])
    func stationarySingleTapTogglesChrome(chromeVisible: Bool) throws {
        let fixture = try makeFixture(chromeVisible: chromeVisible)
        #expect(fixture.owner.gestureRecognizer(fixture.owner.tapGesture, shouldReceive: UITouch()))

        sendTap(to: fixture, doubleTap: false)

        #expect(fixture.state.taps == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func motionAfterAdmissionStillSuppressesCompletedTap(doubleTap: Bool, chromeVisible: Bool) throws {
        let fixture = try makeFixture(chromeVisible: chromeVisible)
        let recognizer = doubleTap ? fixture.owner.doubleTapGesture : fixture.owner.tapGesture
        #expect(fixture.owner.gestureRecognizer(recognizer, shouldReceive: UITouch()))
        fixture.owner.scrollViewDidScroll(fixture.collection)
        fixture.state.time += 0.1

        sendTap(to: fixture, doubleTap: doubleTap)

        #expect(fixture.state.taps == 0)
        #expect(fixture.owner.verticalZoomScale == 1)
    }

    @Test(arguments: [false, true])
    func stationaryDoubleTapKeepsChromeAndZoomBehavior(chromeVisible: Bool) throws {
        let fixture = try makeFixture(chromeVisible: chromeVisible)
        #expect(fixture.owner.gestureRecognizer(fixture.owner.doubleTapGesture, shouldReceive: UITouch()))

        sendTap(to: fixture, doubleTap: true)

        #expect(fixture.state.taps == (chromeVisible ? 1 : 0))
        #expect(fixture.owner.verticalZoomScale == (chromeVisible ? 1 : 2))
        if !chromeVisible {
            sendTap(to: fixture, doubleTap: true)
            #expect(fixture.owner.verticalZoomScale == 1)
        }
    }

    @Test func controlsAreExcludedWithoutDisablingPinchDuringScroll() throws {
        let fixture = try makeFixture()
        let button = UIButton()
        let label = UILabel()
        button.addSubview(label)
        let touch = ViewTouch(targetView: label)
        for recognizer in [fixture.owner.tapGesture, fixture.owner.doubleTapGesture, fixture.owner.pinchGesture] {
            #expect(!fixture.owner.gestureRecognizer(recognizer, shouldReceive: touch))
        }

        fixture.owner.scrollViewDidScroll(fixture.collection)
        #expect(fixture.owner.gestureRecognizer(fixture.owner.pinchGesture, shouldReceive: UITouch()))
        #expect(fixture.owner.gestureRecognizerShouldBegin(fixture.owner.pinchGesture))
    }

    @Test func installedRecognizersGivePanAndPinchPriorityAndOnlyAllowTheirSimultaneity() throws {
        let fixture = try makeFixture()
        let owner = fixture.owner
        let pan = fixture.collection.panGestureRecognizer
        let unrelatedPan = UIPanGestureRecognizer()
        let longPress = UILongPressGestureRecognizer()

        for tap in [owner.tapGesture, owner.doubleTapGesture] {
            #expect(tap.view === fixture.collection)
            #expect(tap.delegate === owner)
            #expect(tap.delegate?.gestureRecognizer?(tap, shouldRequireFailureOf: pan) == true)
            #expect(tap.delegate?.gestureRecognizer?(tap, shouldRequireFailureOf: owner.pinchGesture) == true)
            #expect(tap.delegate?.gestureRecognizer?(tap, shouldRequireFailureOf: unrelatedPan) == false)
            for other in [pan, owner.pinchGesture, longPress] {
                #expect(owner.gestureRecognizer(tap, shouldRecognizeSimultaneouslyWith: other) == false)
                #expect(owner.gestureRecognizer(other, shouldRecognizeSimultaneouslyWith: tap) == false)
            }
        }
        #expect(owner.gestureRecognizer(owner.pinchGesture, shouldRecognizeSimultaneouslyWith: pan))
        #expect(owner.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: owner.pinchGesture))
        #expect(!owner.gestureRecognizer(owner.pinchGesture, shouldRecognizeSimultaneouslyWith: unrelatedPan))
        #expect(!owner.gestureRecognizer(owner.pinchGesture, shouldRecognizeSimultaneouslyWith: longPress))
    }

    private func sendTap(to fixture: Fixture, doubleTap: Bool) {
        let endedTap = EndedTap()
        fixture.collection.addGestureRecognizer(endedTap)
        defer { fixture.collection.removeGestureRecognizer(endedTap) }
        _ = fixture.owner.perform(NSSelectorFromString(doubleTap ? "handleDoubleTap:" : "handleTap:"), with: endedTap)
    }

    private func makeFixture(chromeVisible: Bool = false) throws -> Fixture {
        let state = State()
        let loader = MangaReaderPageImageLoader(imageSource: { _ in
            YamiboImageSource(url: URL(fileURLWithPath: "/nonexistent/manga-vertical-gesture-test.png"))
        }, uiImagePipeline: YamiboUIImagePipeline(core: YamiboImagePipeline()))
        let viewport = MangaVerticalCollectionViewport(
            pages: [try makePipelinePage()], currentPageIndex: 0, viewportPlacement: nil,
            controlScrollStep: nil, imageLoader: loader, isChromeVisible: chromeVisible,
            zoomEnabled: true, likedPageIDs: [], onCurrentPageChange: { _ in },
            onControlScrollEdgeReached: { _ in }, onPageLongPress: { _ in }, onTap: { state.taps += 1 }
        )
        let owner = MangaVerticalCollectionViewport.Coordinator(parent: viewport, currentTime: { state.time })
        return Fixture(owner: owner, collection: viewport.makeCollectionView(coordinator: owner), state: state)
    }

    private struct Fixture {
        let owner: MangaVerticalCollectionViewport.Coordinator
        let collection: UICollectionView
        let state: State
    }

    private final class State {
        var time: CFTimeInterval = 100
        var taps = 0
    }

    private final class MotionScrollView: UIScrollView {
        var simulatedDragging = false
        var simulatedDecelerating = false
        override var isDragging: Bool { simulatedDragging }
        override var isDecelerating: Bool { simulatedDecelerating }
    }

    private final class ViewTouch: UITouch {
        let targetView: UIView
        init(targetView: UIView) {
            self.targetView = targetView
            super.init()
        }
        override var view: UIView? { targetView }
    }

    private final class EndedTap: UITapGestureRecognizer {
        override var state: UIGestureRecognizer.State {
            get { .ended }
            set { }
        }
    }
}
#endif

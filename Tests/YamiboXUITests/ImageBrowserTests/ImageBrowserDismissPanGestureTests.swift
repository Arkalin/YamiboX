import UIKit
import XCTest
@testable import YamiboXUI

@MainActor
final class ImageBrowserDismissPanGestureTests: XCTestCase {
    func testInstalledDelegateRejectsHorizontalUpwardAndDiagonalPansBeforeRecognition() {
        let input = ImageBrowserDismissPanInput()
        let pan = input.makeRecognizer()
        XCTAssertTrue(pan.delegate === input)
        XCTAssertEqual(pan.maximumNumberOfTouches, 1)

        for intent in [CGPoint(x: 900, y: 0), CGPoint(x: -900, y: 0),
                       CGPoint(x: 900, y: 300), CGPoint(x: -900, y: -300),
                       CGPoint(x: 0, y: -900), CGPoint(x: 500, y: 600), .zero] {
            input.localVelocity = { intent }
            XCTAssertEqual(pan.delegate?.gestureRecognizerShouldBegin?(pan), false, "Intent: \(intent)")
        }
        input.localVelocity = { CGPoint(x: 50, y: 600) }
        XCTAssertEqual(pan.delegate?.gestureRecognizerShouldBegin?(pan), true)
    }

    func testAdmissionUsesCurrentVelocityAndFallsBackToTranslationForSlowDrags() {
        let input = ImageBrowserDismissPanInput()
        let pan = input.makeRecognizer()
        input.localTranslation = { CGPoint(x: 1, y: 20) }
        input.localVelocity = { CGPoint(x: 700, y: 10) }
        XCTAssertEqual(pan.delegate?.gestureRecognizerShouldBegin?(pan), false)
        input.localVelocity = { .zero }
        XCTAssertEqual(pan.delegate?.gestureRecognizerShouldBegin?(pan), true)
    }

    func testZoomAndDisabledStateRejectDismissWithoutReplacingTheRecognizer() {
        let input = ImageBrowserDismissPanInput()
        let pan = input.makeRecognizer()
        input.localVelocity = { CGPoint(x: 0, y: 800) }
        input.update(pan, isEnabled: true, zoomFactor: 1.02)
        XCTAssertFalse(pan.isEnabled)
        XCTAssertEqual(pan.delegate?.gestureRecognizerShouldBegin?(pan), false)
        input.update(pan, isEnabled: false, zoomFactor: 1)
        XCTAssertFalse(pan.isEnabled)
        input.update(pan, isEnabled: true, zoomFactor: 1 + .ulpOfOne)
        XCTAssertTrue(pan.isEnabled)
        XCTAssertEqual(pan.delegate?.gestureRecognizerShouldBegin?(pan), true)
    }

    func testEngagedDragRebasesAndUsesTheFinalSampleWithoutRelockingDirection() {
        let input = ImageBrowserDismissPanInput()
        var changes: [CGPoint] = []
        var endings: [(CGPoint, CGPoint)] = []
        input.onChanged = { changes.append($0) }
        input.onEnded = { endings.append(($0, $1)) }
        input.handle(state: .began, translation: CGPoint(x: 2, y: 12), velocity: .zero)
        input.handle(state: .changed, translation: CGPoint(x: 82, y: 32), velocity: .zero)
        input.handle(state: .changed, translation: CGPoint(x: 82, y: -2), velocity: .zero)
        input.handle(state: .ended, translation: CGPoint(x: 12, y: 112), velocity: CGPoint(x: 0, y: 800))
        XCTAssertEqual(changes, [.zero, CGPoint(x: 80, y: 20), CGPoint(x: 80, y: 0)])
        XCTAssertEqual(endings.count, 1)
        XCTAssertEqual(endings.first?.0, CGPoint(x: 10, y: 100))
        XCTAssertEqual(endings.first?.1, CGPoint(x: 0, y: 800))
        input.handle(state: .ended, translation: CGPoint(x: 0, y: 300), velocity: .zero)
        XCTAssertEqual(endings.count, 1)
    }

    func testCancellationClearsTheActiveDragAndNeverCommitsIt() {
        let input = ImageBrowserDismissPanInput()
        var cancellations = 0
        var endings: [CGPoint] = []
        input.onCancelled = { cancellations += 1 }
        input.onEnded = { translation, _ in endings.append(translation) }
        input.handle(state: .began, translation: CGPoint(x: 0, y: 10), velocity: .zero)
        input.handle(state: .changed, translation: CGPoint(x: 0, y: 200), velocity: .zero)
        input.handle(state: .cancelled, translation: .zero, velocity: .zero)
        input.handle(state: .failed, translation: .zero, velocity: .zero)
        input.handle(state: .ended, translation: CGPoint(x: 0, y: 400), velocity: CGPoint(x: 0, y: 900))
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(endings.isEmpty)

        input.handle(state: .began, translation: CGPoint(x: 0, y: 15), velocity: .zero)
        input.handle(state: .ended, translation: CGPoint(x: 0, y: 25), velocity: .zero)
        XCTAssertEqual(endings, [CGPoint(x: 0, y: 10)])
    }

    func testDisablingMidDragDefersCancellationOutsideTheSwiftUIViewUpdate() async {
        let input = ImageBrowserDismissPanInput()
        let pan = input.makeRecognizer()
        var cancellations = 0
        let cancelled = expectation(description: "Cancellation leaves the view update")
        input.onCancelled = {
            cancellations += 1
            cancelled.fulfill()
        }
        input.handle(state: .began, translation: .zero, velocity: .zero)
        input.update(pan, isEnabled: false, zoomFactor: 1)
        XCTAssertEqual(cancellations, 0)
        await fulfillment(of: [cancelled], timeout: 2)
        input.handle(state: .cancelled, translation: .zero, velocity: .zero)
        XCTAssertEqual(cancellations, 1)
    }
}

import UIKit
import XCTest
@testable import YamiboXUI

final class ImageBrowserZoomMathTests: XCTestCase {
    func testFitScaleMatchesTightestAxisAndGuardsDegenerateSizes() {
        XCTAssertEqual(
            ImageBrowserZoomMath.fitScale(
                imageSize: CGSize(width: 1000, height: 500),
                containerSize: CGSize(width: 500, height: 500)
            ),
            0.5
        )
        XCTAssertEqual(
            ImageBrowserZoomMath.fitScale(
                imageSize: CGSize(width: 100, height: 400),
                containerSize: CGSize(width: 200, height: 200)
            ),
            0.5
        )
        XCTAssertEqual(
            ImageBrowserZoomMath.fitScale(imageSize: .zero, containerSize: CGSize(width: 200, height: 200)),
            1
        )
        XCTAssertEqual(
            ImageBrowserZoomMath.fitScale(imageSize: CGSize(width: 100, height: 100), containerSize: .zero),
            1
        )
    }

    func testNormalizedFactorIsRelativeToFitScale() {
        XCTAssertEqual(ImageBrowserZoomMath.normalizedFactor(zoomScale: 1.0, fitScale: 0.5), 2)
        XCTAssertEqual(ImageBrowserZoomMath.normalizedFactor(zoomScale: 0.5, fitScale: 0.5), 1)
        XCTAssertEqual(ImageBrowserZoomMath.normalizedFactor(zoomScale: 2, fitScale: 0), 1)
    }

    func testClampedFactorStaysBetweenFitAndMaximum() {
        XCTAssertEqual(ImageBrowserZoomMath.clampedFactor(0.3), 1)
        XCTAssertEqual(ImageBrowserZoomMath.clampedFactor(2.6), 2.6)
        XCTAssertEqual(ImageBrowserZoomMath.clampedFactor(80), ImageBrowserZoomMath.maximumZoomFactor)
    }

    func testDoubleTapZoomRectCentersOnTapPointAtTargetScale() {
        let imageSize = CGSize(width: 1000, height: 500)
        let containerSize = CGSize(width: 500, height: 500)
        let tapPoint = CGPoint(x: 700, y: 200)

        let rect = ImageBrowserZoomMath.doubleTapZoomRect(
            tapPoint: tapPoint,
            imageSize: imageSize,
            containerSize: containerSize
        )

        // fit = 0.5, target zoom scale = 1.3 → the visible rect in image
        // coordinates is container/1.3, centered on the tapped point.
        XCTAssertEqual(rect.midX, tapPoint.x, accuracy: 0.001)
        XCTAssertEqual(rect.midY, tapPoint.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, containerSize.width / 1.3, accuracy: 0.001)
        XCTAssertEqual(rect.height, containerSize.height / 1.3, accuracy: 0.001)

        XCTAssertEqual(
            ImageBrowserZoomMath.doubleTapZoomRect(
                tapPoint: .zero,
                imageSize: .zero,
                containerSize: .zero
            ),
            .zero
        )
    }

    func testSteppedFactorClampsAtBothEnds() {
        XCTAssertEqual(
            ImageBrowserZoomMath.steppedFactor(from: 1, zoomIn: true),
            ImageBrowserZoomMath.accessibilityZoomStep
        )
        XCTAssertEqual(ImageBrowserZoomMath.steppedFactor(from: 1, zoomIn: false), 1)
        XCTAssertEqual(
            ImageBrowserZoomMath.steppedFactor(from: 4.5, zoomIn: true),
            ImageBrowserZoomMath.maximumZoomFactor
        )
        XCTAssertEqual(
            ImageBrowserZoomMath.steppedFactor(from: ImageBrowserZoomMath.accessibilityZoomStep, zoomIn: false),
            1,
            accuracy: 0.001
        )
    }

    func testEngagedZoomIgnoresFitLevelFactorsIncludingFloatingPointError() {
        XCTAssertFalse(ImageBrowserZoomMath.isEngagedZoom(factor: 1))
        // Aspect-fit zoom scales are floating-point quotients, so the resting
        // factor can land a hair off 1 — that must still count as fit.
        XCTAssertFalse(ImageBrowserZoomMath.isEngagedZoom(factor: 1 + .ulpOfOne))
        XCTAssertFalse(ImageBrowserZoomMath.isEngagedZoom(factor: 1.01))
        XCTAssertFalse(ImageBrowserZoomMath.isEngagedZoom(factor: 0.9))
        XCTAssertTrue(ImageBrowserZoomMath.isEngagedZoom(factor: 1.02))
        XCTAssertTrue(ImageBrowserZoomMath.isEngagedZoom(factor: ImageBrowserZoomMath.maximumZoomFactor))
    }

    func testCenteringInsetsCenterUndersizedContentAndVanishWhenContentFills() {
        let letterboxed = ImageBrowserZoomMath.centeringInsets(
            contentSize: CGSize(width: 500, height: 250),
            containerSize: CGSize(width: 500, height: 500)
        )
        XCTAssertEqual(letterboxed.top, 125)
        XCTAssertEqual(letterboxed.bottom, 125)
        XCTAssertEqual(letterboxed.left, 0)
        XCTAssertEqual(letterboxed.right, 0)

        let overflowing = ImageBrowserZoomMath.centeringInsets(
            contentSize: CGSize(width: 1000, height: 1000),
            containerSize: CGSize(width: 500, height: 500)
        )
        XCTAssertEqual(overflowing, .zero)
    }
}

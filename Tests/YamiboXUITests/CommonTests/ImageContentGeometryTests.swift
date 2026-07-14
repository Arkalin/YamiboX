import CoreGraphics
import XCTest
@testable import YamiboXUI

final class ImageContentGeometryTests: XCTestCase {
    func testAspectFitImageHitTestingUsesAspectFitFrameOnly() {
        let container = CGSize(width: 300, height: 500)
        let image = CGSize(width: 300, height: 200)
        let imageFrame = ImageContentGeometry.aspectFitFrame(
            imageSize: image,
            containerSize: container
        )

        XCTAssertEqual(imageFrame, CGRect(x: 0, y: 150, width: 300, height: 200))
        XCTAssertTrue(ImageContentGeometry.containsAspectFitImagePoint(CGPoint(x: 150, y: 240), imageSize: image, containerSize: container))
        XCTAssertFalse(ImageContentGeometry.containsAspectFitImagePoint(CGPoint(x: 150, y: 420), imageSize: image, containerSize: container))
    }
}

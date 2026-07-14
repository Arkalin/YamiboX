#if os(iOS)
import UIKit
import XCTest
@testable import YamiboXUI

final class FavoriteBackgroundImageDecodeCacheTests: XCTestCase {
    func testSameDataReturnsSameCachedInstance() {
        let cache = FavoriteBackgroundImageDecodeCache()
        let data = testImageData(color: .red)

        let first = cache.image(for: data)
        let second = cache.image(for: data)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    func testEqualButDistinctDataInstancesShareCachedImage() {
        let cache = FavoriteBackgroundImageDecodeCache()
        let originalData = testImageData(color: .blue)
        let copiedData = Data(originalData)

        let first = cache.image(for: originalData)
        let second = cache.image(for: copiedData)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    func testDifferentDataReturnsDifferentInstance() {
        let cache = FavoriteBackgroundImageDecodeCache()
        let redImage = cache.image(for: testImageData(color: .red))
        let blueImage = cache.image(for: testImageData(color: .blue))

        XCTAssertNotNil(redImage)
        XCTAssertNotNil(blueImage)
        XCTAssertFalse(redImage === blueImage)
    }

    func testInvalidDataReturnsNil() {
        let cache = FavoriteBackgroundImageDecodeCache()
        XCTAssertNil(cache.image(for: Data([0, 1, 2])))
    }
}

private func testImageData(color: UIColor) -> Data {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in
        color.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1)).fill()
    }
    return image.pngData()!
}
#endif

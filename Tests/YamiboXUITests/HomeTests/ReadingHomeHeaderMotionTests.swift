import XCTest
@testable import YamiboXUI

final class ReadingHomeHeaderMotionTests: XCTestCase {
    func testTopAndPullDownKeepHeaderVisible() {
        for offset in [-120.0, 0, 8] {
            let motion = ReadingHomeHeaderMotion(scrollOffset: offset)
            XCTAssertEqual(motion.titleOpacity, 1)
            XCTAssertEqual(motion.avatarOpacity, 1)
            XCTAssertEqual(motion.avatarBlurRadius, 0)
        }
    }

    func testTitleDisappearsBeforeAvatar() {
        let motion = ReadingHomeHeaderMotion(scrollOffset: 48)
        XCTAssertEqual(motion.titleOpacity, 0)
        XCTAssertGreaterThan(motion.avatarOpacity, 0.5)
        XCTAssertGreaterThan(motion.avatarBlurRadius, 0)
    }

    func testScrolledHeaderStaysHidden() {
        for offset in [88.0, 120, 10_000] {
            let motion = ReadingHomeHeaderMotion(scrollOffset: offset)
            XCTAssertEqual(motion.titleOpacity, 0)
            XCTAssertEqual(motion.avatarOpacity, 0)
            XCTAssertEqual(motion.avatarBlurRadius, 10)
        }
    }

    func testTransitionIsContinuousMonotonicAndReversible() {
        var previous = ReadingHomeHeaderMotion(scrollOffset: 0)
        for offset in 1...100 {
            let current = ReadingHomeHeaderMotion(scrollOffset: Double(offset))
            XCTAssertLessThanOrEqual(current.titleOpacity, previous.titleOpacity)
            XCTAssertLessThanOrEqual(current.avatarOpacity, previous.avatarOpacity)
            XCTAssertLessThan(abs(current.titleOpacity - previous.titleOpacity), 0.04)
            XCTAssertLessThan(abs(current.avatarOpacity - previous.avatarOpacity), 0.03)
            previous = current
        }
        let returning = (0...100).reversed().map { ReadingHomeHeaderMotion(scrollOffset: Double($0)) }
        XCTAssertEqual(returning.last?.titleOpacity, 1)
        XCTAssertEqual(returning.last?.avatarOpacity, 1)
    }
}

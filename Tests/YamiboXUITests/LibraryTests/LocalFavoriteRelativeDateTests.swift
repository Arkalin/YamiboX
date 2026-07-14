import XCTest
@testable import YamiboXUI

@MainActor
final class LocalFavoriteRelativeDateTests: XCTestCase {
    func testSubMinuteDifferencesCollapseToJustNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(LocalFavoriteRelativeDate.string(from: now, now: now), "刚刚")
        XCTAssertEqual(
            LocalFavoriteRelativeDate.string(from: now.addingTimeInterval(-59), now: now),
            "刚刚"
        )
    }

    func testMinuteAndAboveDifferencesUseTheRelativeFormatterInstead() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertNotEqual(
            LocalFavoriteRelativeDate.string(from: now.addingTimeInterval(-60), now: now),
            "刚刚"
        )
        XCTAssertNotEqual(
            LocalFavoriteRelativeDate.string(from: now.addingTimeInterval(-3600), now: now),
            "刚刚"
        )
    }
}

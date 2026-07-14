import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

/// Liked-manga open dispatch (pluggable-reader-config R13): the smart bit
/// follows the board's *current* configuration when the anchor recorded its
/// fid; legacy fid-less anchors keep the pre-R13 smart-on assumption.
final class LikeMangaOpenTargetPolicyTests: XCTestCase {
    func testAnchorWithFidFollowsCurrentBoardConfiguration() {
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")

        let anchor = MangaImageLikeAnchor(chapterTID: "700", pageLocalIndex: 3, forumID: "46")
        let smartOn = LikeMangaOpenTargetPolicy.launchContext(
            anchor: anchor,
            workID: "测试漫画",
            workTitle: "测试漫画",
            boardReader: boardReader
        )
        XCTAssertTrue(smartOn.isSmartModeEnabled)
        XCTAssertEqual(smartOn.directoryName, "测试漫画")
        XCTAssertEqual(smartOn.forumID, "46")
        XCTAssertEqual(smartOn.chapterTID, "700")
        XCTAssertEqual(smartOn.initialPage, 3)
        XCTAssertTrue(smartOn.isPreview)

        // Smart bit off / 小说 / 普通 / unconfigured all open the anchored
        // chapter as a single mode-off thread — one rule, no special cases.
        boardReader.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "46")
        let smartOff = LikeMangaOpenTargetPolicy.launchContext(
            anchor: anchor,
            workID: "测试漫画",
            workTitle: "测试漫画",
            boardReader: boardReader
        )
        XCTAssertFalse(smartOff.isSmartModeEnabled)
        XCTAssertNil(smartOff.directoryName)
        XCTAssertEqual(smartOff.forumID, "46")

        boardReader.setEntry(.init(mode: .novel), forumID: "46")
        XCTAssertFalse(
            LikeMangaOpenTargetPolicy.launchContext(
                anchor: anchor,
                workID: "测试漫画",
                workTitle: "测试漫画",
                boardReader: boardReader
            ).isSmartModeEnabled
        )

        boardReader.removeEntry(forumID: "46")
        XCTAssertFalse(
            LikeMangaOpenTargetPolicy.launchContext(
                anchor: anchor,
                workID: "测试漫画",
                workTitle: "测试漫画",
                boardReader: boardReader
            ).isSmartModeEnabled
        )
    }

    func testLegacyAnchorWithoutFidKeepsSmartOnAssumption() {
        let anchor = MangaImageLikeAnchor(chapterTID: "700", pageLocalIndex: 3)
        let context = LikeMangaOpenTargetPolicy.launchContext(
            anchor: anchor,
            workID: "旧点赞漫画",
            workTitle: "旧点赞漫画",
            boardReader: BoardReaderSettings(entries: [:])
        )
        XCTAssertTrue(context.isSmartModeEnabled)
        XCTAssertEqual(context.directoryName, "旧点赞漫画")
        XCTAssertNil(context.forumID)
    }
}

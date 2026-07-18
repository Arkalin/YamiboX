import Foundation
import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

#if canImport(UIKit)
private typealias NovelTextLayoutFixture = (
    NovelReaderProjection,
    NovelReaderAppearanceSettings,
    NovelReaderLayout
) throws -> NovelTextLayoutResult

@MainActor
final class NovelReadingSessionRuntimeTests: XCTestCase {
    func testRestoresNovelReadingPositionWithinChapter() throws {
        let document = makeNovelDocument(
            view: 2,
            maxView: 2,
            segments: [
                ("第一章", String(repeating: "第一章 内容。", count: 120)),
                ("第二章", String(repeating: "第二章 内容。", count: 120)),
                ("第三章", String(repeating: "第三章 内容。", count: 120)),
            ]
        )
        let settings = NovelReaderAppearanceSettings(readingMode: .vertical)
        let layout = NovelReaderLayout(width: 320, height: 568)
        let pagination = try NovelTextLayout.layout(document: document, settings: settings, layout: layout)
        let savedViewportSurface = try XCTUnwrap(
            pagination.viewportIndex.surfaces.first { $0.chapterTitle == "第三章" && !$0.ranges.isEmpty }
        )
        let savedRange = try XCTUnwrap(savedViewportSurface.ranges.first)
        let savedOffset = savedRange.startOffset + max(1, savedRange.length / 2)
        let resumePoint = NovelResumePoint(
            view: 2,
            textSegmentIdentity: try XCTUnwrap(document.semantics(forSegmentIndex: savedRange.segmentIndex)?.textSegmentIdentity),
            displayedTextOffset: savedOffset,
            chapterOrdinal: try XCTUnwrap(savedViewportSurface.chapterOrdinal),
            chapterTitle: savedViewportSurface.chapterTitle,
            segmentProgress: 0.5,
            readingModeHint: .vertical
        )

        let session = NovelReadingSession(
            document: document,
            settings: settings,
            layout: layout,
            resumePoint: resumePoint
        )

        XCTAssertEqual(session.snapshot.currentView, 2)
        XCTAssertEqual(session.snapshot.currentChapterTitle, "第三章")
        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, savedViewportSurface.surfaceOrdinal)
        XCTAssertEqual(session.viewportSurfacesForTesting[session.snapshot.selectedSurfaceOrdinal].ranges.first?.segmentIndex, savedRange.segmentIndex)
        XCTAssertGreaterThan(session.snapshot.currentSurfaceIntraProgress, 0.2)
    }

    func testHidingAuthorReplyToOtherFallbacksToPreviousVisibleText() throws {
        let document = NovelReaderProjection(
            threadID: "9101",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 80), chapterTitle: "第一章"),
                .text(String(repeating: "读者甲 发表于 2026-5-1\n楼主回复。", count: 20), chapterTitle: "读者甲 发表于 2026-5-1"),
                .text(String(repeating: "第二章 内容。", count: 80), chapterTitle: "第二章"),
            ],
            segmentSources: [
                NovelReaderSegmentSource(ownerPostID: "100"),
                NovelReaderSegmentSource(ownerPostID: "101", isAuthorReplyToOther: true),
                NovelReaderSegmentSource(ownerPostID: "102"),
            ]
        )
        let layout = NovelReaderLayout(width: 320, height: 568)
        var session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: layout
        )
        let replySurface = try XCTUnwrap(session.viewportSurfacesForTesting.first { surface in
            surface.ranges.contains { $0.segmentIndex == 1 }
        })

        session.updateVerticalViewportPosition(surfaceOrdinal: replySurface.surfaceOrdinal, intraSurfaceProgress: 0.5)
        let replyPosition = try XCTUnwrap(session.captureNovelReadingPosition())
        session.consumeCommittedLayoutResult(
            try committedLayoutResult(
                document: document,
                settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false, readingMode: .vertical),
                layout: layout
            ),
            preferredSurfaceOrdinal: session.snapshot.selectedSurfaceOrdinal,
            preferredResumePoint: replyPosition
        )

        let restoredSurface = session.viewportSurfacesForTesting[session.snapshot.selectedSurfaceOrdinal]
        XCTAssertTrue(restoredSurface.ranges.contains { $0.segmentIndex == 0 })
        XCTAssertFalse(session.viewportSurfacesForTesting.flatMap(\.ranges).contains { $0.segmentIndex == 1 })
        XCTAssertEqual(restoredSurface.chapterTitle, "第一章")
        XCTAssertEqual(session.snapshot.currentSurfaceIntraProgress, 1, accuracy: 0.001)
    }

    func testHidingAuthorReplyToOtherFallbacksToNextVisibleTextWhenNoPreviousTextExists() throws {
        let document = NovelReaderProjection(
            threadID: "9102",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "读者甲 发表于 2026-5-1\n楼主回复。", count: 20), chapterTitle: "读者甲 发表于 2026-5-1"),
                .text(String(repeating: "第一章 内容。", count: 80), chapterTitle: "第一章"),
            ],
            segmentSources: [
                NovelReaderSegmentSource(ownerPostID: "100", isAuthorReplyToOther: true),
                NovelReaderSegmentSource(ownerPostID: "101"),
            ]
        )
        let layout = NovelReaderLayout(width: 320, height: 568)
        var session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: layout
        )
        let replySurface = try XCTUnwrap(session.viewportSurfacesForTesting.first { surface in
            surface.ranges.contains { $0.segmentIndex == 0 }
        })

        session.updateVerticalViewportPosition(surfaceOrdinal: replySurface.surfaceOrdinal, intraSurfaceProgress: 0.5)
        let replyPosition = try XCTUnwrap(session.captureNovelReadingPosition())
        session.consumeCommittedLayoutResult(
            try committedLayoutResult(
                document: document,
                settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false, readingMode: .vertical),
                layout: layout
            ),
            preferredSurfaceOrdinal: session.snapshot.selectedSurfaceOrdinal,
            preferredResumePoint: replyPosition
        )

        let restoredSurface = session.viewportSurfacesForTesting[session.snapshot.selectedSurfaceOrdinal]
        XCTAssertTrue(restoredSurface.ranges.contains { $0.segmentIndex == 1 })
        XCTAssertFalse(session.viewportSurfacesForTesting.flatMap(\.ranges).contains { $0.segmentIndex == 0 })
        XCTAssertEqual(restoredSurface.chapterTitle, "第一章")
        XCTAssertEqual(session.snapshot.currentSurfaceIntraProgress, 0, accuracy: 0.001)
    }

    func testLeftToRightTwoPageSpreadNormalizesSelectionToRightPage() throws {
        let document = NovelReaderProjection(
            threadID: "9002",
            view: 1,
            maxView: 1,
            segments: (0 ..< 6).map { .image(URL(string: "https://example.com/\($0).jpg")!, chapterTitle: "第一章") }
        )
        let settings = NovelReaderAppearanceSettings(
            showsTwoPagesInLandscapeOnPad: true,
            readingMode: .paged
        )
        let landscapeLayout = NovelReaderLayout(width: 844, height: 390, readingMode: .paged)
        var session = NovelReadingSession(
            document: document,
            settings: settings,
            layout: landscapeLayout,
            usesPadPresentation: true
        )

        session.selectSurface(3)

        XCTAssertEqual(
            session.spreadsForTesting.map { "\($0.leftSurfaceIndex)-\($0.rightSurfaceIndex.map(String.init) ?? "nil")" },
            ["0-1", "2-3", "4-5"]
        )
        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, 3)
    }

    func testRightToLeftTwoPageSpreadNormalizesSelectionToLeftPage() throws {
        let document = NovelReaderProjection(
            threadID: "9002",
            view: 1,
            maxView: 1,
            segments: (0 ..< 6).map { .image(URL(string: "https://example.com/\($0).jpg")!, chapterTitle: "第一章") }
        )
        let settings = NovelReaderAppearanceSettings(
            showsTwoPagesInLandscapeOnPad: true,
            readingMode: .paged,
            pageTurnDirection: .rightToLeft
        )
        let landscapeLayout = NovelReaderLayout(width: 844, height: 390, readingMode: .paged)
        var session = NovelReadingSession(
            document: document,
            settings: settings,
            layout: landscapeLayout,
            usesPadPresentation: true
        )

        session.selectSurface(3)

        XCTAssertEqual(
            session.spreadsForTesting.map { "\($0.leftSurfaceIndex)-\($0.rightSurfaceIndex.map(String.init) ?? "nil")" },
            ["0-1", "2-3", "4-5"]
        )
        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, 2)
    }

    func testTwoPageSpreadRequestsNextWebViewPageAfterLastCompleteSpread() throws {
        let document = NovelReaderProjection(
            threadID: "9002",
            view: 1,
            maxView: 2,
            segments: (0 ..< 6).map { .image(URL(string: "https://example.com/\($0).jpg")!, chapterTitle: "第一章") }
        )
        let settings = NovelReaderAppearanceSettings(
            showsTwoPagesInLandscapeOnPad: true,
            readingMode: .paged
        )
        let landscapeLayout = NovelReaderLayout(width: 844, height: 390, readingMode: .paged)
        var session = NovelReadingSession(
            document: document,
            settings: settings,
            layout: landscapeLayout,
            usesPadPresentation: true
        )

        session.selectSurface(5)
        let request = session.jumpRelativeSurface(1)

        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, 5)
        XCTAssertEqual(request, .loadView(view: 2, preferredSurfaceOrdinal: 0, resumePoint: nil))
    }
}

// makeNovelDocument(view:maxView:segments:) 已收敛到 YamiboXTestSupport
// (与 NovelReadingSessionTests 的副本逐字节一致)。

private extension NovelReadingSession {
    init(
        document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        preferredSurfaceOrdinal: Int = 0,
        resumePoint: NovelResumePoint? = nil,
        usesPadPresentation: Bool = false,
        currentAuthorID: String? = nil,
        pagination: @escaping NovelTextLayoutFixture = NovelTextLayout.layout
    ) {
        let layoutResult = try! committedLayoutResult(
            document: document,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            pagination: pagination
        )
        self.init(
            projection: document,
            layoutResult: layoutResult,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            resumePoint: resumePoint,
            currentAuthorID: currentAuthorID,
            usesPagedSpread: committedUsesPagedSpread(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            ),
            pageTurnDirection: settings.pageTurnDirection
        )
    }

    init(
        validating document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        preferredSurfaceOrdinal: Int = 0,
        resumePoint: NovelResumePoint? = nil,
        usesPadPresentation: Bool = false,
        currentAuthorID: String? = nil,
        pagination: @escaping NovelTextLayoutFixture = NovelTextLayout.layout
    ) throws {
        let layoutResult = try committedLayoutResult(
            document: document,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            pagination: pagination
        )
        try self.init(
            validating: document,
            layoutResult: layoutResult,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            resumePoint: resumePoint,
            currentAuthorID: currentAuthorID,
            usesPagedSpread: committedUsesPagedSpread(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            ),
            pageTurnDirection: settings.pageTurnDirection
        )
    }
}

private func committedLayoutResult(
    document: NovelReaderProjection,
    settings: NovelReaderAppearanceSettings,
    layout: NovelReaderLayout,
    usesPadPresentation: Bool = false,
    pagination: NovelTextLayoutFixture = NovelTextLayout.layout
) throws -> NovelTextLayoutResult {
    try pagination(
        document,
        settings,
        layout.novelTextBoxLayout(
            settings: settings,
            usesPadPresentation: usesPadPresentation
        )
    )
}

private func committedUsesPagedSpread(
    settings: NovelReaderAppearanceSettings,
    layout: NovelReaderLayout,
    usesPadPresentation: Bool
) -> Bool {
    settings.readingMode == .paged &&
        settings.showsTwoPagesInLandscapeOnPad &&
        usesPadPresentation &&
        layout.width > layout.height
}
#endif

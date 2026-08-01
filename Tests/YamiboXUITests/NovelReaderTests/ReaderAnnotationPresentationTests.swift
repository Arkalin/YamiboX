import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@Test func annotationCapsuleStaysHiddenUntilTheWorkHasSomethingToShow() {
    let empty = ReaderAnnotationCapsulePresentation(bookmarkCount: 0, likeCount: 0)
    #expect(empty.isVisible == false)

    #expect(ReaderAnnotationCapsulePresentation(bookmarkCount: 1, likeCount: 0).isVisible)
    #expect(ReaderAnnotationCapsulePresentation(bookmarkCount: 0, likeCount: 1).isVisible)
}

@Test func annotationCapsuleShowsOneCombinedCountAndCapsIt() {
    let mixed = ReaderAnnotationCapsulePresentation(bookmarkCount: 3, likeCount: 12)
    #expect(mixed.totalCount == 15)
    #expect(mixed.countText == "15")

    let atLimit = ReaderAnnotationCapsulePresentation(bookmarkCount: 99, likeCount: 0)
    #expect(atLimit.countText == "99")

    // Past the cap the trailing slot must stop growing, or it squeezes the
    // title on a small screen.
    let overLimit = ReaderAnnotationCapsulePresentation(bookmarkCount: 90, likeCount: 30)
    #expect(overLimit.countText == "99+")
}

@Test func annotationCapsuleClampsNegativeCounts() {
    let presentation = ReaderAnnotationCapsulePresentation(bookmarkCount: -4, likeCount: -1)
    #expect(presentation.totalCount == 0)
    #expect(presentation.isVisible == false)
}

@Test func annotationCapsuleOpensOnBookmarksUnlessOnlyLikesExist() {
    let both = ReaderAnnotationCapsulePresentation(bookmarkCount: 2, likeCount: 5)
    #expect(both.initialSegment(remembering: nil) == .bookmarks)

    // Landing on an empty first screen would be pointless when the work only
    // has likes.
    let likesOnly = ReaderAnnotationCapsulePresentation(bookmarkCount: 0, likeCount: 5)
    #expect(likesOnly.initialSegment(remembering: nil) == .likes)

    // A remembered choice always wins — reopening returns where the user was.
    #expect(likesOnly.initialSegment(remembering: .bookmarks) == .bookmarks)
    #expect(both.initialSegment(remembering: .likes) == .likes)
}

@Test func readerLibraryPanelPlacesChaptersBeforeTheAnnotationTabsOnlyWhenAvailable() {
    #expect(
        ReaderLibraryPanelTab.available(includingChapters: true)
            == [.chapters, .bookmarks, .likes]
    )
    #expect(
        ReaderLibraryPanelTab.available(includingChapters: false)
            == [.bookmarks, .likes]
    )

    // The remembered annotation destination stays separate from the chapter
    // entry point, so reopening from the bookmarks-and-likes capsule retains
    // the tab the reader last used there.
    #expect(ReaderLibraryPanelTab(annotationSegment: .bookmarks) == .bookmarks)
    #expect(ReaderLibraryPanelTab(annotationSegment: .likes) == .likes)
}

@Test func bookmarkRowLeadsWithTheBodySnapshotForNovels() {
    // A reflow reader has no stable page number, so the snapshot is the only
    // thing that tells two bookmarks in one chapter apart.
    let item = BookmarkItem(
        workKey: .novel(threadID: "1"),
        anchor: .novel(
            NovelBookmarkAnchor(
                chapterIdentity: NovelChapterIdentity(rawValue: "post:1#chapter:0"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "post:1#chapter:0#text:0"),
                displayedTextOffset: 10,
                view: 1,
                chapterOrdinal: 0,
                chapterTitle: "第三章"
            )
        ),
        excerptText: "她站在门口，久久没有开口。"
    )

    let row = ReaderBookmarkRowPresentation(item: item, relativeDateText: "3 天前")

    #expect(row.primaryText == "她站在门口，久久没有开口。")
    #expect(row.secondaryText == "第三章 · 3 天前")
}

@Test func bookmarkRowFallsBackToTheChapterTitleWhenNoSnapshotWasCaptured() {
    let item = BookmarkItem(
        workKey: .novel(threadID: "1"),
        anchor: .novel(
            NovelBookmarkAnchor(
                chapterIdentity: nil,
                textSegmentIdentity: nil,
                displayedTextOffset: 0,
                view: 1,
                chapterOrdinal: 0,
                chapterTitle: "第三章"
            )
        ),
        excerptText: "   "
    )

    let row = ReaderBookmarkRowPresentation(item: item, relativeDateText: "3 天前")

    // The chapter title moved up into the primary slot, so it must not be
    // repeated in the secondary line.
    #expect(row.primaryText == "第三章")
    #expect(row.secondaryText == "3 天前")
}

@Test func bookmarkRowLeadsWithThePageNumberForManga() {
    // Manga pages DO have a stable index, which is why the manga row does not
    // need a body snapshot at all.
    let item = BookmarkItem(
        workKey: .mangaTitle(cleanBookName: "书名"),
        anchor: .manga(
            MangaBookmarkAnchor(
                chapterTID: "900",
                pageLocalIndex: 4,
                globalPageIndex: 20,
                chapterTitle: "第 2 话"
            )
        )
    )

    let row = ReaderBookmarkRowPresentation(item: item, relativeDateText: "刚刚")

    #expect(row.primaryText.hasPrefix("第 2 话 · "))
    #expect(row.secondaryText == "刚刚")
}

@Test func verticalScrubberSpansExactlyTheRenderedCapsuleStack() {
    let layout = ReaderBottomChromeLayoutPresentation()

    // The baseline (目录 + 评论 + 设置) must keep its historical value, since
    // the scrubber bottom-aligns with the action row.
    let baseline = layout.progressPanelHeight * 3 + layout.panelSpacing * 3 + layout.actionButtonRowHeight
    #expect(layout.verticalScrubberHeight == baseline)
    #expect(layout.verticalScrubberHeight(capsuleCount: layout.baseStackedCapsuleCount) == baseline)

    // One more capsule adds exactly one capsule plus one gap.
    let withAnnotations = layout.verticalScrubberHeight(capsuleCount: 4)
    let expectedWithAnnotations = baseline + layout.progressPanelHeight + layout.panelSpacing
    #expect(withAnnotations == expectedWithAnnotations)

    // A nonsense count must not produce a negative frame.
    let degenerate = layout.verticalScrubberHeight(capsuleCount: 0)
    let expectedDegenerate = layout.progressPanelHeight + layout.panelSpacing + layout.actionButtonRowHeight
    #expect(degenerate == expectedDegenerate)
}

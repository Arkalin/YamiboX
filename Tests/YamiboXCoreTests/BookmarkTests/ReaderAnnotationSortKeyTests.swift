import Foundation
import Testing
@testable import YamiboXCore

@Test func readerAnnotationSortKeyOrdersNovelPositionsByViewThenChapterThenSegmentThenOffset() {
    let earlierView = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: 9, textOccurrence: 9, displayedTextOffset: 999)
    let laterView = ReaderAnnotationSortKey.novel(view: 2, chapterOrdinal: 0, textOccurrence: 0, displayedTextOffset: 0)
    #expect(earlierView < laterView)

    let earlierChapter = ReaderAnnotationSortKey.novel(view: 2, chapterOrdinal: 3, textOccurrence: 9, displayedTextOffset: 999)
    let laterChapter = ReaderAnnotationSortKey.novel(view: 2, chapterOrdinal: 4, textOccurrence: 0, displayedTextOffset: 0)
    #expect(earlierChapter < laterChapter)

    let earlierSegment = ReaderAnnotationSortKey.novel(view: 2, chapterOrdinal: 4, textOccurrence: 0, displayedTextOffset: 999)
    let laterSegment = ReaderAnnotationSortKey.novel(view: 2, chapterOrdinal: 4, textOccurrence: 1, displayedTextOffset: 0)
    #expect(earlierSegment < laterSegment)

    let earlierOffset = ReaderAnnotationSortKey.novel(view: 2, chapterOrdinal: 4, textOccurrence: 1, displayedTextOffset: 10)
    let laterOffset = ReaderAnnotationSortKey.novel(view: 2, chapterOrdinal: 4, textOccurrence: 1, displayedTextOffset: 11)
    #expect(earlierOffset < laterOffset)
}

@Test func readerAnnotationSortKeyClampsInsteadOfCarryingIntoTheBandAbove() {
    // A value past its band must not push into the next band, or an extreme
    // offset would sort as if it belonged to a later segment entirely.
    let hugeOffset = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: 0, textOccurrence: 0, displayedTextOffset: Int.max)
    let nextSegment = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: 0, textOccurrence: 1, displayedTextOffset: 0)
    #expect(hugeOffset < nextSegment)

    let hugeOccurrence = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: 0, textOccurrence: Int.max, displayedTextOffset: 0)
    let nextChapter = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: 1, textOccurrence: 0, displayedTextOffset: 0)
    #expect(hugeOccurrence < nextChapter)

    let hugeChapter = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: Int.max, textOccurrence: 0, displayedTextOffset: 0)
    let nextView = ReaderAnnotationSortKey.novel(view: 2, chapterOrdinal: 0, textOccurrence: 0, displayedTextOffset: 0)
    #expect(hugeChapter < nextView)

    // Negative inputs clamp to the band floor rather than flipping the sign of
    // the whole key.
    let negative = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: -5, textOccurrence: -5, displayedTextOffset: -5)
    let zero = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: 0, textOccurrence: 0, displayedTextOffset: 0)
    #expect(negative == zero)
}

@Test func readerAnnotationSortKeyReadsTextOccurrenceOffASegmentIdentity() {
    let fromIdentity = ReaderAnnotationSortKey.novel(
        view: 1,
        chapterOrdinal: 0,
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "post:9#chapter:0#text:7"),
        displayedTextOffset: 3
    )
    let explicit = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: 0, textOccurrence: 7, displayedTextOffset: 3)
    #expect(fromIdentity == explicit)

    // An identity with no occurrence suffix falls back to 0 rather than
    // producing an unordered key.
    let malformed = ReaderAnnotationSortKey.novel(
        view: 1,
        chapterOrdinal: 0,
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "no-suffix"),
        displayedTextOffset: 3
    )
    let zeroOccurrence = ReaderAnnotationSortKey.novel(view: 1, chapterOrdinal: 0, textOccurrence: 0, displayedTextOffset: 3)
    #expect(malformed == zeroOccurrence)
}

@Test func readerAnnotationSortKeyOrdersMangaByGlobalPageIndex() {
    // `globalIndex` already spans the whole work, so reading order needs no
    // packing — and a page late in one chapter must still sort before the
    // first page of the next.
    let earlyChapterLastPage = ReaderAnnotationSortKey.manga(globalPageIndex: 41)
    let nextChapterFirstPage = ReaderAnnotationSortKey.manga(globalPageIndex: 42)
    #expect(earlyChapterLastPage < nextChapterFirstPage)

    let clampedNegative = ReaderAnnotationSortKey.manga(globalPageIndex: -3)
    #expect(clampedNegative == ReaderAnnotationSortKey.manga(globalPageIndex: 0))
}

@Test func readerAnnotationSortKeyDerivesFromAnAnchorPayload() {
    let novelAnchor = BookmarkAnchorPayload.novel(
        NovelBookmarkAnchor(
            chapterIdentity: NovelChapterIdentity(rawValue: "post:9#chapter:0"),
            textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "post:9#chapter:0#text:2"),
            displayedTextOffset: 40,
            view: 3,
            chapterOrdinal: 5
        )
    )
    let expectedNovel = ReaderAnnotationSortKey.novel(view: 3, chapterOrdinal: 5, textOccurrence: 2, displayedTextOffset: 40)
    #expect(ReaderAnnotationSortKey.of(novelAnchor) == expectedNovel)

    let mangaAnchor = BookmarkAnchorPayload.manga(
        MangaBookmarkAnchor(chapterTID: "900", pageLocalIndex: 7, globalPageIndex: 31)
    )
    let expectedManga = ReaderAnnotationSortKey.manga(globalPageIndex: 31)
    #expect(ReaderAnnotationSortKey.of(mangaAnchor) == expectedManga)
}

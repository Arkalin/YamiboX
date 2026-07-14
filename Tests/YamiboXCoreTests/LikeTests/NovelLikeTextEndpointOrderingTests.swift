import Foundation
import Testing
@testable import YamiboXCore

@Test func novelLikeTextEndpointOrderingExtractsOccurrenceFromSegmentIdentity() {
    #expect(NovelLikeTextEndpointOrdering.occurrence(of: "chapter-1#text:5") == 5)
    #expect(NovelLikeTextEndpointOrdering.occurrence(of: "chapter-1#image:2") == 2)
    #expect(NovelLikeTextEndpointOrdering.occurrence(of: "chapter-1") == nil)
}

@Test func novelLikeTextEndpointOrderingComparesOffsetsWithinSameSegment() {
    let segment = "chapter-1#text:0"
    let earlier = NovelLikeTextEndpoint(segmentIdentity: segment, offset: 2)
    let later = NovelLikeTextEndpoint(segmentIdentity: segment, offset: 8)

    #expect(NovelLikeTextEndpointOrdering.compare(earlier, later) == .orderedAscending)
    #expect(NovelLikeTextEndpointOrdering.compare(later, earlier) == .orderedDescending)
    #expect(NovelLikeTextEndpointOrdering.compare(earlier, earlier) == .orderedSame)
}

@Test func novelLikeTextEndpointOrderingComparesAcrossSegmentsInSameChapter() {
    let first = NovelLikeTextEndpoint(segmentIdentity: "chapter-1#text:0", offset: 99)
    let second = NovelLikeTextEndpoint(segmentIdentity: "chapter-1#text:1", offset: 0)

    #expect(NovelLikeTextEndpointOrdering.compare(first, second) == .orderedAscending)
    #expect(NovelLikeTextEndpointOrdering.compare(second, first) == .orderedDescending)
}

@Test func novelLikeTextEndpointOrderingReturnsNilAcrossChapters() {
    let first = NovelLikeTextEndpoint(segmentIdentity: "chapter-1#text:0", offset: 0)
    let second = NovelLikeTextEndpoint(segmentIdentity: "chapter-2#text:0", offset: 0)

    #expect(NovelLikeTextEndpointOrdering.compare(first, second) == nil)
}

@Test func novelLikeTextEndpointOrderingMergesTouchingAndOverlappingRanges() {
    let chapter = NovelChapterIdentity(rawValue: "chapter-1")
    let segment = NovelTextSegmentIdentity(rawValue: "chapter-1#text:0")
    let first = NovelTextLikeAnchor(chapterIdentity: chapter, textSegmentIdentity: segment, range: NovelCharacterRange(location: 0, length: 10), view: 1, resolvedAuthorID: nil)
    let touching = NovelTextLikeAnchor(chapterIdentity: chapter, textSegmentIdentity: segment, range: NovelCharacterRange(location: 10, length: 5), view: 1, resolvedAuthorID: nil)
    let overlapping = NovelTextLikeAnchor(chapterIdentity: chapter, textSegmentIdentity: segment, range: NovelCharacterRange(location: 5, length: 10), view: 1, resolvedAuthorID: nil)

    #expect(NovelLikeTextEndpointOrdering.overlapsOrTouches(first, touching))
    #expect(NovelLikeTextEndpointOrdering.overlapsOrTouches(touching, first))
    #expect(NovelLikeTextEndpointOrdering.overlapsOrTouches(first, overlapping))
}

@Test func novelLikeTextEndpointOrderingDoesNotMergeGappedRanges() {
    let chapter = NovelChapterIdentity(rawValue: "chapter-1")
    let segment = NovelTextSegmentIdentity(rawValue: "chapter-1#text:0")
    let first = NovelTextLikeAnchor(chapterIdentity: chapter, textSegmentIdentity: segment, range: NovelCharacterRange(location: 0, length: 5), view: 1, resolvedAuthorID: nil)
    let gapped = NovelTextLikeAnchor(chapterIdentity: chapter, textSegmentIdentity: segment, range: NovelCharacterRange(location: 10, length: 5), view: 1, resolvedAuthorID: nil)

    #expect(!NovelLikeTextEndpointOrdering.overlapsOrTouches(first, gapped))
}

@Test func novelLikeTextEndpointOrderingNeverMergesAcrossChapters() {
    let first = NovelTextLikeAnchor(
        chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
        range: NovelCharacterRange(location: 0, length: 5),
        view: 1,
        resolvedAuthorID: nil
    )
    let second = NovelTextLikeAnchor(
        chapterIdentity: NovelChapterIdentity(rawValue: "chapter-2"),
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-2#text:0"),
        range: NovelCharacterRange(location: 0, length: 5),
        view: 1,
        resolvedAuthorID: nil
    )

    #expect(!NovelLikeTextEndpointOrdering.overlapsOrTouches(first, second))
}

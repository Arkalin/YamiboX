import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@Suite("MangaReaderTests: Vertical Image Prefetch Plan")
struct MangaVerticalImagePrefetchTests {
    @Test func windowOrderAndBoundaries() throws {
        let pages = try makeVerticalPrefetchPages()
        #expect(indexes(pages, visible: [3]) == [4, 2, 5])
        #expect(indexes(pages, visible: [0]) == [1, 2])
        #expect(indexes(pages, visible: [8]) == [7])
        #expect(indexes(pages, visible: [7]) == [8, 6])
        #expect(indexes(pages, visible: [4, 2, 3]) == [5, 1, 6])
        #expect(indexes([], visible: [0]) == [])
        #expect(indexes(Array(pages.prefix(1)), visible: [0]) == [])
    }

    @Test func initialPlacementAndInvalidVisibleIndexes() throws {
        let pages = try makeVerticalPrefetchPages()
        #expect(indexes(pages, visible: [], fallback: 5) == [6, 4, 7])
        #expect(indexes(pages, visible: [-1, 99], fallback: 3) == [4, 2, 5])
        #expect(indexes(pages, visible: [3, 99], fallback: 0) == [4, 2, 5])
        #expect(indexes(pages, visible: [], fallback: 99) == [7])
        #expect(indexes(pages, visible: [], fallback: -1) == [1, 2])
        #expect(indexes(pages, visible: []) == [])
    }

    @Test func duplicateURLsAreExcludedIncludingVisibleImages() throws {
        var pages = try makeVerticalPrefetchPages()
        pages[2].imageURL = pages[4].imageURL
        #expect(indexes(pages, visible: [3]) == [4, 5])
        pages[4].imageURL = pages[3].imageURL
        pages[5].imageURL = pages[3].imageURL
        #expect(indexes(pages, visible: [3]) == [2])
    }

    private func indexes(_ pages: [MangaReaderPageProjection], visible: [Int], fallback: Int? = nil) -> [Int] {
        MangaVerticalImagePrefetchPlan.pagesToPrefetch(
            pages: pages, visiblePageIndexes: visible, fallbackPageIndex: fallback
        ).map(\.globalIndex)
    }
}

func makeVerticalPrefetchPages(count: Int = 9) throws -> [MangaReaderPageProjection] {
    try (0..<count).map { index in
        var page = try makePipelinePage()
        page.globalIndex = index
        page.localIndex = index
        page.chapterPageCount = count
        page.imageURL = ReaderImageCacheFixture.source(index).url
        return page
    }
}

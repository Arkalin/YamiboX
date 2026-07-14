import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@Suite("MangaReaderTests: Paged Reading Plan")
struct MangaPagedReadingPlanTests {
    @Test func planKeepsSinglePageIdentityForCurrentPageLookup() throws {
        let pages = try makePagedPlanPages()
        let plan = MangaPagedReadingPlan(pages: pages, currentPageIndex: 1)

        #expect(plan.pages.map(\.id) == ["700#0", "700#1", "700#2"])
        #expect(plan.currentPage?.id == "700#1")
        #expect(plan.globalIndex(forPageAt: 1) == 1)
        #expect(plan.globalIndex(forPageAt: 9) == nil)
    }

    @Test func planClampsInitialCurrentPageWithoutCreatingSpreadState() throws {
        let pages = try makePagedPlanPages()
        let leadingPlan = MangaPagedReadingPlan(pages: pages, currentPageIndex: -5)
        let trailingPlan = MangaPagedReadingPlan(pages: pages, currentPageIndex: 99)

        #expect(leadingPlan.currentPageIndex == 0)
        #expect(leadingPlan.currentPage?.localIndex == 0)
        #expect(trailingPlan.currentPageIndex == 2)
        #expect(trailingPlan.currentPage?.localIndex == 2)
        #expect(trailingPlan.pages.map(\.localIndex) == [0, 1, 2])
    }

    @Test func planBuildsTwoPageSpreadsWithoutReplacingPageLevelCurrentPage() throws {
        let pages = try makePagedPlanPages(pageCountsByTID: [("700", 3), ("701", 2)])
        let plan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 1,
            pageTurnDirection: .leftToRight,
            usesTwoPageSpread: true
        )

        #expect(plan.spreads.count == 3)
        #expect(plan.currentPage?.id == "700#1")
        #expect(plan.currentSpreadIndex == 0)
        #expect(plan.globalIndex(forSpreadAt: 0) == 1)

        #expect(plan.spreads[0].leftPage?.id == "700#0")
        #expect(plan.spreads[0].rightPage?.id == "700#1")
        #expect(plan.spreads[0].preferredPage.id == "700#1")

        #expect(plan.spreads[1].leftPage?.id == "700#2")
        #expect(plan.spreads[1].rightPage == nil)
        #expect(plan.spreads[1].pageIndexes == [2])
        #expect(plan.spreads[1].pageIndexForHorizontalLocation(25, width: 100) == 2)
        #expect(plan.spreads[1].pageIndexForHorizontalLocation(75, width: 100) == nil)

        #expect(plan.spreads[2].leftPage?.id == "701#0")
        #expect(plan.spreads[2].rightPage?.id == "701#1")
        #expect(plan.spreads[2].pageIndexes == [3, 4])
    }

    @Test func planOrdersTwoPageSpreadsByPageTurnDirection() throws {
        let pages = try makePagedPlanPages(pageCountsByTID: [("700", 2)])
        let ltrPlan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 0,
            pageTurnDirection: .leftToRight,
            usesTwoPageSpread: true
        )
        let rtlPlan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 0,
            pageTurnDirection: .rightToLeft,
            usesTwoPageSpread: true
        )

        #expect(ltrPlan.spreads[0].leftPage?.id == "700#0")
        #expect(ltrPlan.spreads[0].rightPage?.id == "700#1")
        #expect(ltrPlan.pageIndex(forSpreadAt: 0) == 1)
        #expect(ltrPlan.globalIndex(forSpreadAt: 0) == 1)
        #expect(rtlPlan.spreads[0].leftPage?.id == "700#1")
        #expect(rtlPlan.spreads[0].rightPage?.id == "700#0")
        #expect(rtlPlan.pageIndex(forSpreadAt: 0) == 1)
        #expect(rtlPlan.globalIndex(forSpreadAt: 0) == 1)
    }

    @Test func planDisplaysLogicalChapterPageRangeForTwoPageSpread() throws {
        let pages = try makePagedPlanPages(pageCountsByTID: [("700", 4)])
        let plan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 1,
            pageTurnDirection: .rightToLeft,
            usesTwoPageSpread: true
        )

        #expect(plan.currentChapterPageLabel == "1-2")
        #expect(plan.chapterPageLabel(forSpreadAt: 0) == "1-2")
        #expect(plan.chapterPageLabel(forSpreadAt: 1) == "3-4")
    }

    @Test func planPlacesRightToLeftOddTailOnRightWithoutFakeLeftPage() throws {
        let pages = try makePagedPlanPages(pageCountsByTID: [("700", 3)])
        let plan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 2,
            pageTurnDirection: .rightToLeft,
            usesTwoPageSpread: true
        )

        #expect(plan.spreads[1].leftPage == nil)
        #expect(plan.spreads[1].rightPage?.id == "700#2")
        #expect(plan.spreads[1].pageIndexes == [2])
        #expect(plan.spreads[1].pageIndexForHorizontalLocation(25, width: 100) == nil)
        #expect(plan.spreads[1].pageIndexForHorizontalLocation(75, width: 100) == 2)
        #expect(plan.currentChapterPageLabel == "3")
    }

    @Test func pageCurlSequenceMapsSinglePagesThroughPhysicalBookOrder() throws {
        let pages = try makePagedPlanPages(pageCountsByTID: [("700", 3)])
        let ltrPlan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 0,
            pageTurnDirection: .leftToRight,
            usesTwoPageSpread: false
        )
        let rtlPlan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 0,
            pageTurnDirection: .rightToLeft,
            usesTwoPageSpread: false
        )

        let ltrSequence = MangaPagedPageCurlSequence(plan: ltrPlan)
        let rtlSequence = MangaPagedPageCurlSequence(plan: rtlPlan)

        #expect(ltrSequence.pageCount == 3)
        #expect(ltrSequence.leaves.map(\.pageIndex) == [0, 1, 2])
        #expect(ltrSequence.leafIndexes(forSelectionIndex: 1) == [1])
        #expect(ltrSequence.selectionIndex(forLeafIndexes: [2]) == 2)
        #expect(ltrSequence.globalIndex(forSelectionIndex: 2) == 2)
        #expect(ltrSequence.leafIndex(after: 1) == 2)

        #expect(rtlSequence.pageCount == 3)
        #expect(rtlSequence.leaves.map(\.pageIndex) == [2, 1, 0])
        #expect(rtlSequence.leafIndexes(forSelectionIndex: 0) == [2])
        #expect(rtlSequence.selectionIndex(forLeafIndexes: [0]) == 2)
        #expect(rtlSequence.globalIndex(forSelectionIndex: 2) == 2)
        #expect(rtlSequence.leafIndex(before: 2) == 1)
    }

    @Test func pageCurlSequenceMapsTwoPageBlankLeavesWithoutCreatingPagePositions() throws {
        let pages = try makePagedPlanPages(pageCountsByTID: [("700", 3), ("701", 2)])
        let ltrPlan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 2,
            pageTurnDirection: .leftToRight,
            usesTwoPageSpread: true
        )
        let rtlPlan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 2,
            pageTurnDirection: .rightToLeft,
            usesTwoPageSpread: true
        )

        let ltrSequence = MangaPagedPageCurlSequence(plan: ltrPlan)
        let rtlSequence = MangaPagedPageCurlSequence(plan: rtlPlan)

        #expect(ltrSequence.pageCount == 3)
        #expect(ltrSequence.leafIndexes(forSelectionIndex: 1) == [2, 3])
        #expect(ltrSequence.leaves.map(\.pageIndex) == [0, 1, 2, nil, 3, 4])
        #expect(ltrSequence.selectionIndex(forLeafIndexes: [3]) == 1)
        #expect(ltrSequence.pageIndex(forSelectionIndex: 1) == 2)
        #expect(ltrSequence.globalIndex(forSelectionIndex: 1) == 2)
        #expect(ltrSequence.pageIndex(forSelectionIndex: 0) == 1)
        #expect(ltrSequence.globalIndex(forSelectionIndex: 0) == 1)

        #expect(rtlSequence.pageCount == 3)
        #expect(rtlSequence.leafIndexes(forSelectionIndex: 1) == [2, 3])
        #expect(rtlSequence.leaves.map(\.pageIndex) == [4, 3, nil, 2, 1, 0])
        #expect(rtlSequence.selectionIndex(forLeafIndexes: [2]) == 1)
        #expect(rtlSequence.pageIndex(forSelectionIndex: 1) == 2)
        #expect(rtlSequence.globalIndex(forSelectionIndex: 1) == 2)
        #expect(rtlSequence.leaves[2].pageIndex == nil)
    }

    @Test func pageCurlSequenceProvidesBlankPresentationLeavesForEmptyPlans() {
        let singlePageSequence = MangaPagedPageCurlSequence(
            plan: MangaPagedReadingPlan(
                pages: [],
                currentPageIndex: nil,
                pageTurnDirection: .leftToRight,
                usesTwoPageSpread: false
            )
        )
        let spreadSequence = MangaPagedPageCurlSequence(
            plan: MangaPagedReadingPlan(
                pages: [],
                currentPageIndex: nil,
                pageTurnDirection: .rightToLeft,
                usesTwoPageSpread: true
            )
        )

        #expect(singlePageSequence.pageCount == 1)
        #expect(singlePageSequence.leafIndexes(forSelectionIndex: 0) == [0])
        #expect(singlePageSequence.leaves.map(\.pageIndex) == [nil])
        #expect(singlePageSequence.pageIndex(forSelectionIndex: 0) == nil)
        #expect(singlePageSequence.globalIndex(forSelectionIndex: 0) == nil)

        #expect(spreadSequence.pageCount == 1)
        #expect(spreadSequence.leafIndexes(forSelectionIndex: 0) == [0, 1])
        #expect(spreadSequence.leaves.map(\.pageIndex) == [nil, nil])
        #expect(spreadSequence.pageIndex(forSelectionIndex: 0) == nil)
        #expect(spreadSequence.globalIndex(forSelectionIndex: 0) == nil)
    }

    @Test func pageCurlSequenceRemapsOldLeavesAfterAdjacentChapterPrefetchChangesPhysicalOrder() throws {
        let initialPages = try makePagedPlanPages(pageCountsByTID: [("700", 3)])
        let prefetchedPages = try makePagedPlanPages(pageCountsByTID: [("700", 3), ("701", 2)])
        let initialSequence = MangaPagedPageCurlSequence(
            plan: MangaPagedReadingPlan(
                pages: initialPages,
                currentPageIndex: 0,
                pageTurnDirection: .rightToLeft,
                usesTwoPageSpread: false
            )
        )
        let prefetchedSequence = MangaPagedPageCurlSequence(
            plan: MangaPagedReadingPlan(
                pages: prefetchedPages,
                currentPageIndex: 0,
                pageTurnDirection: .rightToLeft,
                usesTwoPageSpread: false
            )
        )
        let visibleLeaf = try #require(
            initialSequence.leaves.first { $0.pageID == initialPages[0].id }
        )

        #expect(initialSequence.leaves.map(\.pageID) == ["700#2", "700#1", "700#0"])
        #expect(prefetchedSequence.leaves.map(\.pageID) == ["701#1", "701#0", "700#2", "700#1", "700#0"])
        #expect(prefetchedSequence.leafIndex(matching: visibleLeaf) == 4)
        #expect(prefetchedSequence.leafIndex(before: visibleLeaf) == 3)
        #expect(prefetchedSequence.leafIndex(after: visibleLeaf) == nil)
    }

    @Test func pageCurlSpineConfigurationDoesNotDisableDoubleSidedWhileCurrentSpineIsMid() {
        let rotatingToSinglePage = MangaPagedPageCurlSpineConfiguration.configuration(
            usesTwoPageSpread: false,
            currentSpineLocation: .mid
        )
        let stableSinglePage = MangaPagedPageCurlSpineConfiguration.configuration(
            usesTwoPageSpread: false,
            currentSpineLocation: .min
        )
        let rotatingToTwoPage = MangaPagedPageCurlSpineConfiguration.configuration(
            usesTwoPageSpread: true,
            currentSpineLocation: .min
        )

        #expect(rotatingToSinglePage.spineLocation == .min)
        #expect(rotatingToSinglePage.doubleSidedUpdate == nil)
        #expect(stableSinglePage.spineLocation == .min)
        #expect(stableSinglePage.doubleSidedUpdate == false)
        #expect(rotatingToTwoPage.spineLocation == .mid)
        #expect(rotatingToTwoPage.doubleSidedUpdate == true)
    }

    @Test func pageCurlSelectionResolverIgnoresAlreadyAppliedPlacementAfterPageTurn() throws {
        let pages = try makePagedPlanPages(pageCountsByTID: [("700", 3)])
        let placement = MangaNovelReaderViewportPlacement(targetPageIndex: 0, revision: 1)
        var resolver = MangaPagedPageCurlSelectionResolver()

        let initialPlan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 0,
            pageTurnDirection: .rightToLeft,
            usesTwoPageSpread: false
        )
        #expect(resolver.selectionIndex(plan: initialPlan, viewportPlacement: placement) == 0)

        let turnedPlan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 1,
            pageTurnDirection: .rightToLeft,
            usesTwoPageSpread: false
        )
        #expect(resolver.selectionIndex(plan: turnedPlan, viewportPlacement: placement) == 1)

        let jumpPlacement = MangaNovelReaderViewportPlacement(targetPageIndex: 2, revision: 2)
        #expect(resolver.selectionIndex(plan: turnedPlan, viewportPlacement: jumpPlacement) == 2)
    }

    @Test func imagePrefetchPlanIncludesAdjacentSinglePageTurnsInRightToLeftMode() throws {
        let pages = try makePagedPlanPages(pageCountsByTID: [("700", 4)])
        let plan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 1,
            pageTurnDirection: .rightToLeft,
            usesTwoPageSpread: false
        )

        let prefetchPages = MangaPagedImagePrefetchPlan.pagesToPrefetch(plan: plan, radius: 1)

        #expect(prefetchPages.map(\.id) == ["700#0", "700#2"])
    }

    @Test func imagePrefetchPlanIncludesBothPagesInAdjacentTwoPageSpreads() throws {
        let pages = try makePagedPlanPages(pageCountsByTID: [("700", 6)])
        let plan = MangaPagedReadingPlan(
            pages: pages,
            currentPageIndex: 2,
            pageTurnDirection: .rightToLeft,
            usesTwoPageSpread: true
        )

        let prefetchPages = MangaPagedImagePrefetchPlan.pagesToPrefetch(plan: plan, radius: 1)

        #expect(prefetchPages.map(\.id) == ["700#0", "700#1", "700#4", "700#5"])
    }
}

private func makePagedPlanPages() throws -> [MangaReaderPageProjection] {
    try makePagedPlanPages(pageCountsByTID: [("700", 3)])
}

private func makePagedPlanPages(pageCountsByTID: [(String, Int)]) throws -> [MangaReaderPageProjection] {
    var globalIndex = 0
    var pages: [MangaReaderPageProjection] = []
    for (tid, pageCount) in pageCountsByTID {
        for localIndex in 0 ..< pageCount {
            pages.append(
                MangaReaderPageProjection(
                    tid: tid,
                    ownerPostID: "post-\(tid)",
                    chapterTitle: "Chapter \(tid)",
                    imageURL: try #require(URL(string: "https://img.example.com/\(tid)-\(localIndex).png")),
                    sourceIdentity: MangaReaderProjectionSourceIdentity(
                        tid: tid,
                        authorID: nil,
                        view: 1
                    ),
                    globalIndex: globalIndex,
                    localIndex: localIndex,
                    chapterPageCount: pageCount
                )
            )
            globalIndex += 1
        }
    }
    return pages
}

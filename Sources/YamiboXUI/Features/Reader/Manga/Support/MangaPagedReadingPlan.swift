import Foundation
import YamiboXCore

struct MangaPageSpread: Hashable, Sendable {
    let index: Int
    let pageIndexes: [Int]
    let leftPageIndex: Int?
    let rightPageIndex: Int?
    let leftPage: MangaReaderPageProjection?
    let rightPage: MangaReaderPageProjection?
    let preferredPageIndex: Int
    let preferredPage: MangaReaderPageProjection

    var id: String {
        [
            String(index),
            leftPage?.id ?? "_",
            rightPage?.id ?? "_",
        ].joined(separator: "|")
    }

    func containsPage(at pageIndex: Int) -> Bool {
        pageIndexes.contains(pageIndex)
    }

    func pageIndexForHorizontalLocation(_ x: CGFloat, width: CGFloat) -> Int? {
        guard leftPageIndex != nil || rightPageIndex != nil else { return nil }
        guard width > 0 else { return leftPageIndex ?? rightPageIndex }
        if let leftPageIndex, let rightPageIndex {
            return x < width / 2 ? leftPageIndex : rightPageIndex
        }
        if let leftPageIndex {
            return x < width / 2 ? leftPageIndex : nil
        }
        if let rightPageIndex {
            return x >= width / 2 ? rightPageIndex : nil
        }
        return nil
    }
}

struct MangaPagedReadingPlan: Hashable, Sendable {
    let pages: [MangaReaderPageProjection]
    let currentPageIndex: Int?
    let pageTurnDirection: MangaPageTurnDirection
    let usesTwoPageSpread: Bool
    let spreads: [MangaPageSpread]
    let currentSpreadIndex: Int?

    init(
        pages: [MangaReaderPageProjection],
        currentPageIndex: Int?,
        pageTurnDirection: MangaPageTurnDirection = .leftToRight,
        usesTwoPageSpread: Bool = false
    ) {
        self.pages = pages
        let clampedCurrentPageIndex = Self.clampedIndex(currentPageIndex, pageCount: pages.count)
        self.currentPageIndex = clampedCurrentPageIndex
        self.pageTurnDirection = pageTurnDirection
        self.usesTwoPageSpread = usesTwoPageSpread
        let spreads = Self.makeSpreads(
            pages: pages,
            currentPageIndex: clampedCurrentPageIndex,
            pageTurnDirection: pageTurnDirection,
            usesTwoPageSpread: usesTwoPageSpread
        )
        self.spreads = spreads
        self.currentSpreadIndex = clampedCurrentPageIndex.flatMap { pageIndex in
            spreads.first { $0.containsPage(at: pageIndex) }?.index
        } ?? Self.clampedIndex(nil, pageCount: spreads.count)
    }

    var currentPage: MangaReaderPageProjection? {
        page(at: currentPageIndex)
    }

    var currentSpread: MangaPageSpread? {
        spread(at: currentSpreadIndex)
    }

    var currentChapterPageLabel: String {
        chapterPageLabel(forSpreadAt: currentSpreadIndex)
            ?? currentPage.map { String(max($0.localIndex + 1, 1)) }
            ?? "1"
    }

    func page(at index: Int?) -> MangaReaderPageProjection? {
        guard let index,
              pages.indices.contains(index) else {
            return nil
        }
        return pages[index]
    }

    func spread(at index: Int?) -> MangaPageSpread? {
        guard let index,
              spreads.indices.contains(index) else {
            return nil
        }
        return spreads[index]
    }

    func chapterPageLabel(forSpreadAt index: Int?) -> String? {
        guard let spread = spread(at: index) else { return nil }
        let pageNumbers = spread.pageIndexes.compactMap { pageIndex -> Int? in
            guard pages.indices.contains(pageIndex) else { return nil }
            return max(pages[pageIndex].localIndex + 1, 1)
        }
        guard let firstPageNumber = pageNumbers.first else { return nil }
        guard let lastPageNumber = pageNumbers.last,
              lastPageNumber != firstPageNumber else {
            return String(firstPageNumber)
        }
        return "\(firstPageNumber)-\(lastPageNumber)"
    }

    func globalIndex(forPageAt index: Int) -> Int? {
        page(at: index)?.globalIndex
    }

    func pageIndex(forSpreadAt index: Int) -> Int? {
        spread(at: index)?.preferredPageIndex
    }

    func globalIndex(forSpreadAt index: Int) -> Int? {
        spread(at: index)?.preferredPage.globalIndex
    }

    func spreadIndex(forPageAt index: Int) -> Int? {
        guard pages.indices.contains(index) else { return nil }
        return spreads.first { $0.containsPage(at: index) }?.index
    }

    func clampedPageIndex(_ index: Int?) -> Int? {
        Self.clampedIndex(index, pageCount: pages.count)
    }

    func clampedSpreadIndex(_ index: Int?) -> Int? {
        Self.clampedIndex(index, pageCount: spreads.count)
    }

    private static func clampedIndex(_ index: Int?, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        return min(max(index ?? 0, 0), pageCount - 1)
    }

    private static func makeSpreads(
        pages: [MangaReaderPageProjection],
        currentPageIndex: Int?,
        pageTurnDirection: MangaPageTurnDirection,
        usesTwoPageSpread: Bool
    ) -> [MangaPageSpread] {
        guard usesTwoPageSpread else {
            return pages.indices.map { pageIndex in
                let page = pages[pageIndex]
                return MangaPageSpread(
                    index: pageIndex,
                    pageIndexes: [pageIndex],
                    leftPageIndex: pageIndex,
                    rightPageIndex: nil,
                    leftPage: page,
                    rightPage: nil,
                    preferredPageIndex: pageIndex,
                    preferredPage: page
                )
            }
        }

        var spreads: [MangaPageSpread] = []
        var pageIndex = pages.startIndex
        while pageIndex < pages.endIndex {
            let firstPageIndex = pageIndex
            let firstPage = pages[firstPageIndex]
            let secondPageIndex = pages.index(after: firstPageIndex)
            let pairsWithSecondPage = secondPageIndex < pages.endIndex &&
                pages[secondPageIndex].tid == firstPage.tid
            let pageIndexes = pairsWithSecondPage
                ? [firstPageIndex, secondPageIndex]
                : [firstPageIndex]
            let leftPageIndex: Int?
            let rightPageIndex: Int?

            if let secondPageIndex = pageIndexes.dropFirst().first {
                switch pageTurnDirection {
                case .leftToRight:
                    leftPageIndex = firstPageIndex
                    rightPageIndex = secondPageIndex
                case .rightToLeft:
                    leftPageIndex = secondPageIndex
                    rightPageIndex = firstPageIndex
                }
            } else {
                switch pageTurnDirection {
                case .leftToRight:
                    leftPageIndex = firstPageIndex
                    rightPageIndex = nil
                case .rightToLeft:
                    leftPageIndex = nil
                    rightPageIndex = firstPageIndex
                }
            }

            let preferredPageIndex: Int = switch pageTurnDirection {
            case .leftToRight:
                rightPageIndex ?? leftPageIndex ?? firstPageIndex
            case .rightToLeft:
                leftPageIndex ?? rightPageIndex ?? firstPageIndex
            }
            let preferredPage = pages[preferredPageIndex]

            spreads.append(
                MangaPageSpread(
                    index: spreads.count,
                    pageIndexes: pageIndexes,
                    leftPageIndex: leftPageIndex,
                    rightPageIndex: rightPageIndex,
                    leftPage: leftPageIndex.map { pages[$0] },
                    rightPage: rightPageIndex.map { pages[$0] },
                    preferredPageIndex: preferredPageIndex,
                    preferredPage: preferredPage
                )
            )
            pageIndex = pageIndexes.last.map { pages.index(after: $0) } ?? pages.index(after: firstPageIndex)
        }
        return spreads
    }
}

enum MangaPagedImagePrefetchPlan {
    static func pagesToPrefetch(
        plan: MangaPagedReadingPlan,
        radius: Int = 1
    ) -> [MangaReaderPageProjection] {
        guard radius > 0,
              let currentSpreadIndex = plan.currentSpreadIndex else {
            return []
        }

        var pages: [MangaReaderPageProjection] = []
        var seenPageIDs = Set<String>()
        for distance in 1 ... radius {
            for spreadIndex in [currentSpreadIndex - distance, currentSpreadIndex + distance] {
                guard let spread = plan.spread(at: spreadIndex) else { continue }
                for pageIndex in spread.pageIndexes {
                    guard let page = plan.page(at: pageIndex),
                          seenPageIDs.insert(page.id).inserted else {
                        continue
                    }
                    pages.append(page)
                }
            }
        }
        return pages
    }
}

struct MangaPagedPageCurlLeaf: Hashable, Sendable {
    let index: Int
    let pageIndex: Int?
    let pageID: String?
    let selectionIndex: Int

    var isBlank: Bool {
        pageIndex == nil
    }
}

struct MangaPagedPageCurlSequence: Equatable, Sendable {
    let plan: MangaPagedReadingPlan
    let leaves: [MangaPagedPageCurlLeaf]
    let usesTwoPageSpread: Bool

    init(plan: MangaPagedReadingPlan) {
        self.plan = plan
        usesTwoPageSpread = plan.usesTwoPageSpread

        if plan.usesTwoPageSpread {
            let leafPairs = plan.spreads.map { spread in
                [
                    MangaPagedPageCurlLeaf(
                        index: 0,
                        pageIndex: spread.leftPageIndex,
                        pageID: spread.leftPage?.id,
                        selectionIndex: spread.index
                    ),
                    MangaPagedPageCurlLeaf(
                        index: 0,
                        pageIndex: spread.rightPageIndex,
                        pageID: spread.rightPage?.id,
                        selectionIndex: spread.index
                    ),
                ]
            }
            leaves = Self.indexedLeaves(
                from: Self.physicalBookOrder(
                    leafGroups: leafPairs,
                    pageTurnDirection: plan.pageTurnDirection
                )
            ).ifEmpty(Self.emptySpreadLeaves)
        } else {
            let pageLeaves = plan.pages.indices.map { pageIndex in
                [
                    MangaPagedPageCurlLeaf(
                        index: 0,
                        pageIndex: pageIndex,
                        pageID: plan.pages[pageIndex].id,
                        selectionIndex: pageIndex
                    ),
                ]
            }
            leaves = Self.indexedLeaves(
                from: Self.physicalBookOrder(
                    leafGroups: pageLeaves,
                    pageTurnDirection: plan.pageTurnDirection
                )
            ).ifEmpty([Self.emptySingleLeaf])
        }
    }

    var pageCount: Int {
        usesTwoPageSpread ? max(leaves.count / 2, 1) : max(leaves.count, 1)
    }

    func leafIndexes(forSelectionIndex selectionIndex: Int) -> [Int] {
        guard !leaves.isEmpty else { return [] }
        let clampedSelection = clampedSelectionIndex(selectionIndex)
        let indexes = leaves
            .filter { $0.selectionIndex == clampedSelection }
            .map(\.index)
        guard !indexes.isEmpty else {
            return usesTwoPageSpread ? [0, 1].filter { leaves.indices.contains($0) } : [0]
        }
        return indexes
    }

    func selectionIndex(forLeafIndexes leafIndexes: [Int]) -> Int? {
        leafIndexes
            .compactMap { leaves.indices.contains($0) ? leaves[$0].selectionIndex : nil }
            .min()
    }

    func pageIndex(forSelectionIndex selectionIndex: Int) -> Int? {
        let clampedSelection = clampedSelectionIndex(selectionIndex)
        if usesTwoPageSpread {
            return plan.pageIndex(forSpreadAt: clampedSelection)
        }
        return plan.pages.indices.contains(clampedSelection) ? clampedSelection : nil
    }

    func globalIndex(forSelectionIndex selectionIndex: Int) -> Int? {
        guard let pageIndex = pageIndex(forSelectionIndex: selectionIndex) else {
            return nil
        }
        return plan.globalIndex(forPageAt: pageIndex)
    }

    func leafIndex(before leafIndex: Int) -> Int? {
        let targetIndex = leafIndex - 1
        return leaves.indices.contains(targetIndex) ? targetIndex : nil
    }

    func leafIndex(after leafIndex: Int) -> Int? {
        let targetIndex = leafIndex + 1
        return leaves.indices.contains(targetIndex) ? targetIndex : nil
    }

    func leafIndex(matching leaf: MangaPagedPageCurlLeaf) -> Int? {
        if let pageID = leaf.pageID {
            return leaves.first { $0.pageID == pageID }?.index
        }
        if leaves.indices.contains(leaf.index) {
            let candidate = leaves[leaf.index]
            if candidate.pageID == nil,
               candidate.selectionIndex == leaf.selectionIndex {
                return leaf.index
            }
        }
        if let matchingBlankLeaf = leaves.first(where: { candidate in
            candidate.pageID == nil && candidate.selectionIndex == leaf.selectionIndex
        }) {
            return matchingBlankLeaf.index
        }
        return leaves.indices.contains(leaf.index) ? leaf.index : nil
    }

    func leafIndex(before leaf: MangaPagedPageCurlLeaf) -> Int? {
        guard let leafIndex = leafIndex(matching: leaf) else { return nil }
        return self.leafIndex(before: leafIndex)
    }

    func leafIndex(after leaf: MangaPagedPageCurlLeaf) -> Int? {
        guard let leafIndex = leafIndex(matching: leaf) else { return nil }
        return self.leafIndex(after: leafIndex)
    }

    func firstLeafIndex(forSelectionIndex selectionIndex: Int) -> Int? {
        leafIndexes(forSelectionIndex: selectionIndex).first
    }

    private func clampedSelectionIndex(_ selectionIndex: Int) -> Int {
        let upperBound = usesTwoPageSpread ? plan.spreads.count - 1 : plan.pages.count - 1
        guard upperBound >= 0 else { return 0 }
        return min(max(selectionIndex, 0), upperBound)
    }

    private static func physicalBookOrder(
        leafGroups: [[MangaPagedPageCurlLeaf]],
        pageTurnDirection: MangaPageTurnDirection
    ) -> [MangaPagedPageCurlLeaf] {
        switch pageTurnDirection {
        case .leftToRight:
            leafGroups.flatMap { $0 }
        case .rightToLeft:
            leafGroups.reversed().flatMap { $0 }
        }
    }

    private static func indexedLeaves(from leaves: [MangaPagedPageCurlLeaf]) -> [MangaPagedPageCurlLeaf] {
        leaves.enumerated().map { index, leaf in
            MangaPagedPageCurlLeaf(
                index: index,
                pageIndex: leaf.pageIndex,
                pageID: leaf.pageID,
                selectionIndex: leaf.selectionIndex
            )
        }
    }

    private static var emptySingleLeaf: MangaPagedPageCurlLeaf {
        MangaPagedPageCurlLeaf(index: 0, pageIndex: nil, pageID: nil, selectionIndex: 0)
    }

    private static var emptySpreadLeaves: [MangaPagedPageCurlLeaf] {
        [
            MangaPagedPageCurlLeaf(index: 0, pageIndex: nil, pageID: nil, selectionIndex: 0),
            MangaPagedPageCurlLeaf(index: 1, pageIndex: nil, pageID: nil, selectionIndex: 0),
        ]
    }
}

struct MangaPagedPageCurlSelectionResolver: Equatable, Sendable {
    private(set) var lastAppliedPlacementRevision: Int?

    mutating func selectionIndex(
        plan: MangaPagedReadingPlan,
        viewportPlacement: MangaNovelReaderViewportPlacement?
    ) -> Int {
        if let viewportPlacement,
           viewportPlacement.revision != lastAppliedPlacementRevision,
           let targetPageIndex = plan.clampedPageIndex(viewportPlacement.targetPageIndex),
           let targetSelectionIndex = plan.spreadIndex(forPageAt: targetPageIndex) {
            lastAppliedPlacementRevision = viewportPlacement.revision
            return targetSelectionIndex
        }

        return Self.currentSelectionIndex(plan: plan)
    }

    static func currentSelectionIndex(plan: MangaPagedReadingPlan) -> Int {
        plan.currentSpreadIndex ?? 0
    }
}

private extension Array where Element == MangaPagedPageCurlLeaf {
    func ifEmpty(_ fallback: [MangaPagedPageCurlLeaf]) -> [MangaPagedPageCurlLeaf] {
        isEmpty ? fallback : self
    }
}

enum MangaPagedPageCurlSpineLocation: Equatable, Sendable {
    case min
    case mid
}

struct MangaPagedPageCurlSpineConfiguration: Equatable, Sendable {
    let spineLocation: MangaPagedPageCurlSpineLocation
    let doubleSidedUpdate: Bool?

    static func configuration(
        usesTwoPageSpread: Bool,
        currentSpineLocation: MangaPagedPageCurlSpineLocation
    ) -> MangaPagedPageCurlSpineConfiguration {
        if usesTwoPageSpread {
            return MangaPagedPageCurlSpineConfiguration(
                spineLocation: .mid,
                doubleSidedUpdate: true
            )
        }

        return MangaPagedPageCurlSpineConfiguration(
            spineLocation: .min,
            doubleSidedUpdate: currentSpineLocation == .mid ? nil : false
        )
    }
}

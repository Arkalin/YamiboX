import Foundation

public struct NovelReaderReadingState: Hashable, Sendable {
    public var currentView: Int
    public var maxView: Int
    public var currentChapterTitle: String?
    public var authorID: String?
    public var currentSurfaceIntraProgress: Double

    public init(
        currentView: Int,
        maxView: Int,
        currentChapterTitle: String?,
        authorID: String?,
        currentSurfaceIntraProgress: Double
    ) {
        self.currentView = max(1, currentView)
        self.maxView = max(self.currentView, maxView)
        self.currentChapterTitle = currentChapterTitle
        self.authorID = authorID
        self.currentSurfaceIntraProgress = min(max(currentSurfaceIntraProgress, 0), 1)
    }
}

public struct NovelReaderProgressProjection: Hashable, Sendable {
    public var readingMode: ReaderReadingMode
    public var usesTwoPageSpread: Bool
    public var pageTurnDirection: ReaderPageTurnDirection
    public var surfaceCount: Int
    public var selectedSurfaceIndex: Int
    public var currentSurfaceNumber: Int
    public var displayedView: Int
    public var displayedPageIndex: Int
    public var displayedPageCount: Int
    public var displayedPageLabel: String
    public var currentProgressFraction: Double
    public var currentProgressPercent: Int
    public var currentProgressPercentText: String
    public var visibleSurfaceIndexes: [Int]
    public var fallbackVisibleSurfaceIndex: Int

    public init(
        readingMode: ReaderReadingMode,
        usesTwoPageSpread: Bool,
        pageTurnDirection: ReaderPageTurnDirection = .leftToRight,
        surfaceCount: Int,
        selectedSurfaceIndex: Int,
        currentSurfaceNumber: Int,
        displayedView: Int,
        displayedPageIndex: Int,
        displayedPageCount: Int,
        displayedPageLabel: String,
        currentProgressFraction: Double,
        currentProgressPercent: Int,
        currentProgressPercentText: String,
        visibleSurfaceIndexes: [Int],
        fallbackVisibleSurfaceIndex: Int
    ) {
        self.readingMode = readingMode
        self.usesTwoPageSpread = usesTwoPageSpread
        self.pageTurnDirection = pageTurnDirection
        self.surfaceCount = max(surfaceCount, 1)
        self.selectedSurfaceIndex = max(selectedSurfaceIndex, 0)
        self.currentSurfaceNumber = min(max(currentSurfaceNumber, 1), self.surfaceCount)
        self.displayedView = max(displayedView, 1)
        self.displayedPageIndex = max(displayedPageIndex, 0)
        self.displayedPageCount = max(displayedPageCount, 1)
        self.displayedPageLabel = displayedPageLabel.isEmpty ? "1" : displayedPageLabel
        self.currentProgressFraction = min(max(currentProgressFraction, 0), 1)
        self.currentProgressPercent = min(max(currentProgressPercent, 0), 100)
        self.currentProgressPercentText = currentProgressPercentText
        self.visibleSurfaceIndexes = visibleSurfaceIndexes.map { max($0, 0) }
        self.fallbackVisibleSurfaceIndex = max(fallbackVisibleSurfaceIndex, 0)
    }

    public init(
        readingMode: ReaderReadingMode,
        usesTwoPageSpread: Bool,
        pageTurnDirection: ReaderPageTurnDirection = .leftToRight,
        surfaces: [NovelReaderSurface],
        selectedSurfaceIndex: Int,
        spreads: [NovelReaderPresentationSpread],
        readingState: NovelReaderReadingState
    ) {
        let surfaceCount = max(surfaces.count, 1)
        let maxSurfaceIndex = max(surfaceCount - 1, 0)
        let normalizedSelectedIndex = min(max(selectedSurfaceIndex, 0), maxSurfaceIndex)
        let progressSurfaceIndex = Self.progressSurfaceIndex(
            selectedSurfaceIndex: normalizedSelectedIndex,
            maxSurfaceIndex: maxSurfaceIndex,
            spreads: spreads,
            usesTwoPageSpread: usesTwoPageSpread,
            pageTurnDirection: pageTurnDirection
        )
        let selectedSurface = surfaces.indices.contains(progressSurfaceIndex) ? surfaces[progressSurfaceIndex] : nil
        let displayedView = selectedSurface?.documentView ?? readingState.currentView
        let visibleSurfaceIndexes = surfaces.indices.filter { surfaces[$0].documentView == displayedView }
        let fallbackVisibleSurfaceIndex = visibleSurfaceIndexes.first ?? progressSurfaceIndex
        let displayedPageIndex = visibleSurfaceIndexes.first.map {
            max(progressSurfaceIndex - $0, 0)
        } ?? progressSurfaceIndex
        let displayedPageCount = max(visibleSurfaceIndexes.count, 1)
        let displayedPageLabel = Self.displayedPageLabel(
            displayedPageIndex: displayedPageIndex,
            displayedPageCount: displayedPageCount,
            displayedView: displayedView,
            selectedSurfaceIndex: progressSurfaceIndex,
            surfaces: surfaces,
            spreads: spreads,
            usesTwoPageSpread: usesTwoPageSpread
        )
        let fraction: Double = switch readingMode {
        case .vertical:
            displayedPageCount > 1 ? Double(displayedPageIndex) / Double(displayedPageCount - 1) : 0
        case .paged:
            surfaceCount > 1 ? Double(progressSurfaceIndex) / Double(surfaceCount - 1) : 0
        }
        let percent = Int((fraction * 100).rounded())

        self.init(
            readingMode: readingMode,
            usesTwoPageSpread: usesTwoPageSpread,
            pageTurnDirection: pageTurnDirection,
            surfaceCount: surfaceCount,
            selectedSurfaceIndex: progressSurfaceIndex,
            currentSurfaceNumber: progressSurfaceIndex + 1,
            displayedView: displayedView,
            displayedPageIndex: displayedPageIndex,
            displayedPageCount: displayedPageCount,
            displayedPageLabel: displayedPageLabel,
            currentProgressFraction: fraction,
            currentProgressPercent: percent,
            currentProgressPercentText: "\(percent)%",
            visibleSurfaceIndexes: Array(visibleSurfaceIndexes),
            fallbackVisibleSurfaceIndex: fallbackVisibleSurfaceIndex
        )
    }

    /// The structure has already normalized these arrays. Do not funnel this
    /// through the public initializer, which defensively maps every index.
    package init(
        readingMode: ReaderReadingMode,
        usesTwoPageSpread: Bool,
        pageTurnDirection: ReaderPageTurnDirection,
        structure: NovelReaderPresentationStructure,
        selectedSurfaceIndex: Int,
        readingState: NovelReaderReadingState
    ) {
        let surfaces = structure.surfaces
        let count = max(surfaces.count, 1)
        var index = min(max(selectedSurfaceIndex, 0), count - 1)
        if usesTwoPageSpread, let spread = structure.spread(containing: index) {
            index = pageTurnDirection == .leftToRight
                ? spread.rightSurfaceIndex ?? spread.leftSurfaceIndex : spread.leftSurfaceIndex
            index = min(max(index, 0), count - 1)
        }
        let view = surfaces.indices.contains(index) ? surfaces[index].documentView : readingState.currentView
        let indexes = structure.surfaceIndexesByView[view] ?? []
        let localIndex = indexes.first.map { max(index - $0, 0) } ?? index
        let localCount = max(indexes.count, 1)
        var label = String(localIndex + 1)
        if usesTwoPageSpread, let spread = structure.spread(containing: index) {
            let first = indexes.first ?? 0
            let left = max(spread.leftSurfaceIndex - first + 1, 1)
            label = String(left)
            if let right = spread.rightSurfaceIndex, surfaces.indices.contains(right), surfaces[right].documentView == view {
                label = "\(left)-\(min(max(right - first + 1, left), localCount))"
            }
        }
        let fraction: Double = switch readingMode {
        case .vertical: localCount > 1 ? Double(localIndex) / Double(localCount - 1) : 0
        case .paged: count > 1 ? Double(index) / Double(count - 1) : 0
        }
        let percent = min(max(Int((fraction * 100).rounded()), 0), 100)
        self.readingMode = readingMode
        self.usesTwoPageSpread = usesTwoPageSpread
        self.pageTurnDirection = pageTurnDirection
        surfaceCount = count
        self.selectedSurfaceIndex = index
        currentSurfaceNumber = index + 1
        displayedView = view
        displayedPageIndex = max(localIndex, 0)
        displayedPageCount = localCount
        displayedPageLabel = label
        currentProgressFraction = min(max(fraction, 0), 1)
        currentProgressPercent = percent
        currentProgressPercentText = "\(percent)%"
        visibleSurfaceIndexes = indexes
        fallbackVisibleSurfaceIndex = indexes.first ?? index
    }

    private static func progressSurfaceIndex(
        selectedSurfaceIndex: Int,
        maxSurfaceIndex: Int,
        spreads: [NovelReaderPresentationSpread],
        usesTwoPageSpread: Bool,
        pageTurnDirection: ReaderPageTurnDirection
    ) -> Int {
        let clampedSelectedIndex = min(max(selectedSurfaceIndex, 0), max(maxSurfaceIndex, 0))
        guard usesTwoPageSpread,
              let spread = spreads.first(where: {
                $0.leftSurfaceIndex == clampedSelectedIndex || $0.rightSurfaceIndex == clampedSelectedIndex
              }) else {
            return clampedSelectedIndex
        }
        let progressIndex = switch pageTurnDirection {
        case .leftToRight:
            spread.rightSurfaceIndex ?? spread.leftSurfaceIndex
        case .rightToLeft:
            spread.leftSurfaceIndex
        }
        return min(max(progressIndex, 0), max(maxSurfaceIndex, 0))
    }

    private static func displayedPageLabel(
        displayedPageIndex: Int,
        displayedPageCount: Int,
        displayedView: Int,
        selectedSurfaceIndex: Int,
        surfaces: [NovelReaderSurface],
        spreads: [NovelReaderPresentationSpread],
        usesTwoPageSpread: Bool
    ) -> String {
        let selectedSurfaceNumber = displayedPageIndex + 1
        guard usesTwoPageSpread,
              let spread = spreads.first(where: {
                $0.leftSurfaceIndex == selectedSurfaceIndex || $0.rightSurfaceIndex == selectedSurfaceIndex
              }) else {
            return "\(selectedSurfaceNumber)"
        }
        let firstVisibleSurfaceIndex = surfaces.indices.first {
            surfaces[$0].documentView == displayedView
        } ?? 0
        let leftSurfaceNumber = max(spread.leftSurfaceIndex - firstVisibleSurfaceIndex + 1, 1)
        guard let rightSurfaceIndex = spread.rightSurfaceIndex,
              surfaces.indices.contains(rightSurfaceIndex),
              surfaces[rightSurfaceIndex].documentView == displayedView else {
            return "\(leftSurfaceNumber)"
        }
        let rightSurfaceNumber = max(rightSurfaceIndex - firstVisibleSurfaceIndex + 1, leftSurfaceNumber)
        return "\(leftSurfaceNumber)-\(min(rightSurfaceNumber, displayedPageCount))"
    }
}

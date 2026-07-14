import YamiboXCore

public struct NovelReaderProgressChapterTick: Equatable, Sendable {
    public var chapter: NovelReaderChapter
    public var position: Double
    public var isCurrent: Bool

    public init(chapter: NovelReaderChapter, position: Double, isCurrent: Bool) {
        self.chapter = chapter
        self.position = position
        self.isCurrent = isCurrent
    }
}

private struct NovelReaderProgressScrubData: Equatable, Sendable {
    var readingMode: ReaderReadingMode
    var surfaceCount: Int
    var currentProgressPercent: Int
    var visibleSurfaceIndexes: [Int]
    var fallbackVisibleSurfaceIndex: Int
    var chapterTitlesBySurfaceIndex: [Int: String]
    var chapterTickStartIndexes: Set<Int>
    var isTwoPageSpreadActive: Bool
    var pageTurnDirection: ReaderPageTurnDirection

    func targetSurfaceIndex(for value: Double) -> Int {
        guard surfaceCount > 1 else { return 0 }
        switch readingMode {
        case .paged:
            let target = min(max(Int(value.rounded()), 0), max(surfaceCount - 1, 0))
            guard isTwoPageSpreadActive else { return target }
            return twoPageAnchorSurfaceIndex(containing: target)
        case .vertical:
            guard !visibleSurfaceIndexes.isEmpty,
                  visibleSurfaceIndexes.count > 1 else {
                return fallbackVisibleSurfaceIndex
            }
            let clampedPercent = min(max(value, 0), 100)
            let localSurfaceIndex = min(
                max(Int((clampedPercent / 100) * Double(visibleSurfaceIndexes.count - 1)), 0),
                max(visibleSurfaceIndexes.count - 1, 0)
            )
            return visibleSurfaceIndexes[localSurfaceIndex]
        }
    }

    func twoPageAnchorSurfaceIndex(containing surfaceIndex: Int) -> Int {
        let spreadStartIndex = surfaceIndex - (surfaceIndex % 2)
        switch pageTurnDirection {
        case .leftToRight:
            return min(spreadStartIndex + 1, max(surfaceCount - 1, 0))
        case .rightToLeft:
            return spreadStartIndex
        }
    }

    func chapterTitle(for surfaceIndex: Int) -> String? {
        let clampedIndex = min(max(surfaceIndex, 0), max(surfaceCount - 1, 0))
        return chapterTitlesBySurfaceIndex[clampedIndex]
    }

    func chapterTickStartIndex(for surfaceIndex: Int) -> Int? {
        let clampedIndex = min(max(surfaceIndex, 0), max(surfaceCount - 1, 0))
        return chapterTickStartIndexes.contains(clampedIndex) ? clampedIndex : nil
    }
}

public struct NovelReaderChromeProgressSnapshot: Equatable, Sendable {
    public var readingMode: ReaderReadingMode
    public var visibleView: Int
    public var surfaceCount: Int
    public var currentSurfaceNumber: Int
    public var currentChapterTitle: String?
    public var progressText: String
    public var currentProgressFraction: Double
    public var currentProgressPercent: Int
    public var currentProgressPercentText: String
    public var progressChapterTicks: [NovelReaderProgressChapterTick]
    private var scrubData: NovelReaderProgressScrubData

    public static var empty: NovelReaderChromeProgressSnapshot {
        NovelReaderChromeProgressSnapshot(
            readingMode: .paged,
            visibleView: 1,
            surfaceCount: 1,
            currentSurfaceNumber: 1,
            currentChapterTitle: nil,
            progressText: "",
            currentProgressFraction: 0,
            currentProgressPercent: 0,
            currentProgressPercentText: "0%",
            progressChapterTicks: [],
            scrubData: NovelReaderProgressScrubData(
                readingMode: .paged,
                surfaceCount: 1,
                currentProgressPercent: 0,
                visibleSurfaceIndexes: [],
                fallbackVisibleSurfaceIndex: 0,
                chapterTitlesBySurfaceIndex: [:],
                chapterTickStartIndexes: [],
                isTwoPageSpreadActive: false,
                pageTurnDirection: .leftToRight
            )
        )
    }

    public init(presentation: NovelReaderPresentation) {
        let projection = presentation.progressProjection
        let chapter = presentation.readingState.currentChapterTitle ?? ""
        let progressText = if chapter.isEmpty {
            L10n.string(
                "reader.progress",
                projection.displayedPageLabel,
                max(projection.displayedPageCount, 1),
                projection.displayedView,
                max(presentation.readingState.maxView, 1)
            )
        } else {
            L10n.string(
                "reader.progress_with_chapter",
                projection.displayedPageLabel,
                max(projection.displayedPageCount, 1),
                projection.displayedView,
                max(presentation.readingState.maxView, 1),
                chapter
            )
        }
        let maxIndex = max(projection.surfaceCount - 1, 0)
        let currentChapterIndex = presentation.chapters.lastIndex {
            $0.startIndex <= projection.selectedSurfaceIndex
        }
        let progressChapterTicks: [NovelReaderProgressChapterTick] = {
            guard projection.surfaceCount > 1, !presentation.chapters.isEmpty else { return [] }
            var seenStartIndexes = Set<Int>()
            return presentation.chapters.enumerated().compactMap { index, chapter -> NovelReaderProgressChapterTick? in
                let clampedStartIndex = min(max(chapter.startIndex, 0), max(maxIndex, 1))
                guard seenStartIndexes.insert(clampedStartIndex).inserted else { return nil }
                return NovelReaderProgressChapterTick(
                    chapter: chapter,
                    position: Double(clampedStartIndex) / Double(max(maxIndex, 1)),
                    isCurrent: currentChapterIndex == index
                )
            }
        }()
        let chapterTitlesBySurfaceIndex = Self.chapterTitlesBySurfaceIndex(
            surfaces: presentation.surfaces,
            chapters: presentation.chapters,
            maxIndex: maxIndex
        )
        let tickStartIndexes = Set(presentation.chapters.map { min(max($0.startIndex, 0), maxIndex) })

        self.init(
            readingMode: projection.readingMode,
            visibleView: projection.displayedView,
            surfaceCount: projection.surfaceCount,
            currentSurfaceNumber: projection.currentSurfaceNumber,
            currentChapterTitle: presentation.readingState.currentChapterTitle,
            progressText: progressText,
            currentProgressFraction: projection.currentProgressFraction,
            currentProgressPercent: projection.currentProgressPercent,
            currentProgressPercentText: projection.currentProgressPercentText,
            progressChapterTicks: progressChapterTicks,
            scrubData: NovelReaderProgressScrubData(
                readingMode: projection.readingMode,
                surfaceCount: projection.surfaceCount,
                currentProgressPercent: projection.currentProgressPercent,
                visibleSurfaceIndexes: projection.visibleSurfaceIndexes,
                fallbackVisibleSurfaceIndex: projection.fallbackVisibleSurfaceIndex,
                chapterTitlesBySurfaceIndex: chapterTitlesBySurfaceIndex,
                chapterTickStartIndexes: tickStartIndexes,
                isTwoPageSpreadActive: projection.usesTwoPageSpread,
                pageTurnDirection: projection.pageTurnDirection
            )
        )
    }

    private init(
        readingMode: ReaderReadingMode,
        visibleView: Int,
        surfaceCount: Int,
        currentSurfaceNumber: Int,
        currentChapterTitle: String?,
        progressText: String,
        currentProgressFraction: Double,
        currentProgressPercent: Int,
        currentProgressPercentText: String,
        progressChapterTicks: [NovelReaderProgressChapterTick],
        scrubData: NovelReaderProgressScrubData
    ) {
        self.readingMode = readingMode
        self.visibleView = max(visibleView, 1)
        self.surfaceCount = max(surfaceCount, 1)
        self.currentSurfaceNumber = min(max(currentSurfaceNumber, 1), self.surfaceCount)
        self.currentChapterTitle = currentChapterTitle
        self.progressText = progressText
        self.currentProgressFraction = min(max(currentProgressFraction, 0), 1)
        self.currentProgressPercent = min(max(currentProgressPercent, 0), 100)
        self.currentProgressPercentText = currentProgressPercentText
        self.progressChapterTicks = progressChapterTicks
        self.scrubData = scrubData
    }

    public func progressSliderLabelText(
        isEditing: Bool,
        sliderValue: Double,
        targetSurfaceIndex: Int
    ) -> String {
        if readingMode == .vertical {
            guard isEditing else { return currentProgressPercentText }
            let percent = Int(min(max(sliderValue, 0), 100).rounded())
            return "\(percent)%"
        }

        guard isEditing else {
            return "\(currentSurfaceNumber) / \(surfaceCount)"
        }
        let page = min(max(targetSurfaceIndex + 1, 1), surfaceCount)
        return "\(page) / \(surfaceCount)"
    }

    public func targetSurfaceIndex(forProgressValue value: Double) -> Int {
        scrubData.targetSurfaceIndex(for: value)
    }

    public func chapterTitle(forSurfaceIndex surfaceIndex: Int) -> String? {
        scrubData.chapterTitle(for: surfaceIndex)
    }

    public func progressChapterTickStartIndex(forSurfaceIndex surfaceIndex: Int) -> Int? {
        scrubData.chapterTickStartIndex(for: surfaceIndex)
    }

    public var progressScrubContext: ReaderProgressScrubContext {
        ReaderProgressScrubContext(
            itemCount: scrubData.surfaceCount,
            currentProgressFraction: currentProgressFraction,
            targetIndex: { fraction in
                let clampedFraction = min(max(fraction, 0), 1)
                let value = switch scrubData.readingMode {
                case .paged:
                    clampedFraction * Double(max(scrubData.surfaceCount - 1, 0))
                case .vertical:
                    clampedFraction * 100
                }
                return scrubData.targetSurfaceIndex(for: value)
            },
            title: { surfaceIndex in
                scrubData.chapterTitle(for: surfaceIndex)
            },
            tickTargetIndex: { surfaceIndex in
                scrubData.chapterTickStartIndex(for: surfaceIndex)
            }
        )
    }

    public var chromeProgress: ReaderChromeProgress {
        ReaderChromeProgress(
            itemCount: surfaceCount,
            currentIndex: currentSurfaceNumber - 1,
            progressFraction: currentProgressFraction,
            percentText: currentProgressPercentText,
            primaryText: L10n.string("reader.chapters") + " · \(currentProgressPercentText)",
            secondaryText: progressText,
            ticks: progressChapterTicks.map { tick in
                ReaderChromeProgressTick(
                    targetIndex: tick.chapter.startIndex,
                    positionFraction: tick.position,
                    title: tick.chapter.title,
                    isCurrent: tick.isCurrent
                )
            },
            scrubTargetIndexes: scrubData.scrubTargetIndexes
        )
    }

    private static func chapterTitlesBySurfaceIndex(
        surfaces: [NovelReaderSurface],
        chapters: [NovelReaderChapter],
        maxIndex: Int
    ) -> [Int: String] {
        guard maxIndex >= 0, !surfaces.isEmpty else { return [:] }
        var result: [Int: String] = [:]
        var chapterIndex = 0
        let sortedChapters = chapters.sorted { $0.startIndex < $1.startIndex }
        for index in surfaces.indices {
            while chapterIndex + 1 < sortedChapters.count,
                  sortedChapters[chapterIndex + 1].startIndex <= index {
                chapterIndex += 1
            }
            if let title = surfaces[index].chapterTitle {
                result[index] = title
            } else if sortedChapters.indices.contains(chapterIndex),
                      sortedChapters[chapterIndex].startIndex <= index {
                result[index] = sortedChapters[chapterIndex].title
            }
        }
        return result
    }
}

private extension NovelReaderProgressScrubData {
    var scrubTargetIndexes: [Int] {
        switch readingMode {
        case .paged:
            if isTwoPageSpreadActive {
                return stride(from: 0, through: max(surfaceCount - 1, 0), by: 2).map {
                    twoPageAnchorSurfaceIndex(containing: $0)
                }
            }
            return Array(0 ... max(surfaceCount - 1, 0))
        case .vertical:
            return visibleSurfaceIndexes.isEmpty ? [fallbackVisibleSurfaceIndex] : visibleSurfaceIndexes
        }
    }
}

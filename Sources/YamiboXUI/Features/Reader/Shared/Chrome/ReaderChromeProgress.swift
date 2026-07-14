import Foundation

public struct ReaderChromeProgressTick: Equatable, Sendable {
    public var targetIndex: Int
    public var positionFraction: Double
    public var title: String?
    public var isCurrent: Bool

    public init(
        targetIndex: Int,
        positionFraction: Double,
        title: String?,
        isCurrent: Bool
    ) {
        self.targetIndex = max(targetIndex, 0)
        self.positionFraction = Self.clampFraction(positionFraction)
        self.title = title
        self.isCurrent = isCurrent
    }

    private static func clampFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct ReaderChromeProgress: Equatable, Sendable {
    public var itemCount: Int
    public var currentIndex: Int
    public var progressFraction: Double
    public var percentText: String
    public var primaryText: String
    public var secondaryText: String?
    public var ticks: [ReaderChromeProgressTick]
    public var iconSystemName: String

    private var scrubTargetIndexes: [Int]

    public static var empty: ReaderChromeProgress {
        ReaderChromeProgress(
            itemCount: 1,
            currentIndex: 0,
            progressFraction: 0,
            percentText: "0%",
            primaryText: "",
            secondaryText: nil,
            ticks: [],
            scrubTargetIndexes: [0]
        )
    }

    public init(
        itemCount: Int,
        currentIndex: Int,
        progressFraction: Double? = nil,
        percentText: String? = nil,
        primaryText: String,
        secondaryText: String? = nil,
        ticks: [ReaderChromeProgressTick] = [],
        iconSystemName: String = "list.bullet",
        scrubTargetIndexes: [Int]? = nil
    ) {
        self.itemCount = max(itemCount, 1)
        self.currentIndex = min(max(currentIndex, 0), max(self.itemCount - 1, 0))
        let resolvedFraction = progressFraction ?? Self.positionFraction(
            forTargetIndex: self.currentIndex,
            itemCount: self.itemCount
        )
        self.progressFraction = Self.clampFraction(resolvedFraction)
        let resolvedPercent = Int((self.progressFraction * 100).rounded())
        self.percentText = percentText ?? "\(resolvedPercent)%"
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.ticks = ticks
        self.iconSystemName = iconSystemName
        self.scrubTargetIndexes = Self.normalizedScrubTargetIndexes(
            scrubTargetIndexes,
            itemCount: self.itemCount
        )
    }

    public func targetIndex(forProgressFraction fraction: Double) -> Int {
        let clampedFraction = Self.clampFraction(fraction)
        guard scrubTargetIndexes.count > 1 else {
            return scrubTargetIndexes.first ?? 0
        }
        let targetOffset = Int((clampedFraction * Double(scrubTargetIndexes.count - 1)).rounded())
        let clampedOffset = min(max(targetOffset, 0), scrubTargetIndexes.count - 1)
        return scrubTargetIndexes[clampedOffset]
    }

    public func title(forTargetIndex targetIndex: Int) -> String? {
        currentTick(forTargetIndex: targetIndex)?.title
    }

    /// The tick whose chapter currently covers `targetIndex` — i.e. the
    /// closest tick at or before it, not an exact-position match. This lets
    /// callers detect that a chapter boundary was *crossed* even when a fast
    /// drag jumps `targetIndex` past the tick's exact position in one step.
    public func tickTargetIndex(forTargetIndex targetIndex: Int) -> Int? {
        currentTick(forTargetIndex: targetIndex)?.targetIndex
    }

    private func currentTick(forTargetIndex targetIndex: Int) -> ReaderChromeProgressTick? {
        let normalizedTarget = min(max(targetIndex, 0), max(itemCount - 1, 0))
        return ticks
            .filter { $0.targetIndex <= normalizedTarget }
            .max { lhs, rhs in lhs.targetIndex < rhs.targetIndex }
    }

    public func positionFraction(forTargetIndex targetIndex: Int) -> Double {
        Self.positionFraction(forTargetIndex: targetIndex, itemCount: itemCount)
    }

    public var scrubContext: ReaderProgressScrubContext {
        ReaderProgressScrubContext(
            itemCount: itemCount,
            currentProgressFraction: progressFraction,
            targetIndex: { fraction in
                targetIndex(forProgressFraction: fraction)
            },
            title: { targetIndex in
                title(forTargetIndex: targetIndex)
            },
            tickTargetIndex: { targetIndex in
                tickTargetIndex(forTargetIndex: targetIndex)
            }
        )
    }

    private static func normalizedScrubTargetIndexes(_ indexes: [Int]?, itemCount: Int) -> [Int] {
        let maxIndex = max(itemCount - 1, 0)
        let candidates = indexes ?? Array(0 ... maxIndex)
        let normalized = candidates
            .map { min(max($0, 0), maxIndex) }
            .reduce(into: [Int]()) { result, index in
                if result.last != index {
                    result.append(index)
                }
            }
        return normalized.isEmpty ? [0] : normalized
    }

    private static func positionFraction(forTargetIndex targetIndex: Int, itemCount: Int) -> Double {
        let itemCount = max(itemCount, 1)
        guard itemCount > 1 else { return 0 }
        let maxIndex = max(itemCount - 1, 1)
        let clampedIndex = min(max(targetIndex, 0), maxIndex)
        return Double(clampedIndex) / Double(maxIndex)
    }

    private static func clampFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

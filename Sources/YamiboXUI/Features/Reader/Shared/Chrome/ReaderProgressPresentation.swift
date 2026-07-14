import SwiftUI
import YamiboXCore

public enum ReaderProgressScrubPhase: Equatable, Sendable {
    case idle
    case pressed
    case scrubbing
    case ended
}

public enum ReaderProgressScrubHaptic: Equatable, Sendable {
    case start
    case chapterTick
    case commit
}

public struct ReaderProgressScrubPreview: Equatable, Sendable {
    public var chapterTitle: String?
    public var pageNumber: Int
    public var targetIndex: Int

    public init(chapterTitle: String?, pageNumber: Int, targetIndex: Int? = nil) {
        self.chapterTitle = chapterTitle
        self.pageNumber = max(pageNumber, 1)
        self.targetIndex = max(targetIndex ?? (self.pageNumber - 1), 0)
    }

    public var displayText: String {
        let pageText = L10n.string("reader.page_number_compact", pageNumber)
        guard let chapterTitle,
              !chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return pageText
        }
        return "\(chapterTitle) \(pageText)"
    }
}

public struct ReaderProgressScrubContext: Sendable {
    public var itemCount: Int
    public var currentProgressFraction: Double
    public var targetIndex: @Sendable (Double) -> Int
    public var title: @Sendable (Int) -> String?
    public var tickTargetIndex: @Sendable (Int) -> Int?

    public init(
        itemCount: Int,
        currentProgressFraction: Double,
        targetIndex: @escaping @Sendable (Double) -> Int,
        title: @escaping @Sendable (Int) -> String?,
        tickTargetIndex: @escaping @Sendable (Int) -> Int?
    ) {
        self.itemCount = max(itemCount, 1)
        self.currentProgressFraction = min(max(currentProgressFraction, 0), 1)
        self.targetIndex = targetIndex
        self.title = title
        self.tickTargetIndex = tickTargetIndex
    }

    public var valueRange: ClosedRange<Double> {
        0 ... 1
    }

    public var restingValue: Double {
        currentProgressFraction
    }
}

public struct ReaderProgressScrubUpdate: Equatable, Sendable {
    public var haptics: [ReaderProgressScrubHaptic]
    public var committedTargetIndex: Int?

    public init(haptics: [ReaderProgressScrubHaptic] = [], committedTargetIndex: Int? = nil) {
        self.haptics = haptics
        self.committedTargetIndex = committedTargetIndex
    }
}

public enum ReaderProgressDragMapping {
    public static func value(
        startProgressFraction: Double,
        translation: CGFloat,
        length: CGFloat,
        range: ClosedRange<Double>
    ) -> Double {
        guard length > 0 else { return range.lowerBound }
        let startFraction = min(max(startProgressFraction, 0), 1)
        let translatedFraction = startFraction + Double(translation / length)
        let clampedFraction = min(max(translatedFraction, 0), 1)
        return range.lowerBound + clampedFraction * (range.upperBound - range.lowerBound)
    }
}

public enum ReaderProgressFillDirection: Equatable, Sendable {
    case leftToRight
    case rightToLeft
}

public struct ReaderProgressChromePresentation: Equatable, Sendable {
    public var readingMode: ReaderReadingMode
    public var isChromeVisible: Bool

    public init(readingMode: ReaderReadingMode, isChromeVisible: Bool) {
        self.readingMode = readingMode
        self.isChromeVisible = isChromeVisible
    }

    public var showsConventionalSlider: Bool { false }

    public var showsHorizontalFill: Bool {
        readingMode == .paged
    }

    public var supportsHorizontalScrub: Bool {
        readingMode == .paged
    }

    public var horizontalCapsuleUsesIndependentTapAndDrag: Bool { true }

    public var showsVerticalScrubber: Bool {
        readingMode == .vertical && isChromeVisible
    }

    public func horizontalCapsuleText(percentText: String) -> String {
        L10n.string("reader.progress_capsule.directory_percent", percentText)
    }
}

public enum ReaderBottomActionKind: Equatable, Sendable {
    case browser
    case comments
    case settings
    case bookmark
    case cache
}

public struct ReaderBottomAction: Equatable, Sendable {
    public var kind: ReaderBottomActionKind
    public var isDisabled: Bool

    public init(kind: ReaderBottomActionKind, isDisabled: Bool = false) {
        self.kind = kind
        self.isDisabled = isDisabled
    }
}

public struct ReaderBottomActionRowPresentation: Equatable, Sendable {
    public var isScrubbing: Bool

    public init(isScrubbing: Bool) {
        self.isScrubbing = isScrubbing
    }

    public var actions: [ReaderBottomAction] {
        [
            ReaderBottomAction(kind: .browser),
            ReaderBottomAction(kind: .bookmark, isDisabled: true),
            ReaderBottomAction(kind: .cache),
        ]
    }

    public var opacity: Double {
        isScrubbing ? 0 : 1
    }

    public var allowsHitTesting: Bool {
        !isScrubbing
    }

    public var isAccessibilityHidden: Bool {
        isScrubbing
    }

    public var preservesLayout: Bool { true }
}

public enum ReaderBottomChromeHorizontalAlignment: Equatable, Sendable {
    case trailing
}

public struct ReaderBottomChromeLayoutPresentation: Equatable, Sendable {
    public var usesIndependentControls: Bool { true }
    public var panelSpacing: CGFloat { 10 }
    public var maxChromeWidth: CGFloat { 260 }
    public var progressPanelHeight: CGFloat { 44 }
    public var actionButtonIconFrame: CGFloat { 34 }
    public var actionButtonRowHeight: CGFloat { progressPanelHeight }
    public var actionButtonSpacing: CGFloat { 8 }
    public var bottomControlsAdditionalBottomOffset: CGFloat { 8 }
    public var bottomChromeTopPadding: CGFloat { 8 }
    public var horizontalAlignment: ReaderBottomChromeHorizontalAlignment { .trailing }
    public var progressTextLeadsIcon: Bool { true }
    public var progressFillHasVerticalTrailingEdge: Bool { true }
    public var horizontalProgressThumbVisible: Bool { false }
    public var horizontalChapterTicksVisibleOnlyWhileScrubbing: Bool { true }
    public var directoryChapterTicksDoNotRequireProgressFill: Bool { true }
    public var horizontalDirectoryContentHiddenWhileScrubbing: Bool { true }
    public var progressCapsulesUseButtonTint: Bool { true }
    public var progressSummaryVisibleWhileScrubbing: Bool { true }
    public var verticalScrubberWidth: CGFloat { progressPanelHeight }
    public var verticalScrubberHeight: CGFloat { progressPanelHeight * 3 + panelSpacing * 3 + actionButtonRowHeight }
    public var verticalPreviewWidth: CGFloat { maxChromeWidth }
    public var verticalPreviewHeight: CGFloat { 50 }
    public var verticalScrubberShowsChapterTicks: Bool { true }
    public var verticalChapterTicksVisibleOnlyWhileScrubbing: Bool { true }
    public var verticalScrubberFillHasSquareEdge: Bool { true }
    public var hidesDirectoryCapsuleDuringVerticalScrub: Bool { true }
    public var verticalScrubberSideSpacing: CGFloat { actionButtonSpacing }
    public var verticalScrubberTicksAreCentered: Bool { true }
    public var verticalScrubberShowsLiveThumb: Bool { false }
    public var verticalScrubberBottomAlignsWithActionButtons: Bool { true }
    public var verticalPreviewUsesTwoLineChapterAndPage: Bool { true }
    public var verticalPreviewUsesLiquidGlass: Bool { true }
    public var horizontalPreviewMatchesVerticalCapsule: Bool { true }
    public var verticalScrubberShowsProgressFill: Bool { true }
    public var verticalCurrentChapterTickUsesAccentColor: Bool { true }
    public var directoryCapsuleContentUsesAccentColor: Bool { true }
    public var bottomProgressSummaryUsesPageCenter: Bool { true }
    public var verticalProgressSummaryUsesLiquidGlass: Bool { true }
    public var pagedProgressSummaryMovesBelowContentText: Bool { true }
    public var verticalChapterTitleCapsuleWrapsContent: Bool { true }
    public var capsuleChapterTickRoundedEdgeInset: CGFloat { 6 }

    public init() {}

    public func capsuleChapterTickCoordinate(position: Double, length: CGFloat, edgeInset: CGFloat) -> CGFloat {
        let clampedPosition = min(max(position, 0), 1)
        let clampedLength = max(length, 0)
        let clampedInset = min(max(edgeInset, 0), clampedLength / 2)
        let usableLength = max(clampedLength - clampedInset * 2, 0)
        return clampedInset + CGFloat(clampedPosition) * usableLength
    }

    public func capsuleProgressFillExtent(position: Double, length: CGFloat, edgeInset: CGFloat) -> CGFloat {
        if position <= 0 { return 0 }
        if position >= 1 { return max(length, 0) }
        return capsuleChapterTickCoordinate(position: position, length: length, edgeInset: edgeInset)
    }
}

public enum ReaderChromeVisibilityAnimationKind: Equatable, Sendable {
    case fade
    case anchoredPopup
}

public enum ReaderChromePopupAnchor: Equatable, Sendable {
    case bottomTrailing
}

public struct ReaderChromeVisibilityAnimationPresentation: Equatable, Sendable {
    public var kind: ReaderChromeVisibilityAnimationKind
    public var duration: Double
    public var hiddenScale: CGFloat
    public var anchor: ReaderChromePopupAnchor?

    public static let fade = ReaderChromeVisibilityAnimationPresentation(
        kind: .fade,
        duration: 0.2,
        hiddenScale: 1,
        anchor: nil
    )

    public static let anchoredPopup = ReaderChromeVisibilityAnimationPresentation(
        kind: .anchoredPopup,
        duration: 0.2,
        hiddenScale: 0.88,
        anchor: .bottomTrailing
    )
}

public struct ReaderChromeProgressSummary: Equatable, Sendable {
    public var chapterTitle: String
    public var pageProgressLine: String
    public var webProgressLine: String

    public init(chapterTitle: String?, progressText: String) {
        let components = progressText
            .split(separator: "·", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let trimmedChapter = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chapterTitle = trimmedChapter?.isEmpty == false ? trimmedChapter! : components.dropFirst(2).first ?? ""
        self.pageProgressLine = components.first ?? progressText
        self.webProgressLine = components.dropFirst().first ?? ""
    }
}

public struct ReaderProgressScrubState: Equatable, Sendable {
    public private(set) var phase: ReaderProgressScrubPhase = .idle
    public private(set) var value = 0.0
    public private(set) var targetIndex = 0
    public private(set) var preview: ReaderProgressScrubPreview?
    private var lastTickTargetIndex: Int?

    public init() {}

    @discardableResult
    public mutating func press(value newValue: Double, context: ReaderProgressScrubContext) -> ReaderProgressScrubUpdate {
        phase = .pressed
        return update(value: newValue, context: context)
    }

    @discardableResult
    public mutating func update(value newValue: Double, context: ReaderProgressScrubContext) -> ReaderProgressScrubUpdate {
        var haptics: [ReaderProgressScrubHaptic] = []
        if phase != .scrubbing {
            haptics.append(.start)
            // Seed with the chapter covering the resting position (not nil) so the
            // very first update of a scrub doesn't spuriously read as a chapter
            // crossing merely because it moved off the exact resting index.
            let restingTargetIndex = context.targetIndex(context.restingValue)
            lastTickTargetIndex = context.tickTargetIndex(restingTargetIndex)
        }

        phase = .scrubbing
        value = Self.clamp(newValue, to: context.valueRange)
        targetIndex = context.targetIndex(value)
        preview = ReaderProgressScrubPreview(
            chapterTitle: context.title(targetIndex),
            pageNumber: targetIndex + 1,
            targetIndex: targetIndex
        )

        let tickTargetIndex = context.tickTargetIndex(targetIndex)
        if let tickTargetIndex, tickTargetIndex != lastTickTargetIndex {
            haptics.append(.chapterTick)
        }
        lastTickTargetIndex = tickTargetIndex

        return ReaderProgressScrubUpdate(haptics: haptics)
    }

    @discardableResult
    public mutating func end() -> ReaderProgressScrubUpdate {
        phase = .ended
        lastTickTargetIndex = nil
        return ReaderProgressScrubUpdate(haptics: [.commit], committedTargetIndex: targetIndex)
    }

    public mutating func reset(to value: Double = 0) {
        phase = .idle
        self.value = value
        targetIndex = 0
        preview = nil
        lastTickTargetIndex = nil
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct ReaderPagedPagerIdentity: Hashable {
    let visibleView: Int
    let surfaceCount: Int
    let spreadCount: Int
    let usesTwoPageSpread: Bool
    let layoutWidth: Int
    let layoutHeight: Int

    init(
        visibleView: Int,
        surfaceCount: Int,
        spreadCount: Int,
        usesTwoPageSpread: Bool,
        layout: NovelReaderLayout
    ) {
        self.visibleView = visibleView
        self.surfaceCount = surfaceCount
        self.spreadCount = spreadCount
        self.usesTwoPageSpread = usesTwoPageSpread
        layoutWidth = Int(layout.width.rounded())
        layoutHeight = Int(layout.height.rounded())
    }
}

enum ReaderPagedTapZone: Equatable {
    case previous
    case toggleChrome
    case next

    static func zone(for point: CGPoint, in bounds: CGRect) -> ReaderPagedTapZone {
        guard bounds.width > 0 else { return .toggleChrome }
        let relativeX = point.x - bounds.minX
        let thirdWidth = bounds.width / 3
        if relativeX < thirdWidth {
            return .previous
        }
        if relativeX > thirdWidth * 2 {
            return .next
        }
        return .toggleChrome
    }
}

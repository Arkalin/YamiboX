import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

/// Single owner of the novel reader's vertical partitioning: the paged top
/// chrome band, the paged bottom progress-summary band, the pinned iPad top
/// inset, and the boundary-pull badge avoidance paddings.
///
/// Pagination (`NovelReaderView.readerLayout`), the paged viewports and the
/// bottom chrome must all read these definitions instead of carrying their
/// own copies — the paged progress summary overlapping the last text line
/// was exactly the drift that per-site constants allowed.
struct NovelReaderVerticalBandsPresentation: Equatable, Sendable {
    private let bottomChromeLayout = ReaderBottomChromeLayoutPresentation()

    init() {}

    // MARK: - Paged top band

    /// Height reserved above the content text in paged mode so the top
    /// chrome has a stable landing strip; part of the frozen pagination
    /// inputs, deliberately independent of live chrome visibility.
    var pagedTopBandHeight: CGFloat { 48 }

    /// Status-bar-visible top inset the iPad reader pins pagination to, so
    /// immersive status-bar hiding neither moves text nor changes rendered
    /// page counts.
    var padVisibleStatusBarTopInset: CGFloat { 32 }

    // MARK: - Paged bottom band

    /// Height of the two-line page/web progress summary that
    /// `NovelReaderBottomChrome.progressSummary` renders below the content
    /// text in paged mode. Derived from caption2 font metrics so it tracks
    /// Dynamic Type deterministically — pagination must never depend on a
    /// measured, after-the-fact chrome height or layout would feed back
    /// into itself.
    var pagedProgressSummaryHeight: CGFloat {
        let lineHeight = ceil(UIFont.preferredFont(forTextStyle: .caption2).lineHeight)
        return lineHeight * 2 + bottomChromeLayout.progressSummaryLineSpacing
    }

    /// The extra bottom inset paged pagination reserves beyond the safe
    /// area so the last text line ends above the progress summary. This is
    /// what makes `pagedProgressSummaryMovesBelowContentText` actually true.
    func pagedContentBottomReserve(forBottomInset bottomInset: CGFloat) -> CGFloat {
        bottomChromeLayout.pagedContentBottomReserve(
            forBottomInset: bottomInset,
            progressSummaryHeight: pagedProgressSummaryHeight
        )
    }

    // MARK: - Boundary-pull badge avoidance (vertical mode)

    /// Fallback chrome avoidance used until the measured top chrome height
    /// arrives (first layout pass reports 0).
    var boundaryPullTopChromeFallbackAvoidance: CGFloat { 140 }

    /// Fallback chrome avoidance used until the measured bottom chrome
    /// height arrives.
    var boundaryPullBottomChromeFallbackAvoidance: CGFloat { 210 }

    /// Extra clearance between the bottom chrome and the pull badge; the
    /// bottom chrome sits taller than its measured frame suggests because
    /// the progress summary hangs below the control stack.
    var boundaryPullBottomChromeClearance: CGFloat { 55 }

    /// Minimum distance from the screen edge on inset-less devices.
    var boundaryPullMinimumEdgeClearance: CGFloat { 24 }

    /// Breathing room between the badge and whatever it was pushed off of.
    var boundaryPullBadgeSpacing: CGFloat { 8 }

    func boundaryPullTopPadding(
        topInset: CGFloat,
        isChromeVisible: Bool,
        measuredTopChromeHeight: CGFloat
    ) -> CGFloat {
        let chromeAvoidance = isChromeVisible
            ? max(measuredTopChromeHeight, topInset + boundaryPullTopChromeFallbackAvoidance)
            : 0
        return max(chromeAvoidance, topInset, boundaryPullMinimumEdgeClearance) + boundaryPullBadgeSpacing
    }

    func boundaryPullBottomPadding(
        bottomInset: CGFloat,
        isChromeVisible: Bool,
        measuredBottomChromeHeight: CGFloat
    ) -> CGFloat {
        let chromeAvoidance = isChromeVisible
            ? max(measuredBottomChromeHeight, bottomInset + boundaryPullBottomChromeFallbackAvoidance)
                + boundaryPullBottomChromeClearance
            : 0
        return max(chromeAvoidance, bottomInset, boundaryPullMinimumEdgeClearance) + boundaryPullBadgeSpacing
    }
}
#endif

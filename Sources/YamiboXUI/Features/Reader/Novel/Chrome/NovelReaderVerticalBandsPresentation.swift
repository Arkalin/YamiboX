import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct NovelReaderVerticalBandsPresentation: Equatable, Sendable {
    private let bottomChromeLayout = ReaderBottomChromeLayoutPresentation()

    init() {}


    var pagedTopBandHeight: CGFloat { 48 }

    var padVisibleStatusBarTopInset: CGFloat { 32 }


    var pagedProgressSummaryHeight: CGFloat {
        let lineHeight = ReaderInformationTypography.lineHeight
        return lineHeight * 2 + bottomChromeLayout.progressSummaryLineSpacing
    }

    func pagedContentBottomReserve(forBottomInset bottomInset: CGFloat) -> CGFloat {
        bottomChromeLayout.pagedContentBottomReserve(
            forBottomInset: bottomInset,
            progressSummaryHeight: pagedProgressSummaryHeight
        )
    }


    var boundaryPullTopChromeFallbackAvoidance: CGFloat { 140 }

    var boundaryPullBottomChromeFallbackAvoidance: CGFloat { 210 }

    var boundaryPullBottomChromeClearance: CGFloat { 55 }

    var boundaryPullMinimumEdgeClearance: CGFloat { 24 }

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

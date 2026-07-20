import CoreGraphics
import Testing
import UIKit
@testable import YamiboXUI

// The vertical band definitions are the single source of truth shared by
// pagination (`NovelReaderView.readerLayout`), the paged viewports and the
// bottom chrome. These tests pin the geometric contract that used to be
// scattered as per-site constants — most importantly that the paged text
// band ends above the two-line progress summary.

private let bands = NovelReaderVerticalBandsPresentation()
private let bottomChrome = ReaderBottomChromeLayoutPresentation()

@Test func pagedTextBandEndsAboveProgressSummaryOnEveryInsetProfile() {
    // 0 = inset-less device, 20 = iPad home indicator, 34 = iPhone home
    // indicator, 60 = hypothetical future hardware.
    for bottomInset: CGFloat in [0, 8, 20, 34, 60] {
        let reserve = bands.pagedContentBottomReserve(forBottomInset: bottomInset)
        // Pagination subtracts safe area and chrome reserve separately, so
        // the last text line ends `bottomInset + reserve` above the screen
        // bottom; the summary's top edge sits at its bottom padding plus
        // its own height.
        let textClearance = bottomInset + reserve
        let summaryTop = bottomChrome.bottomPadding(forBottomInset: bottomInset)
            + bands.pagedProgressSummaryHeight
        #expect(
            textClearance - summaryTop >= bottomChrome.pagedProgressSummaryContentGap,
            "bottomInset \(bottomInset): text clearance \(textClearance) must clear summary top \(summaryTop) by the gap"
        )
    }
}

@Test func pagedBottomReserveIsNeverNegative() {
    for bottomInset: CGFloat in [0, 20, 34, 100, 500] {
        #expect(bands.pagedContentBottomReserve(forBottomInset: bottomInset) >= 0)
    }
    // Pure-function clamp: a huge inset with no summary would otherwise go
    // negative (padding 82 + 0 + 8 − 100).
    #expect(bottomChrome.pagedContentBottomReserve(forBottomInset: 100, progressSummaryHeight: 0) == 0)
}

@Test func pagedBottomReserveComposesPaddingSummaryAndGap() {
    let height: CGFloat = 30
    // iPad-like: inset 20 → chrome bottom padding max(20−18, 8) = 8.
    #expect(bottomChrome.pagedContentBottomReserve(forBottomInset: 20, progressSummaryHeight: height)
        == 8 + height + bottomChrome.pagedProgressSummaryContentGap - 20)
    // iPhone-like: inset 34 → padding 16.
    #expect(bottomChrome.pagedContentBottomReserve(forBottomInset: 34, progressSummaryHeight: height)
        == 16 + height + bottomChrome.pagedProgressSummaryContentGap - 34)
}

@Test func progressSummaryHeightTracksCaptionTwoMetrics() {
    let lineHeight = ceil(UIFont.preferredFont(forTextStyle: .caption2).lineHeight)
    #expect(bands.pagedProgressSummaryHeight
        == lineHeight * 2 + bottomChrome.progressSummaryLineSpacing)
    // Two readable lines can't be shorter than this on any content size.
    #expect(bands.pagedProgressSummaryHeight > 20)
}

@Test func pagedTopBandAndPadStatusBarInsetKeepFrozenValues() {
    // Frozen pagination inputs: changing either re-paginates every saved
    // book, so a change here must be deliberate.
    #expect(bands.pagedTopBandHeight == 48)
    #expect(bands.padVisibleStatusBarTopInset == 32)
}

@Test func boundaryPullPaddingsMatchTheFormerInlineFormulas() {
    // Chrome hidden: only edge clearance applies.
    let topHidden = bands.boundaryPullTopPadding(topInset: 32, isChromeVisible: false, measuredTopChromeHeight: 0)
    #expect(topHidden == 40)
    let bottomHidden = bands.boundaryPullBottomPadding(bottomInset: 20, isChromeVisible: false, measuredBottomChromeHeight: 0)
    #expect(bottomHidden == 32)
    // Chrome visible, measurement not yet delivered: fallback avoidance.
    let topFallback = bands.boundaryPullTopPadding(topInset: 32, isChromeVisible: true, measuredTopChromeHeight: 0)
    #expect(topFallback == 180)
    let bottomFallback = bands.boundaryPullBottomPadding(bottomInset: 20, isChromeVisible: true, measuredBottomChromeHeight: 0)
    #expect(bottomFallback == 293)
    // Chrome visible with real measurements: measured height dominates.
    let topMeasured = bands.boundaryPullTopPadding(topInset: 32, isChromeVisible: true, measuredTopChromeHeight: 300)
    #expect(topMeasured == 308)
    let bottomMeasured = bands.boundaryPullBottomPadding(bottomInset: 20, isChromeVisible: true, measuredBottomChromeHeight: 400)
    #expect(bottomMeasured == 463)
}

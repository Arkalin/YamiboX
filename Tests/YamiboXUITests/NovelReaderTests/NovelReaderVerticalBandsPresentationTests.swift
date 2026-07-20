import CoreGraphics
import Testing
import UIKit
@testable import YamiboXUI

// The vertical band definitions are the single source of truth shared by
// pagination (`NovelReaderView.readerLayout`), the paged viewports and the
// bottom chrome. These tests pin the geometric contract that used to be
// scattered as per-site constants.

private let bands = NovelReaderVerticalBandsPresentation()

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

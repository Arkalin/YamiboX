import XCTest
@testable import YamiboXUI

final class NovelNovelReaderChromeStateTests: XCTestCase {
    func testVerticalLoadingTapRevealsChrome() {
        var state = NovelReaderChromeState(showsChrome: false)
        state.update(
            isLoading: true,
            errorMessage: nil,
            hasPages: false,
            hasPresentedOverlay: false,
            usesVerticalReadingMode: true
        )

        state.toggleChrome()
        XCTAssertTrue(state.showsChrome)
        XCTAssertEqual(state.mode, .visible)
    }

    func testLoadingOverlayAllowsChromeForEveryLoadingReason() {
        for reason in 0..<4 {
            let presentation = NovelReaderLoadingOverlayPresentation(
                isLoading: true,
                hasSurfaces: reason != 0,
                isApplyingAppearanceSettings: reason == 1,
                isNavigatingNovelReaderProjection: reason == 2,
                shouldConcealViewportContent: reason == 3
            )
            XCTAssertTrue(presentation.isPresented)
            XCTAssertTrue(presentation.allowsChrome)
        }
    }

    func testInitialContentLoadAutoHidesOnce() {
        var state = NovelReaderChromeState()

        state.update(
            isLoading: true,
            errorMessage: nil,
            hasPages: false,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .loading)
        XCTAssertTrue(state.showsChrome)

        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .immersiveHidden)
        XCTAssertTrue(state.hasCompletedInitialAutoHide)

        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .immersiveHidden)
    }

    func testVerticalInitialLoadHidesChrome() {
        var state = NovelReaderChromeState()

        state.update(
            isLoading: true,
            errorMessage: nil,
            hasPages: false,
            hasPresentedOverlay: false,
            usesVerticalReadingMode: true
        )

        XCTAssertEqual(state.mode, .loading)
        XCTAssertFalse(state.showsChrome)
    }

    func testManualVisibleStateSurvivesRepeatedContentUpdates() {
        var state = NovelReaderChromeState()
        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        state.toggleChrome()
        XCTAssertEqual(state.mode, .visible)

        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .visible)

        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .visible)
    }

    func testManualHiddenStateSurvivesRotationLikeLayoutUpdates() {
        var state = NovelReaderChromeState()
        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .immersiveHidden)

        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .immersiveHidden)
    }

    func testOverlayRestoresPreviousVisibleState() {
        var state = NovelReaderChromeState()
        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        state.toggleChrome()
        XCTAssertEqual(state.mode, .visible)

        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: true
        )
        XCTAssertEqual(state.mode, .visible)

        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .visible)
    }

    func testOverlayRestoresPreviousHiddenState() {
        var state = NovelReaderChromeState()
        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .immersiveHidden)

        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: true
        )
        XCTAssertEqual(state.mode, .visible)

        state.update(
            isLoading: false,
            errorMessage: nil,
            hasPages: true,
            hasPresentedOverlay: false
        )
        XCTAssertEqual(state.mode, .immersiveHidden)
    }
}

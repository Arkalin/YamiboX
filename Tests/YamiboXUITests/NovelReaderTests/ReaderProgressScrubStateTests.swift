import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class ReaderProgressScrubStateTests: XCTestCase {
    func testReaderChromeProgressMapsScrubFractionToNeutralTargetIndex() {
        let progress = ReaderChromeProgress(
            itemCount: 6,
            currentIndex: 3,
            primaryText: "目录 · 60%",
            secondaryText: "第 4 / 6 页",
            ticks: [
                ReaderChromeProgressTick(targetIndex: 0, positionFraction: 0, title: "第一章", isCurrent: false),
                ReaderChromeProgressTick(targetIndex: 3, positionFraction: 0.6, title: "第二章", isCurrent: true),
            ],
            scrubTargetIndexes: [0, 2, 4]
        )

        XCTAssertEqual(progress.itemCount, 6)
        XCTAssertEqual(progress.currentIndex, 3)
        XCTAssertEqual(progress.progressFraction, 0.6, accuracy: 0.001)
        XCTAssertEqual(progress.percentText, "60%")
        XCTAssertEqual(progress.targetIndex(forProgressFraction: 0.75), 4)
        XCTAssertEqual(progress.title(forTargetIndex: 4), "第二章")
        XCTAssertEqual(progress.tickTargetIndex(forTargetIndex: 3), 3)
        XCTAssertEqual(progress.positionFraction(forTargetIndex: 4), 0.8, accuracy: 0.001)
    }

    func testUpdatingScrubClampsValueAndBuildsPreviewWithoutCommit() {
        var state = ReaderProgressScrubState()
        let context = ReaderChromeProgress(
            itemCount: 5,
            currentIndex: 1,
            primaryText: "目录 · 25%",
            ticks: [
                ReaderChromeProgressTick(targetIndex: 0, positionFraction: 0, title: "第一章", isCurrent: false),
                ReaderChromeProgressTick(targetIndex: 2, positionFraction: 0.5, title: "第二章", isCurrent: true),
            ]
        ).scrubContext

        let update = state.update(value: 99, context: context)

        XCTAssertEqual(state.phase, .scrubbing)
        XCTAssertEqual(state.value, 1)
        XCTAssertEqual(state.targetIndex, 4)
        XCTAssertEqual(state.preview, ReaderProgressScrubPreview(chapterTitle: "第二章", pageNumber: 5))
        XCTAssertEqual(state.preview?.targetIndex, 4)
        XCTAssertNil(update.committedTargetIndex)
    }

    func testScrubPreviewCarriesTargetIndexWhileKeepingLegacyDefault() {
        let legacyPreview = ReaderProgressScrubPreview(chapterTitle: nil, pageNumber: 6)
        let explicitPreview = ReaderProgressScrubPreview(chapterTitle: nil, pageNumber: 6, targetIndex: 2)

        XCTAssertEqual(legacyPreview.pageNumber, 6)
        XCTAssertEqual(legacyPreview.targetIndex, 5)
        XCTAssertEqual(explicitPreview.pageNumber, 6)
        XCTAssertEqual(explicitPreview.targetIndex, 2)
    }

    func testCommitReturnsOneTargetPageAndCommitHaptic() {
        var state = ReaderProgressScrubState()
        let context = ReaderChromeProgress(
            itemCount: 5,
            currentIndex: 0,
            primaryText: "目录 · 0%"
        ).scrubContext

        _ = state.update(value: 0.75, context: context)
        let commit = state.end()

        XCTAssertEqual(state.phase, .ended)
        XCTAssertEqual(commit.committedTargetIndex, 3)
        XCTAssertEqual(commit.haptics, [.commit])
    }

    func testHapticsFireForStartAndChapterTickButNotEveryPage() {
        var state = ReaderProgressScrubState()
        let context = ReaderChromeProgress(
            itemCount: 6,
            currentIndex: 0,
            primaryText: "目录 · 0%",
            ticks: [
                ReaderChromeProgressTick(targetIndex: 0, positionFraction: 0, title: nil, isCurrent: true),
                ReaderChromeProgressTick(targetIndex: 2, positionFraction: 0.4, title: nil, isCurrent: false),
                ReaderChromeProgressTick(targetIndex: 5, positionFraction: 1, title: nil, isCurrent: false),
            ]
        ).scrubContext

        XCTAssertEqual(state.update(value: 0.2, context: context).haptics, [.start])
        XCTAssertEqual(state.update(value: 0.4, context: context).haptics, [.chapterTick])
        XCTAssertEqual(state.update(value: 0.6, context: context).haptics, [])
    }

    func testFastDragSkippingPastATickIndexStillFiresChapterTick() {
        var state = ReaderProgressScrubState()
        let context = ReaderChromeProgress(
            itemCount: 6,
            currentIndex: 0,
            primaryText: "目录 · 0%",
            ticks: [
                ReaderChromeProgressTick(targetIndex: 0, positionFraction: 0, title: nil, isCurrent: true),
                ReaderChromeProgressTick(targetIndex: 2, positionFraction: 0.4, title: nil, isCurrent: false),
                ReaderChromeProgressTick(targetIndex: 5, positionFraction: 1, title: nil, isCurrent: false),
            ]
        ).scrubContext

        // A single fast onChanged delivery can jump straight from index 1 to
        // index 3, skipping index 2 (the exact tick position) entirely. The
        // crossing must still be felt.
        XCTAssertEqual(state.update(value: 0.2, context: context).haptics, [.start])
        XCTAssertEqual(state.update(value: 0.6, context: context).haptics, [.chapterTick])
    }

    func testStartingScrubWithinCurrentChapterDoesNotFireSpuriousTick() {
        var state = ReaderProgressScrubState()
        let context = ReaderChromeProgress(
            itemCount: 6,
            currentIndex: 3,
            primaryText: "目录 · 60%",
            ticks: [
                ReaderChromeProgressTick(targetIndex: 0, positionFraction: 0, title: nil, isCurrent: false),
                ReaderChromeProgressTick(targetIndex: 2, positionFraction: 0.4, title: nil, isCurrent: true),
                ReaderChromeProgressTick(targetIndex: 5, positionFraction: 1, title: nil, isCurrent: false),
            ]
        ).scrubContext

        // Resting position (index 3) is already inside the chapter started by
        // the tick at index 2. The first move within that same chapter must
        // not fire a chapter tick, only the start haptic.
        XCTAssertEqual(state.update(value: 0.6, context: context).haptics, [.start])
        XCTAssertEqual(state.update(value: 0.8, context: context).haptics, [])
        XCTAssertEqual(state.update(value: 1.0, context: context).haptics, [.chapterTick])
    }

    func testPreviewFallsBackToPageOnlyWhenChapterTitleIsUnavailable() {
        var state = ReaderProgressScrubState()
        let context = ReaderChromeProgress(
            itemCount: 6,
            currentIndex: 2,
            primaryText: "目录 · 40%"
        ).scrubContext

        _ = state.update(value: 0.5, context: context)

        XCTAssertEqual(state.preview?.displayText, "第4页")
    }

    func testDragMappingUsesCurrentProgressAsAnchorInsteadOfFingerStartLocation() {
        let horizontal = ReaderProgressDragMapping.value(
            startProgressFraction: 0.25,
            translation: 20,
            length: 200,
            range: 0...100
        )
        let vertical = ReaderProgressDragMapping.value(
            startProgressFraction: 0.60,
            translation: -30,
            length: 300,
            range: 0...100
        )

        XCTAssertEqual(horizontal, 35, accuracy: 0.001)
        XCTAssertEqual(vertical, 50, accuracy: 0.001)
    }

    func testPagedChromePresentationUsesHorizontalScrubbingCapsule() {
        let presentation = ReaderProgressChromePresentation(readingMode: .paged, isChromeVisible: true)

        XCTAssertEqual(presentation.horizontalCapsuleText(percentText: "37%"), "目录 · 37%")
        XCTAssertTrue(presentation.showsHorizontalFill)
        XCTAssertTrue(presentation.supportsHorizontalScrub)
        XCTAssertTrue(presentation.horizontalCapsuleUsesIndependentTapAndDrag)
        XCTAssertFalse(presentation.showsConventionalSlider)
        XCTAssertFalse(presentation.showsVerticalScrubber)
    }

    func testVerticalChromePresentationUsesDirectoryCapsuleAndVisibleVerticalScrubber() {
        let visible = ReaderProgressChromePresentation(readingMode: .vertical, isChromeVisible: true)
        let hidden = ReaderProgressChromePresentation(readingMode: .vertical, isChromeVisible: false)

        XCTAssertEqual(visible.horizontalCapsuleText(percentText: "64%"), "目录 · 64%")
        XCTAssertFalse(visible.showsHorizontalFill)
        XCTAssertFalse(visible.supportsHorizontalScrub)
        XCTAssertTrue(visible.showsVerticalScrubber)
        XCTAssertFalse(hidden.showsVerticalScrubber)
    }

    func testBottomActionRowHidesDuringScrubWithoutLosingLayout() {
        let resting = ReaderBottomActionRowPresentation(isScrubbing: false)
        let scrubbing = ReaderBottomActionRowPresentation(isScrubbing: true)

        XCTAssertEqual(resting.actions.map(\.kind), [.browser, .bookmark, .cache])
        XCTAssertTrue(resting.actions.first(where: { $0.kind == .bookmark })?.isDisabled == true)
        XCTAssertEqual(resting.opacity, 1)
        XCTAssertTrue(resting.allowsHitTesting)
        XCTAssertFalse(resting.isAccessibilityHidden)

        XCTAssertEqual(scrubbing.opacity, 0)
        XCTAssertFalse(scrubbing.allowsHitTesting)
        XCTAssertTrue(scrubbing.isAccessibilityHidden)
        XCTAssertTrue(scrubbing.preservesLayout)
    }

    func testBottomChromeSeparatesProgressCapsuleFromActionButtons() {
        let presentation = ReaderBottomChromeLayoutPresentation()

        XCTAssertTrue(presentation.usesIndependentControls)
        XCTAssertEqual(presentation.panelSpacing, 10)
        XCTAssertEqual(presentation.maxChromeWidth, 260)
        XCTAssertEqual(presentation.progressPanelHeight, 44)
        XCTAssertEqual(presentation.actionButtonIconFrame, 34)
        XCTAssertEqual(presentation.actionButtonRowHeight, presentation.progressPanelHeight)
        XCTAssertEqual(presentation.actionButtonSpacing, 8)
        XCTAssertEqual(presentation.bottomControlsAdditionalBottomOffset, 8)
        XCTAssertEqual(presentation.horizontalAlignment, .trailing)
        XCTAssertTrue(presentation.progressTextLeadsIcon)
        XCTAssertTrue(presentation.progressFillHasVerticalTrailingEdge)
        XCTAssertFalse(presentation.horizontalProgressThumbVisible)
        XCTAssertTrue(presentation.horizontalChapterTicksVisibleOnlyWhileScrubbing)
        XCTAssertTrue(presentation.directoryChapterTicksDoNotRequireProgressFill)
        XCTAssertTrue(presentation.horizontalDirectoryContentHiddenWhileScrubbing)
        XCTAssertTrue(presentation.progressCapsulesUseButtonTint)
        XCTAssertTrue(presentation.progressSummaryVisibleWhileScrubbing)
    }

    func testReaderChromeVisibilityAnimationContracts() {
        let fade = ReaderChromeVisibilityAnimationPresentation.fade
        let popup = ReaderChromeVisibilityAnimationPresentation.anchoredPopup

        XCTAssertEqual(fade.kind, .fade)
        XCTAssertEqual(fade.duration, 0.2)
        XCTAssertEqual(fade.hiddenScale, 1)
        XCTAssertNil(fade.anchor)

        XCTAssertEqual(popup.kind, .anchoredPopup)
        XCTAssertEqual(popup.duration, 0.2)
        XCTAssertEqual(popup.hiddenScale, 0.88)
        XCTAssertEqual(popup.anchor, .bottomTrailing)
    }

    func testReaderChromeSummarySeparatesChapterAndProgressLines() {
        let summary = ReaderChromeProgressSummary(
            chapterTitle: "20主导权",
            progressText: "第 75 / 144 页 · 网页第 2 / 5 页 · 20主导权"
        )

        XCTAssertEqual(summary.chapterTitle, "20主导权")
        XCTAssertEqual(summary.pageProgressLine, "第 75 / 144 页")
        XCTAssertEqual(summary.webProgressLine, "网页第 2 / 5 页")
    }

    func testVerticalProgressScrubberMatchesDirectoryCapsuleLayout() {
        let presentation = ReaderBottomChromeLayoutPresentation()

        XCTAssertEqual(presentation.verticalScrubberWidth, presentation.progressPanelHeight)
        XCTAssertEqual(
            presentation.verticalScrubberHeight,
            presentation.progressPanelHeight * 3 + presentation.panelSpacing * 3 + presentation.actionButtonRowHeight
        )
        XCTAssertEqual(presentation.verticalPreviewWidth, presentation.maxChromeWidth)
        XCTAssertEqual(presentation.verticalPreviewHeight, 50)
        XCTAssertTrue(presentation.verticalScrubberShowsChapterTicks)
        XCTAssertTrue(presentation.verticalChapterTicksVisibleOnlyWhileScrubbing)
        XCTAssertTrue(presentation.verticalScrubberFillHasSquareEdge)
        XCTAssertTrue(presentation.hidesDirectoryCapsuleDuringVerticalScrub)
        XCTAssertEqual(presentation.verticalScrubberSideSpacing, presentation.actionButtonSpacing)
        XCTAssertTrue(presentation.verticalScrubberTicksAreCentered)
        XCTAssertFalse(presentation.verticalScrubberShowsLiveThumb)
        XCTAssertTrue(presentation.verticalScrubberBottomAlignsWithActionButtons)
        XCTAssertTrue(presentation.verticalPreviewUsesTwoLineChapterAndPage)
        XCTAssertTrue(presentation.verticalPreviewUsesLiquidGlass)
        XCTAssertTrue(presentation.horizontalPreviewMatchesVerticalCapsule)
        XCTAssertTrue(presentation.verticalScrubberShowsProgressFill)
        XCTAssertTrue(presentation.verticalCurrentChapterTickUsesAccentColor)
        XCTAssertTrue(presentation.directoryCapsuleContentUsesAccentColor)
        XCTAssertTrue(presentation.bottomProgressSummaryUsesPageCenter)
        XCTAssertTrue(presentation.verticalProgressSummaryUsesLiquidGlass)
        XCTAssertTrue(presentation.verticalChapterTitleCapsuleWrapsContent)
    }

    func testCapsuleChapterTicksUseRoundedEdgeInsets() {
        let presentation = ReaderBottomChromeLayoutPresentation()

        XCTAssertEqual(
            presentation.capsuleChapterTickCoordinate(
                position: 0,
                length: presentation.maxChromeWidth,
                edgeInset: presentation.capsuleChapterTickRoundedEdgeInset
            ),
            6
        )
        XCTAssertEqual(
            presentation.capsuleChapterTickCoordinate(
                position: 0.5,
                length: presentation.maxChromeWidth,
                edgeInset: presentation.capsuleChapterTickRoundedEdgeInset
            ),
            130
        )
        XCTAssertEqual(
            presentation.capsuleChapterTickCoordinate(
                position: 1,
                length: presentation.maxChromeWidth,
                edgeInset: presentation.capsuleChapterTickRoundedEdgeInset
            ),
            254
        )
        XCTAssertEqual(
            presentation.capsuleChapterTickCoordinate(
                position: 1,
                length: presentation.verticalScrubberHeight,
                edgeInset: presentation.capsuleChapterTickRoundedEdgeInset
            ),
            200
        )
    }

    func testCapsuleProgressFillUsesTickCoordinateScale() {
        let presentation = ReaderBottomChromeLayoutPresentation()

        XCTAssertEqual(
            presentation.capsuleProgressFillExtent(
                position: 0,
                length: presentation.maxChromeWidth,
                edgeInset: presentation.capsuleChapterTickRoundedEdgeInset
            ),
            0
        )
        XCTAssertEqual(
            presentation.capsuleProgressFillExtent(
                position: 0.5,
                length: presentation.maxChromeWidth,
                edgeInset: presentation.capsuleChapterTickRoundedEdgeInset
            ),
            presentation.capsuleChapterTickCoordinate(
                position: 0.5,
                length: presentation.maxChromeWidth,
                edgeInset: presentation.capsuleChapterTickRoundedEdgeInset
            )
        )
        XCTAssertEqual(
            presentation.capsuleProgressFillExtent(
                position: 1,
                length: presentation.maxChromeWidth,
                edgeInset: presentation.capsuleChapterTickRoundedEdgeInset
            ),
            presentation.maxChromeWidth
        )
    }

    func testFinalSpreadProgressFillIsFull() {
        let surfaceCount = 416
        let surfaces = (0..<surfaceCount).map { index in
            NovelReaderSurface(
                identity: NovelReaderSurfaceIdentity(generation: 1, ordinal: index),
                presentationIndex: index,
                kind: .text,
                documentView: 1,
                chapterTitle: nil,
                presentationSize: .zero
            )
        }
        let spreads = stride(from: 0, to: surfaceCount, by: 2).map { leftIndex in
            NovelReaderPresentationSpread(
                index: leftIndex / 2,
                leftSurfaceIndex: leftIndex,
                leftSurfaceIdentity: surfaces[leftIndex].identity,
                rightSurfaceIndex: leftIndex + 1 < surfaceCount ? leftIndex + 1 : nil,
                rightSurfaceIdentity: leftIndex + 1 < surfaceCount ? surfaces[leftIndex + 1].identity : nil,
                chapterTitle: nil
            )
        }
        let projection = NovelReaderProgressProjection(
            readingMode: .paged,
            usesTwoPageSpread: true,
            pageTurnDirection: .leftToRight,
            surfaces: surfaces,
            selectedSurfaceIndex: 414,
            spreads: spreads,
            readingState: NovelReaderReadingState(
                currentView: 1,
                maxView: 1,
                currentChapterTitle: nil,
                authorID: nil,
                currentSurfaceIntraProgress: 0
            )
        )
        let presentation = ReaderBottomChromeLayoutPresentation()

        XCTAssertEqual(projection.displayedPageLabel, "415-416")
        XCTAssertEqual(projection.selectedSurfaceIndex, 415)
        XCTAssertEqual(projection.currentSurfaceNumber, 416)
        XCTAssertEqual(projection.currentProgressFraction, 1)
        XCTAssertEqual(projection.currentProgressPercentText, "100%")
        XCTAssertEqual(
            presentation.capsuleProgressFillExtent(
                position: projection.currentProgressFraction,
                length: presentation.maxChromeWidth,
                edgeInset: presentation.capsuleChapterTickRoundedEdgeInset
            ),
            presentation.maxChromeWidth
        )
    }

    func testIntegratedProgressChromeContractsAcrossPagedAndVerticalModes() {
        let paged = ReaderProgressChromePresentation(readingMode: .paged, isChromeVisible: true)
        let verticalVisible = ReaderProgressChromePresentation(readingMode: .vertical, isChromeVisible: true)
        let verticalHidden = ReaderProgressChromePresentation(readingMode: .vertical, isChromeVisible: false)
        let restingActions = ReaderBottomActionRowPresentation(isScrubbing: false)
        let scrubbingActions = ReaderBottomActionRowPresentation(isScrubbing: true)

        XCTAssertFalse(paged.showsConventionalSlider)
        XCTAssertTrue(paged.supportsHorizontalScrub)
        XCTAssertTrue(paged.showsHorizontalFill)
        XCTAssertFalse(paged.showsVerticalScrubber)

        XCTAssertFalse(verticalVisible.supportsHorizontalScrub)
        XCTAssertFalse(verticalVisible.showsHorizontalFill)
        XCTAssertTrue(verticalVisible.showsVerticalScrubber)
        XCTAssertFalse(verticalHidden.showsVerticalScrubber)

        XCTAssertTrue(restingActions.actions.contains(ReaderBottomAction(kind: .bookmark, isDisabled: true)))
        XCTAssertEqual(scrubbingActions.opacity, 0)
        XCTAssertFalse(scrubbingActions.allowsHitTesting)
        XCTAssertTrue(scrubbingActions.preservesLayout)
    }
}

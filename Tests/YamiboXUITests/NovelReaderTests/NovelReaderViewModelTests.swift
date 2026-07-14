import Foundation
import CoreGraphics
import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

private typealias NovelTextLayoutFixture = @Sendable (
    NovelReaderProjection,
    NovelReaderAppearanceSettings,
    NovelReaderLayout
) throws -> NovelTextLayoutResult

final class NovelReaderViewModelTests: XCTestCase {
    func testPagedPagerIdentityChangesWhenRotationChangesPagedLayout() {
        let portrait = NovelReaderLayout(
            containerSize: CGSize(width: 1032, height: 1376),
            readingMode: .paged
        )
        let landscape = NovelReaderLayout(
            containerSize: CGSize(width: 1376, height: 1032),
            readingMode: .paged
        )

        let portraitIdentity = ReaderPagedPagerIdentity(
            visibleView: 1,
            surfaceCount: 342,
            spreadCount: 342,
            usesTwoPageSpread: false,
            layout: portrait
        )
        let landscapeIdentity = ReaderPagedPagerIdentity(
            visibleView: 1,
            surfaceCount: 342,
            spreadCount: 171,
            usesTwoPageSpread: true,
            layout: landscape
        )

        XCTAssertNotEqual(portraitIdentity, landscapeIdentity)
    }

    func testPagedPagerIdentityIgnoresCurrentPageChanges() {
        let layout = NovelReaderLayout(
            containerSize: CGSize(width: 1376, height: 1032),
            readingMode: .paged
        )

        let first = ReaderPagedPagerIdentity(
            visibleView: 1,
            surfaceCount: 342,
            spreadCount: 171,
            usesTwoPageSpread: true,
            layout: layout
        )
        let second = ReaderPagedPagerIdentity(
            visibleView: 1,
            surfaceCount: 342,
            spreadCount: 171,
            usesTwoPageSpread: true,
            layout: layout
        )

        XCTAssertEqual(first, second)
    }

    func testChapterTextFormatterSplitsLeadingChapterTitle() {
        let split = NovelChapterTextComponents.split(
            text: "第一章\n这里是正文",
            chapterTitle: "第一章"
        )

        XCTAssertEqual(split.title, "第一章")
        XCTAssertEqual(split.body, "\n这里是正文")
    }

    func testChapterTextFormatterDoesNotSplitWhenTitleIsNotLeadingLine() {
        let split = NovelChapterTextComponents.split(
            text: "序章\n第一章",
            chapterTitle: "第一章"
        )

        XCTAssertNil(split.title)
        XCTAssertNil(split.body)
    }

    func testMovesAcrossWebViewBoundaries() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第三章", "第四章"]),
            ]
        )

        await MainActor.run {
            model.jumpToSurface(model.surfaceCount - 1)
            XCTAssertEqual(model.currentSurfaceNumber, model.surfaceCount)
        }

        await model.jumpRelativeSurface(1)
        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentSurfaceNumber, 1)
        }

        await model.jumpRelativeSurface(-1)
        await MainActor.run {
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(model.currentSurfaceNumber, model.surfaceCount)
        }
    }

    func testWebViewBoundaryNavigationPublishesLoadingOverlayState() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章", "第三章", "第四章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第五章", "第六章"]),
            ]
        )
        let navigationStateRecorder = await MainActor.run {
            let recorder = NovelReaderNavigationStateRecorder()
            let gate = NovelReaderNavigationOverlayGate()
            model.novelReaderPageDocumentNavigationOverlayPreparation = {
                await gate.prepare()
            }
            model.novelReaderPageDocumentNavigationStateDidChange = { state in
                recorder.record(state)
            }
            return (recorder, gate)
        }

        let navigationTask = Task {
            await model.jumpToWebView(2)
        }

        try await waitFor {
            await MainActor.run {
                navigationStateRecorder.1.didEnterPreparation
            }
        }

        await MainActor.run {
            XCTAssertTrue(navigationStateRecorder.0.states.contains(true))
            XCTAssertTrue(model.isNavigatingNovelReaderProjection)
            XCTAssertEqual(model.currentView, 1)
            navigationStateRecorder.1.release()
        }
        await navigationTask.value

        await MainActor.run {
            XCTAssertEqual(navigationStateRecorder.0.states, [true, false])
            XCTAssertFalse(model.isNavigatingNovelReaderProjection)
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentSurfaceNumber, 1)
        }
    }

    func testNavigationHistoryRestoresPreviousNovelReadingPositionAcrossWebViews() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第三章", "第四章"]),
            ]
        )

        await MainActor.run {
            XCTAssertEqual(model.currentView, 1)
            XCTAssertFalse(model.navigation.canNavigateBack)
            XCTAssertFalse(model.navigation.canNavigateForward)
        }

        await model.jumpToWebView(2)
        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertTrue(model.navigation.canNavigateBack)
            XCTAssertFalse(model.navigation.canNavigateForward)
        }

        await model.navigation.navigateBack()
        await MainActor.run {
            XCTAssertEqual(model.currentView, 1)
            XCTAssertFalse(model.navigation.canNavigateBack)
            XCTAssertTrue(model.navigation.canNavigateForward)
        }

        await model.navigation.navigateForward()
        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertTrue(model.navigation.canNavigateBack)
            XCTAssertFalse(model.navigation.canNavigateForward)
        }
    }

    func testNavigationHistoryClearsAfterFiveLinearPagedSurfaceTurns() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"]),
            ]
        )

        await MainActor.run {
            model.jumpToSurface(1)
            XCTAssertTrue(model.navigation.canNavigateBack)
            XCTAssertFalse(model.navigation.canNavigateForward)
        }

        for _ in 0..<4 {
            await model.jumpRelativeSurface(1)
        }
        await MainActor.run {
            XCTAssertTrue(model.navigation.canNavigateBack)
            XCTAssertFalse(model.navigation.canNavigateForward)
        }

        await model.jumpRelativeSurface(1)
        await MainActor.run {
            XCTAssertFalse(model.navigation.canNavigateBack)
            XCTAssertFalse(model.navigation.canNavigateForward)
        }
    }

    func testNavigationHistoryClearsAfterFiveLinearVerticalSurfaceChanges() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"]),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .vertical)
        )

        await MainActor.run {
            model.jumpToSurface(1)
            XCTAssertTrue(model.navigation.canNavigateBack)
            model.updateVerticalViewportPosition(surfaceIndex: 1, intraSurfaceProgress: 0.2, force: true)
            model.updateVerticalViewportPosition(surfaceIndex: 1, intraSurfaceProgress: 0.5, force: true)
            XCTAssertTrue(model.navigation.canNavigateBack)

            for surfaceIndex in 2...5 {
                model.updateVerticalViewportPosition(surfaceIndex: surfaceIndex, intraSurfaceProgress: 0.3, force: true)
            }
            XCTAssertTrue(model.navigation.canNavigateBack)

            model.updateVerticalViewportPosition(surfaceIndex: 6, intraSurfaceProgress: 0.3, force: true)
            XCTAssertFalse(model.navigation.canNavigateBack)
            XCTAssertFalse(model.navigation.canNavigateForward)
        }
    }

    func testNavigationHistoryRestoreDoesNotPresentNovelReaderProjectionNavigationOverlay() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章", "第三章"]),
            ]
        )
        let navigationStateRecorder = await MainActor.run {
            let recorder = NovelReaderNavigationStateRecorder()
            model.novelReaderPageDocumentNavigationOverlayPreparation = {}
            model.novelReaderPageDocumentNavigationStateDidChange = { state in
                recorder.record(state)
            }
            return recorder
        }

        await MainActor.run {
            model.jumpToSurface(model.surfaceCount - 1)
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(model.currentSurfaceNumber, model.surfaceCount)
            XCTAssertTrue(model.navigation.canNavigateBack)
            navigationStateRecorder.removeAll()
        }

        await model.navigation.navigateBack()

        await MainActor.run {
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(model.currentSurfaceNumber, 1)
            XCTAssertFalse(model.isNavigatingNovelReaderProjection)
            XCTAssertEqual(navigationStateRecorder.states, [])
        }
    }

    func testPreviousWebViewBoundaryNavigationLandsOnPreviousLastSurfaceAfterOverlay() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章", "第三章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第四章", "第五章"]),
            ]
        )
        await model.jumpToWebView(2)
        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentSurfaceNumber, 1)
        }
        let navigationStateRecorder = await MainActor.run {
            let recorder = NovelReaderNavigationStateRecorder()
            let gate = NovelReaderNavigationOverlayGate()
            model.novelReaderPageDocumentNavigationOverlayPreparation = {
                await gate.prepare()
            }
            model.novelReaderPageDocumentNavigationStateDidChange = { state in
                recorder.record(state)
            }
            return (recorder, gate)
        }

        let navigationTask = Task {
            await model.jumpRelativeSurface(-1)
        }

        try await waitFor {
            await MainActor.run {
                navigationStateRecorder.1.didEnterPreparation
            }
        }

        await MainActor.run {
            XCTAssertTrue(navigationStateRecorder.0.states.contains(true))
            XCTAssertTrue(model.isNavigatingNovelReaderProjection)
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentSurfaceNumber, 1)
            navigationStateRecorder.1.release()
        }
        await navigationTask.value

        await MainActor.run {
            XCTAssertEqual(navigationStateRecorder.0.states, [true, false])
            XCTAssertFalse(model.isNavigatingNovelReaderProjection)
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(model.currentSurfaceNumber, model.surfaceCount)
        }
    }

    func testPublishesPresentationAndRequestsDisplayReferencesBySurfaceIdentity() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"]),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )

        let initialPresentation = try await MainActor.run {
            try XCTUnwrap(model.novelReaderPresentation)
        }
        let initialSurface = try XCTUnwrap(initialPresentation.selectedSurfaceIdentity)
        let initialReference = await MainActor.run {
            model.novelTextViewportDisplayReference(for: initialSurface)
        }
        let initialReferenceGeneration = await MainActor.run {
            initialReference?.generation
        }
        let modelPageIdentities = await MainActor.run {
            viewportSurfaces(in: model).map(\.surfaceOrdinal)
        }

        XCTAssertEqual(initialReferenceGeneration, initialPresentation.generation)
        XCTAssertEqual(initialPresentation.surfaces.map(\.presentationIndex), modelPageIdentities)

        await MainActor.run {
            model.jumpToSurface(min(1, max(model.surfaceCount - 1, 0)))
        }

        let navigatedPresentation = try await MainActor.run {
            try XCTUnwrap(model.novelReaderPresentation)
        }

        XCTAssertEqual(navigatedPresentation.generation, initialPresentation.generation)
        XCTAssertEqual(navigatedPresentation.revision, initialPresentation.revision + 1)
    }

    func testTracksChapterBoundaries() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"]),
            ]
        )

        await MainActor.run {
            XCTAssertEqual(model.currentChapterTitle, "第一章")
            XCTAssertFalse(model.hasPreviousChapter)
            XCTAssertTrue(model.hasNextChapter)
        }

        await MainActor.run {
            model.jumpToAdjacentChapter(1)
            XCTAssertEqual(model.currentChapterTitle, "第二章")
            XCTAssertTrue(model.hasPreviousChapter)
            XCTAssertFalse(model.hasNextChapter)
        }

        await MainActor.run {
            model.jumpToAdjacentChapter(1)
            XCTAssertEqual(model.currentChapterTitle, "第二章")
        }
    }

    func testCurrentChapterDirectoryChapterUsesOccurrenceInsteadOfTitle() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["同名章", "同名章"]),
            ]
        )

        await MainActor.run {
            let chapters = model.navigation.visibleChapterDirectoryChapters
            XCTAssertEqual(chapters.map(\.title), ["同名章", "同名章"])
            XCTAssertTrue(chapters.indices.contains(1))

            model.jumpToSurface(chapters[1].startIndex)

            XCTAssertEqual(model.navigation.currentChapterDirectoryIndex, 1)
            XCTAssertFalse(model.navigation.isCurrentChapterDirectoryChapter(chapters[0]))
            XCTAssertTrue(model.navigation.isCurrentChapterDirectoryChapter(chapters[1]))
        }
    }

    func testClampsWebJumpAndReportsProgress() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第三章", "第四章"]),
            ]
        )

        await MainActor.run {
            model.jumpToSurface(model.surfaceCount - 1)
            XCTAssertEqual(model.currentProgressFraction, 1)
            XCTAssertEqual(model.currentProgressPercentText, "100%")
        }

        await model.jumpToWebView(99)
        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentSurfaceNumber, 1)
            XCTAssertEqual(model.currentWebViewText, "网页 2 / 2")
            XCTAssertEqual(model.directoryWebTitle, "网页 2 / 2 的章节")
        }
    }

    func testPreviewingChapterDirectoryWebViewDoesNotMoveReadingPosition() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第三章", "第四章"]),
            ]
        )

        await MainActor.run {
            model.jumpToSurface(model.surfaceCount - 1)
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(model.currentChapterTitle, "第二章")
        }

        await model.navigation.previewChapterDirectoryWebView(2)

        await MainActor.run {
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(model.currentChapterTitle, "第二章")
            XCTAssertEqual(model.currentSurfaceNumber, model.surfaceCount)
            XCTAssertEqual(model.navigation.visibleChapterDirectoryView, 2)
            XCTAssertEqual(model.navigation.visibleChapterDirectoryChapters.map(\.title), ["第三章", "第四章"])
            XCTAssertEqual(model.navigation.previousChapterDirectoryWebView, 1)
            XCTAssertNil(model.navigation.nextChapterDirectoryWebView)
            XCTAssertNil(model.navigation.currentChapterDirectoryIndex)
        }
    }

    func testPreviewingCurrentChapterDirectoryWebViewReturnsToReadingDirectory() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第三章", "第四章"]),
            ]
        )

        await model.navigation.previewChapterDirectoryWebView(2)
        await MainActor.run {
            XCTAssertEqual(model.navigation.visibleChapterDirectoryView, 2)
            XCTAssertEqual(model.navigation.previousChapterDirectoryWebView, 1)
            XCTAssertNil(model.navigation.nextChapterDirectoryWebView)
        }

        await model.navigation.previewChapterDirectoryWebView(1)

        await MainActor.run {
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(model.navigation.visibleChapterDirectoryView, 1)
            XCTAssertNil(model.navigation.previousChapterDirectoryWebView)
            XCTAssertEqual(model.navigation.nextChapterDirectoryWebView, 2)
            XCTAssertEqual(model.navigation.visibleChapterDirectoryChapters.map(\.title), ["第一章", "第二章"])
            XCTAssertEqual(model.navigation.currentChapterDirectoryIndex, model.currentChapterIndex)
        }
    }

    func testSelectingPreviewedChapterDirectoryChapterMovesReaderToThatChapter() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第三章", "第四章"]),
            ]
        )

        await model.navigation.previewChapterDirectoryWebView(2)
        let target = try await MainActor.run {
            try XCTUnwrap(model.navigation.visibleChapterDirectoryChapters.first(where: { $0.title == "第四章" }))
        }
        await model.navigation.jumpToChapterDirectoryChapter(target)

        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentChapterTitle, "第四章")
            XCTAssertEqual(model.navigation.visibleChapterDirectoryView, model.visibleView)
            XCTAssertEqual(model.navigation.visibleChapterDirectoryChapters.map(\.title), ["第三章", "第四章"])
        }
    }

    func testSelectingPreviewedChapterDirectoryChapterKeepsPagedSelectionOnTargetPage() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第三章", "第四章", "第五章"]),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )

        await model.navigation.previewChapterDirectoryWebView(2)
        let target = try await MainActor.run {
            try XCTUnwrap(model.navigation.visibleChapterDirectoryChapters.first(where: { $0.title == "第五章" }))
        }
        await model.navigation.jumpToChapterDirectoryChapter(target)

        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentChapterTitle, "第五章")
            XCTAssertGreaterThan(model.pagedViewportSelectionIndex, 0)
            XCTAssertEqual(viewportSurfaces(in: model)[model.selectedSurfaceIndex].chapterTitle, "第五章")
        }
    }

    func testChapterTitleHelperResolvesSurfaceChapter() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"]),
            ]
        )

        await MainActor.run {
            XCTAssertEqual(model.chapterTitle(forSurfaceIndex: 0), "第一章")
            XCTAssertEqual(model.chapterTitle(forSurfaceIndex: model.surfaceCount - 1), "第二章")
            XCTAssertEqual(model.chapterTitle(forSurfaceIndex: 999), "第二章")
        }
    }

    func testProgressChapterTickStartIndexMatchesChapterBoundaryPages() async throws {
        let model = try await makeModel(
            documents: [
                makeImageDocument(view: 1, maxView: 1, surfaceCount: 5),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )

        await MainActor.run {
            XCTAssertEqual(model.progressChapterTickStartIndex(forSurfaceIndex: 0), 0)
            XCTAssertEqual(model.progressChapterTickStartIndex(forSurfaceIndex: 3), 3)
            XCTAssertEqual(model.progressChapterTickStartIndex(forSurfaceIndex: 999), 4)
        }
    }

    func testTargetSurfaceIndexMapsPagedAndVerticalProgress() async throws {
        let pagedModel = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"]),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )
        let verticalModel = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"]),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .vertical)
        )

        await MainActor.run {
            XCTAssertEqual(pagedModel.targetSurfaceIndex(forProgressValue: -3), 0)
            XCTAssertEqual(pagedModel.targetSurfaceIndex(forProgressValue: 999), pagedModel.surfaceCount - 1)
            XCTAssertEqual(verticalModel.targetSurfaceIndex(forProgressValue: 0), 0)
            XCTAssertEqual(verticalModel.targetSurfaceIndex(forProgressValue: 100), verticalModel.surfaceCount - 1)
        }
    }

    func testVerticalProgressScrubContextUsesCachedCurrentViewSurfaceMapping() async throws {
        let model = try await makeModel(
            documents: [
                makeImageDocument(view: 1, maxView: 1, surfaceCount: 5),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .vertical)
        )

        await MainActor.run {
            let context = model.verticalProgressScrubContext

            XCTAssertEqual(context.targetIndex(0), 0)
            XCTAssertEqual(context.targetIndex(0.5), 2)
            XCTAssertEqual(context.targetIndex(1), 4)
            XCTAssertEqual(context.targetIndex(-0.25), 0)
            XCTAssertEqual(context.targetIndex(2.5), 4)
            XCTAssertEqual(context.title(2), "第3章")
            XCTAssertEqual(context.tickTargetIndex(2), 2)
        }
    }

    func testChromeProgressSnapshotUsesLargeVerticalProjection() async throws {
        let model = try await makeModel(
            documents: [
                makeImageDocument(view: 1, maxView: 1, surfaceCount: 800),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .vertical)
        )

        await MainActor.run {
            model.selectSurface(799)
            let snapshot = model.chromeProgressSnapshot

            XCTAssertEqual(snapshot.surfaceCount, 800)
            XCTAssertEqual(snapshot.currentSurfaceNumber, 800)
            XCTAssertEqual(snapshot.currentProgressPercentText, "100%")
            XCTAssertEqual(snapshot.targetSurfaceIndex(forProgressValue: 0), 0)
            XCTAssertEqual(snapshot.targetSurfaceIndex(forProgressValue: 50), 399)
            XCTAssertEqual(snapshot.targetSurfaceIndex(forProgressValue: 100), 799)
            XCTAssertEqual(snapshot.chapterTitle(forSurfaceIndex: 399), "第400章")
            XCTAssertEqual(snapshot.progressChapterTickStartIndex(forSurfaceIndex: 399), 399)

            let revision = model.novelReaderPresentation?.revision
            for _ in 0..<100 {
                _ = model.chromeProgressSnapshot.progressText
                _ = model.chromeProgressSnapshot.currentProgressPercentText
                _ = model.chromeProgressSnapshot.progressChapterTicks
                _ = model.chromeProgressSnapshot.progressScrubContext.targetIndex(0.5)
            }
            XCTAssertEqual(model.novelReaderPresentation?.revision, revision)
        }
    }

    func testVerticalProgressScrubContextClampsSingleSurfaceWithoutChapters() async throws {
        let document = NovelReaderProjection(
            threadID: "445566",
            view: 1,
            maxView: 1,
            segments: [
                .text("没有章节标题的正文。", chapterTitle: nil),
            ]
        )
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(readingMode: .vertical)
        )

        await MainActor.run {
            let context = model.verticalProgressScrubContext

            XCTAssertEqual(context.targetIndex(0), 0)
            XCTAssertEqual(context.targetIndex(0.5), 0)
            XCTAssertEqual(context.targetIndex(1), 0)
            XCTAssertNil(context.title(0))
            XCTAssertNil(context.tickTargetIndex(0))
        }
    }

    func testVerticalNearEndPrefetchDoesNotMergeNextWebView() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第三章"]),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .vertical)
        )

        await MainActor.run {
            model.selectSurface(max(model.surfaceCount - 1, 0))
        }

        try await waitFor {
            await MainActor.run {
                model.currentProgressPercentText == "100%"
            }
        }

        await MainActor.run {
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(Set(viewportSurfaces(in: model).map(\.documentView)), [1])
            XCTAssertEqual(model.currentProgressPercentText, "100%")
            XCTAssertEqual(
                model.targetSurfaceIndex(forProgressValue: 100),
                viewportSurfaces(in: model).lastIndex(where: { $0.documentView == 1 })
            )
        }

        await model.jumpRelativeSurface(1)

        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentSurfaceNumber, 1)
            XCTAssertEqual(Set(viewportSurfaces(in: model).map(\.documentView)), [2])
        }
    }

    func testPagedNearEndPrefetchDoesNotMergeNextWebView() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章", "第二章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第三章"]),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )

        await MainActor.run {
            model.selectSurface(max(model.surfaceCount - 1, 0))
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(Set(viewportSurfaces(in: model).map(\.documentView)), [1])
        }
    }

    func testProgressSliderPreviewLabelUsesEditingTargetPage() async throws {
        let model = try await makeModel(
            documents: [
                makeImageDocument(view: 1, maxView: 1, surfaceCount: 5),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )

        await MainActor.run {
            let targetIndex = model.targetSurfaceIndex(forProgressValue: 3)
            XCTAssertEqual(targetIndex, 3)
            XCTAssertEqual(
                model.progressSliderLabelText(
                    isEditing: true,
                    sliderValue: 3,
                    targetSurfaceIndex: targetIndex
                ),
                "4 / 5"
            )
            XCTAssertEqual(
                model.progressSliderLabelText(
                    isEditing: false,
                    sliderValue: 3,
                    targetSurfaceIndex: targetIndex
                ),
                "1 / 5"
            )
        }
    }

    func testChromeProgressProjectionUsesNeutralProgressForSharedChrome() async throws {
        let model = try await makeModel(
            documents: [
                makeImageDocument(view: 1, maxView: 1, surfaceCount: 5),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )

        await MainActor.run {
            model.selectSurface(2)
            let progress = model.chromeProgressSnapshot.chromeProgress

            XCTAssertEqual(progress.itemCount, 5)
            XCTAssertEqual(progress.currentIndex, 2)
            XCTAssertEqual(progress.progressFraction, 0.5, accuracy: 0.001)
            XCTAssertEqual(progress.percentText, "50%")
            XCTAssertEqual(progress.targetIndex(forProgressFraction: 0.75), 3)
            XCTAssertEqual(progress.positionFraction(forTargetIndex: 3), 0.75, accuracy: 0.001)
            XCTAssertEqual(progress.title(forTargetIndex: 2), "第3章")
            XCTAssertEqual(progress.tickTargetIndex(forTargetIndex: 2), 2)
        }
    }

    func testTwoPageSpreadRequiresPadLandscapePagedModeAndSetting() async throws {
        let document = makeImageDocument(view: 1, maxView: 1, surfaceCount: 5)
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(
                showsTwoPagesInLandscapeOnPad: true,
                readingMode: .paged
            )
        )

        await MainActor.run {
            XCTAssertFalse(model.isTwoPageSpreadActive)
        }
        await model.commitNovelTextPresentationEnvironment(isPad: true)
        await MainActor.run {
            XCTAssertFalse(model.isTwoPageSpreadActive)
        }

        await model.commitNovelTextLayout(
            NovelReaderLayout(
                width: 844,
                height: 390,
                readingMode: .paged
            )
        )
        await MainActor.run {
            XCTAssertTrue(model.isTwoPageSpreadActive)
        }

        await model.commitNovelTextAppearance(
            NovelReaderAppearanceSettings(
                showsTwoPagesInLandscapeOnPad: true,
                readingMode: .vertical
            )
        )
        await MainActor.run {
            XCTAssertFalse(model.isTwoPageSpreadActive)
        }

        await model.commitNovelTextAppearance(
            NovelReaderAppearanceSettings(
                showsTwoPagesInLandscapeOnPad: false,
                readingMode: .paged
            )
        )
        await MainActor.run {
            XCTAssertFalse(model.isTwoPageSpreadActive)
        }
    }

    func testTwoPageSpreadBuildsExpectedPairsAndProgressText() async throws {
        let document = makeImageDocument(view: 1, maxView: 1, surfaceCount: 5)
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(
                showsTwoPagesInLandscapeOnPad: true,
                readingMode: .paged
            )
        )

        await model.commitNovelTextPresentationEnvironment(isPad: true)
        await model.commitNovelTextLayout(
            NovelReaderLayout(
                width: 844,
                height: 390,
                readingMode: .paged
            )
        )

        await MainActor.run {
            XCTAssertEqual(
                model.presentationSpreads.map { "\($0.leftSurfaceIndex)-\($0.rightSurfaceIndex.map(String.init) ?? "nil")" },
                ["0-1", "2-3", "4-nil"]
            )
            XCTAssertEqual(model.selectedSurfaceIndex, 1)
            XCTAssertEqual(model.currentSurfaceNumber, 2)
            XCTAssertEqual(model.pagedViewportSelectionIndex, 0)
            XCTAssertTrue(model.progressText.contains("第 1-2 / 5 页"))

            model.jumpToSurface(4)
            XCTAssertEqual(model.selectedSurfaceIndex, 4)
            XCTAssertEqual(model.pagedViewportSelectionIndex, 2)
            XCTAssertTrue(model.progressText.contains("第 5 / 5 页"))
        }
    }

    func testLeftToRightTwoPageSpreadMapsSliderAndPagingToRightAnchor() async throws {
        let document = makeImageDocument(view: 1, maxView: 1, surfaceCount: 6)
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(
                showsTwoPagesInLandscapeOnPad: true,
                readingMode: .paged
            )
        )

        await model.commitNovelTextPresentationEnvironment(isPad: true)
        await model.commitNovelTextLayout(
            NovelReaderLayout(
                width: 844,
                height: 390,
                readingMode: .paged
            )
        )

        await MainActor.run {
            XCTAssertEqual(model.targetSurfaceIndex(forProgressValue: 1), 1)
            XCTAssertEqual(model.targetSurfaceIndex(forProgressValue: 5), 5)

            model.jumpToSurface(0)
            XCTAssertEqual(model.selectedSurfaceIndex, 1)
            model.jumpToSurface(3)
            XCTAssertEqual(model.selectedSurfaceIndex, 3)
        }

        await model.jumpRelativeSurface(1)
        await MainActor.run {
            XCTAssertEqual(model.selectedSurfaceIndex, 5)
            XCTAssertEqual(model.currentSurfaceNumber, 6)
        }

        await MainActor.run {
            model.selectPagedViewportIndex(1)
            XCTAssertEqual(model.selectedSurfaceIndex, 3)
        }
    }

    func testRightToLeftTwoPageSpreadMapsSliderAndPagingToLeftAnchor() async throws {
        let document = makeImageDocument(view: 1, maxView: 1, surfaceCount: 6)
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(
                showsTwoPagesInLandscapeOnPad: true,
                readingMode: .paged,
                pageTurnDirection: .rightToLeft
            )
        )

        await model.commitNovelTextPresentationEnvironment(isPad: true)
        await model.commitNovelTextLayout(
            NovelReaderLayout(
                width: 844,
                height: 390,
                readingMode: .paged
            )
        )

        await MainActor.run {
            XCTAssertEqual(model.targetSurfaceIndex(forProgressValue: 1), 0)
            XCTAssertEqual(model.targetSurfaceIndex(forProgressValue: 5), 4)

            model.jumpToSurface(1)
            XCTAssertEqual(model.selectedSurfaceIndex, 0)
            model.jumpToSurface(3)
            XCTAssertEqual(model.selectedSurfaceIndex, 2)
        }

        await model.jumpRelativeSurface(1)
        await MainActor.run {
            XCTAssertEqual(model.selectedSurfaceIndex, 4)
            XCTAssertEqual(model.currentSurfaceNumber, 5)
        }

        await MainActor.run {
            model.selectPagedViewportIndex(1)
            XCTAssertEqual(model.selectedSurfaceIndex, 2)
        }
    }

    func testTwoPageSpreadMovesToNextWebViewAfterLastCompleteSpread() async throws {
        let model = try await makeModel(
            documents: [
                makeImageDocument(view: 1, maxView: 2, surfaceCount: 6),
                makeImageDocument(view: 2, maxView: 2, surfaceCount: 4),
            ],
            settings: NovelReaderAppearanceSettings(
                showsTwoPagesInLandscapeOnPad: true,
                readingMode: .paged
            )
        )

        await model.commitNovelTextPresentationEnvironment(isPad: true)
        await model.commitNovelTextLayout(
            NovelReaderLayout(
                width: 844,
                height: 390,
                readingMode: .paged
            )
        )

        await MainActor.run {
            model.jumpToSurface(5)
            XCTAssertEqual(model.selectedSurfaceIndex, 5)
            XCTAssertEqual(model.pagedViewportSelectionIndex, 2)
        }

        await model.jumpRelativeSurface(1)

        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.selectedSurfaceIndex, 1)
            XCTAssertEqual(model.pagedViewportSelectionIndex, 0)
        }
    }

    func testTwoPageSpreadRepaginatesTextForHalfWidthColumns() async throws {
        let document = NovelReaderProjection(
            threadID: "9911",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 420), chapterTitle: "第一章")
            ]
        )
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(
                showsTwoPagesInLandscapeOnPad: true,
                readingMode: .paged
            )
        )

        await model.commitNovelTextPresentationEnvironment(isPad: true)
        await model.commitNovelTextLayout(
            NovelReaderLayout(
                width: 844,
                height: 390,
                readingMode: .paged
            )
        )
        await MainActor.run {
            XCTAssertTrue(model.isTwoPageSpreadActive)
            XCTAssertGreaterThan(model.surfaceCount, 0)
            XCTAssertFalse(model.presentationSpreads.isEmpty)
        }
    }

    func testLatestLandscapeLayoutSupersedesInFlightPortraitLayoutMatchingCommittedLayout() async throws {
        let document = NovelReaderProjection(
            threadID: "9912",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 前台恢复布局竞态。", count: 1_200), chapterTitle: "第一章")
            ]
        )
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(
                showsTwoPagesInLandscapeOnPad: true,
                readingMode: .paged
            )
        )
        let portrait = NovelReaderLayout(
            width: 1032,
            height: 1376,
            readingMode: .paged
        )
        let landscape = NovelReaderLayout(
            width: 1376,
            height: 1032,
            readingMode: .paged
        )

        await model.commitNovelTextPresentationEnvironment(isPad: true)
        await model.commitNovelTextLayout(landscape)
        await MainActor.run {
            model.jumpToSurface(max(model.surfaceCount / 2, 0))
        }

        let initialState = try await MainActor.run {
            (
                try XCTUnwrap(model.novelReaderPresentation),
                try XCTUnwrap(model.novelReaderDebugState),
                try XCTUnwrap(model.currentNovelResumePoint)
            )
        }
        let gate = NovelReaderLayoutUpdatePreparationGate(blockedLayout: portrait)
        await MainActor.run {
            model.runtimeUpdatePreparation = { update in
                await gate.prepare(update)
            }
        }

        let portraitTask = Task {
            await model.commitNovelTextLayout(portrait)
        }
        await gate.waitUntilBlocked()

        await model.commitNovelTextLayout(landscape)
        await gate.release()
        await portraitTask.value

        await MainActor.run {
            let finalPresentation = try? XCTUnwrap(model.novelReaderPresentation)
            let finalDebugState = try? XCTUnwrap(model.novelReaderDebugState)
            let finalResumePoint = try? XCTUnwrap(model.currentNovelResumePoint)

            XCTAssertTrue(model.isTwoPageSpreadActive)
            XCTAssertEqual(finalPresentation?.generation, initialState.0.generation + 1)
            XCTAssertEqual(finalPresentation?.surfaces.count, initialState.0.surfaces.count)
            XCTAssertEqual(finalDebugState?.fingerprints?.layout, initialState.1.fingerprints?.layout)
            XCTAssertEqual(
                finalDebugState?.transactions.committedTransactionCount,
                initialState.1.transactions.committedTransactionCount + 1
            )
            XCTAssertEqual(finalResumePoint?.view, initialState.2.view)
            XCTAssertEqual(finalResumePoint?.chapterIdentity, initialState.2.chapterIdentity)
            XCTAssertEqual(finalResumePoint?.textSegmentIdentity, initialState.2.textSegmentIdentity)
            XCTAssertEqual(finalResumePoint?.displayedTextOffset, initialState.2.displayedTextOffset)
            XCTAssertNil(model.errorMessage)
        }
    }

    func testRepeatedCommittedLayoutDoesNotCreateRuntimeTransaction() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"])
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )
        let layout = NovelReaderLayout(
            width: 844,
            height: 390,
            readingMode: .paged
        )

        await model.commitNovelTextLayout(layout)
        let committedState = try await MainActor.run {
            (
                try XCTUnwrap(model.novelReaderPresentation),
                try XCTUnwrap(model.novelReaderDebugState)
            )
        }

        await model.commitNovelTextLayout(layout)

        await MainActor.run {
            XCTAssertEqual(model.novelReaderPresentation?.generation, committedState.0.generation)
            XCTAssertEqual(
                model.novelReaderDebugState?.transactions,
                committedState.1.transactions
            )
        }
    }

    func testFailedLayoutRequestCanRetrySameLayout() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"])
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )
        let targetLayout = NovelReaderLayout(
            width: 390,
            height: 844,
            readingMode: .paged
        )
        let initialState = try await MainActor.run {
            (
                try XCTUnwrap(model.novelReaderPresentation),
                try XCTUnwrap(model.novelReaderDebugState)
            )
        }
        let failureInjector = NovelReaderLayoutUpdateFailureInjector(failingLayout: targetLayout)
        await MainActor.run {
            model.runtimeUpdatePreparation = { update in
                try await failureInjector.prepare(update)
            }
        }

        await model.commitNovelTextLayout(targetLayout)
        await MainActor.run {
            XCTAssertEqual(model.novelReaderPresentation?.generation, initialState.0.generation)
            XCTAssertEqual(model.novelReaderDebugState?.transactions, initialState.1.transactions)
            XCTAssertEqual(model.errorMessage, NovelTextLayoutFailure.textKitIndexing.localizedDescription)
        }

        await model.commitNovelTextLayout(targetLayout)

        let attemptCount = await failureInjector.attemptCount
        await MainActor.run {
            XCTAssertEqual(attemptCount, 2)
            XCTAssertEqual(model.novelReaderPresentation?.generation, initialState.0.generation + 1)
            XCTAssertNotEqual(
                model.novelReaderDebugState?.fingerprints?.layout,
                initialState.1.fingerprints?.layout
            )
            XCTAssertEqual(
                model.novelReaderDebugState?.transactions.committedTransactionCount,
                initialState.1.transactions.committedTransactionCount + 1
            )
        }
    }

    // Reproduces the "My Likes" jump-to-original bug: the reader's very first
    // layout pass (before the presenting view's real geometry has settled)
    // can be implausibly narrow, so the initial load fails with
    // `.textKitIndexing` before `readingWorkflow.state` is ever set. Without
    // a retry, `commitNovelTextLayout`'s `readingWorkflow?.state != nil`
    // guard treats that as "nothing to refresh" forever, so the corrected
    // layout that follows moments later is silently dropped and the reader
    // is stuck on the error permanently.
    func testInitialLoadFailureRecoversWhenValidLayoutFollows() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let settings = NovelReaderAppearanceSettings(readingMode: .paged)
        let document = makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"])
        try await settingsStore.save(AppSettings(novelReader: settings))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .forum
                ),
                appContext: appContext,
                pagination: { document, settings, layout in
                    // Mirrors the production TextKit adapter's minimum-width
                    // guard (`NovelTextKitRuntimeAdapter.indexSurfaceRanges`).
                    guard layout.readableFrame.width >= 120 else {
                        throw NovelTextLayoutFailure.textKitIndexing
                    }
                    return try novelReaderViewModelSegmentPagination(document: document, settings: settings, layout: layout)
                }
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 80, height: 568))
        await MainActor.run {
            XCTAssertNil(model.novelReaderPresentation)
            XCTAssertEqual(model.errorMessage, NovelTextLayoutFailure.textKitIndexing.localizedDescription)
        }

        await model.commitNovelTextLayout(NovelReaderLayout(width: 320, height: 568))
        await MainActor.run {
            XCTAssertNotNil(model.novelReaderPresentation)
            XCTAssertNil(model.errorMessage)
        }
    }

    func testApplySettingsUpdatesStoredReaderSettings() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"]),
            ]
        )
        let updated = NovelReaderAppearanceSettings(
            fontScale: 1.2,
            fontFamily: .rounded,
            lineHeightScale: 1.7,
            characterSpacingScale: 0.05,
            horizontalPadding: 22,
            usesJustifiedText: true,
            loadsInlineImages: false,
            showsAuthorRepliesToOthers: false,
            backgroundStyle: .paper,
            readingMode: .vertical,
            translationMode: .traditional
        )

        await model.commitNovelTextAppearance(updated)
        await MainActor.run {
            XCTAssertEqual(model.settings, updated)
        }
    }

    func testLayoutSettingsFailureKeepsCommittedSettingsAndDoesNotPersistDraft() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let initialSettings = NovelReaderAppearanceSettings(fontScale: 1.0, readingMode: .paged)
        let document = makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"])
        try await settingsStore.save(AppSettings(novelReader: initialSettings))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .forum
                ),
                appContext: appContext,
            pagination: { document, settings, layout in
                if settings.fontScale > 1.1 {
                    throw NovelTextLayoutFailure.textKitIndexing
                }
                return try novelReaderViewModelSegmentPagination(document: document, settings: settings, layout: layout)
            }
        )
        }
        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        var failedSettings = initialSettings
        failedSettings.fontScale = 1.2

        await model.commitNovelTextAppearance(failedSettings)
        await MainActor.run {
            XCTAssertEqual(model.settings, initialSettings)
            XCTAssertEqual(model.errorMessage, NovelTextLayoutFailure.textKitIndexing.localizedDescription)
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let loaded = await settingsStore.load()
        XCTAssertEqual(loaded.novelReader, initialSettings)
    }

    func testSurfaceOnlyAppearanceSettingsPublishRevisionWithoutRuntimeRebuild() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let initialSettings = NovelReaderAppearanceSettings(backgroundStyle: .system, readingMode: .paged)
        let document = makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"])
        try await settingsStore.save(AppSettings(novelReader: initialSettings))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .forum
                ),
                appContext: appContext,
                pagination: novelReaderViewModelPreviewSourcePagination
            )
        }
        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        let initialPresentation = try await MainActor.run { try XCTUnwrap(model.novelReaderPresentation) }
        var updatedSettings = initialSettings
        updatedSettings.backgroundStyle = .paper

        await model.commitNovelTextAppearance(updatedSettings)
        let updatedPresentation = try await MainActor.run { try XCTUnwrap(model.novelReaderPresentation) }

        XCTAssertEqual(updatedPresentation.generation, initialPresentation.generation)
        XCTAssertEqual(updatedPresentation.revision, initialPresentation.revision + 1)
        XCTAssertEqual(updatedPresentation.committedSettings, updatedSettings)

        try await waitFor {
            await settingsStore.load().novelReader == updatedSettings
        }
    }

    func testApplySettingsPersistsSharedApplePencilSettingsWithoutOverwritingMangaSettings() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let document = makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章"])
        let initialMangaSettings = MangaReaderSettings(
            readingMode: .paged,
            pageEdgeFillStyle: .system,
            brightness: 0.82,
            zoomEnabled: false,
            showsTwoPagesInLandscapeOnPad: true,
            directorySortOrder: .descending
        )
        try await settingsStore.save(
            AppSettings(
                novelReader: NovelReaderAppearanceSettings(readingMode: .paged),
                manga: initialMangaSettings
            )
        )
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .forum
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination
            )
        }
        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        let updatedNovelReaderSettings = NovelReaderAppearanceSettings(
            fontScale: 1.2,
            readingMode: .vertical
        )
        let updatedApplePencilSettings = ApplePencilPageTurnSettings(
            isEnabled: true,
            behavior: .doubleTapNextSqueezePrevious
        )
        await model.commitNovelTextAppearance(
            updatedNovelReaderSettings,
            applePencilPageTurnSettings: updatedApplePencilSettings
        )

        try await waitFor {
            let loaded = await settingsStore.load()
            return loaded.novelReader == updatedNovelReaderSettings &&
                loaded.system.applePencilPageTurn == updatedApplePencilSettings
        }

        let loaded = await settingsStore.load()
        XCTAssertEqual(loaded.manga, initialMangaSettings)
    }

    func testNovelTextLayoutFailureSurfacesAsReaderErrorWithoutEmptyContent() async throws {
        let failure = NovelTextLayoutFailure.textKitIndexing
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章"])
            ],
            pagination: { _, _, _ in throw failure }
        )

        await MainActor.run {
            XCTAssertEqual(model.errorMessage, failure.localizedDescription)
            XCTAssertTrue(viewportSurfaces(in: model).isEmpty)
            XCTAssertFalse(model.isLoading)
        }
    }

    func testChapterDirectoryPreviewDoesNotCreateLayoutCandidate() async throws {
        let failure = NovelTextLayoutFailure.textKitIndexing
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 2, chapterTitles: ["第一章"]),
                makeDocument(view: 2, maxView: 2, chapterTitles: ["第二章"])
            ],
            pagination: { document, settings, layout in
                guard document.view == 1 else { throw failure }
                return try novelReaderViewModelSegmentPagination(
                    document: document,
                    settings: settings,
                    layout: layout
                )
            }
        )

        await model.navigation.previewChapterDirectoryWebView(2)

        await MainActor.run {
            XCTAssertNil(model.navigation.chapterDirectory.error)
            XCTAssertEqual(model.navigation.visibleChapterDirectoryView, 2)
            XCTAssertEqual(model.navigation.visibleChapterDirectoryChapters.map(\.title), ["第二章"])
            XCTAssertEqual(model.navigation.chapterDirectory.pageCount, 0)
            XCTAssertFalse(model.navigation.chapterDirectory.isLoading)
        }
    }

    func testChapterDirectoryPreviewHidesAuthorRepliesToOthersAcrossWebViews() async throws {
        let threadID = "889900"
        let documents = [
            NovelReaderProjection(
                threadID: threadID,
                view: 1,
                maxView: 2,
                resolvedAuthorID: "42",
                segments: [
                    .text(String(repeating: "第一章 正文。", count: 40), chapterTitle: "第一章"),
                    .text(String(repeating: "读者甲 发表于 2026-5-1\n楼主回复。", count: 12), chapterTitle: "读者甲 发表于 2026-5-1"),
                ],
                segmentSources: [
                    NovelReaderSegmentSource(ownerPostID: "1001"),
                    NovelReaderSegmentSource(ownerPostID: "1002", isAuthorReplyToOther: true),
                ]
            ),
            NovelReaderProjection(
                threadID: threadID,
                view: 2,
                maxView: 2,
                resolvedAuthorID: "42",
                segments: [
                    .text(String(repeating: "第二章 正文。", count: 40), chapterTitle: "第二章"),
                    .text(String(repeating: "读者乙 发表于 2026-5-2\n楼主回复。", count: 12), chapterTitle: "读者乙 发表于 2026-5-2"),
                    .text(String(repeating: "第三章 正文。", count: 40), chapterTitle: "第三章"),
                ],
                segmentSources: [
                    NovelReaderSegmentSource(ownerPostID: "2001"),
                    NovelReaderSegmentSource(ownerPostID: "2002", isAuthorReplyToOther: true),
                    NovelReaderSegmentSource(ownerPostID: "2003"),
                ]
            ),
        ]
        let model = try await makeModel(
            documents: documents,
            settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false, readingMode: .vertical),
            launchContext: NovelLaunchContext(
                threadID: threadID,
                threadTitle: "测试线程",
                source: .forum,
                authorID: "42"
            )
        )

        await MainActor.run {
            XCTAssertEqual(model.navigation.visibleChapterDirectoryChapters.map(\.title), ["第一章"])
        }

        await model.navigation.previewChapterDirectoryWebView(2)

        await MainActor.run {
            XCTAssertNil(model.navigation.chapterDirectory.error)
            XCTAssertEqual(model.navigation.visibleChapterDirectoryView, 2)
            XCTAssertEqual(model.navigation.visibleChapterDirectoryChapters.map(\.title), ["第二章", "第三章"])
        }
    }

    func testUpdatingLayoutRepaginatesPagedContentAndKeepsCurrentSegment() async throws {
        let model = try await makeModel(
            documents: [
                makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章", "第三章"]),
            ],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )

        let initialPageCount = await MainActor.run { model.surfaceCount }

        await MainActor.run {
            model.jumpToSurface(min(1, max(initialPageCount - 1, 0)))
        }
        await model.commitNovelTextLayout(
            NovelReaderLayout(
                containerSize: CGSize(width: 390, height: 844),
                safeAreaInsets: NovelReaderLayoutInsets(top: 59, bottom: 34),
                contentInsets: NovelReaderLayoutInsets(leading: 16, trailing: 16),
                chromeInsets: NovelReaderLayoutInsets(top: 88, bottom: 108),
                readingMode: .paged
            )
        )

        await MainActor.run {
            XCTAssertGreaterThan(model.surfaceCount, 0)
            XCTAssertEqual(model.currentView, 1)
            XCTAssertNotNil(model.currentChapterTitle)
            XCTAssertLessThan(model.selectedSurfaceIndex, model.surfaceCount)
        }
    }

    func testSettingsPreviewTextUsesDraftTranslationModeFromOriginalDocument() async throws {
        let document = NovelReaderProjection(
            threadID: "9012",
            view: 1,
            maxView: 1,
            segments: [
                .text("聽到弓莉這麼說，我急忙收拾東西。戀上朋友的妹妹了 後記", chapterTitle: "後記")
            ]
        )
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(translationMode: .simplified)
        )

        await MainActor.run {
            XCTAssertTrue(
                model.previewText(translationMode: .none, characterCount: 80, fallback: "")
                    .contains("聽到弓莉這麼說")
            )
            XCTAssertTrue(
                model.previewText(translationMode: .simplified, characterCount: 80, fallback: "")
                    .contains("听到弓莉这么说")
            )
            XCTAssertTrue(
                model.previewText(translationMode: .traditional, characterCount: 80, fallback: "")
                    .contains("戀上朋友的妹妹了 後記")
            )
        }
    }

    func testWorkflowBackedPreviewAndProgressStayAlignedAfterVerticalViewportMovement() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let threadID = "9013"
        let document = NovelReaderProjection(
            threadID: threadID,
            view: 1,
            maxView: 1,
            resolvedAuthorID: "author-1",
            segments: [
                .text("第一段不应预览", chapterTitle: "第一章"),
                .text("第二段不应预览", chapterTitle: "第一章"),
                .text("0123456789第三段预览", chapterTitle: "第一章")
            ]
        )

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .vertical)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try makeReadingProgressStore(defaultsSuiteName: defaultsSuiteName)

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: threadID,
                    threadTitle: "测试线程",
                    source: .favorites,
                    authorID: "author-1"
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))
        let targetOffset = "0123456789".count
        let previewTarget = try await MainActor.run {
            try XCTUnwrap(
                zip(model.novelReaderSurfaces, model.novelReaderDebugState?.viewportSurfaces ?? []).first { _, page in
                    page.ranges.contains { $0.segmentIndex == 2 }
                }
            )
        }
        let intraSurfaceProgress = try pageProgress(
            in: previewTarget.1,
            segmentIndex: 2,
            segmentOffset: targetOffset
        )
        await MainActor.run {
            model.updateVerticalViewportPosition(
                surfaceIndex: previewTarget.0.presentationIndex,
                intraSurfaceProgress: intraSurfaceProgress
            )
        }

        await MainActor.run {
            let preview = model.previewText(translationMode: .none, characterCount: 40, fallback: "")
            XCTAssertTrue(preview.hasPrefix("第三段预览"))
            XCTAssertFalse(preview.contains("第一段不应预览"))
            XCTAssertFalse(preview.contains("第二段不应预览"))
        }

        let resumeContext = await model.saveProgress()

        let readingProgress = await readingProgressStore.load(threadID: threadID)
        let savedResumePoint = try XCTUnwrap(readingProgress?.novel?.novelResumePoint)
        XCTAssertEqual(savedResumePoint.textSegmentIdentity, try XCTUnwrap(document.semantics(forSegmentIndex: 2)?.textSegmentIdentity))
        XCTAssertEqual(savedResumePoint.displayedTextOffset, targetOffset)
        XCTAssertEqual(resumeContext.initialResumePoint, savedResumePoint)
        XCTAssertEqual(resumeContext.initialView, savedResumePoint.view)
    }

    func testForumNovelProgressDoesNotCreateFavorite() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let document = makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章", "第三章"])

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .paged)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try makeReadingProgressStore(defaultsSuiteName: defaultsSuiteName)

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .forum
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))
        await MainActor.run {
            model.selectSurface(1)
            model.selectSurface(2)
        }
        await model.saveProgress()

        let favorites = try await appContext.localFavoriteLibraryStore.load().items
        let readingProgress = await readingProgressStore.load(threadID: document.threadID)
        XCTAssertTrue(favorites.isEmpty)
        XCTAssertNotNil(readingProgress?.novel)
    }

    func testNovelProgressPersistsReaderResumeRoute() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let readerResumeRouteStore = try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "readerRoute")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let document = makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章", "第三章"])

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .paged)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try makeReadingProgressStore(defaultsSuiteName: defaultsSuiteName)

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readerResumeRouteStore: readerResumeRouteStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .forum
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination,
                onReaderResumeRouteChange: { route in
                    try? await readerResumeRouteStore.saveReadingPosition(route)
                }
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))
        await MainActor.run {
            model.updateVerticalViewportPosition(surfaceIndex: 2, intraSurfaceProgress: 0.55, force: true)
        }
        let savedContext = await model.saveProgress()

        guard case let .novel(context)? = await readerResumeRouteStore.load() else {
            return XCTFail("Expected novel resume route")
        }
        XCTAssertEqual(context.threadID, document.threadID)
        XCTAssertEqual(context.threadTitle, "测试线程")
        XCTAssertEqual(context.source, .resume)
        XCTAssertEqual(context.initialView, 1)
        XCTAssertEqual(context.initialResumePoint?.view, 1)
        XCTAssertEqual(savedContext, context)
    }

    func testNovelProgressInPreviewModeDoesNotPersistReadingProgressOrResumeRoute() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let readerResumeRouteStore = try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "readerRoute")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let document = makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章", "第三章"])

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .paged)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try makeReadingProgressStore(defaultsSuiteName: defaultsSuiteName)

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readerResumeRouteStore: readerResumeRouteStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .like,
                    isPreview: true
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination,
                onReaderResumeRouteChange: { route in
                    try? await readerResumeRouteStore.saveReadingPosition(route)
                }
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))
        await MainActor.run {
            model.updateVerticalViewportPosition(surfaceIndex: 2, intraSurfaceProgress: 0.55, force: true)
        }
        let savedContext = await model.saveProgress()

        XCTAssertTrue(savedContext.isPreview)
        XCTAssertEqual(savedContext.initialView, 1)
        let readingProgress = await readingProgressStore.load(threadID: document.threadID)
        XCTAssertNil(readingProgress?.novel)
        let storedRoute = await readerResumeRouteStore.load()
        XCTAssertNil(storedRoute)
    }

    func testLateNovelSaveAfterDismissDoesNotRecreateReaderResumeRoute() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let readerResumeRouteStore = try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "readerRoute")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let document = makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章", "第三章"])

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .paged)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try makeReadingProgressStore(defaultsSuiteName: defaultsSuiteName)

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readerResumeRouteStore: readerResumeRouteStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let appModel = await MainActor.run {
            YamiboAppModel(appContext: appContext)
        }
        let model = await MainActor.run {
            let context = NovelLaunchContext(
                threadID: document.threadID,
                threadTitle: "测试线程",
                source: .forum
            )
            appModel.presentNovelReader(context)
            return NovelReaderViewModel(
                context: context,
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination,
                onReaderResumeRouteChange: { route in
                    appModel.updateReaderResumeRoute(route)
                }
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))
        await MainActor.run {
            model.selectSurface(2)
        }
        await model.saveProgress()
        try await waitFor {
            await readerResumeRouteStore.load() != nil
        }

        await MainActor.run {
            appModel.dismissNovelReader()
        }
        await model.saveProgress()
        try await Task.sleep(nanoseconds: 100_000_000)

        let routeAfterLateSave = await readerResumeRouteStore.load()
        XCTAssertNil(routeAfterLateSave)
    }

    func testForumNovelProgressUpdatesExistingFavorite() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let document = makeDocument(view: 1, maxView: 1, chapterTitles: ["第一章", "第二章", "第三章"])
        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .paged)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try makeReadingProgressStore(defaultsSuiteName: defaultsSuiteName)

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .forum
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))
        await MainActor.run {
            model.updateVerticalViewportPosition(surfaceIndex: 2, intraSurfaceProgress: 0.55, force: true)
        }
        await model.saveProgress()

        let readingProgress = await readingProgressStore.load(threadID: document.threadID)
        XCTAssertNotNil(readingProgress?.novel?.novelResumePoint)
    }

    func testVerticalModePersistsSemanticResumePoint() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let document = NovelReaderProjection(
            threadID: "901",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 220), chapterTitle: "第一章")
            ]
        )

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .vertical)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try makeReadingProgressStore(defaultsSuiteName: defaultsSuiteName)

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .forum
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        let targetIndex = await MainActor.run { min(2, max(model.surfaceCount - 1, 0)) }
        let targetViewportSurface = try await MainActor.run {
            try viewportSurface(in: model, surfaceIndex: targetIndex)
        }
        let targetRange = try XCTUnwrap(targetViewportSurface.ranges.first)
        await MainActor.run {
            model.updateVerticalViewportPosition(surfaceIndex: targetIndex, intraSurfaceProgress: 0.55)
        }

        try await waitFor {
            let readingProgress = await readingProgressStore.load(threadID: document.threadID)
            return readingProgress?.novel?.novelResumePoint != nil
        }

        let readingProgress = await readingProgressStore.load(threadID: document.threadID)
        let savedResumePoint = try XCTUnwrap(readingProgress?.novel?.novelResumePoint)
        XCTAssertEqual(readingProgress?.novel?.lastView, 1)
        XCTAssertEqual(readingProgress?.novel?.lastChapter, "第一章")
        XCTAssertEqual(savedResumePoint.view, 1)
        XCTAssertEqual(savedResumePoint.textSegmentIdentity, try XCTUnwrap(document.semantics(forSegmentIndex: targetRange.segmentIndex)?.textSegmentIdentity))
        XCTAssertTrue(savedResumePoint.displayedTextOffset > targetRange.startOffset)
        XCTAssertEqual(savedResumePoint.chapterTitle, "第一章")
    }

    func testVerticalModeRestoresStoredResumePointWithinChapter() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let threadID = "902"
        let document = NovelReaderProjection(
            threadID: threadID,
            view: 2,
            maxView: 2,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 120), chapterTitle: "第一章"),
                .text(String(repeating: "第二章 内容。", count: 120), chapterTitle: "第二章"),
                .text(String(repeating: "第三章 内容。", count: 120), chapterTitle: "第三章")
            ]
        )
        let pagination = try novelReaderViewModelSegmentPagination(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568)
        )
        let savedViewportSurface = try XCTUnwrap(
            pagination.viewportIndex.surfaces.first(where: { $0.chapterTitle == "第三章" && !$0.ranges.isEmpty })
        )
        let savedRange = try XCTUnwrap(savedViewportSurface.ranges.first)
        let savedSemantics = try XCTUnwrap(document.semantics(forSegmentIndex: savedRange.segmentIndex))
        let savedOffset = midpoint(in: savedRange)
        let savedResumePoint = NovelResumePoint(
            view: 2,
            chapterIdentity: savedSemantics.chapterIdentity,
            textSegmentIdentity: try XCTUnwrap(savedSemantics.textSegmentIdentity),
            displayedTextOffset: savedOffset,
            chapterOrdinal: try XCTUnwrap(savedViewportSurface.chapterOrdinal),
            chapterTitle: savedViewportSurface.chapterTitle,
            segmentProgress: 0.5,
            authorID: nil,
            readingModeHint: .vertical
        )

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .vertical)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
        try await readingProgressStore.saveNovel(
            NovelReadingPosition(
                threadID: threadID,
                view: 2,
                maxView: 2,
                chapterTitle: "第三章",
                resumePoint: savedResumePoint
            )
        )

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: threadID,
                    threadTitle: "测试线程",
                    source: .favorites
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentChapterTitle, "第三章")
            XCTAssertEqual(model.selectedSurfaceIndex, savedViewportSurface.surfaceOrdinal)
            XCTAssertEqual(viewportSurfaces(in: model)[model.selectedSurfaceIndex].ranges.first?.segmentIndex, savedRange.segmentIndex)
            XCTAssertGreaterThan(model.currentSurfaceIntraProgress, 0.2)
        }
    }

    func testVerticalModePersistsSmallIntraPageScrollAndRestoresIt() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let threadID = "905"
        let document = NovelReaderProjection(
            threadID: threadID,
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 420), chapterTitle: "第一章")
            ]
        )

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .vertical)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let launchContext = NovelLaunchContext(
            threadID: threadID,
            threadTitle: "测试线程",
            source: .favorites
        )
        let model = await MainActor.run {
            NovelReaderViewModel(context: launchContext, appContext: appContext, pagination: novelReaderViewModelSegmentPagination)
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        let targetPage = try await MainActor.run {
            try XCTUnwrap(
                viewportSurfaces(in: model).first { page in
                    page.ranges.contains { $0.length > 50 }
                }
            )
        }
        await MainActor.run {
            model.updateVerticalViewportPosition(surfaceIndex: targetPage.surfaceOrdinal, intraSurfaceProgress: 0.50)
        }
        await model.saveProgress()
        await MainActor.run {
            model.updateVerticalViewportPosition(surfaceIndex: targetPage.surfaceOrdinal, intraSurfaceProgress: 0.59)
        }
        await model.saveProgress()
        let savedReadingProgress = await readingProgressStore.load(threadID: threadID)
        let savedProgressPercent = await MainActor.run { model.currentProgressPercent }
        XCTAssertEqual(savedReadingProgress?.novel?.novelDocumentSurfaceProgressPercent, savedProgressPercent)

        let restoredModel = await MainActor.run {
            NovelReaderViewModel(context: launchContext, appContext: appContext, pagination: novelReaderViewModelSegmentPagination)
        }

        await restoredModel.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        await MainActor.run {
            XCTAssertEqual(restoredModel.selectedSurfaceIndex, targetPage.surfaceOrdinal)
            XCTAssertEqual(
                viewportSurfaces(in: restoredModel)[restoredModel.selectedSurfaceIndex].ranges.first?.segmentIndex,
                targetPage.ranges.first?.segmentIndex
            )
            XCTAssertEqual(restoredModel.currentSurfaceIntraProgress, 0.59, accuracy: 0.02)
        }
    }

    func testStoredResumePointDeterminesPositionWhenPreparingReader() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let threadID = "904"
        let document = NovelReaderProjection(
            threadID: threadID,
            view: 2,
            maxView: 2,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 160), chapterTitle: "第一章"),
                .text(String(repeating: "第二章 内容。", count: 160), chapterTitle: "第二章"),
                .text(String(repeating: "第三章 内容。", count: 160), chapterTitle: "第三章")
            ]
        )
        let pagination = try novelReaderViewModelSegmentPagination(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568)
        )
        let savedViewportSurface = try XCTUnwrap(
            pagination.viewportIndex.surfaces.first(where: { $0.chapterTitle == "第二章" && !$0.ranges.isEmpty })
        )
        let savedRange = try XCTUnwrap(savedViewportSurface.ranges.first)
        let savedSemantics = try XCTUnwrap(document.semantics(forSegmentIndex: savedRange.segmentIndex))
        let savedResumePoint = NovelResumePoint(
            view: 2,
            chapterIdentity: savedSemantics.chapterIdentity,
            textSegmentIdentity: try XCTUnwrap(savedSemantics.textSegmentIdentity),
            displayedTextOffset: savedRange.startOffset,
            chapterOrdinal: try XCTUnwrap(savedViewportSurface.chapterOrdinal),
            chapterTitle: savedViewportSurface.chapterTitle,
            segmentProgress: 0,
            authorID: nil,
            readingModeHint: .vertical
        )

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .vertical)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
        try await readingProgressStore.saveNovel(
            NovelReadingPosition(
                threadID: threadID,
                view: 2,
                maxView: 2,
                chapterTitle: "第二章",
                resumePoint: savedResumePoint
            )
        )

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: threadID,
                    threadTitle: "测试线程",
                    source: .favorites,
                    initialView: 2
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        await MainActor.run {
            XCTAssertEqual(model.currentView, 2)
            XCTAssertEqual(model.currentChapterTitle, "第二章")
            XCTAssertEqual(model.selectedSurfaceIndex, savedViewportSurface.surfaceOrdinal)
            XCTAssertEqual(viewportSurfaces(in: model)[model.selectedSurfaceIndex].ranges.first?.segmentIndex, savedRange.segmentIndex)
        }
    }

    func testPagedFavoriteLaunchKeepsSelectionOnSavedResumePoint() async throws {
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let threadID = "909"
        let document = NovelReaderProjection(
            threadID: threadID,
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 520), chapterTitle: "第一章")
            ]
        )
        let pagination = try novelReaderViewModelSegmentPagination(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568)
        )
        let savedViewportSurface = try XCTUnwrap(pagination.viewportIndex.surfaces.dropFirst().last { !$0.ranges.isEmpty })
        let savedRange = try XCTUnwrap(savedViewportSurface.ranges.first)
        let savedSemantics = try XCTUnwrap(document.semantics(forSegmentIndex: savedRange.segmentIndex))
        let savedResumePoint = NovelResumePoint(
            view: 1,
            chapterIdentity: savedSemantics.chapterIdentity,
            textSegmentIdentity: try XCTUnwrap(savedSemantics.textSegmentIdentity),
            displayedTextOffset: savedRange.startOffset,
            chapterOrdinal: try XCTUnwrap(savedViewportSurface.chapterOrdinal),
            chapterTitle: savedViewportSurface.chapterTitle,
            segmentProgress: 0,
            authorID: nil,
            readingModeHint: .paged
        )

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .paged)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
        try await readingProgressStore.saveNovel(
            NovelReadingPosition(
                threadID: threadID,
                view: 1,
                maxView: 1,
                chapterTitle: "第一章",
                resumePoint: savedResumePoint
            )
        )

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: threadID,
                    threadTitle: "测试线程",
                    source: .favorites
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        await MainActor.run {
            XCTAssertEqual(model.selectedSurfaceIndex, savedViewportSurface.surfaceOrdinal)
            XCTAssertEqual(model.pagedViewportSelectionIndex, savedViewportSurface.surfaceOrdinal)
            XCTAssertGreaterThan(model.pagedViewportSelectionIndex, 0)
            XCTAssertEqual(viewportSurfaces(in: model)[model.selectedSurfaceIndex].ranges.first?.segmentIndex, savedRange.segmentIndex)
        }
    }

    func testPagedDirectLaunchRestoresSemanticPosition() async throws {
        let document = NovelReaderProjection(
            threadID: "910",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 520), chapterTitle: "第一章")
            ]
        )
        let pagination = try novelReaderViewModelSegmentPagination(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568)
        )
        let targetViewportSurface = try XCTUnwrap(pagination.viewportIndex.surfaces.dropFirst().last { !$0.ranges.isEmpty })
        let targetRange = try XCTUnwrap(targetViewportSurface.ranges.first)
        let targetSemantics = try XCTUnwrap(document.semantics(forSegmentIndex: targetRange.segmentIndex))
        let resumePoint = NovelResumePoint(
            view: document.view,
            chapterIdentity: targetSemantics.chapterIdentity,
            textSegmentIdentity: try XCTUnwrap(targetSemantics.textSegmentIdentity),
            displayedTextOffset: targetRange.startOffset,
            chapterOrdinal: targetViewportSurface.chapterOrdinal ?? 0,
            chapterTitle: targetViewportSurface.chapterTitle,
            segmentProgress: 0,
            readingModeHint: .paged
        )
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            launchContext: NovelLaunchContext(
                threadID: document.threadID,
                threadTitle: "测试线程",
                source: .resume,
                initialView: 1,
                initialResumePoint: resumePoint
            )
        )

        await MainActor.run {
            XCTAssertEqual(model.selectedSurfaceIndex, targetViewportSurface.surfaceOrdinal)
            XCTAssertEqual(model.pagedViewportSelectionIndex, targetViewportSurface.surfaceOrdinal)
            XCTAssertGreaterThan(model.pagedViewportSelectionIndex, 0)
            XCTAssertEqual(viewportSurfaces(in: model)[model.selectedSurfaceIndex].ranges.first?.segmentIndex, targetViewportSurface.ranges.first?.segmentIndex)
        }
    }

    func testLaunchWithoutSemanticPositionStartsAtFirstSurface() async throws {
        let document = NovelReaderProjection(
            threadID: "905",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 320), chapterTitle: "第一章")
            ]
        )
        let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
        let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
        let cacheStore = NovelReaderProjectionStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        try await settingsStore.save(AppSettings(novelReader: NovelReaderAppearanceSettings(readingMode: .paged)))
        try await seedReaderSourceCaches(
            documents: [document],
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )

        let appContext = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: defaultsSuiteName, key: "session"),
            settingsStore: settingsStore,
            novelReaderCacheStore: cacheStore,
            forumCacheStore: forumCacheStore
        )
        let model = await MainActor.run {
            NovelReaderViewModel(
                context: NovelLaunchContext(
                    threadID: document.threadID,
                    threadTitle: "测试线程",
                    source: .forum,
                    initialView: 1
                ),
                appContext: appContext,
                pagination: novelReaderViewModelSegmentPagination
            )
        }

        await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))

        await MainActor.run {
            XCTAssertEqual(model.currentView, 1)
            XCTAssertEqual(model.selectedSurfaceIndex, 0)
        }
    }

    func testChangingReadingModeKeepsSemanticAnchorOnSameSegment() async throws {
        let document = NovelReaderProjection(
            threadID: "903",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 260), chapterTitle: "第一章")
            ]
        )
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            pagination: novelReaderViewModelMergedTextPagination
        )

        let originalOffset = await MainActor.run { () -> Int in
            let targetIndex = min(1, max(model.surfaceCount - 1, 0))
            model.updateVerticalViewportPosition(surfaceIndex: targetIndex, intraSurfaceProgress: 0.5)
            let page = viewportSurfaces(in: model)[targetIndex]
            return page.ranges.first.map(midpoint(in:)) ?? 0
        }

        await model.commitNovelTextAppearance(NovelReaderAppearanceSettings(readingMode: .vertical))

        await MainActor.run {
            let page = viewportSurfaces(in: model)[model.selectedSurfaceIndex]
            let viewportSurface = try? viewportSurface(in: model, surfaceIndex: model.selectedSurfaceIndex)
            XCTAssertEqual(page.chapterTitle, "第一章")
            XCTAssertEqual(viewportSurface?.ranges.first?.segmentIndex, 0)
            XCTAssertTrue(viewportSurface.map { viewportSurfaceContainsOffset($0, offset: originalOffset) } ?? false)
        }

        await model.commitNovelTextAppearance(NovelReaderAppearanceSettings(readingMode: .paged))

        await MainActor.run {
            let page = viewportSurfaces(in: model)[model.selectedSurfaceIndex]
            let viewportSurface = try? viewportSurface(in: model, surfaceIndex: model.selectedSurfaceIndex)
            XCTAssertEqual(page.chapterTitle, "第一章")
            XCTAssertEqual(viewportSurface?.ranges.first?.segmentIndex, 0)
            XCTAssertTrue(viewportSurface.map { viewportSurfaceContainsOffset($0, offset: originalOffset) } ?? false)
        }
    }

    func testChangingReadingModeFromMergedPagedTextTargetsActualSegment() async throws {
        let document = NovelReaderProjection(
            threadID: "906",
            view: 1,
            maxView: 1,
            segments: [
                .text("第一段。", chapterTitle: "第一章"),
                .text("第二段目标位置。", chapterTitle: "第一章"),
                .text("第三段。", chapterTitle: "第一章")
            ]
        )
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            pagination: novelReaderViewModelMergedTextPagination
        )

        let target = try await MainActor.run {
            let mergedPage = try XCTUnwrap(viewportSurfaces(in: model).first { $0.ranges.count >= 2 })
            let ranges = mergedPage.ranges
            let targetRange = try XCTUnwrap(ranges.first { $0.segmentIndex == 1 })
            let totalLength = ranges.reduce(0) { $0 + max($1.length, 1) }
            let precedingLength = ranges
                .prefix { $0.segmentIndex != targetRange.segmentIndex }
                .reduce(0) { $0 + max($1.length, 1) }
            let targetOffset = targetRange.startOffset + max(1, targetRange.length / 2)
            let progress = Double(precedingLength + max(1, targetRange.length / 2)) / Double(max(totalLength, 1))
            model.updateVerticalViewportPosition(surfaceIndex: mergedPage.surfaceOrdinal, intraSurfaceProgress: progress)
            return (segmentIndex: targetRange.segmentIndex, offset: targetOffset)
        }

        await model.commitNovelTextAppearance(NovelReaderAppearanceSettings(readingMode: .vertical))

        await MainActor.run {
            let page = viewportSurfaces(in: model)[model.selectedSurfaceIndex]
            let viewportSurface = try? viewportSurface(in: model, surfaceIndex: page.surfaceOrdinal)
            XCTAssertTrue(viewportSurface.map { viewportSurfaceContainsSegmentOffset($0, segmentIndex: target.segmentIndex, offset: target.offset) } ?? false)
        }
    }

    func testModeSwitchAnchorSurvivesFollowUpLayoutRepagination() async throws {
        let document = NovelReaderProjection(
            threadID: "907",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 420), chapterTitle: "第一章")
            ]
        )
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(readingMode: .paged)
        )

        let originalOffset = try await MainActor.run {
            let page = try XCTUnwrap(viewportSurfaces(in: model).dropFirst().first { !$0.ranges.isEmpty })
            let offset = try midpoint(in: XCTUnwrap(page.ranges.first))
            model.updateVerticalViewportPosition(surfaceIndex: page.surfaceOrdinal, intraSurfaceProgress: 0.5)
            return offset
        }

        await model.commitNovelTextAppearance(NovelReaderAppearanceSettings(readingMode: .vertical))
        await model.commitNovelTextLayout(
            NovelReaderLayout(
                containerSize: CGSize(width: 390, height: 844),
                safeAreaInsets: NovelReaderLayoutInsets(top: 59, bottom: 34),
                contentInsets: NovelReaderLayoutInsets(top: 16, leading: 16, bottom: 24, trailing: 16),
                chromeInsets: NovelReaderLayoutInsets(top: 72, bottom: 96),
                readingMode: .vertical
            )
        )

        await MainActor.run {
            let page = viewportSurfaces(in: model)[model.selectedSurfaceIndex]
            let viewportSurface = try? viewportSurface(in: model, surfaceIndex: page.surfaceOrdinal)
            XCTAssertTrue(viewportSurface.map { viewportSurfaceContainsSegmentOffset($0, segmentIndex: 0, offset: originalOffset) } ?? false)
        }
    }

    func testVerticalToPagedModeSwitchDoesNotTemporarilyShowFirstPageBeforeLayoutSync() async throws {
        let document = NovelReaderProjection(
            threadID: "908",
            view: 1,
            maxView: 1,
            segments: [
                .text(String(repeating: "第一章 内容。", count: 520), chapterTitle: "第一章")
            ]
        )
        let model = try await makeModel(
            documents: [document],
            settings: NovelReaderAppearanceSettings(readingMode: .vertical)
        )

        let originalOffset = try await MainActor.run {
            let page = try XCTUnwrap(viewportSurfaces(in: model).dropFirst().last { !$0.ranges.isEmpty })
            let offset = try midpoint(in: XCTUnwrap(page.ranges.first))
            model.updateVerticalViewportPosition(surfaceIndex: page.surfaceOrdinal, intraSurfaceProgress: 0.5)
            return offset
        }

        await MainActor.run {
            XCTAssertGreaterThan(model.selectedSurfaceIndex, 0)
        }
        await model.commitNovelTextAppearance(NovelReaderAppearanceSettings(readingMode: .paged))

        await MainActor.run {
            XCTAssertGreaterThan(model.selectedSurfaceIndex, 0)
            let page = viewportSurfaces(in: model)[model.selectedSurfaceIndex]
            let viewportSurface = try? viewportSurface(in: model, surfaceIndex: page.surfaceOrdinal)
            XCTAssertTrue(viewportSurface.map { viewportSurfaceContainsSegmentOffset($0, segmentIndex: 0, offset: originalOffset) } ?? false)
        }
    }

    func testCachedViewsTrackCurrentVariant() async throws {
        let threadID = "556677"
        let unfilteredDocument = makeDocument(
            threadID: threadID,
            view: 1,
            maxView: 1,
            chapterTitles: ["全部回复"]
        )
        let authorFilteredDocument = makeDocument(
            threadID: threadID,
            view: 1,
            maxView: 1,
            chapterTitles: ["只看楼主"],
            authorID: "42"
        )

        let unfilteredOfflineStore = try makeReaderModelOfflineCacheStore()
        try await seedNovelOfflineCache(unfilteredOfflineStore, document: unfilteredDocument)
        let unfilteredModel = try await makeModel(
            documents: [unfilteredDocument],
            offlineCacheStore: unfilteredOfflineStore
        )
        await MainActor.run {
            XCTAssertEqual(unfilteredModel.cache.state.views.cachedViews, [1])
        }

        let filteredOfflineStore = try makeReaderModelOfflineCacheStore()
        try await seedNovelOfflineCache(filteredOfflineStore, document: authorFilteredDocument)
        let filteredModel = try await makeModel(
            documents: [authorFilteredDocument],
            launchContext: NovelLaunchContext(
                threadID: threadID,
                threadTitle: "测试线程",
                source: .forum,
                authorID: "42"
            ),
            offlineCacheStore: filteredOfflineStore
        )
        await MainActor.run {
            XCTAssertEqual(filteredModel.cache.state.views.cachedViews, [1])
        }
    }

    func testOfflineFallbackShowsStaleNoticeAndRetryKeepsOnlinePathAvailable() async throws {
        defer { NovelReaderTestURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NovelReaderTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        NovelReaderTestURLProtocol.handler = { request in
            (
                Data("temporarily unavailable".utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let threadID = "559900"
        let document = makeDocument(
            threadID: threadID,
            view: 1,
            maxView: 1,
            chapterTitles: ["离线章节"],
            authorID: "42"
        )
        let offlineStore = try makeReaderModelOfflineCacheStore()
        try await seedNovelOfflineCache(
            offlineStore,
            document: document,
            updatedAt: Date(timeIntervalSince1970: 55_990)
        )

        let model = try await makeModel(
            documents: [document],
            launchContext: NovelLaunchContext(
                threadID: threadID,
                threadTitle: "测试线程",
                source: .forum,
                authorID: "42"
            ),
            session: session,
            offlineCacheStore: offlineStore,
            seedSourceCaches: false
        )

        await MainActor.run {
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.novelReaderSurfaces.isEmpty)
            XCTAssertNotNil(model.sourceStatusText)
        }

        await model.loadCurrent(forceRefresh: true)

        await MainActor.run {
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.novelReaderSurfaces.isEmpty)
            XCTAssertNotNil(model.sourceStatusText)
        }
    }

    func testRefreshingCurrentVariantDoesNotDeleteSiblingVariantCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NovelReaderTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let threadID = "556677"
        let unfilteredDocument = makeDocument(
            threadID: threadID,
            view: 1,
            maxView: 1,
            chapterTitles: ["全部回复旧缓存"]
        )
        let authorFilteredDocument = makeDocument(
            threadID: threadID,
            view: 1,
            maxView: 1,
            chapterTitles: ["只看楼主旧缓存"],
            authorID: "42"
        )

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheStore = NovelReaderProjectionStore(baseDirectory: cacheDirectory.appendingPathComponent("reader", isDirectory: true))
        let forumCacheStore = ForumCacheStore(baseDirectory: cacheDirectory.appendingPathComponent("forum", isDirectory: true))
        let offlineStore = try makeReaderModelOfflineCacheStore(
            rootDirectory: cacheDirectory.appendingPathComponent("offline-root", isDirectory: true)
        )
        try await seedNovelOfflineCache(offlineStore, document: authorFilteredDocument)
        try await cacheStore.save(unfilteredDocument)

        let model = try await makeModel(
            documents: [authorFilteredDocument],
            launchContext: NovelLaunchContext(
                threadID: threadID,
                threadTitle: "测试线程",
                source: .forum,
                authorID: "42"
            ),
            session: session,
            cacheStore: cacheStore,
            forumCacheStore: forumCacheStore,
            offlineCacheStore: offlineStore
        )
        await model.cache.refreshCurrentCache()
        try await waitFor {
            await MainActor.run { model.cache.state.views.cachingViews == [1] }
        }

        let preservedAuthorFiltered = await cacheStore.loadProjection(
            for: NovelPageRequest(threadID: threadID, view: 1, authorID: "42")
        )
        let preservedUnfiltered = await cacheStore.loadProjection(
            for: NovelPageRequest(threadID: threadID, view: 1)
        )

        XCTAssertTrue(
            preservedAuthorFiltered?.segments.contains(.text(String(repeating: "只看楼主旧缓存 内容。", count: 80), chapterTitle: "只看楼主旧缓存")) == true
        )
        XCTAssertTrue(
            preservedUnfiltered?.segments.contains(.text(String(repeating: "全部回复旧缓存 内容。", count: 80), chapterTitle: "全部回复旧缓存")) == true
        )
        await MainActor.run {
            XCTAssertEqual(model.cache.state.views.cachedViews, [1])
            XCTAssertEqual(model.cache.state.queueEntryCount, 1)
        }
    }

    func testChapterCommentsReuseSessionCacheUntilExplicitRefresh() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NovelReaderTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let threadID = "9001"
        nonisolated(unsafe) var requestCount = 0
        NovelReaderTestURLProtocol.handler = { request in
            requestCount += 1
            let body = makeChapterCommentsHTML(ownerPostID: "100", commentBody: "评论\(requestCount)")
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            )
        }
        let target = ReaderChapterCommentTarget(threadID: threadID, view: 1, ownerPostID: "100", title: "第一章")
        let model = try await makeModel(
            documents: [makeDocument(threadID: threadID, view: 1, maxView: 1, chapterTitles: ["第一章"])],
            session: session
        )

        await model.loadChapterComments(for: target)
        await model.loadChapterComments(for: target)

        await MainActor.run {
            guard case let .loaded(_, page) = model.chapterComments.state else {
                XCTFail("Expected loaded chapter comments")
                return
            }
            XCTAssertEqual(page.comments.map(\.body), ["评论1"])
            XCTAssertEqual(requestCount, 1)
        }

        await model.refreshChapterComments(for: target)

        await MainActor.run {
            guard case let .loaded(_, page) = model.chapterComments.state else {
                XCTFail("Expected refreshed chapter comments")
                return
            }
            XCTAssertEqual(page.comments.map(\.body), ["评论2"])
            XCTAssertEqual(requestCount, 2)
        }
    }

    func testChapterCommentsRefreshFailurePreservesCachedRows() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NovelReaderTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let threadID = "9002"
        NovelReaderTestURLProtocol.handler = { request in
            let body = makeChapterCommentsHTML(ownerPostID: "100", commentBody: "旧评论")
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            )
        }
        let target = ReaderChapterCommentTarget(threadID: threadID, view: 1, ownerPostID: "100", title: "第一章")
        let model = try await makeModel(
            documents: [makeDocument(threadID: threadID, view: 1, maxView: 1, chapterTitles: ["第一章"])],
            session: session
        )
        await model.loadChapterComments(for: target)

        NovelReaderTestURLProtocol.handler = { request in
            (
                Data("server error".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            )
        }

        await model.refreshChapterComments(for: target)

        await MainActor.run {
            guard case let .loaded(_, page) = model.chapterComments.state else {
                XCTFail("Expected cached comments to remain visible")
                return
            }
            XCTAssertEqual(page.comments.map(\.body), ["旧评论"])
            XCTAssertNotNil(model.chapterComments.refreshError)
        }
    }

    func testChapterCommentsInitialFailureShowsRetryableErrorState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NovelReaderTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let threadID = "9003"
        NovelReaderTestURLProtocol.handler = { request in
            (
                Data("server error".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            )
        }
        let target = ReaderChapterCommentTarget(threadID: threadID, view: 1, ownerPostID: "100", title: "第一章")
        let model = try await makeModel(
            documents: [makeDocument(threadID: threadID, view: 1, maxView: 1, chapterTitles: ["第一章"])],
            session: session
        )

        await model.loadChapterComments(for: target)

        await MainActor.run {
            guard case let .failed(failedTarget, message) = model.chapterComments.state else {
                XCTFail("Expected failed chapter comments state")
                return
            }
            XCTAssertEqual(failedTarget, target)
            XCTAssertFalse(message.isEmpty)
            XCTAssertNil(model.chapterComments.refreshError)
        }
    }

    func testReaderBodyRefreshDoesNotClearChapterCommentsSessionCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NovelReaderTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let threadID = "9004"
        nonisolated(unsafe) var requestCount = 0
        nonisolated(unsafe) var servesComments = true
        NovelReaderTestURLProtocol.handler = { request in
            requestCount += 1
            let body = servesComments
                ? makeChapterCommentsHTML(ownerPostID: "100", commentBody: "缓存评论")
                : "<html><body><div class=\"message\">正文刷新结果</div></body></html>"
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            )
        }
        let target = ReaderChapterCommentTarget(threadID: threadID, view: 1, ownerPostID: "100", title: "第一章")
        let model = try await makeModel(
            documents: [makeDocument(threadID: threadID, view: 1, maxView: 1, chapterTitles: ["第一章"])],
            session: session
        )

        await model.loadChapterComments(for: target)
        servesComments = false
        await model.loadCurrent(forceRefresh: true)
        await model.loadChapterComments(for: target)

        await MainActor.run {
            guard case let .loaded(_, page) = model.chapterComments.state else {
                XCTFail("Expected cached chapter comments")
                return
            }
            XCTAssertEqual(page.comments.map(\.body), ["缓存评论"])
            XCTAssertEqual(requestCount, 2)
        }
    }

    func testCurrentForumTargetURLUsesCurrentChapterPostIdentity() async throws {
        let threadID = "7001"
        let model = try await makeModel(
            documents: [
                makeDocument(
                    threadID: threadID,
                    view: 1,
                    maxView: 1,
                    chapterTitles: ["第一章"],
                    ownerPostIDs: ["100"]
                )
            ]
        )

        await MainActor.run {
            XCTAssertEqual(
                model.currentForumTargetURL.absoluteString,
                "https://bbs.yamibo.com/forum.php?goto=findpost&mobile=2&mod=redirect&pid=100&ptid=7001"
            )
        }
    }

    func testCurrentForumTargetURLFallsBackToCurrentWebPageWithoutPostIdentity() async throws {
        let threadID = "7002"
        let model = try await makeModel(
            documents: [
                makeDocument(
                    threadID: threadID,
                    view: 1,
                    maxView: 1,
                    chapterTitles: ["第一章"]
                )
            ]
        )

        await MainActor.run {
            XCTAssertEqual(model.currentForumTargetURL, model.forumURL)
        }
    }

    func testCurrentForumTargetURLIgnoresAuthorFilterWhenOpeningChapterPost() async throws {
        let threadID = "7003"
        let model = try await makeModel(
            documents: [
                makeDocument(
                    threadID: threadID,
                    view: 1,
                    maxView: 1,
                    chapterTitles: ["第一章"],
                    authorID: "42",
                    ownerPostIDs: ["101"]
                )
            ],
            launchContext: NovelLaunchContext(
                threadID: threadID,
                threadTitle: "测试线程",
                source: .forum,
                authorID: "42"
            )
        )

        await MainActor.run {
            XCTAssertEqual(
                model.currentForumTargetURL.absoluteString,
                "https://bbs.yamibo.com/forum.php?goto=findpost&mobile=2&mod=redirect&pid=101&ptid=7003"
            )
        }
    }

    func testCacheSelectionStateSeparatesCachedAndUncachedViews() async throws {
        let offlineStore = try makeReaderModelOfflineCacheStore()
        let document = makeDocument(view: 1, maxView: 3, chapterTitles: ["第一章"])
        try await seedNovelOfflineCache(offlineStore, document: document)
        let seededSnapshot = await offlineStore.novelOfflineCacheViewsSnapshot(
            ownerTitle: "测试线程",
            threadID: document.threadID,
            authorID: "42"
        )
        XCTAssertEqual(seededSnapshot.cachedViews, [1])
        let model = try await makeModel(
            documents: [
                document,
            ],
            offlineCacheStore: offlineStore
        )

        await MainActor.run {
            let selection = model.cache.selectionState(for: [1, 2])
            XCTAssertEqual(selection.cachedSelectedViews, [1])
            XCTAssertEqual(selection.uncachedSelectedViews, [2])
            XCTAssertTrue(selection.canCache)
            XCTAssertTrue(selection.canUpdate)
            XCTAssertTrue(selection.canDelete)
            XCTAssertFalse(selection.isAllSelected)
        }
    }

    func testStartCachingEnqueuesSelectedViewsInSharedDownloadQueue() async throws {
        defer { NovelReaderTestURLProtocol.handler = nil }

        // `startCaching` is backed by `NovelOfflineStoreReaderCacheOperationAdapter`,
        // which only *enqueues* views 2 and 3 into the shared offline-cache
        // download queue (a fast, network-independent GRDB write) and then
        // fires-and-forgets `OfflineCacheQueueExecutor.continueQueue()` to kick
        // off the actual background download. The assertions below target that
        // enqueue step, so the mocked network response only needs to resolve
        // fast rather than succeed: without a mock, `URLSession.shared` tries
        // the real (unreachable, in this sandbox) forum server and the
        // background download hangs for a very long time before giving up,
        // which doesn't block `operation.status` but does hold the queued
        // work open long past this test's lifetime. A fast-failing mock lets
        // the background attempt fail immediately instead, which is also the
        // behavior the original assertions assume (`cachedViews == []`,
        // `queueEntryCount == 2`, i.e. still-queued/not-yet-downloaded), and
        // matches what the real server would actually return for this thread
        // ID, which doesn't exist.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NovelReaderTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        NovelReaderTestURLProtocol.handler = { request in
            (
                Data("server error".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            )
        }

        let threadID = "7001"

        let model = try await makeModel(
            documents: [
                makeDocument(threadID: threadID, view: 1, maxView: 3, chapterTitles: ["当前页"]),
            ],
            session: session
        )

        await MainActor.run {
            model.cache.startCaching(views: [2, 3])
        }

        // `cachingViews` can be set early by a separate, notification-driven
        // refresh path (NovelReaderCacheCoordinator.startObservingOfflineCacheUpdates)
        // before the batch operation's own `finalize()` runs, so wait on the
        // terminal `operation.status` the assertions below actually depend on.
        try await waitFor {
            await MainActor.run { model.cache.state.operation.status == .completed }
        }

        await MainActor.run {
            XCTAssertEqual(model.cache.state.views.cachedViews, [])
            XCTAssertEqual(model.cache.state.queueEntryCount, 2)
            XCTAssertEqual(model.cache.state.operation.status, .completed)
            XCTAssertEqual(model.cache.state.operation.completedViews, [2, 3])
        }
    }

    func testStartCachingContinuesSharedDownloadQueue() async throws {
        let threadID = "7101"
        let offlineStore = try makeReaderModelOfflineCacheStore()

        let model = try await makeModel(
            documents: [
                makeDocument(threadID: threadID, view: 1, maxView: 2, chapterTitles: ["当前页"]),
            ],
            offlineCacheStore: offlineStore
        )

        await MainActor.run {
            model.cache.startCaching(views: [2])
        }

        try await waitFor {
            await offlineStore.offlineCacheQueueRunState() == .running
        }
    }

    func testOfflineCacheQueueUpdatesRefreshNovelCacheStateAndEntryCount() async throws {
        let threadID = "7102"
        let offlineStore = try makeReaderModelOfflineCacheStore()
        let document = makeDocument(
            threadID: threadID,
            view: 1,
            maxView: 2,
            chapterTitles: ["当前页"],
            authorID: "42"
        )
        let model = try await makeModel(
            documents: [document],
            launchContext: NovelLaunchContext(
                threadID: threadID,
                threadTitle: "测试线程",
                source: .forum,
                authorID: "42"
            ),
            offlineCacheStore: offlineStore
        )

        await MainActor.run {
            XCTAssertEqual(model.cache.status(for: 2), .uncached)
            XCTAssertEqual(model.cache.state.queueEntryCount, 0)
        }

        let request = NovelOfflineCacheWorkRequest(
            ownerTitle: "测试线程",
            title: L10n.string("reader.page_number_spaced", 2),
            threadID: threadID,
            view: 2,
            authorID: "42"
        )
        _ = try await offlineStore.enqueueNovelOfflineCacheWork(request)

        try await waitFor {
            await MainActor.run {
                model.cache.status(for: 2) == .caching
                    && model.cache.state.queueEntryCount == 1
            }
        }

        let completedAt = Date(timeIntervalSince1970: 71_020)
        let completionDocument = makeDocument(
            threadID: threadID,
            view: 2,
            maxView: 2,
            chapterTitles: ["离线完成"],
            authorID: "42"
        )
        let thread = makeThreadIdentity(from: threadID)
        let sourcePage = makeThreadPageSource(from: completionDocument, thread: thread, authorID: "42")
        var projection = completionDocument
        projection.threadID = thread.tid
        projection.resolvedAuthorID = "42"
        try await offlineStore.saveNovelOfflineSourcePage(
            sourcePage,
            request: request,
            updatedAt: completedAt,
            completesMatchingWork: true,
            preservesExistingImageReferencesWhenEmpty: false
        )

        try await waitFor {
            await MainActor.run {
                model.cache.status(for: 2) == .cached
                    && model.cache.state.queueEntryCount == 0
                    && model.cache.updateTime(for: 2) == completedAt
            }
        }
    }

    func testUpdatingCachedViewShowsCachingWhileRetainingLastUpdateTime() async throws {
        let threadID = "7002"
        let offlineStore = try makeReaderModelOfflineCacheStore()
        let updatedAt = Date(timeIntervalSince1970: 44_000)
        let document = makeDocument(threadID: threadID, view: 1, maxView: 4, chapterTitles: ["当前页"])
        try await seedNovelOfflineCache(offlineStore, document: document, updatedAt: updatedAt)
        let model = try await makeModel(
            documents: [
                document,
            ],
            offlineCacheStore: offlineStore
        )

        await MainActor.run {
            model.cache.updateCachedViews([1])
        }

        try await waitFor {
            await MainActor.run { model.cache.status(for: 1) == .caching }
        }

        await MainActor.run {
            XCTAssertEqual(model.cache.state.views.cachedViews, [1])
            XCTAssertEqual(model.cache.state.views.cachingViews, [1])
            XCTAssertEqual(model.cache.updateTime(for: 1), updatedAt)
            XCTAssertEqual(model.cache.state.queueEntryCount, 1)
        }
    }

    func testDeletingNovelOfflineCachePreservesTransparentCaches() async throws {
        let threadID = "7003"
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheStore = NovelReaderProjectionStore(baseDirectory: cacheDirectory.appendingPathComponent("reader", isDirectory: true))
        let forumCacheStore = ForumCacheStore(baseDirectory: cacheDirectory.appendingPathComponent("forum", isDirectory: true))
        let offlineStore = try makeReaderModelOfflineCacheStore(rootDirectory: cacheDirectory.appendingPathComponent("offline-root", isDirectory: true))
        let document = makeDocument(
            threadID: threadID,
            view: 1,
            maxView: 2,
            chapterTitles: ["离线缓存"]
        )
        try await seedNovelOfflineCache(offlineStore, document: document)

        let model = try await makeModel(
            documents: [document],
            cacheStore: cacheStore,
            forumCacheStore: forumCacheStore,
            offlineCacheStore: offlineStore
        )

        await MainActor.run {
            XCTAssertEqual(model.cache.state.views.cachedViews, [1])
        }
        await model.cache.deleteCachedViews([1])
        try await waitFor {
            await MainActor.run { model.cache.state.views.cachedViews.isEmpty }
        }

        let thread = makeThreadIdentity(from: threadID)
        let retainedThreadPage = await forumCacheStore.loadThreadPage(thread: thread, page: 1, authorID: "42")
        XCTAssertNotNil(retainedThreadPage)
        let retainedProjection = await cacheStore.loadProjection(
            for: NovelPageRequest(threadID: threadID, view: 1, authorID: "42")
        )
        XCTAssertNotNil(retainedProjection)
    }
}

private func makeModel(
    documents: [NovelReaderProjection],
    settings: NovelReaderAppearanceSettings = NovelReaderAppearanceSettings(readingMode: .paged),
    launchContext: NovelLaunchContext? = nil,
    session: URLSession = .shared,
    cacheStore: NovelReaderProjectionStore? = nil,
    forumCacheStore: ForumCacheStore? = nil,
    offlineCacheStore: (any TestOfflineCacheStoring)? = nil,
    seedSourceCaches: Bool = true,
    pagination: @escaping NovelTextLayoutFixture = novelReaderViewModelSegmentPagination
) async throws -> NovelReaderViewModel {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "reader-container-model")
    let sessionStore = try SessionStore(testSuiteName: defaultsSuiteName, key: "session")
    let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
    let readingProgressStore = try ReadingProgressStore(
        testSuiteName: defaultsSuiteName,
        key: "reading-progress"
    )
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let resolvedCacheStore = cacheStore
        ?? NovelReaderProjectionStore(baseDirectory: cacheDirectory.appendingPathComponent("reader", isDirectory: true))
    let resolvedForumCacheStore = forumCacheStore
        ?? ForumCacheStore(baseDirectory: cacheDirectory.appendingPathComponent("forum", isDirectory: true))
    let grdbRootDirectory = cacheDirectory.appendingPathComponent("grdb", isDirectory: true)
    let resolvedOfflineCacheStore: any TestOfflineCacheStoring
    if let offlineCacheStore {
        resolvedOfflineCacheStore = offlineCacheStore
    } else {
        resolvedOfflineCacheStore = try OfflineCacheStore(
            databasePool: try YamiboDatabase.openPool(rootDirectory: grdbRootDirectory),
            baseDirectory: cacheDirectory.appendingPathComponent("offline", isDirectory: true)
        )
    }

    try await settingsStore.save(AppSettings(novelReader: settings))
    if seedSourceCaches {
        try await seedReaderSourceCaches(
            documents: documents,
            novelReaderCacheStore: resolvedCacheStore,
            forumCacheStore: resolvedForumCacheStore
        )
    }

    let appContext = YamiboAppContext(
        sessionStore: sessionStore,
        settingsStore: settingsStore,
        readingProgressStore: readingProgressStore,
        novelReaderCacheStore: resolvedCacheStore,
        offlineCacheStore: resolvedOfflineCacheStore,
        forumCacheStore: resolvedForumCacheStore,
        grdbRootDirectory: grdbRootDirectory,
        cachesRootDirectory: grdbRootDirectory,
        session: session
    )
    let model = await MainActor.run {
        NovelReaderViewModel(
            context: launchContext ?? NovelLaunchContext(
                threadID: documents[0].threadID,
                threadTitle: "测试线程",
                source: .forum
            ),
            appContext: appContext,
            pagination: pagination
        )
    }

    await model.prepare(layout: NovelReaderLayout(width: 320, height: 568))
    await model.cache.refresh()
    return model
}

private func seedReaderSourceCaches(
    documents: [NovelReaderProjection],
    novelReaderCacheStore: NovelReaderProjectionStore,
    forumCacheStore: ForumCacheStore
) async throws {
    var didSaveDiscoveryPage: Set<String> = []
    for document in documents {
        let thread = makeThreadIdentity(from: document.threadID)
        let trimmedAuthorID = document.resolvedAuthorID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authorID = trimmedAuthorID.isEmpty ? "42" : trimmedAuthorID
        let sourcePage = makeThreadPageSource(from: document, thread: thread, authorID: authorID)
        try await forumCacheStore.saveThreadPage(
            sourcePage,
            thread: thread,
            pageNumber: document.view,
            authorID: authorID
        )
        if didSaveDiscoveryPage.insert(thread.tid).inserted {
            try await forumCacheStore.saveThreadPage(
                sourcePage,
                thread: thread,
                pageNumber: 1,
                authorID: nil
            )
        }

        var projection = document
        projection.threadID = thread.tid
        projection.resolvedAuthorID = authorID
        projection.projectionSourceFingerprint = projectionFingerprint(
            page: sourcePage,
            threadID: thread.tid,
            view: document.view,
            authorID: authorID
        )
        projection.projectionSchemaVersion = 1
        try await novelReaderCacheStore.save(projection)
    }
}

private func seedNovelOfflineCache(
    _ store: any TestOfflineCacheStoring,
    document: NovelReaderProjection,
    ownerTitle: String = "测试线程",
    updatedAt: Date = Date(timeIntervalSince1970: 40_000)
) async throws {
    let thread = makeThreadIdentity(from: document.threadID)
    let trimmedAuthorID = document.resolvedAuthorID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorID = trimmedAuthorID?.isEmpty == false ? trimmedAuthorID! : "42"
    let sourcePage = makeThreadPageSource(from: document, thread: thread, authorID: authorID)
    let request = NovelOfflineCacheWorkRequest(
        ownerTitle: ownerTitle,
        title: L10n.string("reader.page_number_spaced", document.view),
        threadID: document.threadID,
        view: document.view,
        authorID: authorID
    )
    var projection = document
    projection.threadID = thread.tid
    projection.resolvedAuthorID = authorID
    try await store.saveNovelOfflineSourcePage(
        sourcePage,
        request: request,
        updatedAt: updatedAt,
        completesMatchingWork: true,
        preservesExistingImageReferencesWhenEmpty: false
    )
}

private func makeReaderModelOfflineCacheStore(
    rootDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
) throws -> OfflineCacheStore {
    OfflineCacheStore(
        databasePool: try YamiboDatabase.openPool(rootDirectory: rootDirectory.appendingPathComponent("grdb", isDirectory: true)),
        baseDirectory: rootDirectory.appendingPathComponent("offline", isDirectory: true)
    )
}

private func makeThreadIdentity(from threadID: String) -> ThreadIdentity {
    ThreadIdentity(tid: threadID)
}

private func makeThreadPageSource(
    from document: NovelReaderProjection,
    thread: ThreadIdentity,
    authorID: String
) -> ForumThreadPage {
    let posts = document.segments.enumerated().map { index, segment in
        ForumThreadPost(
            postID: document.segmentSources.indices.contains(index)
                ? document.segmentSources[index]?.ownerPostID ?? "\(document.view)\(index)"
                : "\(document.view)\(index)",
            author: BlogReaderUser(uid: authorID, name: "楼主"),
            contentHTML: projectionSourceHTML(for: segment, index: index),
            contentText: ""
        )
    }
    return ForumThreadPage(
        thread: thread,
        title: "测试线程",
        posts: posts,
        pageNavigation: ForumPageNavigation(currentPage: document.view, totalPages: document.maxView)
    )
}

private func projectionSourceHTML(for segment: NovelReaderSegment, index: Int) -> String {
    switch segment {
    case let .text(text, chapterTitle):
        return "<strong>\(escapeHTML(chapterTitle ?? "第\(index + 1)章"))</strong><br>\(escapeHTML(text))"
    case let .image(url, _):
        return #"<img src="\#(escapeHTML(url.absoluteString))" />"#
    }
}

private func projectionFingerprint(
    page: ForumThreadPage,
    threadID: String,
    view: Int,
    authorID: String
) -> String {
    let value = [
        threadID,
        String(max(1, view)),
        authorID,
        page.posts.map { post in
            [
                post.postID,
                post.author.uid ?? "",
                post.contentHTML,
                post.images.map(\.url).joined(separator: ",")
            ].joined(separator: "\u{1E}")
        }.joined(separator: "\u{1D}"),
        String(page.pageNavigation?.totalPages ?? 0)
    ].joined(separator: "\u{1F}")
    var hash: UInt64 = 1469598103934665603
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }
    return String(hash, radix: 16)
}

private func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func makeReadingProgressStore(
    defaultsSuiteName: String
) throws -> ReadingProgressStore {
    try ReadingProgressStore(
        testSuiteName: defaultsSuiteName,
        key: "reading-progress"
    )
}

private func novelReaderViewModelSegmentPagination(
    document: NovelReaderProjection,
    settings: NovelReaderAppearanceSettings,
    layout: NovelReaderLayout
) throws -> NovelTextLayoutResult {
    let targetCharactersPerSurface = 120
    return try NovelTextLayout.layout(
        document: document,
        settings: settings,
        layout: layout,
        viewportSurfaceLayout: { context, _, _ in
            document.segments.indices.flatMap { segmentIndex -> [NovelTextViewportDocumentSurfaceRange] in
                guard case .text = document.segments[segmentIndex],
                      let range = context.document.textRangesBySegment[segmentIndex],
                      range.endOffset > range.startOffset else {
                    return []
                }
                var surfaceRanges: [NovelTextViewportDocumentSurfaceRange] = []
                var startOffset = range.startOffset
                while startOffset < range.endOffset {
                    let endOffset = min(startOffset + targetCharactersPerSurface, range.endOffset)
                    surfaceRanges.append(
                        NovelTextViewportDocumentSurfaceRange(
                            startOffset: startOffset,
                            endOffset: endOffset
                        )
                    )
                    startOffset = endOffset
                }
                return surfaceRanges
            }
        }
    )
}

private func waitFor(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    pollIntervalNanoseconds: UInt64 = 20_000_000,
    predicate: @escaping () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await predicate() {
            return
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    XCTFail("Timed out waiting for condition")
}

@MainActor
private final class NovelReaderNavigationStateRecorder {
    private(set) var states: [Bool] = []

    func record(_ state: Bool) {
        states.append(state)
    }

    func removeAll() {
        states.removeAll()
    }
}

@MainActor
private final class NovelReaderNavigationOverlayGate {
    private(set) var didEnterPreparation = false
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare() async {
        didEnterPreparation = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor NovelReaderLayoutUpdatePreparationGate {
    private let blockedLayout: NovelReaderLayout
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockedLayout: NovelReaderLayout) {
        self.blockedLayout = blockedLayout
    }

    func prepare(
        _ update: NovelReadingWorkflowRuntimeUpdate
    ) async -> NovelReadingWorkflowRuntimeUpdate {
        guard update.layout == blockedLayout else { return update }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return update
    }

    func waitUntilBlocked() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor NovelReaderLayoutUpdateFailureInjector {
    private let failingLayout: NovelReaderLayout
    private var hasFailed = false
    private(set) var attemptCount = 0

    init(failingLayout: NovelReaderLayout) {
        self.failingLayout = failingLayout
    }

    func prepare(
        _ update: NovelReadingWorkflowRuntimeUpdate
    ) async throws -> NovelReadingWorkflowRuntimeUpdate {
        guard update.layout == failingLayout else { return update }
        attemptCount += 1
        if !hasFailed {
            hasFailed = true
            throw NovelTextLayoutFailure.textKitIndexing
        }
        return update
    }
}

@MainActor
private func viewportSurfaces(in model: NovelReaderViewModel) -> [NovelTextViewportIndexSurface] {
    model.novelReaderDebugState?.viewportSurfaces ?? []
}

@MainActor
private func viewportSurface(
    in model: NovelReaderViewModel,
    surfaceIndex: Int
) throws -> NovelTextViewportIndexSurface {
    try XCTUnwrap(viewportSurfaces(in: model).first { $0.surfaceOrdinal == surfaceIndex })
}

private func midpoint(in range: NovelRenderedTextRange) -> Int {
    range.startOffset + max(1, range.length / 2)
}

private func viewportSurfaceContainsOffset(_ page: NovelTextViewportIndexSurface, offset: Int) -> Bool {
    page.ranges.contains { rangeContainsOffset($0, offset: offset) }
}

private func pageProgress(
    in page: NovelTextViewportIndexSurface,
    segmentIndex: Int,
    segmentOffset: Int
) throws -> Double {
    let ranges = page.ranges
    let totalLength = ranges.reduce(0) { $0 + max($1.length, 1) }
    var runningLength = 0
    for range in ranges {
        let length = max(range.length, 1)
        defer { runningLength += length }
        guard range.segmentIndex == segmentIndex else { continue }
        let localOffset = min(max(segmentOffset - range.startOffset, 0), length)
        return Double(runningLength + localOffset) / Double(max(totalLength, 1))
    }
    throw XCTSkip("Surface does not contain requested segment.")
}

private func viewportSurfaceContainsSegmentOffset(
    _ page: NovelTextViewportIndexSurface,
    segmentIndex: Int,
    offset: Int
) -> Bool {
    page.ranges.filter { $0.segmentIndex == segmentIndex }.contains {
        rangeContainsOffset($0, offset: offset)
    }
}

private func rangeContainsOffset(_ range: NovelRenderedTextRange, offset: Int) -> Bool {
    if range.startOffset == range.endOffset {
        return offset <= range.startOffset
    }
    return offset >= range.startOffset && offset < range.endOffset
}

private func makeDocument(
    threadID: String = "556677",
    view: Int,
    maxView: Int,
    chapterTitles: [String],
    authorID: String? = nil,
    ownerPostIDs: [String?]? = nil
) -> NovelReaderProjection {
    let segments = chapterTitles.map { title in
        NovelReaderSegment.text(String(repeating: "\(title) 内容。", count: 80), chapterTitle: title)
    }
    let segmentSources = ownerPostIDs.map { postIDs in
        segments.indices.map { index in
            postIDs.indices.contains(index) ? NovelReaderSegmentSource(ownerPostID: postIDs[index]) : nil
        }
    }
    return NovelReaderProjection(
        threadID: threadID,
        view: view,
        maxView: maxView,
        resolvedAuthorID: authorID,
        segments: segments,
        segmentSources: segmentSources
    )
}

private func makeImageDocument(
    threadID: String = "998877",
    view: Int,
    maxView: Int,
    surfaceCount: Int
) -> NovelReaderProjection {
    let segments = (0..<surfaceCount).map { index in
        NovelReaderSegment.image(
            URL(string: "https://example.com/\(view)-\(index).jpg")!,
            chapterTitle: "第\(index + 1)章"
        )
    }
    return NovelReaderProjection(
        threadID: threadID,
        view: view,
        maxView: maxView,
        segments: segments
    )
}

private func layoutResult(
    pages: [NovelTextViewportIndexSurface],
    chapters: [NovelReaderChapter],
    viewportIndex: NovelTextViewportIndex? = nil,
    viewportContext: NovelTextViewportContext? = nil
) -> NovelTextLayoutResult {
    let index = viewportIndex ?? NovelTextViewportIndex(
        documentView: pages.first?.documentView ?? 1,
        readingMode: viewportContext?.identity.appearance.readingMode ?? .paged,
        surfaces: pages.map { page in
            NovelTextViewportIndexSurface(
                surfaceOrdinal: page.surfaceOrdinal,
                documentView: page.documentView,
                chapterOrdinal: page.chapterOrdinal,
                chapterTitle: page.chapterTitle,
                ranges: []
            )
        },
        chapters: chapters.map {
            NovelTextViewportIndexChapter(
                ordinal: $0.ordinal,
                title: $0.title,
                startSurfaceOrdinal: $0.startIndex
            )
        }
    )
    let context = viewportContext ?? NovelTextViewportContext(
        identity: NovelTextViewportIdentity(
            threadID: "test-thread",
            documentView: index.documentView,
            maxView: index.documentView,
            fetchedAt: Date(timeIntervalSince1970: 0),
            appearance: NovelReaderAppearanceSettings(readingMode: index.readingMode),
            layout: NovelReaderLayout(width: 320, height: 568, readingMode: index.readingMode)
        ),
        document: NovelTextViewportDocument(
            text: "",
            textRangesBySegment: [:],
            insertedSeparatorRanges: []
        ),
        externalBlocks: [],
        diagnostics: NovelTextViewportDiagnostics(indexBuildCount: 1)
    )
    return NovelTextLayoutResult(
        viewportContext: context,
        viewportIndex: index
    )
}

private enum ViewportTestBlock {
    case text(String, chapterTitle: String?, ranges: [NovelRenderedTextRange] = [])
    case image(URL, chapterTitle: String?)
}

private func viewportTestPage(
    index: Int,
    blocks: [ViewportTestBlock] = [],
    documentView: Int = 1,
    chapterOrdinal: Int? = nil,
    chapterTitle: String? = nil,
    chapterCommentTarget: ReaderChapterCommentTarget? = nil
) -> NovelTextViewportIndexSurface {
    let ranges = blocks.flatMap { block -> [NovelRenderedTextRange] in
        if case let .text(_, _, ranges) = block {
            return ranges
        }
        return []
    }
    let externalBlocks = blocks.compactMap { block -> NovelTextViewportExternalBlock? in
        guard case let .image(url, imageChapterTitle) = block else { return nil }
        return NovelTextViewportExternalBlock(
            chapterIdentity: chapterTitle.map { NovelChapterIdentity(rawValue: "fixture.chapter.\($0)") },
            url: url,
            chapterOrdinal: chapterOrdinal,
            chapterTitle: imageChapterTitle ?? chapterTitle,
            chapterCommentTarget: chapterCommentTarget
        )
    }
    return NovelTextViewportIndexSurface(
        surfaceOrdinal: index,
        documentView: documentView,
        chapterOrdinal: chapterOrdinal,
        chapterTitle: chapterTitle,
        ranges: ranges,
        externalBlocks: externalBlocks,
        chapterCommentTarget: chapterCommentTarget
    )
}

private func novelReaderViewModelPreviewSourcePagination(
    document: NovelReaderProjection,
    settings: NovelReaderAppearanceSettings,
    layout: NovelReaderLayout
) -> NovelTextLayoutResult {
    layoutResult(
        pages: document.segments.enumerated().map { index, segment in
            return viewportTestPage(
                index: index,
                blocks: [],
                documentView: document.view,
                chapterOrdinal: 0,
                chapterTitle: segment.chapterTitle
            )
        },
        chapters: [
            NovelReaderChapter(
                ordinal: 0,
                title: document.segments.first?.chapterTitle ?? "Chapter",
                startIndex: 0
            )
        ],
        viewportIndex: NovelTextViewportIndex(
            documentView: document.view,
            readingMode: settings.readingMode,
            surfaces: document.segments.enumerated().map { index, segment in
                let text: String
                if case let .text(value, _) = segment {
                    text = value
                } else {
                    text = ""
                }
                return NovelTextViewportIndexSurface(
                    surfaceOrdinal: index,
                    documentView: document.view,
                    chapterOrdinal: 0,
                    chapterTitle: segment.chapterTitle,
                    ranges: text.isEmpty
                        ? []
                        : [NovelRenderedTextRange(segmentIndex: index, startOffset: 0, endOffset: text.count)]
                )
            },
            chapters: [
                NovelTextViewportIndexChapter(
                    ordinal: 0,
                    title: document.segments.first?.chapterTitle ?? "Chapter",
                    startSurfaceOrdinal: 0
                )
            ]
        )
    )
}

private func novelReaderViewModelMergedTextPagination(
    document: NovelReaderProjection,
    settings: NovelReaderAppearanceSettings,
    layout: NovelReaderLayout
) -> NovelTextLayoutResult {
    let ranges = document.segments.enumerated().compactMap { index, segment -> NovelRenderedTextRange? in
        guard case let .text(text, _) = segment else { return nil }
        return NovelRenderedTextRange(segmentIndex: index, startOffset: 0, endOffset: text.count)
    }
    return layoutResult(
        pages: [
            viewportTestPage(
                index: 0,
                blocks: [
                    .text(
                        document.segments.compactMap { segment in
                            if case let .text(text, _) = segment { return text }
                            return nil
                        }.joined(separator: "\n\n"),
                        chapterTitle: document.segments.first?.chapterTitle,
                        ranges: ranges
                    )
                ],
                documentView: document.view,
                chapterOrdinal: 0,
                chapterTitle: document.segments.first?.chapterTitle
            )
        ],
        chapters: [
            NovelReaderChapter(
                ordinal: 0,
                title: document.segments.first?.chapterTitle ?? "Chapter",
                startIndex: 0
            )
        ],
        viewportIndex: NovelTextViewportIndex(
            documentView: document.view,
            readingMode: settings.readingMode,
            surfaces: [
                NovelTextViewportIndexSurface(
                    surfaceOrdinal: 0,
                    documentView: document.view,
                    chapterOrdinal: 0,
                    chapterTitle: document.segments.first?.chapterTitle,
                    ranges: ranges
                )
            ],
            chapters: [
                NovelTextViewportIndexChapter(
                    ordinal: 0,
                    title: document.segments.first?.chapterTitle ?? "Chapter",
                    startSurfaceOrdinal: 0
                )
            ]
        )
    )
}

private final class NovelReaderViewModelFixtureRuntimeAdapter: NovelTextLayoutRuntimeAdapter {
    private let fixture: NovelTextLayoutFixture

    init(fixture: @escaping NovelTextLayoutFixture) {
        self.fixture = fixture
    }

    func prepareCandidate(
        input: NovelTextLayoutRuntimeAdapterInput
    ) throws -> NovelTextLayoutRuntimeCandidate {
        let result = try fixture(
            input.preparedInput.document,
            input.preparedInput.settings,
            input.preparedInput.layout
        )
        return NovelTextLayoutRuntimeCandidate(
            result: result,
            fullDocumentLayoutPassCount: 0,
            postIndexCompactionCount: 0,
            ownsAuthoritativeIndex: false
        )
    }
}

@MainActor
private extension NovelReaderViewModel {
    convenience init(
        context: NovelLaunchContext,
        appContext: YamiboAppContext,
        initialSettings: NovelReaderAppearanceSettings? = nil,
        pagination: @escaping NovelTextLayoutFixture = novelReaderViewModelSegmentPagination,
        onReaderResumeRouteChange: @escaping ReaderResumeRouteChangeHandler = { _ in }
    ) {
        self.init(
            context: context,
            dependencies: appContext.novelReaderDependencies,
            initialSettings: initialSettings,
            runtimeAdapter: NovelReaderViewModelFixtureRuntimeAdapter(fixture: pagination),
            onReaderResumeRouteChange: onReaderResumeRouteChange
        )
    }
}

private func makeChapterCommentsHTML(ownerPostID: String, commentBody: String) -> String {
    """
    <html><body>
      <div class="t_f" id="postmessage_\(ownerPostID)">第一章<br>正文</div>
      <div id="comment_\(ownerPostID)" class="cm">
        <div class="pstl xs1 cl">
          <div class="psta vm"><a class="xi2 xw1">读者甲</a></div>
          <div class="psti">\(commentBody) <span class="xg1">发表于 2026-5-1 12:00</span></div>
        </div>
      </div>
    </body></html>
    """
}

private final class NovelReaderTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

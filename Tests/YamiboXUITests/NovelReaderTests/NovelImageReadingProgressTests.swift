import Foundation
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class NovelImageReadingProgressTests: XCTestCase {
    func testReadingSecondImagePersistsAndRestoresItsIdentity() async throws {
        let document = try makeImageProgressDocument()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try YamiboDatabase.openPool(rootDirectory: root)
        let store = ReadingProgressStore(databasePool: database)

        for mode in [ReaderReadingMode.vertical, .paged] {
            let settings = NovelReaderAppearanceSettings(readingMode: mode)
            let layout = NovelReaderLayout(width: 320, height: 568, readingMode: mode)
            let result = try NovelTextLayout.layout(document: document, settings: settings, layout: layout)
            let images = result.viewportIndex.surfaces.filter { !$0.externalBlocks.isEmpty }
            XCTAssertEqual(images.count, 2)
            let target = images[1]
            let imageIdentity = try XCTUnwrap(target.externalBlocks.first?.imageSegmentIdentity)
            var session = try NovelReadingSession(validating: document, layoutResult: result)
            XCTAssertNotNil(session.captureNovelReadingPosition())

            if mode == .vertical {
                session.updateVerticalViewportPosition(surfaceOrdinal: target.surfaceOrdinal, intraSurfaceProgress: 0.7)
            } else {
                session.selectSurface(target.surfaceOrdinal)
            }
            let captured = try XCTUnwrap(session.captureNovelReadingPosition())
            XCTAssertEqual(captured.textSegmentIdentity, imageIdentity)
            XCTAssertEqual(captured.displayedTextOffset, 0)
            XCTAssertEqual(captured.segmentProgress, 0)
            _ = try await store.saveNovel(NovelReadingPosition(
                threadID: document.threadID, view: document.view, resumePoint: captured
            ))
            let reopenedStore = ReadingProgressStore(databasePool: try YamiboDatabase.openPool(rootDirectory: root))
            let loaded = await reopenedStore.load(threadID: document.threadID)
            let saved = try XCTUnwrap(loaded?.novel?.novelResumePoint)
            XCTAssertEqual(saved, captured)

            let payload = ReadingProgressWebDAVPayload(updatedAt: .now, records: [try XCTUnwrap(loaded)])
            let decoded = try JSONDecoder().decode(
                ReadingProgressWebDAVPayload.self, from: JSONEncoder().encode(payload)
            )
            XCTAssertEqual(decoded.records.first?.novel?.novelResumePoint, captured)

            let restored = try NovelReadingSession(validating: document, layoutResult: result, resumePoint: saved)
            XCTAssertEqual(restored.snapshot.selectedSurfaceOrdinal, target.surfaceOrdinal)
            XCTAssertEqual(restored.captureNovelReadingPosition()?.textSegmentIdentity, imageIdentity)
        }
    }

    func testImageOnlyChapterCapturesFirstAndLastImagesWithoutPreviousText() throws {
        let document = try imageOnlyProgressDocument(count: 3)
        let result = try NovelTextLayout.layout(
            document: document, settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568)
        )
        XCTAssertTrue(result.viewportIndex.surfaces.allSatisfy { $0.ranges.isEmpty })
        for target in result.viewportIndex.surfaces {
            var session = try NovelReadingSession(validating: document, layoutResult: result)
            session.updateVerticalViewportPosition(surfaceOrdinal: target.surfaceOrdinal, intraSurfaceProgress: 0.8)
            let saved = try XCTUnwrap(session.captureNovelReadingPosition())
            XCTAssertEqual(saved.textSegmentIdentity, target.externalBlocks.first?.imageSegmentIdentity)
            XCTAssertEqual(saved.segmentProgress, 0)
            let reopened = try NovelReadingSession(validating: document, layoutResult: result, resumePoint: saved)
            XCTAssertEqual(reopened.snapshot.selectedSurfaceOrdinal, target.surfaceOrdinal)
        }
    }

    func testImageIdentitySurvivesRepaginationModeChangesAndContinuedTextReading() throws {
        let document = try makeImageProgressDocument(body:
            "Chapter One<br>" + String(repeating: "Text before the image. ", count: 80) +
            "<img src=\"https://example.com/one.jpg\">After the image."
        )
        let result = try NovelTextLayout.layout(
            document: document, settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568)
        )
        var session = try NovelReadingSession(validating: document, layoutResult: result)
        let image = try XCTUnwrap(result.viewportIndex.surfaces.first { !$0.externalBlocks.isEmpty })
        session.updateVerticalViewportPosition(surfaceOrdinal: image.surfaceOrdinal, intraSurfaceProgress: 0.5)
        let saved = try XCTUnwrap(session.captureNovelReadingPosition())

        for mode in [ReaderReadingMode.paged, .vertical] {
            let next = try NovelTextLayout.layout(
                document: document,
                settings: NovelReaderAppearanceSettings(fontScale: 1.5, readingMode: mode),
                layout: NovelReaderLayout(width: 420, height: 700, readingMode: mode)
            )
            session.consumeCommittedLayoutResult(next, preferredSurfaceOrdinal: 0, preferredResumePoint: saved)
            let selected = session.viewportSurfacesForTesting[session.snapshot.selectedSurfaceOrdinal]
            XCTAssertEqual(selected.externalBlocks.first?.imageSegmentIdentity, saved.textSegmentIdentity)
            XCTAssertEqual(session.captureNovelReadingPosition()?.textSegmentIdentity, saved.textSegmentIdentity)
        }

        let text = try XCTUnwrap(session.viewportSurfacesForTesting.last)
        session.updateVerticalViewportPosition(surfaceOrdinal: text.surfaceOrdinal, intraSurfaceProgress: 0.5)
        let textPosition = try XCTUnwrap(session.captureNovelReadingPosition())
        XCTAssertNotEqual(textPosition.textSegmentIdentity, saved.textSegmentIdentity)
        XCTAssertEqual(textPosition.textSegmentIdentity, document.semantics(forSegmentIndex: document.segments.count - 1)?.textSegmentIdentity)
    }

    func testUnavailableImageIdentityPreservesLastValidImagePosition() throws {
        let document = try makeImageProgressDocument()
        for mode in [ReaderReadingMode.vertical, .paged] {
            var result = try NovelTextLayout.layout(
                document: document, settings: NovelReaderAppearanceSettings(readingMode: mode),
                layout: NovelReaderLayout(width: 320, height: 568, readingMode: mode)
            )
            var session = try NovelReadingSession(validating: document, layoutResult: result)
            let image = try XCTUnwrap(result.viewportIndex.surfaces.first { !$0.externalBlocks.isEmpty })
            if mode == .vertical {
                session.updateVerticalViewportPosition(surfaceOrdinal: image.surfaceOrdinal, intraSurfaceProgress: 0)
            } else {
                session.selectSurface(image.surfaceOrdinal)
            }
            let saved = try XCTUnwrap(session.captureNovelReadingPosition())
            result.viewportIndex.surfaces[image.surfaceOrdinal].externalBlocks[0].imageSegmentIdentity = nil
            session.consumeCommittedLayoutResult(
                result, preferredSurfaceOrdinal: image.surfaceOrdinal, preferredResumePoint: nil
            )
            XCTAssertEqual(session.captureNovelReadingPosition(), saved)
        }
    }

    func testHidingImagesFallsBackToChapterText() throws {
        let document = try makeImageProgressDocument()
        let settings = NovelReaderAppearanceSettings(readingMode: .vertical)
        let layout = NovelReaderLayout(width: 320, height: 568)
        let result = try NovelTextLayout.layout(document: document, settings: settings, layout: layout)
        var session = try NovelReadingSession(validating: document, layoutResult: result)
        let image = try XCTUnwrap(result.viewportIndex.surfaces.last { !$0.externalBlocks.isEmpty })
        session.updateVerticalViewportPosition(surfaceOrdinal: image.surfaceOrdinal, intraSurfaceProgress: 0)
        let saved = try XCTUnwrap(session.captureNovelReadingPosition())
        var hiddenSettings = settings
        hiddenSettings.loadsInlineImages = false
        let hidden = try NovelTextLayout.layout(document: document, settings: hiddenSettings, layout: layout)
        session.consumeCommittedLayoutResult(hidden, preferredSurfaceOrdinal: 0, preferredResumePoint: saved)
        XCTAssertTrue(session.viewportSurfacesForTesting[session.snapshot.selectedSurfaceOrdinal].containsText)
        XCTAssertEqual(session.captureNovelReadingPosition()?.chapterIdentity, saved.chapterIdentity)
    }

    func testImageSpreadRestoresUsingExistingReadingDirectionRule() throws {
        let document = try imageOnlyProgressDocument(count: 6)
        for direction in [ReaderPageTurnDirection.leftToRight, .rightToLeft] {
            let result = try NovelTextLayout.layout(
                document: document,
                settings: NovelReaderAppearanceSettings(readingMode: .paged, pageTurnDirection: direction),
                layout: NovelReaderLayout(width: 400, height: 500, readingMode: .paged)
            )
            var session = try NovelReadingSession(
                validating: document, layoutResult: result, usesPagedSpread: true, pageTurnDirection: direction
            )
            session.selectSurface(3)
            let expectedOrdinal = direction == .leftToRight ? 3 : 2
            let saved = try XCTUnwrap(session.captureNovelReadingPosition())
            XCTAssertEqual(saved.textSegmentIdentity, result.viewportIndex.surfaces[expectedOrdinal].externalBlocks.first?.imageSegmentIdentity)
            let reopened = try NovelReadingSession(
                validating: document, layoutResult: result, resumePoint: saved,
                usesPagedSpread: true, pageTurnDirection: direction
            )
            XCTAssertEqual(reopened.snapshot.selectedSurfaceOrdinal, expectedOrdinal)
        }
    }
}

private func imageOnlyProgressDocument(count: Int) throws -> NovelReaderProjection {
    var document = try makeImageProgressDocument(body: "Chapter One<br>" + String(
        repeating: "<img src=\"https://example.com/repeated.jpg\">", count: count
    ))
    // Keep the chapter's real parser-generated identities while isolating
    // image-only layout from the heading's text surface.
    let indexes = document.segments.indices.filter {
        if case .image = document.segments[$0] { return true }
        return false
    }
    document.segments = indexes.map { document.segments[$0] }
    document.segmentSources = indexes.map { document.segmentSources[$0] }
    document.segmentSemantics = indexes.map { document.segmentSemantics[$0] }
    return document
}

func makeImageProgressDocument(body: String = """
    Chapter One<br>Before the images.
    <img src="https://example.com/repeated.jpg">
    <img src="https://example.com/repeated.jpg">
    After the images.
    """) throws -> NovelReaderProjection {
    let html = """
    <html><body><div class="message" id="postmessage_101">
    \(body)
    </div></body></html>
    """
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: html, thread: ThreadIdentity(tid: "9103"), fallbackTitle: nil
    )
    return try NovelReaderProjectionBuilder.build(
        from: page, request: NovelPageRequest(threadID: "9103", view: 1), authorID: "99"
    )
}

import Foundation
import Testing
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

// 拆分自 ReaderCoreTests.swift:NovelTextSelection 选区复制与代际失效。
// NovelTextViewportRuntimeOwner 便捷构造器位于 NovelReaderTestSupport.swift。

final class NovelTextLikeAnchorEndpointTests: XCTestCase {
    @MainActor
    func testKeepsTheLastSelectedCharacterAfterEmoji() throws {
#if canImport(UIKit)
        let text = "甲😀乙"
        let document = NovelReaderProjection(
            threadID: "197",
            view: 1,
            maxView: 1,
            segments: [.text(text, chapterTitle: "Selection")]
        )
        let runtime = NovelTextViewportRuntimeOwner()
        let transaction = try runtime.prepareTransaction(
            preparedInput: NovelTextLayout.prepareInput(
                document: document,
                settings: NovelReaderAppearanceSettings(readingMode: .paged),
                layout: NovelReaderLayout(width: 320, height: 480, readingMode: .paged)
            )
        )
        let surface = try XCTUnwrap(transaction.result.viewportIndex.surfaces.first)
        try runtime.prepareInitialViewport(for: transaction, around: surface.surfaceOrdinal)
        XCTAssertTrue(runtime.commit(transaction))

        let displayReference = try XCTUnwrap(runtime.displayReference(for: NovelReaderSurfaceIdentity(
            generation: transaction.generation,
            ordinal: surface.surfaceOrdinal
        )))
        let selectionRange = try XCTUnwrap(NovelTextSelectionRange(
            generation: transaction.generation,
            lowerBound: 0,
            upperBound: text.count
        ))
        let selectionRects = displayReference.selectionRects(for: selectionRange)
        let startRect = try XCTUnwrap(selectionRects.first)
        let endRect = try XCTUnwrap(selectionRects.last)
        let start = try XCTUnwrap(displayReference.viewportSample(
            referencePoint: CGPoint(x: startRect.minX + 1, y: startRect.midY)
        ))
        let endCharacter = try XCTUnwrap(displayReference.viewportSample(
            referencePoint: CGPoint(x: endRect.maxX - 1, y: endRect.midY)
        ))
        let startChapter = try XCTUnwrap(start.textSegmentIdentity.chapterIdentity)
        let endChapter = try XCTUnwrap(endCharacter.textSegmentIdentity.chapterIdentity)

        XCTAssertEqual(endCharacter.displayedTextOffset, 2)
        let endpoints = NovelTextLikeAnchorEndpointResolver.resolve(
            start: start,
            endCharacter: endCharacter,
            startChapterIdentity: startChapter,
            endChapterIdentity: endChapter
        )
        func resumePoint(for endpoint: NovelTextViewportSemanticTextPosition) -> NovelResumePoint {
            NovelResumePoint(
                view: 1,
                chapterIdentity: endpoint.chapterIdentity,
                textSegmentIdentity: endpoint.textSegmentIdentity,
                displayedTextOffset: endpoint.displayedTextOffset,
                chapterOrdinal: 0,
                segmentProgress: 0,
                readingModeHint: .paged
            )
        }
        let resolvedRange = try XCTUnwrap(runtime.documentSelectionRange(
            from: resumePoint(for: endpoints.start),
            to: resumePoint(for: endpoints.end)
        ))

        XCTAssertEqual(resolvedRange.range, 0..<text.count)
        XCTAssertEqual(runtime.selectedText(for: resolvedRange), text)
#endif
    }
}

@MainActor
@Test func novelTextSelectionCopiesDisplayedTextFromCommittedGeneration() throws {
    let document = NovelReaderProjection(
        threadID: "197",
        view: 1,
        maxView: 1,
        segments: [.text("Alpha beta gamma delta", chapterTitle: "Selection")]
    )
    let runtime = NovelTextViewportRuntimeOwner()
    let firstTransaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 480, readingMode: .paged)
        )
    )
    #expect(runtime.commit(firstTransaction))
    let range = try #require(NovelTextSelectionRange(
        generation: firstTransaction.generation,
        lowerBound: 6,
        upperBound: 10
    ))

    #expect(runtime.selectedText(for: range) == "beta")

    let staleTransaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: NovelReaderAppearanceSettings(fontScale: 1.1, readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 480, readingMode: .paged)
        )
    )
    #expect(runtime.commit(staleTransaction))

    #expect(runtime.selectedText(for: range) == nil)
}

@MainActor
@Test func novelTextSelectionCopiesDisplayedTextAcrossVerticalSurfaces() throws {
#if canImport(UIKit)
    let text = String(
        repeating: "Selection can cross a vertical TextKit chunk while staying in the current runtime generation. ",
        count: 80
    )
    let document = NovelReaderProjection(
        threadID: "198",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "Selection")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .vertical)
    let layout = NovelReaderLayout(width: 320, height: 240, readingMode: .vertical)
    let runtime = NovelTextViewportRuntimeOwner()
    let transaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: settings,
            layout: layout
        )
    )
    let firstSurface = try #require(transaction.result.viewportIndex.surfaces.first)
    let secondSurface = try #require(transaction.result.viewportIndex.surfaces.dropFirst().first)
    try runtime.prepareInitialViewport(for: transaction, around: firstSurface.surfaceOrdinal)
    #expect(runtime.commit(transaction))

    let firstReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: transaction.generation,
        ordinal: firstSurface.surfaceOrdinal
    )))
    let secondReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: transaction.generation,
        ordinal: secondSurface.surfaceOrdinal
    )))
    let firstGeometry = try #require(firstSurface.frozenGeometry)
    let secondGeometry = try #require(secondSurface.frozenGeometry)
    let range = try #require(NovelTextSelectionRange(
        generation: transaction.generation,
        lowerBound: firstGeometry.documentEndOffset - 12,
        upperBound: secondGeometry.documentStartOffset + 12
    ))
    let copiedText = try #require(firstReference.selectedText(for: range))
    let documentText = transaction.result.viewportContext.document.text
    let expectedText = String(documentText[
        documentText.index(documentText.startIndex, offsetBy: range.lowerBound)..<documentText.index(
            documentText.startIndex,
            offsetBy: range.upperBound
        )
    ])

    #expect(copiedText == expectedText)
    #expect(!firstReference.selectionRects(for: range).isEmpty)
    #expect(!secondReference.selectionRects(for: range).isEmpty)
#endif
}

@MainActor
@Test func novelTextSelectionRejectsStaleGeneration() throws {
#if canImport(UIKit)
    let document = NovelReaderProjection(
        threadID: "199",
        view: 1,
        maxView: 1,
        segments: [.text(String(repeating: "Stale selection should not copy. ", count: 20), chapterTitle: "Selection")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 320, height: 480, readingMode: .paged)
    let runtime = NovelTextViewportRuntimeOwner()
    let firstTransaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: settings,
            layout: layout
        )
    )
    try runtime.prepareInitialViewport(for: firstTransaction, around: 0)
    #expect(runtime.commit(firstTransaction))
    let oldReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: firstTransaction.generation,
        ordinal: 0
    )))
    let oldRange = try #require(NovelTextSelectionRange(
        generation: firstTransaction.generation,
        lowerBound: 0,
        upperBound: 5
    ))

    let secondTransaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: NovelReaderAppearanceSettings(fontScale: 1.1, readingMode: .paged),
            layout: layout
        )
    )
    try runtime.prepareInitialViewport(for: secondTransaction, around: 0)
    #expect(runtime.commit(secondTransaction))

    #expect(oldReference.isStale)
    #expect(oldReference.selectedText(for: oldRange) == nil)
    #expect(oldReference.selectionRects(for: oldRange).isEmpty)
#endif
}

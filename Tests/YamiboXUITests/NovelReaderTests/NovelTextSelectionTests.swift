import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

// 拆分自 ReaderCoreTests.swift:NovelTextSelection 选区复制与代际失效。
// NovelTextViewportRuntimeOwner 便捷构造器位于 NovelReaderTestSupport.swift。

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

import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

#if canImport(UIKit)
import UIKit
#endif

// 拆分自 ReaderCoreTests.swift:NovelAttributedTextFactory 富文本构造
// (段落样式/首行缩进/语义标题/行内粗体)、NovelParagraphIndentPlanner 与
// NovelTextSettingsPreviewSurface。

#if canImport(UIKit)
private typealias ReaderTestFont = UIFont

private func readerTestFontWeight(_ font: ReaderTestFont) -> CGFloat {
    let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
    if let value = traits?[.weight] as? CGFloat {
        return value
    }
    if let value = traits?[.weight] as? NSNumber {
        return CGFloat(truncating: value)
    }
    return 0
}
#endif

@Test func readerParagraphIndentPlannerKeepsContinuationFirstParagraphUnindentedOnly() {
    let text = "续页正文。\n\n新段落正文。\n第三段正文。"
    let ranges = NovelParagraphIndentPlanner.indentedParagraphRangesAfterFirst(in: text)
    let substrings = ranges.map { String(text[$0]) }

    #expect(substrings == ["\n\n新段落正文。", "\n第三段正文。"])
}

#if canImport(UIKit)
@Test func readerAttributedTextFactoryUsesParagraphStyleForTitleAndBody() throws {
    let pointSize = 24.0
    let attributedText = NovelAttributedTextFactory.makeAttributedText(
        text: "第一章\n第一段正文。\n\n第二段正文。",
        chapterTitle: "第一章",
        settings: NovelReaderAppearanceSettings(lineHeightScale: 1.6),
        baseFontSize: pointSize
    )
    let titleStyle = try #require(
        attributedText.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
    )
    let bodyStyle = try #require(
        attributedText.attribute(
            .paragraphStyle,
            at: "第一章\n".count,
            effectiveRange: nil
        ) as? NSParagraphStyle
    )

    // Leading is proportional to the point size (6pt at the default 22pt
    // body), scaled by the user's lineHeightScale.
    let expectedLineSpacing = pointSize * NovelAttributedTextFactory.lineSpacingRatio * 1.6
    #expect(abs(titleStyle.lineSpacing - expectedLineSpacing) < 0.001)
    #expect(abs(bodyStyle.lineSpacing - expectedLineSpacing) < 0.001)
}

@Test func novelTextSettingsPreviewSurfaceUsesAttributedParagraphSemantics() throws {
    let surface = NovelTextSettingsPreviewSurface(
        text: "第一段正文。\n\n第二段正文。",
        settings: NovelReaderAppearanceSettings(
            usesJustifiedText: true,
            indentsParagraphFirstLine: true
        )
    )
    let style = try #require(surface.diagnosticParagraphStyle(at: 0))

    #expect(style.alignment == .justified)
    #expect(style.firstLineHeadIndent == 44)
}

@Test func readerAttributedTextFactoryIndentsBodyButNotTitleOrContinuationSlices() throws {
    let pointSize = 24.0
    let settings = NovelReaderAppearanceSettings(indentsParagraphFirstLine: true)
    let paragraphStart = NovelAttributedTextFactory.makeAttributedText(
        text: "第一章\n第一段正文。",
        chapterTitle: "第一章",
        startsAtParagraphBoundary: true,
        settings: settings,
        baseFontSize: pointSize
    )
    let continuation = NovelAttributedTextFactory.makeAttributedText(
        text: "续页正文。",
        chapterTitle: "第一章",
        startsAtParagraphBoundary: false,
        settings: settings,
        baseFontSize: pointSize
    )
    let titleStyle = try #require(
        paragraphStart.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )
    let bodyStyle = try #require(
        paragraphStart.attribute(.paragraphStyle, at: "第一章\n".count, effectiveRange: nil) as? NSParagraphStyle
    )
    let continuationStyle = try #require(
        continuation.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )

    #expect(titleStyle.firstLineHeadIndent == 0)
    #expect(bodyStyle.firstLineHeadIndent == 48)
    #expect(continuationStyle.firstLineHeadIndent == 0)
}

@Test func readerAttributedTextFactoryIndentsLaterParagraphsInContinuationSlices() throws {
    let pointSize = 24.0
    let attributedText = NovelAttributedTextFactory.makeAttributedText(
        text: "续页正文。\n\n新段落正文。",
        chapterTitle: "第一章",
        startsAtParagraphBoundary: false,
        settings: NovelReaderAppearanceSettings(indentsParagraphFirstLine: true),
        baseFontSize: pointSize
    )
    let continuationStyle = try #require(
        attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )
    let newParagraphStyle = try #require(
        attributedText.attribute(.paragraphStyle, at: "续页正文。\n\n".count, effectiveRange: nil) as? NSParagraphStyle
    )

    #expect(continuationStyle.firstLineHeadIndent == 0)
    #expect(newParagraphStyle.firstLineHeadIndent == 48)
}

@Test func novelAttributedDocumentUsesPreparedSemanticRunsAndMatchesViewportText() throws {
    let document = NovelReaderProjection(
        threadID: "301",
        view: 1,
        maxView: 1,
        segments: [
            .text("第一章\n第一段正文。", chapterTitle: "第一章"),
            .text("第二段正文。", chapterTitle: nil),
        ]
    )
    let preparedInput = try NovelTextLayout.prepareInput(
        document: document,
        settings: NovelReaderAppearanceSettings(indentsParagraphFirstLine: true),
        layout: NovelReaderLayout(width: 390, height: 844)
    )
    let attributedDocument = NovelAttributedTextFactory.makeAttributedDocument(
        from: preparedInput
    )
    let titleStyle = try #require(
        attributedDocument.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )
    let bodyStyle = try #require(
        attributedDocument.attribute(
            .paragraphStyle,
            at: "第一章\n".count,
            effectiveRange: nil
        ) as? NSParagraphStyle
    )

    #expect(attributedDocument.string == preparedInput.viewportContextSeed.document.text)
    #expect(titleStyle.firstLineHeadIndent == 0)
    #expect(bodyStyle.firstLineHeadIndent > 0)
}

@Test func novelAttributedDocumentStylesChapterTitleFromSemanticRangeOnly() throws {
    let document = NovelReaderProjection(
        threadID: "303",
        view: 1,
        maxView: 1,
        segments: [
            .text("真正标题\n正文。", chapterTitle: "旧标题不应参与主文档样式")
        ],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                chapterTitleRange: NovelCharacterRange(location: 0, length: "真正标题".count)
            )
        ]
    )
    let preparedInput = try NovelTextLayout.prepareInput(
        document: document,
        settings: NovelReaderAppearanceSettings(indentsParagraphFirstLine: true),
        layout: NovelReaderLayout(width: 390, height: 844)
    )
    let attributedDocument = NovelAttributedTextFactory.makeAttributedDocument(
        from: preparedInput
    )
    let titleStyle = try #require(
        attributedDocument.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )
    let bodyStyle = try #require(
        attributedDocument.attribute(
            .paragraphStyle,
            at: "真正标题\n".count,
            effectiveRange: nil
        ) as? NSParagraphStyle
    )

    #expect(attributedDocument.string == "真正标题\n正文。")
    #expect(titleStyle.firstLineHeadIndent == 0)
    #expect(bodyStyle.firstLineHeadIndent > 0)
}

@Test func readerAttributedTextFactoryAppliesInlineBoldWithoutChangingNormalBody() throws {
    let document = NovelReaderProjection(
        threadID: "305",
        view: 1,
        maxView: 1,
        segments: [.text("普通粗体普通", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                inlineTextStyles: [
                    NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 2, length: 2))
                ]
            )
        ]
    )
    let preparedInput = try NovelTextLayout.prepareInput(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    let attributedDocument = NovelAttributedTextFactory.makeAttributedDocument(from: preparedInput)
    let normalFont = try #require(attributedDocument.attribute(.font, at: 0, effectiveRange: nil) as? ReaderTestFont)
    let boldFont = try #require(attributedDocument.attribute(.font, at: 2, effectiveRange: nil) as? ReaderTestFont)

    #expect(readerTestFontWeight(boldFont) > readerTestFontWeight(normalFont))
}
#endif

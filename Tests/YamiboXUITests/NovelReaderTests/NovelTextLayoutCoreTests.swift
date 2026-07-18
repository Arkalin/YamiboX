import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

#if canImport(UIKit)
import UIKit
#endif

// 拆分自 ReaderCoreTests.swift:NovelTextLayout 布局管线及其视口家族
// (NovelTextViewportIndex / FrozenGeometry / SurfaceFragmentPartitioner /
// DrawingGeometry / RuntimeOwner 事务)。条件编译块与测试体保持原样;
// 语义 fixture 与 NovelTextViewportRuntimeOwner 便捷构造器位于
// NovelReaderTestSupport.swift。

#if canImport(UIKit)
@Test func novelTextLayoutProducesChaptersForBothModes() async throws {
    let document = NovelReaderProjection(
        threadID: "1",
        view: 1,
        maxView: 2,
        segments: [
            .text(String(repeating: "第一章内容。", count: 80), chapterTitle: "第一章"),
            .text(String(repeating: "第二章内容。", count: 80), chapterTitle: "第二章")
        ]
    )

    let paged = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 320, height: 568)
    )
    #expect(paged.viewportIndex.surfaces.count >= 2)
    #expect(paged.viewportIndex.chapters.count == 2)
    #expect(paged.viewportIndex.chapters.first?.title == "第一章")
    #expect(paged.viewportIndex.chapters.last?.title == "第二章")
    #expect((paged.viewportIndex.chapters.last?.startSurfaceOrdinal ?? 0) > 0)

    let vertical = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: NovelReaderLayout(width: 320, height: 568)
    )
    #expect(vertical.viewportIndex.surfaces.count >= 2)
    #expect(vertical.viewportIndex.chapters.first?.title == "第一章")
    #expect(vertical.viewportIndex.chapters.last?.title == "第二章")
}

@Test func novelTextLayoutFiltersAuthorRepliesToOthersWhenSettingIsDisabled() throws {
    let document = NovelReaderProjection(
        threadID: "188",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "第一章 正文。", count: 40), chapterTitle: "第一章"),
            .text(String(repeating: "读者甲 发表于 2026-5-1\n楼主回复。", count: 12), chapterTitle: "读者甲 发表于 2026-5-1"),
            .text(String(repeating: "第二章 正文。", count: 40), chapterTitle: "第二章"),
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "301"),
            NovelReaderSegmentSource(ownerPostID: "302", isAuthorReplyToOther: true),
            NovelReaderSegmentSource(ownerPostID: "303"),
        ]
    )
    let layout = NovelReaderLayout(width: 320, height: 568)
    let visible = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: layout
    )
    let hidden = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false, readingMode: .vertical),
        layout: layout
    )

    let visibleSegmentIndexes = Set(visible.viewportIndex.surfaces.flatMap { $0.ranges.map(\.segmentIndex) })
    let hiddenSegmentIndexes = Set(hidden.viewportIndex.surfaces.flatMap { $0.ranges.map(\.segmentIndex) })

    #expect(visibleSegmentIndexes.contains(1))
    #expect(!hiddenSegmentIndexes.contains(1))
    #expect(hidden.viewportIndex.chapters.map(\.title) == ["第一章", "第二章"])
}

@Test func novelTextLayoutRendersImageOnlySurfaceWhenAllTextOnPageIsHiddenByAuthorReplyFilter() throws {
    let document = NovelReaderProjection(
        threadID: "189",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "读者回复正文。", count: 20), chapterTitle: "读者回复"),
            .image(URL(string: "https://example.com/only-image.jpg")!, chapterTitle: "读者回复"),
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "701", isAuthorReplyToOther: true),
            NovelReaderSegmentSource(ownerPostID: "702"),
        ]
    )

    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false, readingMode: .vertical),
        layout: NovelReaderLayout(width: 320, height: 568)
    )

    #expect(result.viewportIndex.surfaces.allSatisfy { $0.ranges.isEmpty })
    #expect(result.viewportIndex.surfaces.contains { !$0.externalBlocks.isEmpty })
}
#endif

#if canImport(UIKit)
@Test func novelTextLayoutProducesPagedAndVerticalPagesAtModuleSeam() throws {
    let text = String(repeating: "这是用于模块边界测试的正文。", count: 120)
    let document = NovelReaderProjection(
        threadID: "58",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    let paged = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 320, height: 568)
    )
    let vertical = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: NovelReaderLayout(width: 320, height: 568)
    )

    #expect(!paged.viewportIndex.surfaces.isEmpty)
    #expect(!vertical.viewportIndex.surfaces.isEmpty)
    #expect(paged.viewportIndex.surfaces.first?.ranges.first?.startOffset == 0)
    #expect(paged.viewportIndex.surfaces.last?.ranges.last?.endOffset == text.count)
    #expect(vertical.viewportIndex.surfaces.first?.ranges.first?.startOffset == 0)
    #expect(vertical.viewportIndex.surfaces.last?.ranges.last?.endOffset == text.count)
    #expect(paged.viewportIndex.chapters.first?.title == "第一章")
    #expect(vertical.viewportIndex.chapters.first?.title == "第一章")
    #expect(
        NovelTextPreviewLayout.textFits(
            String(text.prefix(80)),
            chapterTitle: "第一章",
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568)
        )
    )
}
#endif

@Test func novelTextLayoutAssemblesDocumentPagesChaptersImagesAndViewportIndex() async throws {
    let imageURL = try #require(URL(string: "https://example.com/image.jpg"))
    let document = NovelReaderProjection(
        threadID: "99",
        view: 1,
        maxView: 1,
        segments: [
            .text("开头", chapterTitle: "第一章"),
            .text("继续", chapterTitle: "第一章"),
            .image(imageURL, chapterTitle: "第一章"),
            .text("第二章正文", chapterTitle: "第二章")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-0"),
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-1"),
            novelReaderImageSemantics(chapterID: "chapter-1"),
            novelReaderTextSemantics(chapterID: "chapter-2", textID: "chapter-2-text-0")
        ]
    )

    let pagination = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    #expect(pagination.viewportIndex.surfaces.count == 3)
    #expect(pagination.viewportIndex.chapters.map(\.title) == ["第一章", "第二章"])
    #expect(pagination.viewportIndex.chapters.map(\.startSurfaceOrdinal) == [0, 2])
    #expect(pagination.viewportIndex.surfaces[0].externalBlocks.isEmpty)
    #expect(pagination.viewportIndex.surfaces[0].ranges == [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 2),
        NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 2)
    ])
    #expect(pagination.viewportIndex.surfaces[1].externalBlocks.map(\.url) == [imageURL])
    #expect(pagination.viewportIndex.surfaces[1].externalBlocks.map(\.chapterTitle) == ["第一章"])
    #expect(pagination.viewportIndex.surfaces[2].ranges.first?.segmentIndex == 3)
    #expect(pagination.viewportIndex.surfaces[2].externalBlocks.isEmpty)
    #expect(pagination.viewportIndex.surfaces[2].ranges == [
        NovelRenderedTextRange(segmentIndex: 3, startOffset: 0, endOffset: 5)
    ])
}

@Test func novelTextLayoutGroupsSameTitleChaptersBySemanticIdentity() throws {
    let document = NovelReaderProjection(
        threadID: "100",
        view: 1,
        maxView: 1,
        segments: [
            .text("同名章\n第一处。", chapterTitle: "同名章"),
            .text("同名章\n第二处。", chapterTitle: "同名章")
        ],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-a"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-a"),
                chapterTitleRange: NovelCharacterRange(location: 0, length: "同名章".count)
            ),
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-b"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-b"),
                chapterTitleRange: NovelCharacterRange(location: 0, length: "同名章".count)
            )
        ]
    )

    let pagination = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    #expect(pagination.viewportIndex.chapters.map(\.title) == ["同名章", "同名章"])
    #expect(pagination.viewportIndex.chapters.map(\.startSurfaceOrdinal) == [0, 1])
    #expect(pagination.viewportIndex.surfaces.map(\.chapterOrdinal) == [0, 1])
}

@Test func novelTextLayoutPublishesNovelTextViewportIndexForRenderedPages() async throws {
    let document = NovelReaderProjection(
        threadID: "100",
        view: 2,
        maxView: 3,
        segments: [
            .text("第一章前半", chapterTitle: "第一章"),
            .text("第一章后半", chapterTitle: "第一章"),
            .text("第二章正文", chapterTitle: "第二章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "post-1"),
            NovelReaderSegmentSource(ownerPostID: "post-1"),
            NovelReaderSegmentSource(ownerPostID: "post-2")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "post:post-1#chapter:0", textID: "post:post-1#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:post-1#chapter:0", textID: "post:post-1#chapter:0#text:1"),
            novelReaderTextSemantics(chapterID: "post:post-2#chapter:0", textID: "post:post-2#chapter:0#text:0")
        ]
    )

    let pagination = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    let index = pagination.viewportIndex
    #expect(index.documentView == 2)
    #expect(index.readingMode == .paged)
    #expect(index.surfaces.map(\.surfaceOrdinal) == [0, 1])
    #expect(index.surfaces[0].ranges == [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 5),
        NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 5)
    ])
    #expect(index.surfaces[1].ranges == [
        NovelRenderedTextRange(segmentIndex: 2, startOffset: 0, endOffset: 5)
    ])
    #expect(index.chapters.map(\.title) == ["第一章", "第二章"])
    #expect(index.chapters.map(\.startSurfaceOrdinal) == [0, 1])
    let firstChapterSecondText = try #require(document.semantics(forSegmentIndex: 1)?.textSegmentIdentity)
    let secondChapterText = try #require(document.semantics(forSegmentIndex: 2)?.textSegmentIdentity)
    #expect(index.position(for: firstChapterSecondText, displayedTextOffset: 3, in: document)?.surfaceOrdinal == 0)
    #expect(index.position(for: secondChapterText, displayedTextOffset: 2, in: document)?.chapterCommentTarget?.ownerPostID == "post-2")
}

@Test func novelTextLayoutPublishesNovelTextViewportIndexForVerticalChunks() async throws {
    let document = NovelReaderProjection(
        threadID: "101",
        view: 1,
        maxView: 1,
        segments: [
            .text("纵向阅读第一段", chapterTitle: "第一章")
        ]
    )

    let pagination = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: NovelReaderLayout(width: 390, height: 844, readingMode: .vertical),
        viewportSurfaceLayout: { _, _, _ in
            [
                NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: 4),
                NovelTextViewportDocumentSurfaceRange(startOffset: 4, endOffset: 7)
            ]
        }
    )

    let index = pagination.viewportIndex
    #expect(index.readingMode == .vertical)
    #expect(index.surfaces.map(\.ranges) == [
        [NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 4)],
        [NovelRenderedTextRange(segmentIndex: 0, startOffset: 4, endOffset: 7)]
    ])
    let textSegmentIdentity = try #require(document.semantics(forSegmentIndex: 0)?.textSegmentIdentity)
    #expect(index.position(for: textSegmentIdentity, displayedTextOffset: 5, in: document)?.surfaceOrdinal == 1)
}

@Test func novelTextLayoutBuildsCurrentWebpageViewportContextBeforePublishingReadablePages() async throws {
    let imageURL = try #require(URL(string: "https://example.com/inline.jpg"))
    let document = NovelReaderProjection(
        threadID: "146",
        view: 3,
        maxView: 4,
        segments: [
            .text("第一章正文", chapterTitle: "第一章"),
            .text("第二段正文", chapterTitle: "第一章"),
            .image(imageURL, chapterTitle: "第一章"),
            .text("第二章正文", chapterTitle: "第二章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "post-1"),
            NovelReaderSegmentSource(ownerPostID: "post-1"),
            NovelReaderSegmentSource(ownerPostID: "post-image"),
            NovelReaderSegmentSource(ownerPostID: "post-2")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "post:post-1#chapter:0", textID: "post:post-1#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:post-1#chapter:0", textID: "post:post-1#chapter:0#text:1"),
            novelReaderImageSemantics(chapterID: "post:post-1#chapter:0"),
            novelReaderTextSemantics(chapterID: "post:post-2#chapter:0", textID: "post:post-2#chapter:0#text:0")
        ],
        fetchedAt: Date(timeIntervalSince1970: 146)
    )

    let pagination = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    let context = pagination.viewportContext
    let index = pagination.viewportIndex

    #expect(context.identity.documentView == 3)
    #expect(context.identity.threadID == document.threadID)
    #expect(context.identity.fetchedAt == document.fetchedAt)
    #expect(context.document.text == "第一章正文\n\n第二段正文\n\n第二章正文")
    #expect(context.document.textRangesBySegment[0] == NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 5))
    #expect(context.document.textRangesBySegment[1] == NovelRenderedTextRange(segmentIndex: 1, startOffset: 7, endOffset: 12))
    #expect(context.document.textRangesBySegment[3] == NovelRenderedTextRange(segmentIndex: 3, startOffset: 14, endOffset: 19))
    #expect(context.document.insertedSeparatorRanges == [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 5, endOffset: 7),
        NovelRenderedTextRange(segmentIndex: 1, startOffset: 12, endOffset: 14)
    ])
    #expect(context.externalBlocks.map(\.chapterIdentity) == [
        NovelChapterIdentity(rawValue: "post:post-1#chapter:0")
    ])
    #expect(context.diagnostics.indexBuildCount == 1)
    #expect(context.diagnostics.visibleLayoutPassCount == 0)
    #expect(index.surfaces.flatMap(\.ranges).map(\.segmentIndex) == [0, 1, 3])
}

@Test func novelTextLayoutResultIsViewportFirstWithoutRenderedPageCompatibility() async throws {
    let document = NovelReaderProjection(
        threadID: "163",
        view: 1,
        maxView: 1,
        segments: [
            .text("第一段", chapterTitle: "第一章"),
            .text("第二段", chapterTitle: "第一章")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-0"),
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-1")
        ]
    )

    let layoutResult = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    #expect(layoutResult.viewportContext.document.text == "第一段\n\n第二段")
    #expect(layoutResult.viewportIndex.surfaces.map(\.ranges) == [
        [
            NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 3),
            NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 3)
        ]
    ])
    #expect(layoutResult.viewportIndex.surfaces.map(\.surfaceOrdinal) == [0])
    #expect(layoutResult.viewportIndex.surfaces.first?.externalBlocks.isEmpty == true)
}

@Test func novelTextLayoutCreatesAndUpdatesNovelTextViewportThroughHighLevelInterface() throws {
    let document = NovelReaderProjection(
        threadID: "62",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "High level Novel Text Viewport creation should publish exact ranges. ", count: 8), chapterTitle: "第一章")
        ]
    )
    let compactLayout = NovelReaderLayout(width: 320, height: 568)
    let expandedLayout = NovelReaderLayout(width: 414, height: 896)

    let created = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: compactLayout
    )
    let updated = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: expandedLayout
    )

    #expect(created.viewportContext.identity.layout == compactLayout)
    #expect(created.viewportIndex.readingMode == .paged)
    #expect(updated.viewportContext.identity.layout == expandedLayout)
    #expect(updated.viewportIndex.readingMode == .vertical)
    #expect(updated.viewportContext.document == created.viewportContext.document)
}

#if canImport(UIKit)
@Test func novelTextViewportUpdatePublishesPageLayoutMetrics() throws {
    let repetitionCount = 400
    let layout = NovelReaderLayout(width: 320, height: 568, readingMode: .vertical)
    let document = NovelReaderProjection(
        threadID: "63",
        view: 1,
        maxView: 1,
        segments: [
            .text(
                String(repeating: "Viewport update metrics should size native novel text. ", count: repetitionCount),
                chapterTitle: "第一章"
            )
        ]
    )

    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: layout
    )

    #expect(result.viewportIndex.surfaces.count > 2)
    for page in result.viewportIndex.surfaces {
        let geometry = try #require(page.frozenGeometry)
        let textHeight = try #require(result.layoutMetrics.surfaceMetrics[page.surfaceOrdinal]?.textHeight)
        #expect(textHeight == geometry.clipHeight)
        #expect(textHeight > 0)
        #expect(textHeight <= layout.readableFrame.height)
    }
}
#endif

@Test func novelTextViewportFrozenGeometryUsesSurfaceClipHeight() {
    let clipRect = CGRect(x: 0, y: 2_400, width: 320, height: 780)

    #expect(
        NovelTextViewportFrozenGeometry.surfaceContentHeight(forDocumentClipRect: clipRect) == 780
    )
}

@Test func novelTextLayoutConvertsDisplayOffsetsUsingSwiftCharacterRanges() throws {
    let document = NovelReaderProjection(
        threadID: "412",
        view: 3,
        maxView: 3,
        segments: [
            .text("第一段文本", chapterTitle: "第一章"),
            .text("第二段文本", chapterTitle: "第一章"),
            .text("第三段文本", chapterTitle: "第一章")
        ]
    )
    let ranges = [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 10, endOffset: 12),
        NovelRenderedTextRange(segmentIndex: 2, startOffset: 40, endOffset: 43)
    ]

    let sample = try #require(
        NovelTextLayout.viewportSample(
            displayOffset: 5,
            ranges: ranges,
            projection: document,
            surfaceOrdinal: 7
        )
    )
    let textSegmentIdentity = try #require(document.semantics(forSegmentIndex: 2)?.textSegmentIdentity)
    let displayOffset = try #require(
        NovelTextLayout.displayOffset(
            for: textSegmentIdentity,
            displayedTextOffset: 41,
            in: document,
            ranges: ranges
        )
    )

    #expect(sample.textSegmentIdentity == textSegmentIdentity)
    #expect(sample.displayedTextOffset == 41)
    #expect(displayOffset == 5)
}

@Test func novelTextViewportIndexPagePublishesImageExternalBlockPlacement() async throws {
    let imageURL = try #require(URL(string: "https://example.com/viewport-image.jpg"))
    let document = NovelReaderProjection(
        threadID: "164",
        view: 2,
        maxView: 2,
        segments: [
            .text("第一章正文", chapterTitle: "第一章"),
            .image(imageURL, chapterTitle: "第一章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "text-post"),
            NovelReaderSegmentSource(ownerPostID: "image-post")
        ]
    )

    let layoutResult = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    let imagePage = try #require(layoutResult.viewportIndex.surfaces.first { !$0.externalBlocks.isEmpty })
    #expect(imagePage.ranges.isEmpty)
    #expect(imagePage.externalBlocks == [
        NovelTextViewportExternalBlock(
            chapterIdentity: document.semantics(forSegmentIndex: 1)?.chapterIdentity,
            url: imageURL,
            chapterOrdinal: 0,
            chapterTitle: "第一章",
            frozenFrame: NovelTextViewportExternalBlockFrame(
                x: 0,
                y: 0,
                width: 390,
                height: 253.5
            ),
            chapterCommentTarget: ReaderChapterCommentTarget(
                threadID: document.threadID,
                view: 2,
                ownerPostID: "image-post",
                title: "第一章"
            )
        )
    ])
    #expect(layoutResult.viewportIndex.surfaces[imagePage.surfaceOrdinal].externalBlocks.map(\.url) == [imageURL])
}

@Test func novelTextLayoutDerivesPageRangesFromComposedViewportDocument() async throws {
    let document = NovelReaderProjection(
        threadID: "165",
        view: 1,
        maxView: 1,
        segments: [
            .text("第一段", chapterTitle: "第一章"),
            .text("第二段", chapterTitle: "第一章")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-0"),
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-1")
        ]
    )
    let layoutInputCount = LockedCounter()

    let layoutResult = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            layoutInputCount.increment()
            #expect(context.document.text == "第一段\n\n第二段")
            return [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    #expect(layoutInputCount.value == 1)
    #expect(layoutResult.viewportContext.document.insertedSeparatorRanges == [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 3, endOffset: 5)
    ])
    #expect(layoutResult.viewportIndex.surfaces.map(\.ranges) == [
        [
            NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 3),
            NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 3)
        ]
    ])
    let secondSegmentIdentity = try #require(document.semantics(forSegmentIndex: 1)?.textSegmentIdentity)
    #expect(layoutResult.viewportIndex.position(for: secondSegmentIdentity, displayedTextOffset: 1, in: document)?.surfaceOrdinal == 0)
}

@Test func novelTextLayoutPreservesViewportPageRangesWithoutDisplayValueMaterialization() async throws {
    let settings = NovelReaderAppearanceSettings(
        fontScale: 1.25,
        fontFamily: .systemSerif,
        lineHeightScale: 1.7,
        characterSpacingScale: 0.12,
        usesJustifiedText: true,
        indentsParagraphFirstLine: true,
        readingMode: .paged
    )
    let context = NovelTextViewportContext(
        identity: NovelTextViewportIdentity(
            threadID: "159",
            documentView: 2,
            maxView: 3,
            fetchedAt: Date(timeIntervalSince1970: 159),
            appearance: settings,
            layout: NovelReaderLayout(width: 390, height: 844)
        ),
        document: NovelTextViewportDocument(
            text: "第一段正文很长\n\n第二段正文继续",
            textRangesBySegment: [
                0: NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 7),
                1: NovelRenderedTextRange(segmentIndex: 1, startOffset: 9, endOffset: 16)
            ],
            insertedSeparatorRanges: [
                NovelRenderedTextRange(segmentIndex: 0, startOffset: 7, endOffset: 9)
            ]
        ),
        externalBlocks: [],
        diagnostics: NovelTextViewportDiagnostics(indexBuildCount: 1)
    )
    let ranges = [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 2, endOffset: 7),
        NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 4)
    ]
    let viewportPage = NovelTextViewportIndexSurface(
        surfaceOrdinal: 4,
        documentView: 2,
        chapterOrdinal: 0,
        chapterTitle: "第一章",
        ranges: ranges
    )

    let result = NovelTextLayoutResult(
        viewportContext: context,
        viewportIndex: NovelTextViewportIndex(
            documentView: 2,
            readingMode: .paged,
            surfaces: [viewportPage],
            chapters: []
        )
    )

    #expect(result.viewportIndex.surfaces.first?.ranges == ranges)
    #expect(result.viewportIndex.surfaces.first?.chapterTitle == "第一章")
    #expect(result.viewportContext.identity.appearance == settings)
}

@Test func novelTextLayoutDoesNotExposeDisplayValueForMissingViewportPageRange() async throws {
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let context = NovelTextViewportContext(
        identity: NovelTextViewportIdentity(
            threadID: "159-missing",
            documentView: 1,
            maxView: 1,
            fetchedAt: Date(timeIntervalSince1970: 159),
            appearance: settings,
            layout: NovelReaderLayout(width: 390, height: 844)
        ),
        document: NovelTextViewportDocument(
            text: "第一段正文",
            textRangesBySegment: [
                0: NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 5)
            ],
            insertedSeparatorRanges: []
        ),
        externalBlocks: [],
        diagnostics: NovelTextViewportDiagnostics(indexBuildCount: 1)
    )
    let viewportPage = NovelTextViewportIndexSurface(
        surfaceOrdinal: 0,
        documentView: 1,
        chapterOrdinal: nil,
        chapterTitle: nil,
        ranges: [NovelRenderedTextRange(segmentIndex: 9, startOffset: 0, endOffset: 2)]
    )

    let result = NovelTextLayoutResult(
        viewportContext: context,
        viewportIndex: NovelTextViewportIndex(
            documentView: 1,
            readingMode: .paged,
            surfaces: [viewportPage],
            chapters: []
        )
    )
    #expect(result.viewportIndex.surfaces.first?.ranges.first?.segmentIndex == 9)
}

@Test func novelTextLayoutDoesNotReuseCachedNovelTextViewportIndexForMatchingInputs() async throws {
    let document = NovelReaderProjection(
        threadID: "102",
        view: 1,
        maxView: 1,
        segments: [.text("重复打开时应该复用精确索引", chapterTitle: "第一章")],
        fetchedAt: Date(timeIntervalSince1970: 1)
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 390, height: 844)
    let layoutPassCount = LockedCounter()
    let viewportSurfaceLayout: NovelTextViewportSurfaceLayout = { context, _, _ in
        layoutPassCount.increment()
        return [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
    }

    let first = try NovelTextLayout.layout(
        projection: document,
        settings: settings,
        layout: layout,
        viewportSurfaceLayout: viewportSurfaceLayout,
    )
    let second = try NovelTextLayout.layout(
        projection: document,
        settings: settings,
        layout: layout,
        viewportSurfaceLayout: viewportSurfaceLayout,
    )

    #expect(layoutPassCount.value == 2)
    #expect(first.viewportIndex == second.viewportIndex)
    #expect(first.viewportIndex.surfaces == second.viewportIndex.surfaces)
}

@Test func novelTextLayoutInvalidatesCachedNovelTextViewportIndexForSettingsAndLayoutChanges() async throws {
    let document = NovelReaderProjection(
        threadID: "103",
        view: 1,
        maxView: 1,
        segments: [.text("设置和布局改变必须重建索引", chapterTitle: "第一章")],
        fetchedAt: Date(timeIntervalSince1970: 1)
    )
    let layoutPassCount = LockedCounter()
    let viewportSurfaceLayout: NovelTextViewportSurfaceLayout = { context, _, _ in
        layoutPassCount.increment()
        return [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
    }

    _ = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: viewportSurfaceLayout,
    )
    _ = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(fontScale: 1.2, readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: viewportSurfaceLayout,
    )
    _ = try NovelTextLayout.layout(
        projection: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 320, height: 568),
        viewportSurfaceLayout: viewportSurfaceLayout,
    )

    #expect(layoutPassCount.value == 3)
}

@Test func novelTextLayoutDoesNotCacheFailedNovelTextViewportIndexBuilds() async throws {
    let document = NovelReaderProjection(
        threadID: "104",
        view: 1,
        maxView: 1,
        segments: [.text("失败的索引构建不能污染缓存", chapterTitle: "第一章")],
        fetchedAt: Date(timeIntervalSince1970: 1)
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 390, height: 844)

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            projection: document,
            settings: settings,
            layout: layout,
            viewportSurfaceLayout: { _, _, _ in [] },
        )
    }

    let pagination = try NovelTextLayout.layout(
        projection: document,
        settings: settings,
        layout: layout,
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        },
    )

    #expect(pagination.viewportIndex.surfaces.count == 1)
}

#if canImport(UIKit)
@Test func novelTextLayoutPreservesSingleTextSegmentRanges() async throws {
    let text = String(repeating: "分页边界应来自 Novel Text Layout。", count: 100)
    let document = NovelReaderProjection(
        threadID: "58",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 320, height: 568)

    let pagination = try NovelTextLayout.layout(document: document, settings: settings, layout: layout)
    let ranges = pagination.viewportIndex.surfaces.flatMap(\.ranges)

    #expect(ranges.first?.startOffset == 0)
    #expect(ranges.last?.endOffset == text.count)
    for pair in zip(ranges, ranges.dropFirst()) {
        #expect(pair.0.endOffset <= pair.1.startOffset)
    }
    #expect(Set(ranges.map(\.segmentIndex)) == [0])
}

@Test func novelTextLayoutFreezesPagedSurfaceGeometryFromTextKitDocument() async throws {
    let text = String(repeating: "Frozen paged geometry must be committed with the surface. ", count: 160)
    let layout = NovelReaderLayout(width: 320, height: 568)
    let document = NovelReaderProjection(
        threadID: "189",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: layout
    )
    let textPages = result.viewportIndex.surfaces.filter { !$0.ranges.isEmpty }

    #expect(textPages.count > 1)
    for page in textPages {
        let geometry = try #require(page.frozenGeometry)
        #expect(geometry.documentStartOffset < geometry.documentEndOffset)
        #expect(geometry.clipHeight > 0)
        #expect(geometry.documentClipMinY.isFinite)
        #expect(geometry.documentClipMaxY.isFinite)
        #expect(geometry.contentHeight >= geometry.clipHeight)
    }

    for pair in zip(textPages, textPages.dropFirst()) {
        let previous = try #require(pair.0.frozenGeometry)
        let next = try #require(pair.1.frozenGeometry)
        #expect(previous.documentEndOffset <= next.documentStartOffset)
        #expect(previous.documentClipMaxY <= next.documentClipMinY)
    }
}
#endif

@Test func novelTextLayoutAcceptsRematerializedGeometryWhenPageStartsAfterTrimmedWhitespace() async throws {
#if canImport(UIKit)
    let paragraph = "    页首空白不应使 TextKit 重新物化后的片段几何校验失败。"
    let text = Array(repeating: paragraph, count: 180).joined(separator: "\n\n")
    let document = NovelReaderProjection(
        threadID: "190",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 320, height: 568)
    )

    #expect(result.viewportIndex.surfaces.count > 1)
    #expect(result.viewportIndex.surfaces.allSatisfy { $0.frozenGeometry != nil })
#endif
}

@Test func novelTextSurfaceFragmentPartitionerMovesCrossingLineToNextSurface() throws {
    let surfaces = NovelTextSurfaceFragmentPartitioner.partition(
        [
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 0, length: 10),
                rect: CGRect(x: 0, y: 0, width: 200, height: 35)
            ),
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 10, length: 10),
                rect: CGRect(x: 0, y: 40, width: 200, height: 35)
            ),
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 20, length: 10),
                rect: CGRect(x: 0, y: 80, width: 200, height: 35)
            )
        ],
        surfaceHeight: 100
    )

    #expect(surfaces.count == 2)
    #expect(surfaces.allSatisfy { $0.clipRect.height <= 100 })
    let firstSurface = try #require(surfaces.first)
    let secondSurface = try #require(surfaces.dropFirst().first)
    #expect(firstSurface.characterRange == NSRange(location: 0, length: 20))
    #expect(secondSurface.characterRange == NSRange(location: 20, length: 10))
}

@Test func novelTextSurfaceFragmentPartitionerIgnoresAlreadyCoveredOverlappingFragments() throws {
    let surfaces = NovelTextSurfaceFragmentPartitioner.partition(
        [
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 0, length: 10),
                rect: CGRect(x: 0, y: 0, width: 200, height: 35)
            ),
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 10, length: 10),
                rect: CGRect(x: 0, y: 40, width: 200, height: 35)
            ),
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 15, length: 5),
                rect: CGRect(x: 0, y: 80, width: 200, height: 35)
            )
        ],
        surfaceHeight: 100
    )

    #expect(surfaces.count == 1)
    #expect(try #require(surfaces.first).characterRange == NSRange(location: 0, length: 20))
}

@Test func novelTextViewportDrawingClipsToFrozenPageGeometry() {
    let clipRect = NovelTextViewportDrawingGeometry.clipRect(
        bounds: CGRect(x: 0, y: 0, width: 361, height: 669),
        surfaceOriginY: 1_000,
        documentClipMaxY: 1_629.64
    )

    #expect(clipRect.origin == .zero)
    #expect(clipRect.width == 361)
    #expect(abs(clipRect.height - 629.64) < 0.001)
    #expect(
        NovelTextViewportDrawingGeometry.clipRect(
            bounds: CGRect(x: 0, y: 0, width: 361, height: 669),
            surfaceOriginY: 1_000,
            documentClipMaxY: nil
        ) == CGRect(x: 0, y: 0, width: 361, height: 669)
    )
}

@Test func novelTextViewportDrawingAssignsFragmentsToOneSurfaceByStartOffset() {
    let surfaceRange = 102 ..< 180

    #expect(!NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
        fragmentStart: 100,
        fragmentEnd: 150,
        documentRange: surfaceRange
    ))
    #expect(NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
        fragmentStart: 102,
        fragmentEnd: 150,
        documentRange: surfaceRange
    ))
    #expect(!NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
        fragmentStart: 50,
        fragmentEnd: 102,
        documentRange: surfaceRange
    ))
    #expect(!NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
        fragmentStart: 180,
        fragmentEnd: 220,
        documentRange: surfaceRange
    ))
}

@MainActor
@Test func novelTextViewportDrawsRestoredVerticalSurfaceAfterInitialFirstPageViewport() throws {
#if canImport(UIKit)
    let text = Array(
        repeating: "围绕着王位继承权的争夺，距离那场内战的落幕已过去半个月的时间，而今天，是女王陛下的王位继承仪式。",
        count: 260
    ).joined(separator: "\n\n")
    let document = NovelReaderProjection(
        threadID: "191",
        view: 1,
        maxView: 4,
        segments: [.text(text, chapterTitle: "第六章 贵穿之物")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .vertical)
    let layout = NovelReaderLayout(width: 390, height: 844, readingMode: .vertical)
    let runtime = NovelTextViewportRuntimeOwner()
    let transaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: settings,
            layout: layout
        )
    )
    let targetSurface = try #require(transaction.result.viewportIndex.surfaces.dropFirst(9).first)
    try runtime.prepareInitialViewport(for: transaction, around: 0)
    #expect(runtime.commit(transaction))
    runtime.updateVisibleSurfaceIdentities(
        transaction.result.viewportIndex.surfaces
            .filter { abs($0.surfaceOrdinal - targetSurface.surfaceOrdinal) <= 1 }
            .map {
                NovelReaderSurfaceIdentity(
                    generation: transaction.generation,
                    ordinal: $0.surfaceOrdinal
                )
            }
    )
    let displayReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: transaction.generation,
        ordinal: targetSurface.surfaceOrdinal
    )))
    let width = 390
    let height = 844
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))

    displayReference.draw(in: context, bounds: CGRect(x: 0, y: 0, width: width, height: height))

    let upperHalfAlphaPixelCount = stride(from: 0, to: (height / 2) * bytesPerRow, by: 4).reduce(0) { count, offset in
        count + (pixels[offset + 3] > 0 ? 1 : 0)
    }
    #expect(upperHalfAlphaPixelCount > 100)

    let inkRows = (0..<height).map { y -> Bool in
        let rowStart = y * bytesPerRow
        let alphaPixels = stride(from: rowStart, to: rowStart + bytesPerRow, by: 4).reduce(0) { count, offset in
            count + (pixels[offset + 3] > 0 ? 1 : 0)
        }
        return alphaPixels > 8
    }
    let firstInkRow = try #require(inkRows.firstIndex(of: true))
    let lastInkRow = try #require(inkRows.lastIndex(of: true))
    var longestBlankBand = 0
    var currentBlankBand = 0
    for hasInk in inkRows[firstInkRow...lastInkRow] {
        if hasInk {
            longestBlankBand = max(longestBlankBand, currentBlankBand)
            currentBlankBand = 0
        } else {
            currentBlankBand += 1
        }
    }
    longestBlankBand = max(longestBlankBand, currentBlankBand)
    #expect(longestBlankBand < 220)
#endif
}

@MainActor
@Test func novelTextViewportDrawsLaterSurfaceLinesWhenLayoutFragmentStartsBeforeSurface() throws {
#if canImport(UIKit)
    let text = String(
        repeating: "库莉茜耶把听到的话认真记在心里，然后继续望向远方闪闪发亮的雪原和村庄。 ",
        count: 220
    )
    let document = NovelReaderProjection(
        threadID: "192",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "长段落")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .vertical)
    let layout = NovelReaderLayout(width: 390, height: 844, readingMode: .vertical)
    let runtime = NovelTextViewportRuntimeOwner()
    let transaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: settings,
            layout: layout
        )
    )
    let targetSurface = try #require(transaction.result.viewportIndex.surfaces.first {
        ($0.frozenGeometry?.documentStartOffset ?? 0) > 0 && !$0.ranges.isEmpty
    })
    let geometry = try #require(targetSurface.frozenGeometry)
    try runtime.prepareInitialViewport(for: transaction, around: 0)
    #expect(runtime.commit(transaction))
    runtime.updateVisibleSurfaceIdentities([
        NovelReaderSurfaceIdentity(
            generation: transaction.generation,
            ordinal: targetSurface.surfaceOrdinal
        )
    ])
    let displayReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: transaction.generation,
        ordinal: targetSurface.surfaceOrdinal
    )))
    let width = 390
    let height = max(Int(ceil(geometry.contentHeight)), 1)
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let context = try #require(CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))

    displayReference.draw(in: context, bounds: CGRect(x: 0, y: 0, width: width, height: height))

    let inkRows = (0..<height).map { y -> Bool in
        let rowStart = y * bytesPerRow
        let alphaPixels = stride(from: rowStart, to: rowStart + bytesPerRow, by: 4).reduce(0) { count, offset in
            count + (pixels[offset + 3] > 0 ? 1 : 0)
        }
        return alphaPixels > 8
    }
    let firstInkRow = try #require(inkRows.firstIndex(of: true))
    let lastInkRow = try #require(inkRows.lastIndex(of: true))

    #expect(firstInkRow < 80)
    #expect(lastInkRow > height / 2)
    #expect(height - lastInkRow - 1 < 100)
#endif
}

@Test func novelTextLayoutPagedViewportSurfaceRangeFailureDoesNotUseEstimatedFallback() async throws {
    let text = String(repeating: "TextKit 2 failure should not fall back. ", count: 40)
    let document = NovelReaderProjection(
        threadID: "65",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            projection: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            viewportSurfaceLayout: { _, _, _ in [] }
        )
    }
}

@Test func novelTextLayoutPagedFailureThrowsInsteadOfPublishingFallbackPage() async throws {
    let document = NovelReaderProjection(
        threadID: "59",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "TextKit 2 failure should stop pagination. ", count: 40), chapterTitle: "第一章")
        ]
    )

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            projection: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            viewportSurfaceLayout: { _, _, _ in [] }
        )
    }
}

@Test func novelTextLayoutVerticalViewportPageRangeFailureDoesNotUseEstimatedFallback() async throws {
    let text = String(repeating: "Vertical TextKit 2 failure should not fall back. ", count: 40)
    let document = NovelReaderProjection(
        threadID: "66",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            projection: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568),
            viewportSurfaceLayout: { _, _, _ in [] }
        )
    }
}

@Test func novelTextLayoutVerticalFailureThrowsInsteadOfPublishingFallbackPage() async throws {
    let document = NovelReaderProjection(
        threadID: "60",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "Vertical TextKit 2 failure should stop pagination. ", count: 40), chapterTitle: "第一章")
        ]
    )

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            projection: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568),
            viewportSurfaceLayout: { _, _, _ in [] }
        )
    }
}

@Test func novelTextLayoutTransformsInlineBoldRangesWithDisplayedText() throws {
    let document = NovelReaderProjection(
        threadID: "304",
        view: 1,
        maxView: 1,
        segments: [.text("繁體粗體結束", chapterTitle: nil)],
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
        settings: NovelReaderAppearanceSettings(readingMode: .paged, translationMode: .simplified),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(preparedInput.viewportContextSeed.document.text == "繁体粗体结束")
    #expect(preparedInput.annotatedSegments.first?.semantics?.inlineTextStyles == [
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 2, length: 2))
    ])
    #expect(preparedInput.viewportContextSeed.document.inlineTextStylesBySegment[0] == [
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 2, length: 2))
    ])
}

@Test func novelTextLayoutTransformsQuoteRangesAndProjectsDocumentOffsets() throws {
    let document = NovelReaderProjection(
        threadID: "307",
        view: 1,
        maxView: 1,
        segments: [
            .text("前段", chapterTitle: nil),
            .text("繁體引用結束", chapterTitle: nil),
        ],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1")
            ),
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-2"),
                blockTextStyles: [
                    NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 2, length: 2))
                ]
            ),
        ]
    )

    let preparedInput = try NovelTextLayout.prepareInput(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged, translationMode: .simplified),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(preparedInput.viewportContextSeed.document.text == "前段\n\n繁体引用结束")
    #expect(preparedInput.annotatedSegments[1].semantics?.blockTextStyles == [
        NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 2, length: 2))
    ])
    #expect(preparedInput.viewportContextSeed.document.blockTextStyles == [
        NovelBlockTextStyleRange(
            style: .quote,
            range: NovelCharacterRange(location: "前段\n\n繁体".count, length: 2)
        )
    ])
}

#if canImport(UIKit)
@MainActor
@Test func novelTextRuntimeRebuildsSemanticDocumentWhenOnlyInlineStylesChange() throws {
    let runtime = NovelTextViewportRuntimeOwner()
    let plain = NovelReaderProjection(
        threadID: "306",
        view: 1,
        maxView: 1,
        segments: [.text("同一段正文", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1")
            )
        ]
    )
    let styled = NovelReaderProjection(
        threadID: "306",
        view: 1,
        maxView: 1,
        segments: [.text("同一段正文", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                inlineTextStyles: [
                    NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 3, length: 2))
                ]
            )
        ]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 390, height: 844)

    let first = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(document: plain, settings: settings, layout: layout)
    )
    #expect(runtime.commit(first))
    let second = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(document: styled, settings: settings, layout: layout)
    )
    #expect(runtime.commit(second))

    #expect(runtime.runtimeTransactionDiagnostics.semanticAttributedDocumentBuildCount == 2)
    #expect(runtime.runtimeTransactionDiagnostics.semanticAttributedDocumentReuseCount == 0)
}

@MainActor
@Test func novelTextRuntimeRebuildsSemanticDocumentWhenOnlyBlockStylesChange() throws {
    let runtime = NovelTextViewportRuntimeOwner()
    let plain = NovelReaderProjection(
        threadID: "308",
        view: 1,
        maxView: 1,
        segments: [.text("同一段正文", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1")
            )
        ]
    )
    let styled = NovelReaderProjection(
        threadID: "308",
        view: 1,
        maxView: 1,
        segments: [.text("同一段正文", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                blockTextStyles: [
                    NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 3, length: 2))
                ]
            )
        ]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 390, height: 844)

    let first = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(document: plain, settings: settings, layout: layout)
    )
    #expect(runtime.commit(first))
    let second = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(document: styled, settings: settings, layout: layout)
    )
    #expect(runtime.commit(second))

    #expect(runtime.runtimeTransactionDiagnostics.semanticAttributedDocumentBuildCount == 2)
    #expect(runtime.runtimeTransactionDiagnostics.semanticAttributedDocumentReuseCount == 0)
}
#endif

@Test func novelTextLayoutRejectsEmptySemanticDocumentBeforeRuntimeAllocation() throws {
    let document = NovelReaderProjection(
        threadID: "302",
        view: 1,
        maxView: 1,
        segments: [.text(" \n ", chapterTitle: nil)]
    )

    #expect(throws: NovelTextLayoutFailure.semanticDocumentPreparation) {
        _ = try NovelTextLayout.prepareInput(
            document: document,
            settings: NovelReaderAppearanceSettings(),
            layout: NovelReaderLayout(width: 390, height: 844)
        )
    }
}

#if canImport(UIKit)
@Test func novelTextLayoutCommitsSemanticLayoutFontPlatformAndTextKitFingerprints() throws {
    let document = NovelReaderProjection(
        threadID: "303",
        view: 1,
        maxView: 1,
        segments: [.text("第一章\n指纹正文。", chapterTitle: "第一章")]
    )
    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(!result.fingerprints.semantic.isEmpty)
    #expect(!result.fingerprints.text.isEmpty)
    #expect(!result.fingerprints.layout.isEmpty)
    #expect(!result.fingerprints.font.isEmpty)
    #expect(!result.fingerprints.platform.isEmpty)
    #expect(result.fingerprints.textKitImplementation == "NSTextLayoutManager-TextKit2-v1")
}
#endif

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

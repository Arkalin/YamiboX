import Foundation
import Testing
@testable import YamiboXCore

// 拆分自 ReaderCoreTests.swift:NovelChapterDirectoryExtractor 章节目录抽取。
// 语义 fixture 构造器位于 NovelReaderTestSupport.swift。

@Test func novelChapterDirectoryExtractorMatchesReaderPreviewDirectoryRules() throws {
    let document = NovelReaderProjection(
        threadID: "99",
        view: 2,
        maxView: 3,
        resolvedAuthorID: "42",
        segments: [
            .text("第一章\n开头", chapterTitle: "第一章"),
            .text("第一章续文", chapterTitle: "第一章"),
            .image(try #require(URL(string: "https://example.com/1.jpg")), chapterTitle: "第一章"),
            .text("同名章\n正文", chapterTitle: "同名章"),
            .text("同名章\n另一处正文", chapterTitle: "同名章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "1001"),
            NovelReaderSegmentSource(ownerPostID: "1001"),
            NovelReaderSegmentSource(ownerPostID: "1001"),
            NovelReaderSegmentSource(ownerPostID: "1002"),
            NovelReaderSegmentSource(ownerPostID: "1003")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "post:1001#chapter:0", textID: "post:1001#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:1001#chapter:0", textID: "post:1001#chapter:0#text:1"),
            novelReaderImageSemantics(chapterID: "post:1001#chapter:0"),
            novelReaderTextSemantics(chapterID: "post:1002#chapter:0", textID: "post:1002#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:1003#chapter:0", textID: "post:1003#chapter:0#text:0")
        ]
    )

    let entries = NovelChapterDirectoryExtractor.entries(
        from: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical)
    )

    #expect(entries.map(\.chapter.title) == ["第一章", "同名章", "同名章"])
    #expect(entries.map(\.chapter.ordinal) == [0, 1, 2])
    #expect(entries.map(\.chapter.startIndex) == [0, 1, 2])
    #expect(entries.map(\.ownerPostID) == ["1001", "1002", "1003"])
    #expect(entries[0].anchor?.resumePoint.view == 2)
    #expect(entries[0].anchor?.resumePoint.authorID == "42")
    #expect(entries[0].anchor?.resumePoint.chapterIdentity?.rawValue == "post:1001#chapter:0")
    #expect(entries[0].anchor?.resumePoint.textSegmentIdentity?.rawValue == "post:1001#chapter:0#text:0")
    #expect(entries[0].anchor?.resumePoint.chapterTitle == "第一章")
    #expect(entries[0].anchor?.resumePoint.readingModeHint == .vertical)
}

@Test func novelChapterDirectoryExtractorUsesReaderAuthorReplyVisibilitySetting() throws {
    let document = NovelReaderProjection(
        threadID: "100",
        view: 1,
        maxView: 1,
        resolvedAuthorID: "42",
        segments: [
            .text("第一章\n正文", chapterTitle: "第一章"),
            .text("作者回复\n正文", chapterTitle: "作者回复"),
            .text("第二章\n正文", chapterTitle: "第二章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "1001"),
            NovelReaderSegmentSource(ownerPostID: "1002", isAuthorReplyToOther: true),
            NovelReaderSegmentSource(ownerPostID: "1003")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "post:1001#chapter:0", textID: "post:1001#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:1002#chapter:0", textID: "post:1002#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:1003#chapter:0", textID: "post:1003#chapter:0#text:0")
        ]
    )

    let visible = NovelChapterDirectoryExtractor.entries(
        from: document,
        settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: true)
    )
    let hidden = NovelChapterDirectoryExtractor.entries(
        from: document,
        settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false)
    )

    #expect(visible.map(\.chapter.title) == ["第一章", "作者回复", "第二章"])
    #expect(hidden.map(\.chapter.title) == ["第一章", "第二章"])
}

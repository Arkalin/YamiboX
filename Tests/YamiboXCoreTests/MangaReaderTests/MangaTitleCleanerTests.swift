import Testing
@testable import YamiboXCore

@Test func extractTidSupportsMobileAndLegacyURLs() async throws {
    #expect(MangaTitleCleaner.extractTid(from: "forum.php?mod=viewthread&tid=12345&mobile=2") == "12345")
    #expect(MangaTitleCleaner.extractTid(from: "thread-54321-1-1.html") == "54321")
}

@Test func chapterNumberMatchesSimplePatterns() async throws {
    #expect(MangaTitleCleaner.extractChapterNumber("第12话 相遇") == 12)
    #expect(MangaTitleCleaner.extractChapterNumber("第12-3话") == 12.03)
    #expect(MangaTitleCleaner.extractChapterNumber("最终话") == 999)
}

@Test func chapterNumberMatchesCircledSuffixAfterEpisodeMarker() async throws {
    #expect(MangaTitleCleaner.extractChapterNumber("第03话①") == 3.01)
    #expect(MangaTitleCleaner.extractChapterNumber("第06话②③") == 6.23)
    #expect(MangaChapterDisplayFormatter.displayNumber(rawTitle: "第03话①", chapterNumber: 3.01) == "3-1")
}

@Test func chapterNumberMatchesBareTrailingCircledSuffix() async throws {
    let firstTitle = "【提灯喵汉化组】【あおのなち】与你相恋到生命尽头 17①"
    let secondTitle = "【提灯喵汉化组】【あおのなち】与你相恋到生命尽头 17②"

    #expect(MangaTitleCleaner.extractChapterNumber(firstTitle) == 17.01)
    #expect(MangaTitleCleaner.extractChapterNumber(secondTitle) == 17.02)
    #expect(MangaChapterDisplayFormatter.displayNumber(rawTitle: firstTitle, chapterNumber: 17.01) == "17-1")
    #expect(MangaChapterDisplayFormatter.displayNumber(rawTitle: secondTitle, chapterNumber: 17.02) == "17-2")
}

@Test func searchKeywordKeepsAuthorAndBookName() async throws {
    #expect(MangaTitleCleaner.searchKeyword("【作者名】作品标题 - 中文百合漫画区") == "作者名 作品标题")
    #expect(MangaTitleCleaner.searchKeyword("【提灯喵汉化组】【桜木蓮】温热的银莲花 四卷番外") == "提灯喵汉化组 温热的银莲花")
}

@Test func cleanBookNameRemovesChapterSuffixes() async throws {
    #expect(MangaTitleCleaner.cleanBookName("【作者】作品 第12话 - 中文百合漫画区 - 百合会") == "作品")
    #expect(MangaTitleCleaner.cleanBookName("作品 第12-13话") == "作品")
    #expect(MangaTitleCleaner.cleanBookName("【提灯喵汉化组】【桜木蓮】温热的银莲花 32") == "温热的银莲花")
    #expect(MangaTitleCleaner.cleanBookName("【提灯喵汉化组】【桜木蓮】温热的银莲花 四卷番外") == "温热的银莲花")
    #expect(MangaTitleCleaner.cleanBookName("作品 最终话") == "作品")
    #expect(MangaTitleCleaner.cleanBookName("Area 51") == "Area 51")
}

@Test func readerHeaderTitleRemovesBookNameMetadataAndScanlationGroup() async throws {
    #expect(
        MangaChapterDisplayFormatter.readerHeaderTitle(
            rawTitle: "【提灯喵汉化组】【作者】温热的银莲花 32",
            cleanBookName: "温热的银莲花"
        ) == "第32话"
    )

    #expect(
        MangaChapterDisplayFormatter.readerHeaderTitle(
            rawTitle: "【某汉化组】作品 第12话 相遇（修正版）",
            cleanBookName: "作品"
        ) == "第12话 相遇"
    )

    #expect(
        MangaChapterDisplayFormatter.readerHeaderTitle(
            rawTitle: "[组]作品 第17话① 标题",
            cleanBookName: "作品"
        ) == "第17-1话 标题"
    )

    #expect(
        MangaChapterDisplayFormatter.readerHeaderTitle(
            rawTitle: "Area 51",
            cleanBookName: "Area 51"
        ) != "第51话"
    )
}

@Test func readerHeaderTitleKeepsEmbeddedSpecialEpisodeWords() async throws {
    #expect(
        MangaChapterDisplayFormatter.readerHeaderTitle(
            rawTitle: "【提灯喵汉化组】【あおのなち】与你相恋到生命尽头 日常番外篇1闪闪发光",
            cleanBookName: "与你相恋到生命尽头"
        ) == "SP 日常番外篇1闪闪发光"
    )
}

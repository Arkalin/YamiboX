import Foundation
import Testing
@testable import YamiboXCore

@Test func parsePCListExtractsThreadRows() async throws {
    let html = """
    <table>
      <tr>
        <th><a href="thread-10001-1-1.html">第12话 测试章节</a></th>
        <td class="by"></td>
        <td class="by"><cite><a href="space-uid-77.html">作者甲</a></cite><em><span>2026-01-02</span></em></td>
      </tr>
    </table>
    """

    let chapters = MangaHTMLParser.parseListHTML(html)
    #expect(chapters.count == 1)
    #expect(chapters.first?.tid == "10001")
    #expect(chapters.first?.authorUID == "77")
    #expect(chapters.first?.chapterNumber == 12)
}

@Test func parsePCListExtractsBareTrailingCircledChapterNumbers() async throws {
    let html = """
    <table>
      <tr>
        <th><a href="thread-10017-1-1.html">【提灯喵汉化组】【あおのなち】与你相恋到生命尽头 17①</a></th>
        <td class="by"></td>
        <td class="by"><cite><a href="space-uid-77.html">作者甲</a></cite></td>
      </tr>
      <tr>
        <th><a href="thread-10018-1-1.html">【提灯喵汉化组】【あおのなち】与你相恋到生命尽头 17②</a></th>
        <td class="by"></td>
        <td class="by"><cite><a href="space-uid-77.html">作者甲</a></cite></td>
      </tr>
    </table>
    """

    let chapters = MangaHTMLParser.parseListHTML(html)

    #expect(chapters.map(\.chapterNumber) == [17.01, 17.02])
    #expect(chapters.map(MangaChapterDisplayFormatter.displayNumber(for:)) == ["17-1", "17-2"])
}

@Test func parsePCListDecodesHTMLEntitiesInThreadHrefs() async throws {
    let html = """
    <table>
      <tr>
        <th><a href="forum.php?mod=viewthread&amp;tid=501595&amp;extra=&amp;mobile=2">第12话 测试章节</a></th>
        <td class="by"></td>
        <td class="by"><cite><a href="space-uid-77.html">作者甲</a></cite><em><span>2026-01-02</span></em></td>
      </tr>
    </table>
    """

    let chapter = try #require(MangaHTMLParser.parseListHTML(html).first)

    #expect(chapter.tid == "501595")
    #expect(chapter.view == 1)
}

// Pluggable-reader-config decision #6: tag-page thread rows are filtered by
// whatever fid the launching board passed in — not a hardcoded "30" — so the
// same tag list scopes to different boards depending on the caller.
@Test func parseTagThreadListHTMLKeepsOnlyRowsLinkingToAllowedForumIDs() async throws {
    let html = """
    <table>
      <tr>
        <th><a href="thread-20001-1-1.html">任意板块 第1话</a></th>
        <td class="by"><a href="forum-99-1.html">任意板块</a></td>
        <td class="by"><cite><a href="space-uid-71.html">作者甲</a></cite></td>
      </tr>
      <tr>
        <th><a href="thread-20002-1-1.html">漫画区 第2话</a></th>
        <td class="by"><a href="forum.php?mod=forumdisplay&fid=30">中文百合漫画区</a></td>
        <td class="by"><cite><a href="space-uid-72.html">作者乙</a></cite></td>
      </tr>
      <tr>
        <th><a href="thread-20003-1-1.html">无板块链接 第3话</a></th>
        <td class="by"><cite><a href="space-uid-73.html">作者丙</a></cite></td>
      </tr>
    </table>
    """

    // An arbitrary board's fid keeps only its own row (`forum-99-1.html`
    // link form); rows for other boards and rows with no forum link at all
    // are dropped.
    let arbitraryBoardChapters = MangaHTMLParser.parseTagThreadListHTML(html, allowedForumIDs: ["99"])
    #expect(arbitraryBoardChapters.map(\.tid) == ["20001"])

    // The same HTML scoped to fid 30 keeps only the fid-query-form row —
    // proving the filter follows the passed-in fid, not a hardcoded "30".
    let factoryBoardChapters = MangaHTMLParser.parseTagThreadListHTML(html, allowedForumIDs: ["30"])
    #expect(factoryBoardChapters.map(\.tid) == ["20002"])
}

@Test func favoriteParserKeepsOnlyThreadLinks() async throws {
    let html = #"""
    <ul class="sclist">
      <li>
        <a class="mdel" href="home.php?mod=spacecp&ac=favorite&op=delete&favid=456">删除</a>
        <a href="forum.php?mod=viewthread&tid=88&mobile=2">作品 A</a>
      </li>
      <li>
        <a href="home.php?mod=space">不是作品</a>
      </li>
    </ul>
    """#

    let favorites = FavoriteHTMLParser.parseFavorites(from: html)
    #expect(favorites.count == 1)
    #expect(favorites.first?.title == "作品 A")
    #expect(favorites.first?.remoteFavoriteID == "456")
}

@Test func favoriteParserKeepsFavoriteWhenDeleteLinkIsMissing() async throws {
    let html = #"""
    <ul class="sclist">
      <li>
        <a href="forum.php?mod=viewthread&tid=99&mobile=2">作品 B</a>
      </li>
    </ul>
    """#

    let favorites = FavoriteHTMLParser.parseFavorites(from: html)
    #expect(favorites.count == 1)
    #expect(favorites.first?.title == "作品 B")
    #expect(favorites.first?.remoteFavoriteID == nil)
}

@Test func samePageLinksResolveRelativeURLsAgainstBaseURL() throws {
    let baseURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=700&page=1&mobile=2"))
    let html = #"""
    <html><body>
      <div class="message">
        <a href="thread-701-1-1.html">第2话</a>
      </div>
    </body></html>
    """#

    let chapters = MangaHTMLParser.extractSamePageLinks(from: html, baseURL: baseURL)

    #expect(chapters.count == 1)
    #expect(chapters.first?.tid == "701")
    #expect(chapters.first?.view == 1)
}

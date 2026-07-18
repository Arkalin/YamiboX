import Foundation
import Testing
@testable import YamiboXCore

@Suite("BoardFavoriteParser")
struct BoardFavoriteParserTests {
    @Test func parsesBoardRowsWithDeleteIDsAndPagination() throws {
        let html = #"""
        <div class="pg"><strong>1</strong> <a href="home.php?mod=space&amp;do=favorite&amp;type=forum&amp;page=2">2</a> <label><span title="共 2 页"> / 2 页</span></label></div>
        <div class="findbox mt10 cl">
          <ul>
            <li class="sclist"><a href="home.php?mod=spacecp&amp;ac=favorite&amp;op=delete&amp;favid=456&amp;type=forum&amp;handlekey=a_delete_456" class="dialog mdel"><i class="dm-error"></i></a><a href="forum.php?mod=forumdisplay&amp;fid=30&amp;mobile=2">漫画交流区</a></li>
            <li class="sclist"><a href="home.php?mod=spacecp&amp;ac=favorite&amp;op=delete&amp;favid=789&amp;type=forum" class="dialog mdel"><i class="dm-error"></i></a><a href="forum-44-1.html">小说交流区</a></li>
            <li class="sclist"><a href="home.php?mod=space">不是板块</a></li>
          </ul>
        </div>
        """#

        let result = FavoriteHTMLParser.parseBoardFavoritePage(from: html)

        #expect(result.boards.count == 2)
        #expect(result.boards.first?.fid == "30")
        #expect(result.boards.first?.title == "漫画交流区")
        #expect(result.boards.first?.remoteFavoriteID == "456")
        #expect(result.boards.last?.fid == "44")
        #expect(result.boards.last?.title == "小说交流区")
        #expect(result.boards.last?.remoteFavoriteID == "789")
        #expect(result.currentPage == 1)
        #expect(result.totalPages == 2)
        #expect(result.documentParsed)
    }

    @Test func keepsBoardWhenDeleteLinkIsMissing() throws {
        let html = #"""
        <div class="findbox mt10 cl">
          <ul>
            <li class="sclist"><a href="forum.php?mod=forumdisplay&amp;fid=55">百合会</a></li>
          </ul>
        </div>
        """#

        let result = FavoriteHTMLParser.parseBoardFavoritePage(from: html)

        #expect(result.boards.count == 1)
        #expect(result.boards.first?.fid == "55")
        #expect(result.boards.first?.remoteFavoriteID == nil)
    }

    @Test func fallsBackToBareBoardLinksAndDeduplicates() throws {
        let html = #"""
        <div>
          <a href="forum.php?mod=forumdisplay&fid=30">漫画交流区</a>
          <a href="forum.php?mod=forumdisplay&fid=30&page=2">漫画交流区（重复）</a>
          <a href="forum-61-1.html">小说交流区</a>
        </div>
        """#

        let result = FavoriteHTMLParser.parseBoardFavoritePage(from: html)

        #expect(result.boards.map(\.fid) == ["30", "61"])
        #expect(result.boards.first?.remoteFavoriteID == nil)
    }

    @Test func emptyFavoriteListParsesToNoBoards() throws {
        let html = "<html><body><div class=\"emp\">暂无收藏</div></body></html>"

        let result = FavoriteHTMLParser.parseBoardFavoritePage(from: html)

        #expect(result.boards.isEmpty)
        #expect(result.documentParsed)
    }
}

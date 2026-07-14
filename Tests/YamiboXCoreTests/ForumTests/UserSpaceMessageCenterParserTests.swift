import Foundation
import Testing
@testable import YamiboXCore

@Test func userSpaceParserParsesPrivateMessageList() throws {
    let page = try UserSpaceHTMLParser.parsePrivateMessageList(from: privateMessageListHTML())

    #expect(page.unreadCount == 5)
    #expect(page.pageNavigation?.currentPage == 2)
    #expect(page.pageNavigation?.totalPages == 4)
    #expect(page.messages.count == 1)
    #expect(page.messages.first?.uid == "800001")
    #expect(page.messages.first?.name == "好友A")
    #expect(page.messages.first?.title == "好友A")
    #expect(page.messages.first?.message.contains("最近一条消息") == true)
    #expect(page.messages.first?.timeText == "2026-06-01 10:30")
    #expect(page.messages.first?.unreadCount == 2)
}

@Test func userSpaceParserParsesNoticeList() throws {
    let page = try UserSpaceHTMLParser.parseNotices(from: noticeListHTML())

    #expect(page.pageNavigation?.currentPage == 1)
    #expect(page.pageNavigation?.totalPages == 3)
    #expect(page.notices.count == 1)
    #expect(page.notices.first?.noticeID == "55")
    #expect(page.notices.first?.userID == "705216")
    #expect(page.notices.first?.contentText.contains("回复了你的主题") == true)
    #expect(page.notices.first?.quote == "引用内容")
    #expect(page.notices.first?.timeText == "2026-06-02 11:00")
}

private func privateMessageListHTML() -> String {
    #"""
    <html>
      <body>
        <div>未读 5</div>
        <ul class="pm_list">
          <li>
            <a href="home.php?mod=spacecp&amp;ac=pm&amp;op=showmsg&amp;touid=800001&amp;mobile=2">好友A</a>
            <span class="unread">2</span>
            <p>最近一条消息</p>
            <span>2026-06-01 10:30</span>
          </li>
        </ul>
        <div class="pg"><a href="home.php?mod=space&amp;do=pm&amp;page=1">1</a><strong>2</strong><a href="home.php?mod=space&amp;do=pm&amp;page=4">4</a>共 4 页</div>
      </body>
    </html>
    """#
}

private func noticeListHTML() -> String {
    #"""
    <html>
      <body>
        <ul class="notice">
          <li id="notice_55">
            <img src="/uc_server/data/avatar/000/70/52/16_avatar_middle.jpg" />
            <div class="content"><a href="home.php?mod=space&amp;uid=705216">张瑞泽</a> 回复了你的主题</div>
            <blockquote>引用内容</blockquote>
            <span>2026-06-02 11:00</span>
          </li>
        </ul>
        <div class="pg"><strong>1</strong><a href="home.php?mod=space&amp;do=notice&amp;page=3">3</a>共 3 页</div>
      </body>
    </html>
    """#
}

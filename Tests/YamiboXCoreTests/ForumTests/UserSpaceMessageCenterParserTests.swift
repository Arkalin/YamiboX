import Foundation
import Testing
@testable import YamiboXCore

// Fixtures mirror the live touch templates (`space_pm.htm` / `space_notice.htm`)
// rendered by bbs.yamibo.com: conversation rows live in `#pmlist li` with
// `do=pm&subop=view&touid=` links, notices in `#notice_ul li[notice]` with the
// content in `.mbody`.

@Test func userSpaceParserParsesPrivateMessageList() throws {
    let page = try UserSpaceHTMLParser.parsePrivateMessageList(from: privateMessageListHTML())

    #expect(page.unreadCount == 5)
    #expect(page.pageNavigation?.currentPage == 2)
    #expect(page.pageNavigation?.totalPages == 4)
    #expect(page.messages.count == 2)

    let incoming = try #require(page.messages.first)
    #expect(incoming.uid == "800001")
    #expect(incoming.name == "好友A")
    #expect(incoming.title == "好友A 对我 说:")
    #expect(incoming.message == "最近一条消息")
    #expect(incoming.timeText == "半小时前")
    #expect(incoming.unreadCount == 2)
    #expect(incoming.avatarURL?.absoluteString.contains("70/52/16_avatar_small") == true)

    let outgoing = try #require(page.messages.last)
    #expect(outgoing.uid == "800002")
    #expect(outgoing.name == "好友B")
    #expect(outgoing.title == "我对 好友B 说:")
    #expect(outgoing.message == "我发出的最后一句")
    #expect(outgoing.timeText == "2026-6-1 10:30")
    #expect(outgoing.unreadCount == nil)
}

@Test func userSpaceParserParsesNoticeList() throws {
    let page = try UserSpaceHTMLParser.parseNotices(from: noticeListHTML())

    #expect(page.pageNavigation?.currentPage == 1)
    #expect(page.pageNavigation?.totalPages == 3)
    // The header, tab bar, and pager must not leak in as notice rows.
    #expect(page.notices.count == 2)

    let reply = try #require(page.notices.first)
    #expect(reply.noticeID == "55")
    #expect(reply.userID == "705216")
    #expect(reply.contentText.contains("回复了您的帖子"))
    #expect(!reply.contentText.contains("屏蔽"))
    #expect(!reply.contentText.contains("3 天前"))
    #expect(reply.contentHTML.contains("viewthread"))
    #expect(reply.quote == "引用内容")
    #expect(reply.timeText == "3 天前")

    let system = try #require(page.notices.last)
    #expect(system.noticeID == "56")
    #expect(system.userID == nil)
    #expect(system.contentText.contains("系统通知内容"))
    #expect(system.timeText == "2026-5-2 09:18")
}

private func privateMessageListHTML() -> String {
    #"""
    <html>
      <body>
        <div class="header cl">
          <div class="mz"><a href="javascript:history.back();"></a></div>
          <h2>短消息</h2>
          <div class="my"><a href="home.php?mod=spacecp&amp;ac=pm"></a></div>
        </div>
        <div class="dhnv flex-box cl">
          <a href="home.php?mod=space&amp;do=pm" class="flex mon">我的消息<strong>(5)</strong></a>
          <a href="home.php?mod=space&amp;do=notice" class="flex">我的提醒</a>
        </div>
        <div id="pmlist" class="imglist mt10 cl">
          <ul>
            <li>
              <span class="mimg"><a href="home.php?mod=space&amp;do=pm&amp;subop=view&amp;touid=800001"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/70/52/16_avatar_small.jpg"></a></span>
              <a href="home.php?mod=space&amp;do=pm&amp;subop=view&amp;touid=800001">
                <p class="mtit">
                  <span class="mtime">半小时前</span>
                  <span class="mnum">2</span>
                  好友A 对我 说:
                </p>
                <p class="mtxt">最近一条消息</p>
              </a>
            </li>
            <li>
              <span class="mimg"><a href="home.php?mod=space&amp;do=pm&amp;subop=view&amp;touid=800002"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/80/00/02_avatar_small.jpg"></a></span>
              <a href="home.php?mod=space&amp;do=pm&amp;subop=view&amp;touid=800002">
                <p class="mtit">
                  <span class="mtime">2026-6-1 10:30</span>
                  我对 好友B 说:
                </p>
                <p class="mtxt">我发出的最后一句</p>
              </a>
            </li>
            <li>
              <span class="mimg"><a href="home.php?mod=space&amp;do=pm&amp;subop=view&amp;plid=77&amp;type=1"><img src="https://bbs.yamibo.com/static/image/common/grouppm.png"></a></span>
              <a href="home.php?mod=space&amp;do=pm&amp;subop=view&amp;plid=77&amp;type=1">
                <p class="mtit"><span class="mtime">昨天 08:00</span>群聊作者:某人</p>
                <p class="mtxt">[群聊]群聊消息</p>
              </a>
            </li>
          </ul>
        </div>
        <div class="pg"><a href="home.php?mod=space&amp;do=pm&amp;page=1">1</a><strong>2</strong><a href="home.php?mod=space&amp;do=pm&amp;page=4">4</a>共 4 页</div>
      </body>
    </html>
    """#
}

private func noticeListHTML() -> String {
    #"""
    <html>
      <body>
        <div class="header cl">
          <div class="mz"><a href="javascript:history.back();"></a></div>
          <h2>提醒</h2>
          <div class="my"><a href="home.php?mod=space&amp;uid=535977&amp;do=profile&amp;mycenter=1"></a></div>
        </div>
        <div class="dhnv flex-box cl">
          <a href="home.php?mod=space&amp;do=pm" class="flex">我的消息</a>
          <a href="home.php?mod=space&amp;do=notice" class="flex mon">我的提醒<strong>(2)</strong></a>
        </div>
        <div id="notice_ul" class="imglist mt10 cl">
          <ul>
            <li class="cl" notice="55">
              <span class="mimg"><a href="home.php?mod=space&amp;uid=705216"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/70/52/16_avatar_small.jpg"></a></span>
              <p class="mtit">
                <a href="home.php?mod=spacecp&amp;ac=common&amp;op=ignore&amp;authorid=705216&amp;type=post&amp;handlekey=addfriendhk_705216" id="a_note_55" class="dialog mico">屏蔽</a>
                <span>3 天前</span>
              </p>
              <p class="mbody"><a href="home.php?mod=space&amp;uid=705216">张瑞泽</a> 回复了您的帖子 <a href="forum.php?mod=viewthread&amp;tid=565409">主题标题</a><blockquote>引用内容</blockquote></p>
            </li>
            <li class="cl" notice="56">
              <span class="mimg"><img src="https://bbs.yamibo.com/static/image/common/systempm.png" alt="systempm" /></span>
              <p class="mtit">
                <a href="home.php?mod=spacecp&amp;ac=common&amp;op=ignore&amp;authorid=0&amp;type=system&amp;handlekey=addfriendhk_0" id="a_note_56" class="dialog mico">屏蔽</a>
                <span>2026-5-2 09:18</span>
              </p>
              <p class="mbody">系统通知内容</p>
            </li>
          </ul>
        </div>
        <div class="pg"><strong>1</strong><a href="home.php?mod=space&amp;do=notice&amp;page=3">3</a>共 3 页</div>
      </body>
    </html>
    """#
}

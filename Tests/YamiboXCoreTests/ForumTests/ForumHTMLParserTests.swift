import Foundation
import Testing
@testable import YamiboXCore

@Test func parseForumHomeExtractsCategoriesBoardsAndCarousel() throws {
    let html = #"""
    <html>
    <body id="forum" class="pg_index">
      <div class="yami-swiper">
        <div class="swiper-wrapper">
          <div class="swiper-slide">
            <a href="https://bbs.yamibo.com/thread-570956-1-1.html">
              <img src="data/attachment/block/home.jpg">
            </a>
          </div>
        </div>
      </div>
      <div class="forumlist cl">
        <div class="subforumshow cl" href="#sub-forum_14">
          <h2><a href="javascript:;">庙堂</a></h2>
        </div>
        <div id="sub-forum_14" class="sub-forum mlist1 cl">
          <ul>
            <li>
              <span class="micon">
                <a href="forum.php?mod=forumdisplay&amp;fid=16&amp;mobile=2">
                  <img src="data/attachment/common/c7/common_16_icon.gif" alt="管理版" />
                </a>
              </span>
              <a href="forum.php?mod=forumdisplay&amp;fid=16&amp;mobile=2" class="murl">
                <p class="mtit">管理版</p>
                <p class="mtxt">既无论先民后主，何必辩你们我们。</p>
              </a>
            </li>
          </ul>
        </div>
        <div class="subforumshow cl" href="#sub-forum_2">
          <h2><a href="javascript:;">江湖</a></h2>
        </div>
        <div id="sub-forum_2" class="sub-forum mlist1 cl">
          <ul>
            <li>
              <a href="forum.php?mod=forumdisplay&amp;fid=5&amp;mobile=2" class="murl">
                <p class="mtit">動漫區<span class="mnum">今日 39</span></p>
                <p class="mtxt">请不要在莉莉安女子学院里狂奔……你给我站住！！</p>
              </a>
            </li>
          </ul>
        </div>
      </div>
    </body>
    </html>
    """#

    let page = try ForumHTMLParser.parseHomePage(from: html, fetchedAt: Date(timeIntervalSince1970: 1))

    #expect(page.categories.map(\.title) == ["庙堂", "江湖"])
    #expect(page.categories.first?.boards.first?.fid == "16")
    #expect(page.categories.first?.boards.first?.name == "管理版")
    #expect(page.categories.first?.boards.first?.detail == "既无论先民后主，何必辩你们我们。")
    #expect(page.categories.first?.boards.first?.iconURL?.absoluteString == "https://bbs.yamibo.com/data/attachment/common/c7/common_16_icon.gif")
    #expect(page.categories[1].boards.first?.todayCount == 39)
    #expect(page.carouselItems.first?.threadID == "570956")
    #expect(page.carouselItems.first?.isThreadTarget == true)
    #expect(page.carouselItems.first?.imageURL.absoluteString == "https://bbs.yamibo.com/data/attachment/block/home.jpg")
}

@Test func forumHomeCarouselItemIsOpenableOnlyForThreadTargets() throws {
    let threadItem = ForumHomeCarouselItem(
        targetURL: try #require(URL(string: "https://bbs.yamibo.com/thread-570956-1-1.html")),
        imageURL: try #require(URL(string: "https://bbs.yamibo.com/data/attachment/block/home.jpg")),
        threadID: "570956"
    )
    let webOnlyItem = ForumHomeCarouselItem(
        targetURL: try #require(URL(string: "https://bbs.yamibo.com/plugin.php?id=activity")),
        imageURL: try #require(URL(string: "https://bbs.yamibo.com/data/attachment/block/activity.jpg"))
    )
    let blankThreadItem = ForumHomeCarouselItem(
        targetURL: try #require(URL(string: "https://bbs.yamibo.com/thread-0-1-1.html")),
        imageURL: try #require(URL(string: "https://bbs.yamibo.com/data/attachment/block/blank.jpg")),
        threadID: " "
    )

    #expect(threadItem.isThreadTarget)
    #expect(!webOnlyItem.isThreadTarget)
    #expect(!blankThreadItem.isThreadTarget)
}

@Test func parseForumHomeFailsWhenNoBoardsAreAvailable() {
    let html = "<html><body><div class=\"forumlist\"></div></body></html>"

    #expect(throws: YamiboError.parsingFailed(context: L10n.string("context.forum_home"))) {
        try ForumHTMLParser.parseHomePage(from: html)
    }
}

@Test func parseForumBoardExtractsMetadataControlsPinnedItemsAndThreads() throws {
    let html = #"""
    <html>
    <head>
      <title>動漫區 -  百合会 -  手机版 - Powered by Discuz!</title>
      <base href="https://bbs.yamibo.com/" />
    </head>
    <body id="forum" class="pg_forumdisplay">
      <div class="header cl"><h2>動漫區</h2></div>
      <div id="nav-more-menu">
        <a href="home.php?mod=spacecp&amp;ac=favorite&amp;type=forum&amp;id=5&amp;handlekey=favoriteforum&amp;formhash=f47bb54f&amp;mobile=2">收藏本版</a>
      </div>
      <div class="forumdisplay-top cl">
        <h2>
          <img src="data/attachment/common/e4/common_5_icon.gif" alt="動漫區" />
          <a href="forum.php?mod=post&amp;action=newthread&amp;fid=5&amp;mobile=2" title="发帖">发帖</a>
          動漫區
        </h2>
        <p>今日: <span>40</span>主题: <span>28169</span>排名: <span>4</span></p>
      </div>
      <div class="dhnav_box">
        <ul>
          <li><a href="forum.php?mod=forumdisplay&amp;fid=5&amp;mobile=2">全部</a></li>
          <li><a href="forum.php?mod=forumdisplay&amp;fid=5&amp;filter=lastpost&amp;orderby=lastpost&amp;mobile=2">最新</a></li>
          <li><a href="forum.php?mod=forumdisplay&amp;fid=5&amp;orderby=dateline&amp;filter=dateline&amp;mobile=2">新帖</a></li>
        </ul>
      </div>
      <div class="dhnavs_box">
        <ul>
          <li><a href="forum.php?mod=forumdisplay&amp;fid=5&amp;filter=typeid&amp;typeid=400&amp;mobile=2">动画讨论</a></li>
          <li><a href="forum.php?mod=forumdisplay&amp;fid=5&amp;filter=typeid&amp;typeid=403&amp;mobile=2">求推</a></li>
        </ul>
      </div>
      <div class="forumlist cl">
        <div id="sub-forum_5" class="sub-forum mlist4 cl">
          <ul>
            <li>
              <span class="subforumshow cl">子版块</span>
              <span class="micon"><a href="forum.php?mod=forumdisplay&amp;fid=52&amp;mobile=2"><img src="data/attachment/common/9a/common_52_icon.gif" alt="百合会最萌世界杯专版！" /></a></span>
              <a href="forum.php?mod=forumdisplay&amp;fid=52&amp;mobile=2" class="murl"><p class="mtit">百合会最萌世界杯专版！</p></a>
            </li>
          </ul>
        </div>
      </div>
      <div class="threadlist_box mt10 cl">
        <div class="threadlist cl">
          <ul>
            <li class="list_top"><a href="forum.php?mod=announcement&amp;id=17#17&amp;mobile=2"><span class="micon gonggao">公告</span>欢迎光临。</a></li>
            <li class="list_top">
              <a href="forum.php?mod=viewthread&amp;tid=533721&amp;extra=page%3D1&amp;mobile=2">
                <span class="micon">置顶</span>
                <em>如何找回账号/如何修改密码</em>
              </a>
            </li>
            <li class="list">
              <div class="threadlist_top cl">
                <a href="home.php?mod=space&amp;uid=705216&amp;mobile=2" class="mimg"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/70/52/16_avatar_middle.jpg"></a>
                <div class="muser">
                  <h3><a href="home.php?mod=space&amp;uid=705216&amp;mobile=2" class="mmc">张瑞泽</a></h3>
                  <span class="mtime">2025-12-22 14:33</span>
                </div>
              </div>
              <a href="forum.php?mod=viewthread&amp;tid=565409&amp;extra=page%3D1&amp;mobile=2">
                <div class="threadlist_tit cl">
                  <span class="micon">投票</span>
                  <em>那对cp是你心中的no1</em>
                </div>
              </a>
              <a href="forum.php?mod=viewthread&amp;tid=565409&amp;extra=page%3D1&amp;mobile=2"><div class="threadlist_mes cl">还有好多就不一个一个写了</div></a>
              <div class="threadlist_foot cl">
                <ul>
                  <li class="mr"><a href="forum.php?mod=forumdisplay&amp;fid=5&amp;filter=typeid&amp;typeid=3&amp;mobile=2">#其他</a></li>
                  <li><i class="dm-eye-fill"></i>35530</li>
                  <li><i class="dm-chat-s-fill"></i>189</li>
                </ul>
              </div>
            </li>
          </ul>
        </div>
        <div class="pg"><strong>1</strong><a href="forum.php?mod=forumdisplay&amp;fid=5&amp;page=2&amp;mobile=2">2</a><a href="forum.php?mod=forumdisplay&amp;fid=5&amp;page=1409&amp;mobile=2" class="last">.. 1409</a><label><span title="共 1409 页"> / 1409 页</span></label></div>
      </div>
    </body>
    </html>
    """#

    let page = try ForumHTMLParser.parseBoardPage(from: html, fid: "5", fetchedAt: Date(timeIntervalSince1970: 2))

    #expect(page.board.name == "動漫區")
    #expect(page.board.todayCount == 40)
    #expect(page.board.threadCount == 28169)
    #expect(page.board.rank == 4)
    #expect(page.board.iconURL?.absoluteString == "https://bbs.yamibo.com/data/attachment/common/e4/common_5_icon.gif")
    #expect(page.formHash == "f47bb54f")
    #expect(page.subBoards.map(\.fid) == ["52"])
    #expect(page.subBoards.first?.name == "百合会最萌世界杯专版！")
    #expect(page.orders.map(\.id) == ["lastpost", "dateline"])
    #expect(page.filters.map(\.title) == ["动画讨论", "求推"])
    #expect(page.pinnedItems.map(\.kind) == [.announcement, .thread])
    #expect(page.pinnedItems[1].threadID == "533721")
    #expect(page.threads.first?.tid == "565409")
    #expect(page.threads.first?.fid == "5")
    #expect(page.threads.first?.authorName == "张瑞泽")
    #expect(page.threads.first?.authorID == "705216")
    #expect(page.threads.first?.isPoll == true)
    #expect(page.threads.first?.description == "还有好多就不一个一个写了")
    #expect(page.threads.first?.tag == "其他")
    #expect(page.threads.first?.viewCount == 35530)
    #expect(page.threads.first?.replyCount == 189)
    #expect(page.pageNavigation == ForumPageNavigation(currentPage: 1, totalPages: 1409))
}

@Test func parseForumBoardReturnsNilNavigationWhenPagerIsAbsent() throws {
    let html = #"""
    <html>
    <head><title>動漫區 -  百合会</title></head>
    <body id="forum" class="pg_forumdisplay">
      <div class="header cl"><h2>動漫區</h2></div>
      <div class="forumdisplay-top cl"><p>今日: <span>0</span>主题: <span>1</span></p></div>
      <div class="threadlist cl"><ul>
        <li class="list">
          <a href="forum.php?mod=viewthread&amp;tid=565409&amp;mobile=2">
            <div class="threadlist_tit cl"><em>单页主题</em></div>
          </a>
        </li>
      </ul></div>
    </body>
    </html>
    """#

    let page = try ForumHTMLParser.parseBoardPage(from: html, fid: "5")

    #expect(page.pageNavigation == nil)
}

@Test func parseForumBoardAllowsThreadTitlesMentioningLoginAfter() throws {
    let html = #"""
    <html>
    <head><title>管理版 -  百合会</title></head>
    <body id="forum" class="pg_forumdisplay">
      <div class="header cl"><h2>管理版</h2></div>
      <div class="forumdisplay-top cl">
        <h2><img src="data/attachment/common/c7/common_16_icon.gif" alt="管理版" />管理版</h2>
        <p>今日: <span>0</span>主题: <span>4948</span>排名: <span>27</span></p>
      </div>
      <div class="threadlist cl">
        <ul>
          <li class="list_top">
            <a href="forum.php?mod=viewthread&amp;tid=123&amp;mobile=2">
              <span class="micon">置顶</span>
              <em>请被盗号的会员重新登录后设定安全提问</em>
            </a>
          </li>
          <li class="list">
            <a href="forum.php?mod=viewthread&amp;tid=456&amp;mobile=2">
              <div class="threadlist_tit cl"><em>开通了使用指南版块，有问题先看使用指南</em></div>
            </a>
          </li>
        </ul>
      </div>
    </body>
    </html>
    """#

    let page = try ForumHTMLParser.parseBoardPage(from: html, fid: "16")

    #expect(page.board.name == "管理版")
    #expect(page.pinnedItems.first?.title == "请被盗号的会员重新登录后设定安全提问")
    #expect(page.threads.first?.tid == "456")
}

@Test func parseBoardFavoriteResultReturnsServerMessage() throws {
    let html = #"""
    <html>
      <body>
        <div class="jump_c">收藏成功，正在返回上一页。</div>
      </body>
    </html>
    """#

    #expect(try ForumHTMLParser.parseBoardFavoriteResult(from: html) == "收藏成功，正在返回上一页。")
}

@Test func parseBoardFavoriteResultThrowsWhenLoginIsRequired() {
    let html = #"""
    <html>
      <body>
        <div class="jump_c">请先登录后才能继续浏览</div>
      </body>
    </html>
    """#

    #expect(throws: YamiboError.notAuthenticated) {
        try ForumHTMLParser.parseBoardFavoriteResult(from: html)
    }
}

@Test func parseForumSearchExtractsSearchIDResultsTotalAndPagination() throws {
    let html = #"""
    <html>
    <head><title>搜索 -  百合会</title></head>
    <body>
      <div class="threadlist_box">
        <h2><em>结果: 找到 “<span class="emfont">搜索</span>” 相关内容 1234 个</em></h2>
        <div class="threadlist cl">
          <ul>
            <li class="list">
              <div class="threadlist_top cl">
                <a href="home.php?mod=space&amp;uid=705216&amp;mobile=2" class="mimg"><img src="https://bbs.yamibo.com/avatar.jpg"></a>
                <div class="muser">
                  <h3><a href="home.php?mod=space&amp;uid=705216&amp;mobile=2" class="mmc">张瑞泽</a></h3>
                  <span class="mtime">2026-01-02 10:00</span>
                </div>
              </div>
              <a href="forum.php?mod=viewthread&amp;tid=565409&amp;mobile=2">
                <div class="threadlist_tit cl"><em>搜索结果主题</em></div>
              </a>
              <div class="threadlist_foot cl">
                <ul>
                  <li class="mr"><a href="forum.php?mod=forumdisplay&amp;fid=5&amp;mobile=2">#動漫區</a></li>
                  <li><i class="dm-eye-fill"></i>300</li>
                  <li><i class="dm-chat-s-fill"></i>12</li>
                </ul>
              </div>
            </li>
          </ul>
        </div>
        <div class="pg">
          <strong>1</strong>
          <a href="search.php?mod=forum&amp;searchid=99&amp;page=2&amp;mobile=2">2</a>
          <label><span title="共 2 页"> / 2 页</span></label>
        </div>
      </div>
    </body>
    </html>
    """#

    let page = try ForumHTMLParser.parseSearchPage(from: html, query: "搜索")

    #expect(page.query == "搜索")
    #expect(page.searchID == "99")
    #expect(page.totalCount == 1234)
    #expect(page.results.map(\.tid) == ["565409"])
    #expect(page.results.first?.authorName == "张瑞泽")
    #expect(page.results.first?.tag == "動漫區")
    #expect(page.pageNavigation == ForumPageNavigation(currentPage: 1, totalPages: 2))
}

/// A rendered no-match page (`.threadlist_box > h4`) is a legitimate empty
/// search result; only pages without the search chrome are parse failures.
@Test func parseForumSearchReturnsEmptyResultsForNoMatchPage() throws {
    let html = #"""
    <html>
      <body>
        <div class="threadlist_box">
          <h2><em>结果: 找到 “<span class="emfont">missing</span>” 相关内容 0 个</em></h2>
          <h4>对不起，没有找到匹配结果</h4>
        </div>
      </body>
    </html>
    """#

    let page = try ForumHTMLParser.parseSearchPage(from: html, query: "missing")
    #expect(page.results.isEmpty)
    #expect(page.totalCount == 0)
}

@Test func parseForumSearchFailsWhenPageHasNoSearchChrome() {
    let html = #"""
    <html>
      <body><div>意外页面</div></body>
    </html>
    """#

    #expect(throws: YamiboError.parsingFailed(context: L10n.string("context.forum_search"))) {
        try ForumHTMLParser.parseSearchPage(from: html, query: "missing")
    }
}

/// Fixture mirrors the live touch template (`space_profile.htm`): the credit
/// value `<span>` comes BEFORE its label inside `.user_box li`, and the
/// `.myinfo_list li` rows have no colon between label and `<span>` value.
@Test func parseUserSpaceProfileExtractsIdentityStatsAndInfoRows() throws {
    let html = #"""
    <html>
      <head><title>张瑞泽的个人资料 -  百合会 -  Powered by Discuz!</title></head>
      <body>
        <style>.user_avatar {background-image:url(https://bbs.yamibo.com/uc_server/data/avatar/000/70/52/16_avatar_big.jpg) !important}</style>
        <div class="header cl">
          <div class="mz"><a href="javascript:history.back();"></a></div>
          <h2>我的资料</h2>
        </div>
        <div class="userinfo">
          <div class="user_avatar">
            <div class="avatar_bg">
              <div class="avatar_m"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/70/52/16_avatar_middle.jpg" /></div>
              <h2 class="name">张瑞泽</h2>
            </div>
          </div>
          <div class="user_box cl">
            <ul>
              <li><span>155</span>总积分</li>
              <li><span>29 点</span>积分</li>
              <li><span>377 个</span>对象</li>
            </ul>
          </div>
          <div class="myinfo_list cl">
            <ul>
              <li><b>个人签名</b></li>
              <li class="sig">百合签名</li>
            </ul>
          </div>
          <div class="myinfo_list cl">
            <ul>
              <li><b>个人资料</b><span class="mtxt">在线</span></li>
              <li>UID<span>705216</span></li>
              <li>用户组<span style="color:#FF00FF">百合花蕾</span></li>
              <li>个人主页<span><a href="https://example.com">https://example.com</a></span></li>
              <li>最后访问<span>2026-2-24 00:49</span></li>
            </ul>
          </div>
        </div>
      </body>
    </html>
    """#

    let profile = try UserSpaceHTMLParser.parseProfile(from: html, uidHint: nil, titleHint: nil)

    #expect(profile.uid == "705216")
    #expect(profile.username == "张瑞泽")
    #expect(profile.totalPoints == 155)
    #expect(profile.points == 29)
    #expect(profile.partner == 377)
    #expect(profile.signature == "百合签名")
    #expect(profile.userGroup == "百合花蕾")
    #expect(profile.avatarURL?.absoluteString.contains("_avatar_middle") == true)
    #expect(profile.avatarBackgroundURL?.absoluteString.contains("_avatar_big") == true)
    #expect(profile.infoRows.contains(UserSpaceInfoRow(label: "UID", value: "705216")))
    #expect(profile.infoRows.contains(where: { $0.label == "最后访问" && $0.value == "2026-2-24 00:49" }))
}

/// Fixtures mirror the live touch templates: `space_thread.htm` rows (author in
/// `.threadlist_top`, subject in `.threadlist_tit em`, icon-keyed counts in
/// `.threadlist_foot`, relative datelines), reply rows via `findpost` links with
/// the own reply quoted, `space_blog_list.htm` rows (one anchor wrapping title
/// AND excerpt), and `space_friend.htm` rows (avatar link first, name link
/// last, `do=pm&subop=view` message link, `op=ignore` delete link).
@Test func parseUserSpaceThreadsRepliesBlogsFriends() throws {
    let threadsHTML = #"""
    <html><body>
      <div class="threadlist cl"><ul>
        <li class="list">
          <div class="threadlist_top cl">
            <a href="home.php?mod=space&amp;uid=705216" class="mimg"><img src="https://bbs.yamibo.com/uc_server/avatar.php?uid=705216&amp;size=middle"></a>
            <div class="muser"><h3><a href="home.php?mod=space&amp;uid=705216" class="mmc">张瑞泽</a></h3><span class="mtime">昨天 22:11</span></div>
          </div>
          <a href="forum.php?mod=viewthread&amp;tid=565409&amp;extra="><div class="threadlist_tit cl"><span class="micon">投票</span><em>主题标题</em></div></a>
          <a href="forum.php?mod=viewthread&amp;tid=565409&amp;extra="><div class="threadlist_mes cl">正文摘要</div></a>
          <div class="threadlist_foot cl"><ul>
            <li class="mr"><a href="forum.php?mod=forumdisplay&amp;fid=5">#漫画讨论区</a></li>
            <li><i class="dm-eye-fill"></i>300</li>
            <li><i class="dm-chat-s-fill"></i>12</li>
          </ul></div>
        </li>
      </ul></div>
      <div class="pg"><strong>1</strong><a href="home.php?mod=space&amp;do=thread&amp;view=me&amp;page=2">2</a></div>
    </body></html>
    """#

    let repliesHTML = #"""
    <html><body>
      <div class="threadlist cl"><ul>
        <li class="list">
          <a href="forum.php?mod=redirect&amp;goto=findpost&amp;ptid=565409&amp;pid=9000001" target="_blank" class="mt10"><div class="threadlist_tit cl"><em>主题标题</em></div></a>
          <a href="forum.php?mod=redirect&amp;goto=findpost&amp;ptid=565409&amp;pid=9000001" target="_blank"><div class="quote"><blockquote>我的回复内容</blockquote></div></a>
        </li>
      </ul></div>
    </body></html>
    """#

    let blogsHTML = #"""
    <html><body>
      <div class="threadlist cl"><ul>
        <li class="list">
          <div class="threadlist_top cl">
            <a href="home.php?mod=space&amp;uid=705216&amp;do=profile" class="avatar mimg z"><img src="https://bbs.yamibo.com/uc_server/avatar.php?uid=705216&amp;size=middle"></a>
            <div class="muser"><h3><a href="home.php?mod=space&amp;uid=705216&amp;do=profile" id="author_88" class="mmc">张瑞泽</a></h3><div class="mtime"><span>3 天前</span></div></div>
          </div>
          <a href="home.php?mod=space&amp;uid=705216&amp;do=blog&amp;id=88">
            <div class="threadlist_tit cl">日志标题</div>
            <div class="threadlist_mes cl">日志摘要内容</div>
          </a>
        </li>
      </ul></div>
    </body></html>
    """#

    let friendsHTML = #"""
    <html><body>
      <div id="friend_ul" class="imglist mt10 cl"><ul>
        <li>
          <span class="mimg"><a href="home.php?mod=space&amp;uid=800001"><img src="https://bbs.yamibo.com/uc_server/avatar.php?uid=800001&amp;size=small"></a></span>
          <a href="home.php?mod=spacecp&amp;ac=friend&amp;op=ignore&amp;uid=800001&amp;handlekey=delfriendhk_800001" class="dialog">删除</a>
          <a href="home.php?mod=space&amp;do=pm&amp;subop=view&amp;touid=800001" class="mico">发消息</a>
          <a href="home.php?mod=space&amp;uid=800001"><span>好友A</span></a>
          <p class="mtxt"><i class="dm-chat-s"></i>最近的签名</p>
        </li>
      </ul></div>
    </body></html>
    """#

    let threads = try UserSpaceHTMLParser.parseThreads(from: threadsHTML)
    let replies = try UserSpaceHTMLParser.parseReplies(from: repliesHTML)
    let blogs = try UserSpaceHTMLParser.parseBlogs(from: blogsHTML)
    let friends = try UserSpaceHTMLParser.parseFriends(from: friendsHTML)

    #expect(threads.threads.map(\.tid) == ["565409"])
    #expect(threads.threads.first?.title == "主题标题")
    #expect(threads.threads.first?.authorID == "705216")
    #expect(threads.threads.first?.authorName == "张瑞泽")
    #expect(threads.threads.first?.description == "正文摘要")
    #expect(threads.threads.first?.viewCount == 300)
    #expect(threads.threads.first?.replyCount == 12)
    #expect(threads.threads.first?.lastActivityText == "昨天 22:11")
    #expect(threads.pageNavigation == ForumPageNavigation(currentPage: 1, totalPages: 2))

    #expect(replies.replies.map(\.threadID) == ["565409"])
    #expect(replies.replies.first?.threadTitle == "主题标题")
    #expect(replies.replies.first?.excerpt == "我的回复内容")

    #expect(blogs.blogs.map(\.blogID) == ["88"])
    #expect(blogs.blogs.first?.title == "日志标题")
    #expect(blogs.blogs.first?.excerpt == "日志摘要内容")
    #expect(blogs.blogs.first?.authorName == "张瑞泽")
    #expect(blogs.blogs.first?.lastActivityText == "3 天前")

    #expect(friends.friends.map(\.uid) == ["800001"])
    #expect(friends.friends.first?.name == "好友A")
    #expect(friends.friends.first?.privateMessageURL?.absoluteString == "https://bbs.yamibo.com/home.php?mod=space&do=pm&subop=view&touid=800001")
    #expect(friends.friends.first?.deleteURL?.absoluteString.contains("op=ignore") == true)
}

/// The add-friend float is an ajax `<root><![CDATA[…]]></root>` envelope
/// wrapping the desktop `spacecp_friend.htm` op=add form: dialog chrome in
/// `h3.flb`, the username inside `td strong`, avatar in `th.avt`.
@Test func parseUserSpaceAddFriendFormExtractsFormHashUserAndGroups() throws {
    let html = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <root><![CDATA[<h3 class="flb"><em id="return_addfriendhk_705216">添加好友</em><span><a href="javascript:;" class="flbc">关闭</a></span></h3>
    <form method="post" autocomplete="off" id="addform_705216" action="home.php?mod=spacecp&ac=friend&op=add&uid=705216">
      <input type="hidden" name="referer" value="home.php" />
      <input type="hidden" name="formhash" value="form123" />
      <table cellspacing="0" cellpadding="0" class="tfm">
        <tr>
          <th width="60" class="avt"><a href="home.php?mod=space&uid=705216"><img src="https://bbs.yamibo.com/uc_server/avatar.php?uid=705216&size=middle" /></a></th>
          <td valign="top">添加 <strong>张瑞泽</strong> 为好友<br />
            <select name="gid" class="ps">
              <option value="1">好友</option>
              <option value="2">同好</option>
            </select>
          </td>
        </tr>
      </table>
      <input type="hidden" name="addsubmit" value="true" />
    </form>]]></root>
    """#

    let form = try UserSpaceHTMLParser.parseAddFriendForm(from: html, uid: "705216")

    #expect(form.uid == "705216")
    #expect(form.name == "张瑞泽")
    #expect(form.avatarURL?.absoluteString.contains("avatar.php?uid=705216") == true)
    #expect(form.formHash == "form123")
    #expect(form.options == [
        UserSpaceAddFriendOption(id: 1, name: "好友"),
        UserSpaceAddFriendOption(id: 2, name: "同好")
    ])
}

/// The add-friend POST carries `inajax=1`, so the result is the touch
/// showmessage ajax branch inside a CDATA envelope (`dt#messagetext`).
@Test func parseUserSpaceAddFriendResultReturnsServerMessage() throws {
    let html = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <root><![CDATA[<div class="tip"><dt id="messagetext"><p>好友请求已送出</p></dt></div>]]></root>
    """#

    #expect(try UserSpaceHTMLParser.parseAddFriendResult(from: html) == "好友请求已送出")
}

@Test func parsePrivateMessagePageExtractsConversationMessagesAndPager() throws {
    let html = #"""
    <html>
      <head><title>与 好友A 的短消息 -  百合会</title></head>
      <body>
        <div class="header"><h2>与 好友A 的短消息</h2></div>
        <form action="home.php?mod=spacecp&amp;ac=pm&amp;op=send&amp;pmid=900&amp;touid=800001&amp;mobile=2">
          <input type="hidden" name="formhash" value="hash123" />
        </form>
        <ul class="pmlist">
          <li id="pm_1">
            <a href="home.php?mod=space&amp;uid=800001&amp;mobile=2">好友A</a>
            <img src="avatar-a.jpg">
            <span>2026-06-01 10:00</span>
            <div class="content">你好</div>
          </li>
          <li id="pm_2" class="self">
            <a href="home.php?mod=space&amp;uid=705216&amp;mobile=2">我</a>
            <span>2026-06-01 10:01</span>
            <div class="content">收到</div>
          </li>
        </ul>
        <div class="pg"><strong>1</strong><a href="home.php?page=2">2</a></div>
      </body>
    </html>
    """#

    let page = try UserSpaceHTMLParser.parsePrivateMessagePage(from: html, toUID: "800001", titleHint: nil)

    #expect(page.title == "与 好友A 的短消息")
    #expect(page.privateMessageID == "900")
    #expect(page.toUID == "800001")
    #expect(page.toName == "好友A")
    #expect(page.formHash == "hash123")
    #expect(page.messages.map(\.messageID) == ["1", "2"])
    #expect(page.messages.map(\.kind) == [.other, .me])
    #expect(page.messages.first?.author.avatarURL?.absoluteString == "https://bbs.yamibo.com/avatar-a.jpg")
    #expect(page.messages.map(\.contentText) == ["你好", "收到"])
    #expect(page.messages.map(\.postedAtText) == ["2026-06-01 10:00", "2026-06-01 10:01"])
    #expect(page.pageNavigation == ForumPageNavigation(currentPage: 1, totalPages: 2))
}

@Test func parsePrivateMessageSendResultReturnsServerMessage() throws {
    let html = #"""
    <html>
      <body>
        <div class="jump_c">短消息发送成功</div>
      </body>
    </html>
    """#

    #expect(try UserSpaceHTMLParser.parsePrivateMessageSendResult(from: html) == "短消息发送成功")
}

/// Fixture mirrors the touch templates `space_blog_view.htm` +
/// `space_comment_li.htm`: subject in `.view_tit` (leading `em` = category),
/// author row in `li.mtit span.z`, icon+`em` counters in `li.mtime span.y`,
/// body in `.message`, comments as `li#comment_<id>_li` with the text in
/// `div.do_comment`.
@Test func parseBlogReaderExtractsRootBlogActionsCommentsAndPager() throws {
    let html = #"""
    <html>
      <head><title>日志标题 -  百合会</title></head>
      <body>
        <div class="view_tit"><em>[<a href="home.php?mod=space&amp;uid=705216&amp;do=blog&amp;classid=3">随笔</a>]</em>日志标题</div>
        <div class="plc">
          <div class="avatar"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/70/52/16_avatar_middle.jpg" /></div>
          <ul class="authi">
            <li class="mtit"><span class="z"><a href="home.php?mod=space&amp;uid=705216&amp;do=profile">张瑞泽</a></span></li>
            <li class="mtime"><span class="y"><i class="dm-eye"></i><em>42</em><i class="dm-chat-s"></i><em>3</em></span>2026-6-1 12:34</li>
          </ul>
          <div class="message"><p>第一段正文</p><p>第二段 &amp; 细节</p></div>
          <div class="threadlist_foot cl"><ul>
            <li><a href="home.php?mod=spacecp&amp;ac=favorite&amp;type=blog&amp;id=88&amp;mobile=2">收藏</a></li>
            <li><a href="home.php?mod=spacecp&amp;ac=share&amp;type=blog&amp;id=88&amp;mobile=2">分享</a></li>
            <li><a href="misc.php?mod=invite&amp;action=blog&amp;id=88&amp;mobile=2">邀请</a></li>
          </ul></div>
        </div>
        <div class="doing_list"><ul>
          <li id="comment_9001_li" class="doing_list_li list cl">
            <div class="avatar l0"><a href="home.php?mod=space&amp;uid=800001"><img src="https://bbs.yamibo.com/uc_server/avatar.php?uid=800001&amp;size=small" /></a></div>
            <div class="muser">
              <h3><a href="home.php?mod=space&amp;uid=800001" id="author_9001" class="mmc">评论者</a></h3>
              <div class="mtime"><span>2026-6-2 08:00</span><a href="home.php?mod=spacecp&amp;ac=comment&amp;op=reply&amp;cid=9001&amp;handlekey=replycommenthk_9001" id="c_9001_reply" class="y doing_gl dialog">回复</a></div>
            </div>
            <div id="comment_9001" class="do_comment"><p>评论内容</p></div>
          </li>
        </ul></div>
        <div class="pgs cl">
          <div class="pg">
            <strong>1</strong>
            <a href="home.php?mod=space&amp;do=blog&amp;id=88&amp;page=2&amp;mobile=2">2</a>
            <label><span title="共 2 页"> / 2 页</span></label>
          </div>
        </div>
      </body>
    </html>
    """#

    let page = try BlogReaderHTMLParser.parsePage(from: html, blogID: "88", uidHint: "705216")

    #expect(page.blogID == "88")
    #expect(page.title == "日志标题")
    #expect(page.author.uid == "705216")
    #expect(page.author.name == "张瑞泽")
    #expect(page.author.avatarURL?.absoluteString == "https://bbs.yamibo.com/uc_server/data/avatar/000/70/52/16_avatar_middle.jpg")
    #expect(page.postedAtText == "2026-6-1 12:34")
    #expect(page.contentText == "第一段正文 第二段 & 细节")
    #expect(page.viewCount == 42)
    #expect(page.replyCount == 3)
    #expect(page.collectURL?.absoluteString == "https://bbs.yamibo.com/home.php?mod=spacecp&ac=favorite&type=blog&id=88&mobile=2")
    #expect(page.shareURL?.absoluteString == "https://bbs.yamibo.com/home.php?mod=spacecp&ac=share&type=blog&id=88&mobile=2")
    #expect(page.inviteURL?.absoluteString == "https://bbs.yamibo.com/misc.php?mod=invite&action=blog&id=88&mobile=2")
    #expect(page.comments.count == 1)
    #expect(page.comments.first?.commentID == "9001")
    #expect(page.comments.first?.author.uid == "800001")
    #expect(page.comments.first?.author.name == "评论者")
    #expect(page.comments.first?.contentText == "评论内容")
    #expect(page.comments.first?.postedAtText == "2026-6-2 08:00")
    #expect(page.comments.first?.replyURL?.absoluteString.contains("ac=comment&op=reply&cid=9001") == true)
    #expect(page.pageNavigation == ForumPageNavigation(currentPage: 1, totalPages: 2))
}

@Test func parseBlogCommentResultReturnsServerMessage() throws {
    let html = #"""
    <html>
      <body>
        <div class="jump_c">评论发表成功</div>
      </body>
    </html>
    """#

    #expect(try BlogReaderHTMLParser.parseCommentResult(from: html) == "评论发表成功")
}

import Foundation
import Testing
@testable import YamiboXCore

@Test func chapterCommentsParserReadsOwnerPostCommentsAndFilteredRatings() throws {
    let html = """
    <html><body>
      <div id="postlist">
        <div class="pcb">
          <div class="t_f" id="postmessage_100">第一章<br>正文</div>
          <div id="comment_100" class="cm">
            <div class="pstl xs1 cl">
              <div class="psta vm"><a class="xi2 xw1">读者甲</a></div>
              <div class="psti">这章很好 <span class="xg1">发表于 2026-5-1 12:00</span></div>
            </div>
          </div>
          <dl id="ratelog_100" class="rate">
            <dd>
              <table>
                <tbody class="ratl_l">
                  <tr>
                    <td><a>读者乙</a></td><td class="xi1"> + 1</td><td class="xg1">我很赞同</td>
                  </tr>
                  <tr>
                    <td><a>读者丙</a></td><td class="xi1"> + 5</td><td class="xg1">这期神了</td>
                  </tr>
                  <tr>
                    <td><a>读者丁</a></td><td class="xi1"> + 1</td><td class="xg1">   </td>
                  </tr>
                </tbody>
              </table>
            </dd>
          </dl>
        </div>
      </div>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "42",
        view: 3,
        ownerPostID: "100",
        title: "第一章"
    )

    let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)

    #expect(page.comments.map(\.source) == [.postComment, .ratingReason])
    #expect(page.comments.map(\.authorName) == ["读者甲", "读者丙"])
    #expect(page.comments.map(\.body) == ["这章很好", "这期神了"])
    #expect(page.comments.first?.metadata == "发表于 2026-5-1 12:00")
    #expect(page.comments.last?.metadata == nil)
    #expect(page.isBoundaryClosed == false)
}


@Test func chapterCommentsParserReadsMobileOwnerPostCommentsAndRatings() throws {
    let html = """
    <html><body>
      <div class="plc cl" id="pid41257246">
        <div class="message">第一章<br>正文</div>
        <div id="comment_41257246">
          <h3>点评</h3>
          <div class="plc p0 cl" id="commentdetail_1">
            <ul>
              <li><a>读者甲</a></li>
              <li class="mtime">2025-5-25 19:58</li>
              <li class="mtxt mt5">悠宇把自己开发成了0</li>
            </ul>
          </div>
        </div>
        <h3>评分</h3>
        <div id="ratelog_41257246">
          <ul class="post_box cl">
            <li class="flex-box mli p0">
              <div class="flex-2 xs1 xg1 xw1">参与人数 <span class="xi1">14</span></div>
              <div class="flex-2 xs1 xg1 xw1">积分 <span class="xi1">+116</span></div>
              <div class="flex-3 xs1 xg1 xw1">理由</div>
            </li>
            <li class="flex-box mli p0">
              <div class="flex-2 xs1 xg1"><a>丰川之刃</a></div>
              <div class="flex-2 xs1 xi1 xw1"> + 10</div>
              <div class="flex-3 xs1 xg1">精品文章</div>
            </li>
            <li class="flex-box mli p0">
              <div class="flex-2 xs1 xg1"><a>seccyzwvvk</a></div>
              <div class="flex-2 xs1 xi1 xw1"> + 5</div>
              <div class="flex-3 xs1 xg1">翻译大大辛苦了</div>
            </li>
            <li class="flex-box mli p0">
              <div class="flex-2 xs1 xg1"><a>3504822324</a></div>
              <div class="flex-2 xs1 xi1 xw1"> + 10</div>
              <div class="flex-3 xs1 xg1">感谢款待</div>
            </li>
          </ul>
        </div>
      </div>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "557752",
        view: 1,
        ownerPostID: "41257246",
        title: "第一章"
    )

    let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)

    #expect(page.comments.map(\.source) == [.postComment, .ratingReason, .ratingReason])
    #expect(page.comments.map(\.authorName) == ["读者甲", "seccyzwvvk", "3504822324"])
    #expect(page.comments.map(\.body) == ["悠宇把自己开发成了0", "翻译大大辛苦了", "感谢款待"])
    #expect(page.comments.first?.metadata == "2025-5-25 19:58")
}

@Test func chapterCommentsParserIncludesMobileRepliesBetweenOwnerPosts() throws {
    let html = """
    <html><body>
      <div class="plc cl" id="pid40217745">
        <ul class="authi">
          <li class="mtit"><span class="y">21<sup>#</sup></span><a href="home.php?mod=space&uid=406769&mobile=2">楼主</a></li>
          <li class="mtime">2021-10-16 20:00</li>
        </ul>
        <div class="message">episode 16<br>正文</div>
      </div>
      <div class="plc cl" id="pid40218000">
        <ul class="authi">
          <li class="mtit"><span class="y">22<sup>#</sup></span><a href="home.php?mod=space&uid=700001&mobile=2">读者甲</a></li>
          <li class="mtime">2021-10-16 21:00</li>
        </ul>
        <div class="message"><i class="pstatus">编辑记录</i><br>楼间回复内容</div>
      </div>
      <div class="plc cl" id="pid40218661">
        <ul class="authi">
          <li class="mtit"><span class="y">23<sup>#</sup></span><a href="home.php?mod=space&uid=406769&mobile=2">楼主</a></li>
          <li class="mtime">2021-10-16 22:32</li>
        </ul>
        <div class="message">episode 17<br>下一章正文</div>
      </div>
      <a href="forum.php?mod=viewthread&tid=521519&page=3&mobile=2">3</a>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "521519",
        view: 2,
        ownerPostID: "40217745",
        title: "episode 16",
        authorID: "406769"
    )

    let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)

    #expect(page.comments.map(\.source) == [.reply])
    #expect(page.comments.map(\.authorName) == ["读者甲"])
    #expect(page.comments.map(\.body) == ["楼间回复内容"])
    #expect(page.comments.first?.metadata == "22# · 2021-10-16 21:00")
    #expect(page.isBoundaryClosed == true)
    #expect(page.nextView == nil)
}

@Test func chapterCommentsParserFiltersDefaultRatingReasonTemplatesExactly() throws {
    let filteredReasons = ["你太可爱", "好萌好萌好萌", "我很赞同", "精品文章", "原创内容"]
    let rows = filteredReasons.enumerated().map { index, reason in
        """
        <tr><td><a>读者\(index)</a></td><td class="xi1"> + 1</td><td class="xg1">\(reason)</td></tr>
        """
    }.joined()
    let html = """
    <html><body>
      <div class="t_f" id="postmessage_100">第一章<br>正文</div>
      <dl id="ratelog_100" class="rate"><dd><table><tbody class="ratl_l">
        \(rows)
        <tr><td><a>读者保留</a></td><td class="xi1"> + 1</td><td class="xg1">我很赞同这个观点</td></tr>
      </tbody></table></dd></dl>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "42",
        view: 1,
        ownerPostID: "100",
        title: "第一章"
    )

    let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)

    #expect(page.comments.map(\.body) == ["我很赞同这个观点"])
}

@Test func chapterCommentsParserOmitsImageOnlyEmoticonOnlyAndEmptyRows() throws {
    let html = """
    <html><body>
      <div id="post_100"><div class="t_f" id="postmessage_100">第一章<br>正文</div></div>
      <div id="comment_100" class="cm">
        <div class="pstl"><div class="psta"><a>空点评</a></div><div class="psti"><span class="xg1">发表于 2026-5-1</span></div></div>
        <div class="pstl"><div class="psta"><a>图点评</a></div><div class="psti"><img src="x.jpg"></div></div>
        <div class="pstl"><div class="psta"><a>表情点评</a></div><div class="psti"><img smilieid="1" alt=""></div></div>
        <div class="pstl"><div class="psta"><a>有效点评</a></div><div class="psti">有文字</div></div>
      </div>
      <div id="post_101">
        <div class="authi"><a class="author">回复甲</a></div>
        <div class="t_f" id="postmessage_101"><img src="reply.jpg"></div>
      </div>
      <div id="post_102">
        <div class="authi"><a class="author">回复乙</a></div>
        <div class="t_f" id="postmessage_102">有效回复</div>
      </div>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "42",
        view: 1,
        ownerPostID: "100",
        title: "第一章"
    )

    let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)

    #expect(page.comments.map(\.body) == ["有文字", "有效回复"])
}

@Test func chapterCommentOriginalPostURLUsesThreadAndPostIdentity() throws {
    let comment = ChapterComment(
        id: "100:reply:102",
        source: .reply,
        authorName: "读者",
        body: "回复",
        postID: "102"
    )

    let url = try #require(comment.originalPostURL(threadID: "42"))

    #expect(url.absoluteString == "https://bbs.yamibo.com/forum.php?goto=findpost&mobile=2&mod=redirect&pid=102&ptid=42")
}

@Test func findPostURLUsesQueryThreadAndPostIdentity() throws {
    let threadURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=42&mobile=2&page=3"))

    let url = try #require(YamiboRoute.findPostURL(threadURL: threadURL, postID: "102"))

    #expect(url.absoluteString == "https://bbs.yamibo.com/forum.php?goto=findpost&mobile=2&mod=redirect&pid=102&ptid=42")
}

@Test func findPostURLUsesThreadHTMLIdentity() throws {
    let threadURL = try #require(URL(string: "https://bbs.yamibo.com/thread-54321-1-1.html"))

    let url = try #require(YamiboRoute.findPostURL(threadURL: threadURL, postID: "987"))

    #expect(url.absoluteString == "https://bbs.yamibo.com/forum.php?goto=findpost&mobile=2&mod=redirect&pid=987&ptid=54321")
}

@Test func findPostURLRequiresThreadAndPostIdentity() throws {
    let missingThreadURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&mobile=2"))
    let threadURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=42&mobile=2"))

    #expect(YamiboRoute.findPostURL(threadURL: missingThreadURL, postID: "102") == nil)
    #expect(YamiboRoute.findPostURL(threadURL: threadURL, postID: "") == nil)
    #expect(YamiboRoute.findPostURL(threadURL: threadURL, postID: "   ") == nil)
    #expect(YamiboRoute.findPostURL(threadURL: threadURL, postID: nil) == nil)
}

@Test func chapterCommentSourcesExposeLocalizedDisplayLabels() {
    #expect(ChapterCommentSource.postComment.displayLabel == "点评")
    #expect(ChapterCommentSource.ratingReason.displayLabel == "评分")
    #expect(ChapterCommentSource.reply.displayLabel == "帖子")
}

@Test func chapterCommentsParserKeepsReplyFloorAndTimeMetadata() throws {
    let html = """
    <html><body>
      <div id="post_100">
        <div class="t_f" id="postmessage_100">第一章<br>正文</div>
      </div>
      <div id="post_101">
        <div class="pi"><strong><a><em>2#</em></a></strong></div>
        <div class="authi"><a class="author">回复甲</a><em>发表于 2026-5-2 10:00</em></div>
        <div class="t_f" id="postmessage_101">有效回复</div>
      </div>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "42",
        view: 1,
        ownerPostID: "100",
        title: "第一章"
    )

    let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)

    #expect(page.comments.first?.metadata == "2# · 发表于 2026-5-2 10:00")
}

@Test func chapterCommentsParserIncludesSamePageRepliesUntilNextOwnerPost() throws {
    let html = """
    <html><body>
      <div id="post_100">
        <div class="authi"><em title="楼主"></em><a class="author">楼主</a></div>
        <div class="t_f" id="postmessage_100">第一章<br>正文</div>
      </div>
      <div id="post_101">
        <div class="authi"><a class="author">读者甲</a></div>
        <div class="t_f" id="postmessage_101">
          <div class="quote"><blockquote>引用内容</blockquote></div>
          自己的回复
        </div>
      </div>
      <div id="post_102">
        <div class="authi"><a class="author">读者乙</a></div>
        <div class="t_f" id="postmessage_102">第二条回复</div>
      </div>
      <div id="post_200">
        <div class="authi"><em title="楼主"></em><a class="author">楼主</a></div>
        <div class="t_f" id="postmessage_200">第二章<br>正文</div>
      </div>
      <div id="post_103">
        <div class="authi"><a class="author">读者丙</a></div>
        <div class="t_f" id="postmessage_103">下一章评论</div>
      </div>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "42",
        view: 1,
        ownerPostID: "100",
        title: "第一章"
    )

    let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)

    #expect(page.comments.map(\.source) == [.reply, .reply])
    #expect(page.comments.map(\.authorName) == ["读者甲", "读者乙"])
    #expect(page.comments.map(\.body) == ["自己的回复", "第二条回复"])
    #expect(page.isBoundaryClosed == true)
}

@Test func chapterCommentsParserExposesNextPageWhenBoundaryStaysOpen() throws {
    let html = """
    <html><body>
      <a href="forum.php?mod=viewthread&tid=42&page=2&mobile=2">2</a>
      <div id="post_100">
        <div class="authi"><em title="楼主"></em></div>
        <div class="t_f" id="postmessage_100">第一章<br>正文</div>
      </div>
      <div id="post_101">
        <div class="authi"><a class="author">读者甲</a></div>
        <div class="t_f" id="postmessage_101">页尾回复</div>
      </div>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "42",
        view: 1,
        ownerPostID: "100",
        title: "第一章"
    )

    let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)

    #expect(page.comments.map(\.body) == ["页尾回复"])
    #expect(page.isBoundaryClosed == false)
    #expect(page.nextView == 2)
}

@Test func chapterCommentsParserContinuationClosesSilentlyWhenNextPageStartsWithOwnerPost() throws {
    let html = """
    <html><body>
      <a href="forum.php?mod=viewthread&tid=42&page=2&mobile=2">2</a>
      <div id="post_200">
        <div class="authi"><em title="楼主"></em></div>
        <div class="t_f" id="postmessage_200">第二章<br>正文</div>
      </div>
      <div id="post_201">
        <div class="authi"><a class="author">读者甲</a></div>
        <div class="t_f" id="postmessage_201">下一章回复</div>
      </div>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "42",
        view: 1,
        ownerPostID: "100",
        title: "第一章"
    )

    let page = try ChapterCommentsHTMLParser.parseContinuationPage(html: html, target: target, view: 2)

    #expect(page.comments.isEmpty)
    #expect(page.isBoundaryClosed == true)
    #expect(page.nextView == nil)
}

@Test func chapterCommentsParserContinuationAppendsRepliesBeforeNextOwnerPost() throws {
    let html = """
    <html><body>
      <a href="forum.php?mod=viewthread&tid=42&page=3&mobile=2">3</a>
      <div id="post_150">
        <div class="authi"><a class="author">读者甲</a></div>
        <div class="t_f" id="postmessage_150">跨页回复</div>
      </div>
      <div id="post_200">
        <div class="authi"><em title="楼主"></em></div>
        <div class="t_f" id="postmessage_200">第二章<br>正文</div>
      </div>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "42",
        view: 1,
        ownerPostID: "100",
        title: "第一章"
    )

    let page = try ChapterCommentsHTMLParser.parseContinuationPage(html: html, target: target, view: 2)

    #expect(page.comments.map(\.body) == ["跨页回复"])
    #expect(page.isBoundaryClosed == true)
    #expect(page.nextView == nil)
}

@Test func chapterCommentsParserReadsFullRatingReasonDialogAndFiltersTemplates() throws {
    let html = """
    <html><body>
      <div id="floatlayout_topicadmin">
        <h2>查看全部评分</h2>
        <ul class="post_box cl">
          <li class="flex-box mli">
            <div><span class="z">积分</span></div>
            <div><span class="z">用户名</span></div>
            <div><span class="y">时间</span></div>
          </li>
          <li class="flex-box mli">
            <div><span class="z">积分 +2 点</span></div>
            <div><span class="z">读者甲</span></div>
            <div><span class="y">2026-5-6 00:10</span></div>
          </li>
          <li class="flex-box mli"><div><span class="z">好萌好萌好萌</span></div></li>
          <li class="flex-box mli">
            <div><span class="z">积分 +5 点</span></div>
            <div><span class="z">读者乙</span></div>
            <div><span class="y">2024-11-23 11:15</span></div>
          </li>
          <li class="flex-box mli"><div><span class="z">嘿嘿，急了👈</span></div></li>
          <li class="flex-box mli">
            <div><span class="z">积分 +1 点</span></div>
            <div><span class="z">读者丙</span></div>
            <div><span class="y">2023-4-1 04:21</span></div>
          </li>
          <li class="flex-box mli"><div><span class="z">你太可愛</span></div></li>
        </ul>
      </div>
    </body></html>
    """
    let target = ReaderChapterCommentTarget(
        threadID: "42",
        view: 1,
        ownerPostID: "100",
        title: "第一章"
    )

    let comments = try ChapterCommentsHTMLParser.parseFullRatingReasonsPage(html: html, target: target)

    #expect(comments.map(\.body) == ["嘿嘿，急了👈"])
    #expect(comments.first?.authorName == "读者乙")
    #expect(comments.first?.metadata == "积分 +5 点 · 2024-11-23 11:15")
}

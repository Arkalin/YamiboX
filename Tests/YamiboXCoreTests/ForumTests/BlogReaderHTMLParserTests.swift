import Testing
@testable import YamiboXCore

struct BlogReaderHTMLParserTests {
    @Test(arguments: [
        "",
        #"<div class="doing_list"><ul></ul></div>"#,
        #"<ul id="comment_ul"></ul>"#
    ])
    func emptyCommentsDoNotIncludePageElements(commentSection: String) throws {
        let page = try BlogReaderHTMLParser.parsePage(
            from: pageHTML(commentSection: commentSection),
            blogID: "88",
            uidHint: "705216"
        )

        #expect(page.comments.isEmpty)
        #expect(page.title == "日志标题")
        #expect(page.author.uid == "705216")
        #expect(page.author.name == "日志作者")
        #expect(page.author.avatarURL?.absoluteString == "https://bbs.yamibo.com/avatar-author.jpg")
        #expect(page.postedAtText == "2026-9-6 21:40")
        #expect(page.viewCount == 0)
        #expect(page.replyCount == 0)
        #expect(page.contentText == "日志正文 正文列表 正文条目 条目说明")
        #expect(page.contentHTML.contains("<li>正文列表</li>"))
        #expect(page.collectURL?.absoluteString == "https://bbs.yamibo.com/home.php?mod=spacecp&ac=favorite&type=blog&id=88")
        #expect(page.shareURL?.absoluteString == "https://bbs.yamibo.com/home.php?mod=spacecp&ac=share&type=blog&id=88")
        #expect(page.inviteURL?.absoluteString == "https://bbs.yamibo.com/misc.php?mod=invite&action=blog&id=88")
    }

    @Test(arguments: ["评论内容", "收藏", "分享", "邀请"])
    func realCommentsSurviveZeroReplyCountAndActionWords(content: String) throws {
        let commentSection = """
        <div class="doing_list"><ul>
          <li id="comment_9001_li" class="doing_list_li list cl">
            <div class="avatar"><a href="home.php?mod=space&amp;uid=800001"><img src="avatar-commenter.jpg" /></a></div>
            <div class="muser">
              <h3><a href="home.php?mod=space&amp;uid=800001" id="author_9001" class="mmc">评论者</a></h3>
              <div class="mtime"><span>2026-9-6 22:00</span><a href="home.php?mod=spacecp&amp;ac=comment&amp;op=reply&amp;cid=9001">回复</a></div>
            </div>
            <div id="comment_9001" class="do_comment"><p>\(content)</p></div>
          </li>
        </ul></div>
        """
        let page = try BlogReaderHTMLParser.parsePage(
            from: pageHTML(commentSection: commentSection),
            blogID: "88",
            uidHint: "705216"
        )

        #expect(page.replyCount == 0)
        #expect(page.comments.count == 1)
        let comment = try #require(page.comments.first)
        #expect(comment.commentID == "9001")
        #expect(comment.author.uid == "800001")
        #expect(comment.author.name == "评论者")
        #expect(comment.author.avatarURL?.absoluteString == "https://bbs.yamibo.com/avatar-commenter.jpg")
        #expect(comment.postedAtText == "2026-9-6 22:00")
        #expect(comment.contentText == content)
        #expect(comment.contentHTML.contains("<p>\(content)</p>"))
        #expect(comment.replyURL?.absoluteString == "https://bbs.yamibo.com/home.php?mod=spacecp&ac=comment&op=reply&cid=9001")
    }

    private func pageHTML(commentSection: String) -> String {
        """
        <html><body>
          <div class="view_tit">日志标题</div>
          <div class="plc">
            <div class="avatar"><img src="avatar-author.jpg" /></div>
            <ul class="authi">
              <li class="mtit"><a href="home.php?mod=space&amp;uid=705216">日志作者</a></li>
              <li class="mtime"><span class="y"><i class="dm-eye"></i><em>0</em><i class="dm-chat-s"></i><em>0</em></span>2026-9-6 21:40</li>
            </ul>
            <div class="message">
              <p>日志正文</p>
              <ul><li>正文列表</li></ul>
              <dl><dt>正文条目</dt><dd>条目说明</dd></dl>
            </div>
            <div class="threadlist_foot"><ul>
              <li><a href="home.php?mod=spacecp&amp;ac=favorite&amp;type=blog&amp;id=88">收藏</a></li>
              <li><a href="home.php?mod=spacecp&amp;ac=share&amp;type=blog&amp;id=88">分享</a></li>
              <li><a href="misc.php?mod=invite&amp;action=blog&amp;id=88">邀请</a></li>
            </ul></div>
          </div>
          \(commentSection)
        </body></html>
        """
    }
}

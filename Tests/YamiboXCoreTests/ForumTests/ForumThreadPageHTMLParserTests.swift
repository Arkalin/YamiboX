import Foundation
import Testing
@testable import YamiboXCore

@Test func forumThreadPageParserExtractsRegularThreadPosts() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=700&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <head><title>普通讨论 - 百合会</title></head>
        <body>
          <div class="header cl">
            <div class="mz"><a href="javascript:history.back();"><i class="dm-c-left"></i></a></div>
            <h2><a href="forum.php?mod=forumdisplay&amp;fid=123&amp;">原创小说</a></h2>
          </div>
          <input type="hidden" name="formhash" value="form123" />
          <div class="viewthread">
            <div class="plc cl" id="pid1001">
              <div class="avatar"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/00/00/42_avatar_small.jpg" /></div>
              <div class="display pi pione" href="#replybtn_1001">
                <ul class="authi">
                  <li class="mtit">
                    <span class="y">1<sup>#</sup></span>
                    <span class="z"><a href="home.php?mod=space&amp;uid=42">楼主名</a></span>
                  </li>
                  <li class="mtime"><span class="y"><i class="dm-eye"></i><em>321</em><i class="dm-chat-s"></i><em>45</em></span>2026-6-1 10:00</li>
                </ul>
                <div class="message">
                  第一段<br>第二段
                  <i class="pstatus">本帖最后由 楼主名 于 2026-6-2 12:00 编辑</i>
                </div>
              </div>
            </div>
            <div class="plc cl" id="pid1002">
              <div class="avatar"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/00/00/77_avatar_small.jpg" /></div>
              <div class="display pi" href="#replybtn_1002">
                <ul class="authi">
                  <li class="mtit">
                    <span class="y">2<sup>#</sup></span>
                    <span class="z"><a href="home.php?mod=space&amp;uid=77">读者甲</a></span>
                  </li>
                  <li class="mtime">2026-6-1 10:05</li>
                </ul>
                <div class="message">回复内容</div>
              </div>
            </div>
          </div>
          <div class="pg"><strong>1</strong><a href="forum.php?mod=viewthread&amp;tid=700&amp;page=2">2</a><label><span title="共 3 页"> / 3 页</span></label></div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "700"),
        fallbackTitle: nil
    )

    #expect(page.title == "普通讨论")
    #expect(page.posts.count == 2)
    #expect(page.posts[0].postID == "1001")
    #expect(page.posts[0].author.uid == "42")
    #expect(page.posts[0].author.name == "楼主名")
    #expect(page.posts[0].floorText == "1#")
    #expect(page.posts[0].postedAtText == "2026-6-1 10:00")
    #expect(page.posts[0].lastEditedText == "本帖最后由 楼主名 于 2026-6-2 12:00 编辑")
    #expect(page.posts[0].contentText == "第一段\n第二段")
    #expect(page.posts[0].contentBlocks == [
        ForumThreadContentBlock(
            id: page.posts[0].contentBlocks[0].id,
            kind: .text(ForumThreadTextBlock(text: "第一段\n第二段"))
        )
    ])
    #expect(page.posts[1].postID == "1002")
    #expect(page.posts[1].author.uid == "77")
    #expect(page.posts[1].floorText == "2#")
    #expect(page.pageNavigation?.currentPage == 1)
    #expect(page.pageNavigation?.totalPages == 3)
    #expect(page.totalViews == 321)
    #expect(page.totalReplies == 45)
    #expect(page.forumID == "123")
    #expect(page.forumName == "原创小说")
    #expect(page.formHash == "form123")
}

@Test func forumThreadPageParserExtractsMobileDiscuzFloorAndCoverCandidate() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=544422&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <head><title>小说标题 - 百合会</title></head>
        <body>
          <div class="viewthread">
            <div class="plc cl" id="pid40946503">
              <div class="avatar">
                <img src="https://bbs.yamibo.com/uc_server/data/avatar/000/39/76/33_avatar_small.jpg" />
              </div>
              <div class="display pi pione" href="#replybtn_40946503">
                <ul class="authi">
                  <li class="mtit">
                    <span class="y">1<sup>#</sup></span>
                    <span class="z">
                      <a href="home.php?mod=space&amp;uid=397633&amp;mobile=2">106371928</a>
                    </span>
                  </li>
                  <li class="mtime">2024-3-16 01:44</li>
                </ul>
                <div class="message">
                  译名：人妻教师被班里的女高中生迷得神魂颠倒的故事
                  <a href="data/attachment/forum/202405/12/194518v77x7wqd77x75hw9.png" class="orange" />
                  <img
                    id="aimg_1239120"
                    src="data/attachment/forum/202405/12/194518v77x7wqd77x75hw9.png"
                    alt="28CA3F415BD916D532FE0D1BF8C291F2.png"
                    loading="lazy" />
                  </a>
                </div>
              </div>
            </div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "544422"),
        fallbackTitle: nil
    )

    let post = try #require(page.posts.first)
    #expect(post.floorText == "1#")
    #expect(post.postedAtText == "2024-3-16 01:44")
    #expect(post.author.uid == "397633")
    #expect(post.images == [
        ForumThreadPostImage(
            url: "data/attachment/forum/202405/12/194518v77x7wqd77x75hw9.png",
            altText: "28CA3F415BD916D532FE0D1BF8C291F2.png"
        )
    ])
    #expect(
        ThreadCoverResolver.findThreadCoverCandidate(in: page)?.absoluteString ==
        "https://bbs.yamibo.com/data/attachment/forum/202405/12/194518v77x7wqd77x75hw9.png"
    )
}

@Test func forumThreadPageParserExtractsMobileDiscuzPostedAtWithViewCountNoise() throws {
    // Regression coverage for the real bbs.yamibo.com mobile-theme markup (fetched with
    // the app's own mobile User-Agent + `mobile=2`): the thread's first floor concatenates
    // the view/reply-count digits directly in front of the date with no separator
    // ("189623" immediately before "2026-7-5 11:49"), and non-first floors are a bare
    // "<li class=\"mtime\">" date with no "发表于" prefix at all.
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <head><title>普通讨论 - 百合会</title></head>
        <body>
          <div class="plc cl" id="pid41575986">
            <div class="display pi pione" href="#replybtn_41575986">
              <ul class="authi">
                <li class="mtit">
                  <span class="y">1<sup>#</sup></span>
                  <span class="z"><a href="home.php?mod=space&amp;uid=729432&amp;mobile=2">longzi43</a></span>
                </li>
                <li class="mtime"><span class="y"><em>1896</em><em>23</em></span>2026-7-5 11:49</li>
              </ul>
              <div class="message">正文</div>
            </div>
          </div>
          <div class="plc cl" id="pid41576018">
            <div class="display pi" href="#replybtn_41576018">
              <ul class="authi">
                <li class="mtit">
                  <span class="y">2<sup>#</sup></span>
                  <span class="z"><a href="home.php?mod=space&amp;uid=706656&amp;mobile=2">读者甲</a></span>
                </li>
                <li class="mtime">2026-7-5 12:51</li>
              </ul>
              <div class="message">回复内容</div>
            </div>
          </div>
          <div class="plc cl" id="pid41576020">
            <div class="display pi" href="#replybtn_41576020">
              <ul class="authi">
                <li class="mtit">
                  <span class="y">3<sup>#</sup></span>
                  <span class="z"><a href="home.php?mod=space&amp;uid=706657&amp;mobile=2">读者乙</a></span>
                </li>
                <li class="mtime">昨天 09:12</li>
              </ul>
              <div class="message">回复内容2</div>
            </div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "573280"),
        fallbackTitle: nil
    )

    #expect(page.posts.count == 3)
    #expect(page.posts[0].floorText == "1#")
    #expect(page.posts[0].postedAtText == "2026-7-5 11:49")
    #expect(page.posts[1].floorText == "2#")
    #expect(page.posts[1].postedAtText == "2026-7-5 12:51")
    #expect(page.posts[2].floorText == "3#")
    #expect(page.posts[2].postedAtText == "昨天 09:12")
}

@Test func forumThreadPageParserCoverImagesMatchAndroidSrcOnlyExtraction() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=544422&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <head><title>小说标题 - 百合会</title></head>
        <body>
          <div id="post_40946503">
            <div class="authi">
              <a class="author" href="home.php?mod=space&amp;uid=397633&amp;mobile=2">106371928</a>
              <em title="楼主">楼主</em>
              <em>发表于 2024-3-16 01:44</em>
            </div>
            <div class="message" id="postmessage_40946503">
              译名：人妻教师被班里的女高中生迷得神魂颠倒的故事
              <img
                id="aimg_1239120"
                aid="1239120"
                src="static/image/common/none.gif"
                zoomfile="data/attachment/forum/202405/12/194518v77x7wqd77x75hw9.png"
                file="data/attachment/forum/202405/12/194518v77x7wqd77x75hw9.png"
                alt="cover.png" />
            </div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "544422"),
        fallbackTitle: nil
    )

    let post = try #require(page.posts.first)
    #expect(post.images.isEmpty)
    #expect(ThreadCoverResolver.findThreadCoverCandidate(in: page) == nil)
}

@Test func forumThreadPageParserExtractsFlatCoverImagesFromNestedMessageAndImgOne() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=545000&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <body>
          <div class="plc" id="pid5001">
            <ul class="authi">
              <li class="mtit">
                <span class="y">1<sup>#</sup></span>
                <span class="z"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主名</a></span>
              </li>
            </ul>
            <div class="message">
              正文
              <div class="quote"><img src="data/attachment/forum/quote.jpg" alt="quote"></div>
              <table><tr><td><img src="//img.example.com/table.jpg" alt="table"></td></tr></table>
              <img src="static/image/common/icon.gif" alt="icon">
            </div>
            <div class="img_one">
              <img src="/data/attachment/forum/img-one.jpg" alt="one">
            </div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "545000"),
        fallbackTitle: "图片测试"
    )

    let post = try #require(page.posts.first)
    #expect(post.images == [
        ForumThreadPostImage(url: "data/attachment/forum/quote.jpg", altText: "quote"),
        ForumThreadPostImage(url: "//img.example.com/table.jpg", altText: "table"),
        ForumThreadPostImage(url: "/data/attachment/forum/img-one.jpg", altText: "one")
    ])
    #expect(
        ThreadCoverResolver.findThreadCoverCandidate(in: page)?.absoluteString ==
        "https://bbs.yamibo.com/data/attachment/forum/quote.jpg"
    )
}

@Test func forumThreadPageParserStripsDiscuzSiteTitleSuffix() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=701&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <head>
          <title>文学区版规已更新 请各位会员阅读知悉 - 文學區 - 百合会 - 手机版 - Powered by Discuz!</title>
        </head>
        <body>
          <div id="post_1001">
            <div class="message">正文</div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "701"),
        fallbackTitle: nil
    )

    #expect(page.title == "文学区版规已更新 请各位会员阅读知悉")
}

@Test func forumThreadPageParserExtractsKMPStyleHtmlBlocks() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=702&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <body>
          <div id="post_2001">
            <div class="authi">
              <a class="author" href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主名</a>
            </div>
            <div class="message" id="postmessage_2001">
              正文
              <b>重点</b>
              <i>斜体</i>
              <u>下划线</u>
              <s>删除</s>
              <font color="red" size="5">红大</font>
              <span style="color: rgb(0, 128, 255); background-color: #fff; font-size: 20px;">蓝底</span>
              <ruby>東京<rt>とうきょう</rt></ruby>
              <a href="forum.php?mod=viewthread&amp;tid=888&amp;mobile=2">关联帖</a>
              <div class="quote">引用<br>第二行</div>
              <img zoomfile="data/attachment/forum/sample.jpg" alt="样图">
              <ul class="post_attlist">
                <li>
                  <a href="forum.php?mod=attachment&amp;aid=abc">
                    <img src="static/image/filetype/common.gif">
                    <span class="link">资料.zip</span>
                    <p>上传于 2026-06-01</p>
                    <p>下载次数 3</p>
                  </a>
                </li>
              </ul>
              <div class="blockcode">let value = 1</div>
              <hr>
              <div class="showcollapse_box">
                <div class="showcollapse_title">展开内容</div>
                折叠正文
              </div>
              <div class="locked-content">
                <div class="locked-tip">本帖隐藏内容需要积分: 10</div>
                隐藏正文
              </div>
              <table><tr><th>标题</th><td>值</td></tr></table>
            </div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "702"),
        fallbackTitle: "普通讨论"
    )

    let post = try #require(page.posts.first)
    #expect(post.contentBlocks.contains { block in
        guard case let .text(textBlock) = block.kind else { return false }
        return textBlock.text.contains("正文 重点 斜体 下划线 删除 红大 蓝底 東京 关联帖")
            && textBlock.links.first?.url.absoluteString == "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=888&mobile=2"
            && textBlock.hasStyle(for: "重点", where: \.isBold)
            && textBlock.hasStyle(for: "斜体", where: \.isItalic)
            && textBlock.hasStyle(for: "下划线", where: \.isUnderline)
            && textBlock.hasStyle(for: "删除", where: \.isStrikethrough)
            && textBlock.style(for: "红大")?.foregroundHex == "#FF0000"
            && textBlock.style(for: "红大")?.relativeFontSize == 1.5
            && textBlock.style(for: "蓝底")?.foregroundHex == "#0080FF"
            && textBlock.style(for: "蓝底")?.backgroundHex == "#FFFFFF"
            && textBlock.style(for: "蓝底")?.relativeFontSize == 1.25
            && textBlock.ruby(for: "東京")?.rubyText == "とうきょう"
            && !textBlock.text.contains("とうきょう")
    })
    #expect(post.contentBlocks.contains { block in
        guard case let .quote(blocks) = block.kind,
              case let .text(textBlock)? = blocks.first?.kind else { return false }
        return textBlock.text == "引用\n第二行"
    })
    #expect(post.contentBlocks.contains { block in
        guard case let .quote(blocks) = block.kind else { return false }
        return !blocks.contains { nested in
            if case .quote = nested.kind {
                return true
            }
            return false
        }
    })
    #expect(post.contentBlocks.contains { block in
        guard case let .image(image) = block.kind else { return false }
        return image.url.absoluteString == "https://bbs.yamibo.com/data/attachment/forum/sample.jpg"
            && image.altText == "样图"
            && !image.isEmoticon
    })
    #expect(post.contentBlocks.contains { block in
        guard case let .attachment(attachment) = block.kind else { return false }
        return attachment.fileName == "资料.zip"
            && attachment.url.absoluteString == "https://bbs.yamibo.com/forum.php?mod=attachment&aid=abc"
            && attachment.uploadInfo == "上传于 2026-06-01"
            && attachment.statInfo == "下载次数 3"
    })
    #expect(post.contentBlocks.contains { block in
        guard case .code("let value = 1") = block.kind else { return false }
        return true
    })
    #expect(post.contentBlocks.contains { block in
        guard case .horizontalRule = block.kind else { return false }
        return true
    })
    #expect(post.contentBlocks.contains { block in
        guard case let .collapse(title, blocks) = block.kind,
              case let .text(textBlock)? = blocks.first?.kind else { return false }
        return title == "展开内容" && textBlock.text == "折叠正文"
    })
    #expect(post.contentBlocks.contains { block in
        guard case let .locked(cost, blocks) = block.kind,
              case let .text(textBlock)? = blocks.last?.kind else { return false }
        return cost == 10 && textBlock.text == "隐藏正文"
    })
    #expect(post.contentBlocks.contains { block in
        guard case let .table(rows) = block.kind else { return false }
        return rows.count == 1
            && rows.first?.count == 2
            && rows[0][0].isHeader
    })
}

@Test func forumThreadPageParserKeepsLinkRangesAlignedAfterWhitespaceNormalization() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=703&mobile=2"))
    let sourceURL = "https://kakuyomu.jp/works/16817139558239041302"
    let supportURL = "https://bbs.yamibo.com/thread-546219-1-1.html"
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <body>
          <div id="post_3001">
            <div class="message" id="postmessage_3001"><div>原文： 人間關係に疲れた女子高生が女子中学生に癒されてロリコンにされる話 </div>生肉網址： <a href="https://kakuyomu.jp/works/16817139558239041302">https://kakuyomu.jp/works/16817139558239041302</a><br>支援者翻外「痛痛飛走吧」： <a href="https://bbs.yamibo.com/thread-546219-1-1.html">https://bbs.yamibo.com/thread-546219-1-1.html</a></div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "703"),
        fallbackTitle: "链接测试"
    )

    let post = try #require(page.posts.first)
    let textBlock = try #require(post.contentBlocks.compactMap { block -> ForumThreadTextBlock? in
        guard case let .text(textBlock) = block.kind else { return nil }
        return textBlock
    }.first)
    #expect(textBlock.linkText(for: sourceURL) == sourceURL)
    #expect(textBlock.linkText(for: supportURL) == supportURL)
}

@Test func forumThreadPageParserFlattensDiscuzQuoteBlockquoteWrapper() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=702&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <body>
          <div id="post_2001">
            <div class="message" id="postmessage_2001">
              <div class="quote">
                <blockquote>读者甲 发表于 2026-06-01 12:00<br>引用正文</blockquote>
              </div>
            </div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "702"),
        fallbackTitle: "普通讨论"
    )

    let post = try #require(page.posts.first)
    let quote = try #require(post.contentBlocks.first)
    guard case let .quote(blocks) = quote.kind else {
        Issue.record("Expected quote block")
        return
    }
    #expect(blocks.count == 1)
    guard case let .text(textBlock) = blocks[0].kind else {
        Issue.record("Expected quote text")
        return
    }
    #expect(textBlock.text == "读者甲 发表于 2026-06-01 12:00\n引用正文")
}

@Test func forumThreadPageParserPreservesTextAlignmentBoundaries() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=703&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <body>
          <div id="post_3001">
            <div class="authi">
              <a class="author" href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主名</a>
            </div>
            <div class="message" id="postmessage_3001">
              开头
              <div align="center">居中标题</div>
              <div align="right">右侧落款</div>
              <p align="left">左对齐补充</p>
              结尾
            </div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "703"),
        fallbackTitle: "普通讨论"
    )

    let post = try #require(page.posts.first)
    let textBlocks = post.contentBlocks.compactMap { block -> ForumThreadTextBlock? in
        guard case let .text(textBlock) = block.kind else { return nil }
        return textBlock
    }
    #expect(textBlocks.map(\.text) == ["开头", "居中标题", "右侧落款", "左对齐补充", "结尾"])
    #expect(textBlocks.map(\.alignment) == [.start, .center, .right, .left, .start])
    #expect(post.contentText == "开头\n居中标题\n右侧落款\n左对齐补充\n结尾")
}

private extension ForumThreadTextBlock {
    func hasStyle(for substring: String, where predicate: (ForumThreadTextStyle) -> Bool) -> Bool {
        guard let style = style(for: substring) else { return false }
        return predicate(style)
    }

    func style(for substring: String) -> ForumThreadTextStyle? {
        guard let range = text.range(of: substring) else { return nil }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        return styleRuns.first { run in
            run.start <= start && run.start + run.length >= start + length
        }?.style
    }

    func ruby(for substring: String) -> ForumThreadRubyText? {
        guard let range = text.range(of: substring) else { return nil }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        return rubies.first { ruby in
            ruby.start == start && ruby.length == length
        }
    }

    func linkText(for urlString: String) -> String? {
        guard let link = links.first(where: { $0.url.absoluteString == urlString }) else { return nil }
        let startIndex = text.index(text.startIndex, offsetBy: link.start)
        let endIndex = text.index(startIndex, offsetBy: link.length)
        return String(text[startIndex ..< endIndex])
    }
}

@Test func forumThreadPageParserExtractsPostFooterBlocks() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=704&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <body>
          <div id="post_4001">
            <div class="authi">
              <a class="author" href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主名</a>
            </div>
            <div class="message" id="postmessage_4001">
              正文
              <div class="poll cl">
                <form id="poll" name="poll" method="post" action="forum.php?mod=misc&amp;action=votepoll&amp;fid=123&amp;tid=704&amp;pollsubmit=yes&amp;quickforward=yes&amp;mobile=2">
                  <input type="hidden" name="formhash" value="form123" />
                  <div class="poll_txt">多选投票: 最多可选 2 项, 共有 20 人参与投票</div>
                  <div class="poll_txt">距结束还有: 4 天 12 小时 30 分钟</div>
                  <div class="poll_box">
                    <p><input type="checkbox" id="option_1" name="pollanswers[]" value="11" /><label for="option_1">1.选项甲</label><em class="y">65% (13票)</em></p>
                    <hr class="l">
                    <p><input type="checkbox" id="option_2" name="pollanswers[]" value="12" /><label for="option_2">2.选项乙</label><em class="y">35% (7票)</em></p>
                    <hr class="l">
                    <input type="submit" name="pollsubmit" id="pollsubmit" value="提交" class="formdialog btn_pn" />
                  </div>
                </form>
              </div>
            </div>
            <div id="ratelog_4001">
              <ul class="post_box cl">
                <li class="flex-box mli p0"><div>参与人数 2</div><div>积分 +7</div><div>理由</div></li>
                <li class="flex-box mli p0"><div><a href="home.php?mod=space&amp;uid=77&amp;mobile=2">读者甲</a></div><div>+2</div><div>有效评分理由</div></li>
                <li class="flex-box mli p0"><div><a>读者乙</a></div><div>+5</div><div>好萌</div></li>
                <li class="flex-box mli p0"><div><a href="forum.php?mod=misc&amp;action=viewratings&amp;tid=704&amp;pid=4001&amp;mobile=2">查看全部评分</a></div></li>
              </ul>
            </div>
            <ul class="post_attlist">
              <li class="b_t p5"><em class="tit"><a href="forum.php?mod=attachment&amp;aid=777"><span class="link">章节.txt</span><p class="pl5 f_9">2026-6-1 10:05 上传</p><p class="pl5 f_9">17.93 KB, 下载次数: 122</p></a></em></li>
            </ul>
            <div id="comment_4001">
              <h3 class="psth xs1"><span class="icon_ring vm"></span>点评</h3>
              <div class="plc p0 cl" id="commentdetail_9001">
                <div class="avatar l0"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/00/00/88_avatar_small.jpg"></div>
                <div class="display pi">
                  <ul class="authi">
                    <li class="mtit">
                      <span class="y">180.100.1.1</span>
                      <span class="z"><a href="home.php?mod=space&amp;uid=88" class="xi2 xw1">点评者</a></span>
                    </li>
                    <li class="mtime">发表于 2026-6-2 08:00</li>
                    <li class="mtxt mt5">点评内容</li>
                  </ul>
                </div>
              </div>
            </div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "704"),
        fallbackTitle: "普通讨论"
    )

    let post = try #require(page.posts.first)
    #expect(post.contentText == "正文")

    let poll = try #require(post.poll)
    #expect(poll.title == "多选投票: 最多可选 2 项, 共有 20 人参与投票")
    #expect(poll.endTimeText == "4 天 12 小时 30 分钟")
    #expect(poll.type == .multipleChoice)
    #expect(poll.status == .notVoted)
    #expect(poll.options.map(\.id) == ["11", "12"])
    // The touch template renders each option as "1.选项甲" + "65% (13票)"; the
    // title cleanup strips the numeric prefix, percentage, and vote count but
    // leaves the em's emptied parentheses behind.
    #expect(poll.options.map(\.title) == ["选项甲()", "选项乙()"])
    #expect(poll.options.map(\.voteCount) == [13, 7])
    #expect(poll.options.map(\.percentage) == [65, 35])
    // The touch template never pre-checks poll options for a user who has not
    // voted yet, so no option reports selected.
    #expect(poll.options.map(\.isSelected) == [false, false])

    let ratingBlock = try #require(post.ratingBlock)
    #expect(ratingBlock.participantCount == 2)
    #expect(ratingBlock.totalScore == 7)
    #expect(ratingBlock.ratings.map(\.user.name) == ["读者甲", "读者乙"])
    #expect(ratingBlock.ratings.map(\.scoreText) == ["+2", "+5"])
    #expect(ratingBlock.ratings.map(\.reason) == ["有效评分理由", "好萌"])
    #expect(ratingBlock.allRatingsURL?.absoluteString == "https://bbs.yamibo.com/forum.php?mod=misc&action=viewratings&tid=704&pid=4001&mobile=2")

    #expect(post.comments.count == 1)
    #expect(post.comments.first?.author.uid == "88")
    #expect(post.comments.first?.author.name == "点评者")
    #expect(post.comments.first?.message == "点评内容")
    #expect(post.comments.first?.postedAtText == "发表于 2026-6-2 08:00")

    #expect(post.attachments.count == 1)
    #expect(post.attachments.first?.fileName == "章节.txt")
    #expect(post.attachments.first?.url.absoluteString == "https://bbs.yamibo.com/forum.php?mod=attachment&aid=777")
    #expect(post.attachments.first?.uploadInfo == "2026-6-1 10:05 上传")
    #expect(post.attachments.first?.statInfo == "17.93 KB, 下载次数: 122")
}

@Test func forumThreadPageParserExtractsRatingResultsPopout() throws {
    let page = try ForumThreadPageHTMLParser.parseRatingResults(
        from: #"""
        <html>
        <body>
          <div class="o pns">积分 +9 点</div>
          <ul class="post_box cl">
            <li class="flex-box mli">
              <div class="flex-2 xs1 xg1"><span class="z">积分</span><span class="z">用户名</span></div>
              <div class="flex-3 xs1 xg1"><span class="y">时间</span></div>
            </li>
            <li class="flex-box mli">
              <div class="flex-2 xs1 xg1"><span class="z">积分 + 2 点</span><span class="z">读者甲</span></div>
              <div class="flex-3 xs1 xg1"><span class="y">2026-7-1 12:00</span></div>
            </li>
            <li class="flex-box mli">
              <div class="flex xs1 xg1"><span class="z">有效评分理由</span></div>
            </li>
            <li class="flex-box mli">
              <div class="flex-2 xs1 xg1"><span class="z">积分 + 7 点</span><span class="z">读者乙</span></div>
              <div class="flex-3 xs1 xg1"><span class="y">2026-7-2 09:30</span></div>
            </li>
            <li class="flex-box mli">
              <div class="flex xs1 xg1"><span class="z">好萌</span></div>
            </li>
          </ul>
        </body>
        </html>
        """#
    )

    #expect(page.totalScore == 9)
    // The viewratings float renders bare user names without profile links, so
    // no uid can be extracted from its rows.
    #expect(page.ratings.map(\.user.uid) == [nil, nil])
    #expect(page.ratings.map(\.user.name) == ["读者甲", "读者乙"])
    #expect(page.ratings.map(\.scoreText) == ["+2", "+7"])
    #expect(page.ratings.map(\.reason) == ["有效评分理由", "好萌"])
}

@Test func forumThreadPageParserExtractsRatingResultsFromAjaxCData() throws {
    let page = try ForumThreadPageHTMLParser.parseRatingResults(
        from: #"""
        <root><![CDATA[
          <div class="o pns">积分 +5 点</div>
          <ul class="post_box cl">
            <li class="flex-box mli">
              <div class="flex-2 xs1 xg1"><span class="z">积分</span><span class="z">用户名</span></div>
              <div class="flex-3 xs1 xg1"><span class="y">时间</span></div>
            </li>
            <li class="flex-box mli">
              <div class="flex-2 xs1 xg1"><span class="z">积分 + 5 点</span><span class="z">读者甲</span></div>
              <div class="flex-3 xs1 xg1"><span class="y">2026-7-1 12:00</span></div>
            </li>
            <li class="flex-box mli">
              <div class="flex xs1 xg1"><span class="z">有效评分理由</span></div>
            </li>
          </ul>
        ]]></root>
        """#
    )

    #expect(page.totalScore == 5)
    #expect(page.ratings.map(\.user.uid) == [nil])
    #expect(page.ratings.map(\.user.name) == ["读者甲"])
    #expect(page.ratings.map(\.scoreText) == ["+5"])
    #expect(page.ratings.map(\.reason) == ["有效评分理由"])
}

@Test func forumThreadPageParserExtractsRateOptionsPopout() throws {
    let page = try ForumThreadPageHTMLParser.parseRateOptions(
        from: #"""
        <root><![CDATA[
          <form>
            <select id="rate1">
              <option value="1">+1</option>
              <option value="5">+5</option>
            </select>
            <select id="reason">
              <option value="感谢分享">感谢分享</option>
              <option>好萌</option>
            </select>
          </form>
        ]]></root>
        """#
    )

    #expect(page.availableScores == [1, 5])
    #expect(page.defaultReasons == ["感谢分享", "好萌"])
}

@Test func forumThreadPageParserExtractsThreadActionResultFromAjaxMessage() throws {
    let message = try ForumThreadPageHTMLParser.parseThreadActionResult(
        from: #"""
        <root><![CDATA[
          <div id="messagetext"><p>评分成功</p></div>
          <script>succeedhandle_rate();</script>
        ]]></root>
        """#,
        context: L10n.string("forum.thread.ratings")
    )

    #expect(message == "评分成功")
}

@Test func forumThreadPageParserExtractsPollVotersPopout() throws {
    let page = try ForumThreadPageHTMLParser.parsePollVoters(
        from: #"""
        <html>
        <body>
          <form>
            <select id="polloptionid">
              <option value="11">选项甲</option>
              <option value="12" selected="selected">选项乙</option>
            </select>
          </form>
          <ul class="voters">
            <li><a href="home.php?mod=space&amp;uid=77&amp;mobile=2">读者甲</a></li>
            <li><a href="space-uid-88.html">读者乙</a></li>
          </ul>
          <div class="pg"><a>1</a><strong>2</strong><label><span title="共 5 页"> / 5 页</span></label></div>
        </body>
        </html>
        """#,
        threadID: "704",
        requestedOptionID: nil
    )

    #expect(page.threadID == "704")
    #expect(page.selectedOptionID == "12")
    #expect(page.pollOptions.map(\.id) == ["11", "12"])
    #expect(page.pollOptions.map(\.name) == ["选项甲", "选项乙"])
    #expect(page.voters.map(\.uid) == ["77", "88"])
    #expect(page.voters.map(\.name) == ["读者甲", "读者乙"])
    #expect(page.pageNavigation?.currentPage == 2)
    #expect(page.pageNavigation?.totalPages == 5)
}

@Test func forumThreadPageParserExtractsPollVotersFromAjaxCData() throws {
    let page = try ForumThreadPageHTMLParser.parsePollVoters(
        from: #"""
        <?xml version="1.0" encoding="utf-8"?>
        <root><![CDATA[
          <div id="floatlayout_viewvote">
            <select id="polloptionid">
              <option value="34677">架空历史</option>
              <option value="34678" selected="selected">架空正史</option>
            </select>
            <ul class="post_box flex-box flex-wrap cl">
              <li><a href="home.php?mod=space&amp;uid=77&amp;mobile=2">读者甲</a></li>
              <li><a href="space-uid-88.html">读者乙</a></li>
            </ul>
          </div>
        ]]></root>
        """#,
        threadID: "704",
        requestedOptionID: nil
    )

    #expect(page.threadID == "704")
    #expect(page.selectedOptionID == "34678")
    #expect(page.pollOptions.map(\.id) == ["34677", "34678"])
    #expect(page.pollOptions.map(\.name) == ["架空历史", "架空正史"])
    #expect(page.voters.map(\.uid) == ["77", "88"])
    #expect(page.voters.map(\.name) == ["读者甲", "读者乙"])
}

@Test func forumThreadPageParserSurfacesPollVotersAjaxPromptMessage() throws {
    #expect(throws: YamiboError.underlying("投票主题不存在")) {
        _ = try ForumThreadPageHTMLParser.parsePollVoters(
            from: #"""
            <root><![CDATA[<div class="jump_c"><p>投票主题不存在</p></div>]]></root>
            """#,
            threadID: "704",
            requestedOptionID: nil
        )
    }
}

@Test func forumThreadPageParserExtractsPinnedStateAndManageActions() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=705&mobile=2"))
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: #"""
        <html>
        <body>
          <div class="plc cl" id="pid5001">
            <div class="avatar"><img src="https://bbs.yamibo.com/uc_server/data/avatar/000/00/00/09_avatar_small.jpg" /></div>
            <div class="display pi" href="#replybtn_5001">
              <ul class="authi">
                <li class="mtit">
                  <span class="y"><img src="https://bbs.yamibo.com/static/image/mobile/settop.png" class="vm" /> 来自 5#</span>
                  <span class="z"><a href="home.php?mod=space&amp;uid=9">作者</a></span>
                </li>
                <li class="mtime">
                  <em class="mgl"><a href="#moption_5001" class="popup">管理</a></em>
                  <div id="moption_5001" popup="true" class="manage" style="display:none">
                    <div class="manage_popup">
                      <a class="button" href="forum.php?mod=post&amp;action=edit&amp;tid=705&amp;pid=5001">编辑</a>
                      <input type="button" value="删除主题" class="dialog button" href="forum.php?mod=topicadmin&amp;action=moderate&amp;tid=705&amp;pid=5001" />
                    </div>
                  </div>
                  2026-6-1 10:00
                </li>
              </ul>
              <div class="message">正文</div>
            </div>
          </div>
          <div class="plc cl" id="pid5002">
            <div class="display pi" href="#replybtn_5002">
              <ul class="authi">
                <li class="mtit">
                  <span class="y">6<sup>#</sup></span>
                  <span class="z"><a href="home.php?mod=space&amp;uid=77">读者甲</a></span>
                </li>
                <li class="mtime">2026-6-1 10:05</li>
              </ul>
              <div class="message">普通回复</div>
            </div>
          </div>
        </body>
        </html>
        """#,
        thread: ThreadIdentity(tid: "705"),
        fallbackTitle: "普通讨论"
    )

    #expect(page.posts.count == 2)
    #expect(page.posts[0].isPinned)
    #expect(page.posts[1].isPinned == false)
    #expect(page.posts[0].manageActions.map(\.title) == ["编辑", "删除主题"])
    #expect(page.posts[0].manageActions.map(\.url.absoluteString) == [
        "https://bbs.yamibo.com/forum.php?mod=post&action=edit&tid=705&pid=5001",
        "https://bbs.yamibo.com/forum.php?mod=topicadmin&action=moderate&tid=705&pid=5001"
    ])
    #expect(page.posts[1].manageActions.isEmpty)
}

@Test func forumThreadPageParserThrowsWhenNoPostsAreReadable() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=701&mobile=2"))

    #expect(throws: YamiboError.parsingFailed(context: L10n.string("context.thread_page"))) {
        _ = try ForumThreadPageHTMLParser.parsePage(
            from: "<html><body><div>empty</div></body></html>",
            thread: ThreadIdentity(tid: "701"),
            fallbackTitle: "普通讨论"
        )
    }
}

@Test func forumThreadPageParserSplitsLongTextBlocksForLazyRendering() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=703&mobile=2"))
    let longText = String(repeating: "长文本", count: 180)
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: """
        <html>
        <body>
          <div id="post_3001">
            <div class="authi"><a class="author" href="home.php?mod=space&uid=42&mobile=2">楼主名</a></div>
            <div class="message" id="postmessage_3001">\(longText)</div>
          </div>
        </body>
        </html>
        """,
        thread: ThreadIdentity(tid: "703"),
        fallbackTitle: "普通讨论"
    )

    let post = try #require(page.posts.first)
    let textBlocks = post.contentBlocks.compactMap { block -> ForumThreadTextBlock? in
        guard case let .text(textBlock) = block.kind else { return nil }
        return textBlock
    }
    #expect(textBlocks.count > 1)
    #expect(textBlocks.allSatisfy { $0.text.count <= 320 })
    #expect(textBlocks.map(\.text).joined() == longText)
}

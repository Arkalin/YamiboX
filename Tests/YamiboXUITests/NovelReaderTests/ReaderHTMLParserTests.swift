import Foundation
import Testing
@testable import YamiboXCore

// 拆分自 ReaderCoreTests.swift:阅读器 HTML 解析(ForumThreadPageHTMLParser →
// NovelReaderProjectionBuilder 投影链路,以及 YamiboThreadHTMLFacts /
// YamiboHTMLPageInspector 的页面事实抽取)。测试体保持原样。

@Test func readerHTMLParserExtractsTextImagesAndAuthor() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message">
          第一章 相遇<br>这里是正文。<img src="images/cover.jpg" />
        </div>
        <div class="message">
          第二章<br>第二段内容
        </div>
        <div class="pg"><strong>2</strong><a>... 4</a><span>/ 4 页</span></div>
        <a href="forum.php?mod=viewthread&tid=1&page=4&authorid=99">4</a>
      </body>
    </html>
    """#

    let request = NovelPageRequest(
        threadID: "1",
        view: 2
    )
    let document = try novelProjection(from: html, request: request)

    #expect(document.maxView == 4)
    #expect(document.resolvedAuthorID == "99")
    #expect(document.segments.count == 3)
    #expect(document.segments[0] == .text("第一章 相遇\n这里是正文。", chapterTitle: "第一章 相遇"))
    #expect(document.segments[1] == .image(try #require(URL(string: "https://bbs.yamibo.com/images/cover.jpg")), chapterTitle: "第一章 相遇"))
    #expect(document.segments[2] == .text("第二章\n第二段内容", chapterTitle: "第二章"))
}

@Test func readerHTMLParserAssignsStableChapterAndTextSegmentIdentities() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message" id="postmessage_101">
          第一章<br>第一段。<img src="images/first.jpg" />第二段。
        </div>
        <div class="message" id="postmessage_102">
          第一章<br>另一个同名章节。
        </div>
      </body>
    </html>
    """#
    let request = NovelPageRequest(
        threadID: "186",
        view: 1
    )

    let document = try novelProjection(from: html, request: request)

    #expect(document.segmentSemantics.count == document.segments.count)
    let firstText = try #require(document.semantics(forSegmentIndex: 0))
    let image = try #require(document.semantics(forSegmentIndex: 1))
    let secondTextInFirstChapter = try #require(document.semantics(forSegmentIndex: 2))
    let repeatedTitleText = try #require(document.semantics(forSegmentIndex: 3))

    #expect(firstText.chapterIdentity?.rawValue == "post:101#chapter:0")
    #expect(firstText.textSegmentIdentity?.rawValue == "post:101#chapter:0#text:0")
    #expect(firstText.chapterTitleRange == NovelCharacterRange(location: 0, length: "第一章".count))
    #expect(image.chapterIdentity == firstText.chapterIdentity)
    #expect(image.textSegmentIdentity?.rawValue == "post:101#chapter:0#image:0")
    #expect(secondTextInFirstChapter.chapterIdentity == firstText.chapterIdentity)
    #expect(secondTextInFirstChapter.textSegmentIdentity?.rawValue == "post:101#chapter:0#text:1")
    #expect(repeatedTitleText.chapterIdentity?.rawValue == "post:102#chapter:0")
    #expect(repeatedTitleText.chapterIdentity != firstText.chapterIdentity)
}

@Test func readerHTMLParserMarksAuthorReplyQuoteSourcesWithoutMarkingPlainBlockquotes() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message" id="postmessage_201">
          <div class="quote">
            <blockquote>读者甲 发表于 2026-5-1 12:00<br>引用内容</blockquote>
          </div>
          楼主自己的回复
        </div>
        <div class="message" id="postmessage_202">
          第一章<br>
          <blockquote>这里是小说正文里的引用排版。</blockquote>
          正文继续。
        </div>
      </body>
    </html>
    """#
    let request = NovelPageRequest(
        threadID: "187",
        view: 1,
        authorID: "42"
    )

    let document = try novelProjection(from: html, request: request)

    #expect(document.source(forSegmentIndex: 0)?.isAuthorReplyToOther == true)
    #expect(document.source(forSegmentIndex: 1)?.isAuthorReplyToOther == false)

    let firstText: String
    if case let .text(text, _) = document.segments[0] {
        firstText = text
    } else {
        Issue.record("Expected the first segment to be text.")
        return
    }
    let secondText: String
    if case let .text(text, _) = document.segments[1] {
        secondText = text
    } else {
        Issue.record("Expected the second segment to be text.")
        return
    }
    let firstQuote = "读者甲 发表于 2026-5-1 12:00\n引用内容"
    let secondQuote = "这里是小说正文里的引用排版。"

    #expect(firstText.hasPrefix(firstQuote))
    #expect(document.semantics(forSegmentIndex: 0)?.blockTextStyles == [
        NovelBlockTextStyleRange(
            style: .quote,
            range: NovelCharacterRange(location: 0, length: firstQuote.count)
        )
    ])
    #expect(document.semantics(forSegmentIndex: 1)?.blockTextStyles == [
        NovelBlockTextStyleRange(
            style: .quote,
            range: NovelCharacterRange(location: "第一章\n".count, length: secondQuote.count)
        )
    ])
    #expect(secondText.contains("\n正文继续。"))
}

@Test func readerHTMLParserExtractsAttachmentImagesFromSiblingImgOne() async throws {
    let html = #"""
    <html>
      <body>
        <div class="plc cl" id="pid41142124">
          <div class="display pi">
            <div class="message">
              文库版的一些插图
            </div>
            <ul class="img_one">
              <li>
                <a href="data/attachment/forum/202412/08/153657ahhp2shbtyzzheoo.jpeg" class="orange" />
                <img id="aimg_1330202" src="data/attachment/forum/202412/08/153657ahhp2shbtyzzheoo.jpeg" alt="IMG_6332.jpeg" loading="lazy" />
                </a>
              </li>
              <li>
                <a href="data/attachment/forum/202412/08/153657pwam4aaa8ca33nzu.jpeg" class="orange" />
                <img id="aimg_1330203" src="data/attachment/forum/202412/08/153657pwam4aaa8ca33nzu.jpeg" alt="IMG_6326.jpeg" loading="lazy" />
                </a>
              </li>
            </ul>
          </div>
        </div>
      </body>
    </html>
    """#
    let request = NovelPageRequest(
        threadID: "514442",
        view: 5
    )

    let document = try novelProjection(from: html, request: request)

    #expect(document.segments == [
        .text("文库版的一些插图", chapterTitle: "文库版的一些插图"),
        .image(
            try #require(URL(string: "https://bbs.yamibo.com/data/attachment/forum/202412/08/153657ahhp2shbtyzzheoo.jpeg")),
            chapterTitle: "文库版的一些插图"
        ),
        .image(
            try #require(URL(string: "https://bbs.yamibo.com/data/attachment/forum/202412/08/153657pwam4aaa8ca33nzu.jpeg")),
            chapterTitle: "文库版的一些插图"
        )
    ])

    let textSemantics = try #require(document.semantics(forSegmentIndex: 0))
    let firstImageSemantics = try #require(document.semantics(forSegmentIndex: 1))
    let secondImageSemantics = try #require(document.semantics(forSegmentIndex: 2))

    #expect(textSemantics.chapterIdentity?.rawValue == "post:41142124#chapter:0")
    #expect(textSemantics.textSegmentIdentity?.rawValue == "post:41142124#chapter:0#text:0")
    #expect(firstImageSemantics.chapterIdentity == textSemantics.chapterIdentity)
    #expect(secondImageSemantics.chapterIdentity == textSemantics.chapterIdentity)
    #expect(firstImageSemantics.textSegmentIdentity?.rawValue == "post:41142124#chapter:0#image:0")
    #expect(secondImageSemantics.textSegmentIdentity?.rawValue == "post:41142124#chapter:0#image:1")
    #expect(document.segmentSources == [
        NovelReaderSegmentSource(ownerPostID: "41142124"),
        NovelReaderSegmentSource(ownerPostID: "41142124"),
        NovelReaderSegmentSource(ownerPostID: "41142124")
    ])
}

@Test func readerHTMLParserPreservesBoldInlineTextStyles() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message" id="postmessage_201">第一章<br>普通<strong>粗体</strong><span style="font-weight: 700">重字</span><b style="font-weight: normal">不粗</b><span style="font-weight: bold">再粗</span></div>
      </body>
    </html>
    """#
    let request = NovelPageRequest(
        threadID: "201",
        view: 1
    )

    let document = try novelProjection(from: html, request: request)
    let semantics = try #require(document.semantics(forSegmentIndex: 0))

    #expect(document.segments[0] == .text("第一章\n普通 粗体 重字 不粗 再粗", chapterTitle: "第一章"))
    #expect(semantics.inlineTextStyles == [
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 7, length: 2)),
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 10, length: 2)),
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 16, length: 2)),
    ])
}

@Test func readerHTMLParserPreservesSyntheticZeroIdentityWhenOwnerPostIdentityIsMissing() async throws {
    let request = NovelPageRequest(
        threadID: "187",
        view: 2
    )
    let page = ForumThreadPage(
        thread: ThreadIdentity(tid: "187"),
        title: "同名章",
        posts: [
            ForumThreadPost(
                postID: "",
                author: BlogReaderUser(uid: "99", name: "楼主"),
                contentHTML: "",
                contentText: "同名章\n第一处。",
                contentBlocks: [
                    ForumThreadContentBlock(id: "first", kind: .text(ForumThreadTextBlock(text: "同名章\n第一处。")))
                ]
            ),
            ForumThreadPost(
                postID: "",
                author: BlogReaderUser(uid: "99", name: "楼主"),
                contentHTML: "",
                contentText: "同名章\n第二处。",
                contentBlocks: [
                    ForumThreadContentBlock(id: "second", kind: .text(ForumThreadTextBlock(text: "同名章\n第二处。")))
                ]
            )
        ]
    )

    let document = try NovelReaderProjectionBuilder.build(from: page, request: request, authorID: "99")
    let first = try #require(document.semantics(forSegmentIndex: 0)?.chapterIdentity?.rawValue)
    let second = try #require(document.semantics(forSegmentIndex: 1)?.chapterIdentity?.rawValue)

    #expect(first == "post:0#chapter:0")
    #expect(second == "post:0#chapter:0")
    #expect(document.semantics(forSegmentIndex: 0)?.textSegmentIdentity?.rawValue == "post:0#chapter:0#text:0")
    #expect(document.semantics(forSegmentIndex: 1)?.textSegmentIdentity?.rawValue == "post:0#chapter:0#text:1")
    #expect(document.source(forSegmentIndex: 0)?.ownerPostID == "0")
    #expect(document.source(forSegmentIndex: 1)?.ownerPostID == "0")
}

@Test func novelProjectionBuilderPrefersContentHTMLOverContentBlocks() async throws {
    let page = ForumThreadPage(
        thread: ThreadIdentity(tid: "188"),
        title: "HTML 优先",
        posts: [
            ForumThreadPost(
                postID: "18801",
                author: BlogReaderUser(uid: "99", name: "楼主"),
                contentHTML: #"HTML章<br>来自 <strong>HTML</strong>"#,
                contentText: "Blocks章\n来自 blocks",
                contentBlocks: [
                    ForumThreadContentBlock(id: "wrong", kind: .text(ForumThreadTextBlock(text: "Blocks章\n来自 blocks")))
                ]
            )
        ]
    )

    let document = try NovelReaderProjectionBuilder.build(
        from: page,
        request: NovelPageRequest(threadID: "188", view: 1),
        authorID: "99"
    )

    #expect(document.segments == [.text("HTML章\n来自 HTML", chapterTitle: "HTML章")])
    #expect(document.semantics(forSegmentIndex: 0)?.inlineTextStyles == [
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: "HTML章\n来自 ".count, length: "HTML".count))
    ])
}

@Test func readerHTMLParserKeepsBoldRangesAlignedAcrossImages() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message">
          序章<br><b>前文</b><img src="images/first.jpg" /><strong>后文</strong>
        </div>
      </body>
    </html>
    """#

    let parsed = novelReaderParsedContent(from: html, threadID: "557752")

    #expect(parsed.segments == [
        .text("序章\n前文", chapterTitle: "序章"),
        .image(try #require(URL(string: "https://bbs.yamibo.com/images/first.jpg")), chapterTitle: "序章"),
        .text("后文", chapterTitle: "序章")
    ])
    #expect(parsed.segmentSemantics[0]?.inlineTextStyles == [
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 3, length: 2))
    ])
    #expect(parsed.segmentSemantics[1]?.inlineTextStyles == [])
    #expect(parsed.segmentSemantics[2]?.inlineTextStyles == [
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 0, length: 2))
    ])
}

@Test func readerHTMLParserKeepsQuoteRangesAlignedAcrossBoldAndImages() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message">
          序章<br><blockquote><strong>前文</strong><img src="images/first.jpg" />后文</blockquote>
        </div>
      </body>
    </html>
    """#

    let parsed = novelReaderParsedContent(from: html, threadID: "557752")

    #expect(parsed.segments == [
        .text("序章\n前文", chapterTitle: "序章"),
        .image(try #require(URL(string: "https://bbs.yamibo.com/images/first.jpg")), chapterTitle: "序章"),
        .text("后文", chapterTitle: "序章")
    ])
    #expect(parsed.segmentSemantics[0]?.inlineTextStyles == [
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 3, length: 2))
    ])
    #expect(parsed.segmentSemantics[0]?.blockTextStyles == [
        NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 3, length: 2))
    ])
    #expect(parsed.segmentSemantics[1]?.blockTextStyles == [])
    #expect(parsed.segmentSemantics[2]?.blockTextStyles == [
        NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 0, length: 2))
    ])
}

@Test func readerHTMLParserPreservesInlineImagePositionWithinMessage() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message">
          第一章 相遇<br>
          这里是前文。
          <img src="images/first.jpg" />
          这里是后文。
          <img file="images/second.jpg" src="images/fallback.jpg" />
          这里是尾声。
        </div>
      </body>
    </html>
    """#

    let parsed = novelReaderParsedContent(from: html, threadID: "557752")

    #expect(parsed.segments == [
        .text("第一章 相遇\n这里是前文。", chapterTitle: "第一章 相遇"),
        .image(try #require(URL(string: "https://bbs.yamibo.com/images/first.jpg")), chapterTitle: "第一章 相遇"),
        .text("这里是后文。", chapterTitle: "第一章 相遇"),
        .image(try #require(URL(string: "https://bbs.yamibo.com/images/second.jpg")), chapterTitle: "第一章 相遇"),
        .text("这里是尾声。", chapterTitle: "第一章 相遇")
    ])
}

@Test func readerHTMLParserPreservesNestedMessageContent() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message">
          <div class="wrapper">
            序章<br>这里是开头。
            <div class="nested">
              这里是被嵌套的正文。
              <img src="images/nested.jpg" />
            </div>
          </div>
        </div>
      </body>
    </html>
    """#

    let request = NovelPageRequest(
        threadID: "2",
        view: 1
    )
    let document = try novelProjection(from: html, request: request)

    #expect(document.segments.count == 2)

    guard case let .text(text, chapterTitle) = document.segments[0] else {
        Issue.record("Expected the first segment to be text")
        return
    }

    #expect(chapterTitle == "序章")
    #expect(text.contains("这里是开头。"))
    #expect(text.contains("这里是被嵌套的正文。"))
    #expect(document.segments[1] == .image(try #require(URL(string: "https://bbs.yamibo.com/images/nested.jpg")), chapterTitle: "序章"))
}

@Test func readerHTMLParserKeepsMessageOrderAndDeduplicatesSharedSelectors() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message" id="postmessage_1">第一章<br>正文一</div>
        <div class="message">第二章<br>正文二</div>
      </body>
    </html>
    """#

    let parsed = novelReaderParsedContent(from: html, threadID: "557752")

    #expect(parsed.segments.count == 2)
    #expect(parsed.segments[0] == .text("第一章\n正文一", chapterTitle: "第一章"))
    #expect(parsed.segments[1] == .text("第二章\n正文二", chapterTitle: "第二章"))
}

@Test func readerHTMLParserSupportsPostmessageWithoutMessageClass() async throws {
    let html = #"""
    <html>
      <body>
        <table><tr><td id="postmessage_9">尾声<br>只有 postmessage 也要解析</td></tr></table>
      </body>
    </html>
    """#

    let parsed = novelReaderParsedContent(from: html, threadID: "557752")

    #expect(parsed.segments == [.text("尾声\n只有 postmessage 也要解析", chapterTitle: "尾声")])
}

@Test func readerHTMLParserExtractsImagesFromPreferredAttributesAndSkipsSmiley() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message">
          插图回<br>
          <img zoomfile="images/zoom.jpg" src="images/fallback-a.jpg" />
          <img file="images/file.jpg" src="images/fallback-b.jpg" />
          <img src="images/plain.jpg" />
          <img src="images/smiley/icon.png" />
        </div>
      </body>
    </html>
    """#

    let parsed = novelReaderParsedContent(from: html, threadID: "557752")

    #expect(parsed.segments.count == 4)
    #expect(parsed.segments[0] == .text("插图回", chapterTitle: "插图回"))
    #expect(parsed.segments[1] == .image(try #require(URL(string: "https://bbs.yamibo.com/images/zoom.jpg")), chapterTitle: "插图回"))
    #expect(parsed.segments[2] == .image(try #require(URL(string: "https://bbs.yamibo.com/images/file.jpg")), chapterTitle: "插图回"))
    #expect(parsed.segments[3] == .image(try #require(URL(string: "https://bbs.yamibo.com/images/plain.jpg")), chapterTitle: "插图回"))
}

@Test func readerHTMLParserPreservesDuplicateImagesAndRemovesItalicText() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message">
          <i>隐藏注音</i>插图回<br>
          <img src="images/repeated.jpg" />
          <img src="images/repeated.jpg" />
        </div>
      </body>
    </html>
    """#

    let parsed = novelReaderParsedContent(from: html, threadID: "557752")

    #expect(parsed.segments == [
        .text("插图回", chapterTitle: "插图回"),
        .image(try #require(URL(string: "https://bbs.yamibo.com/images/repeated.jpg")), chapterTitle: "插图回"),
        .image(try #require(URL(string: "https://bbs.yamibo.com/images/repeated.jpg")), chapterTitle: "插图回")
    ])
}

@Test func readerHTMLParserExtractsMaxViewFromSameThreadLinksOnly() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message">正文里提到第 315 页和 9494 次浏览</div>
        <select id="dumppage">
          <option value="1">1/4</option>
          <option value="4">4/4</option>
        </select>
        <a href="forum.php?mod=viewthread&tid=557752&page=2&mobile=2">2</a>
        <a href="forum.php?mod=viewthread&tid=557752&page=4&mobile=2">4</a>
        <a href="forum.php?mod=viewthread&tid=999999&page=88&mobile=2">88</a>
      </body>
    </html>
    """#
    let request = NovelPageRequest(
        threadID: "557752",
        view: 1
    )

    #expect(YamiboThreadHTMLFacts.maxView(from: html, threadID: request.threadID, currentView: request.view) == 4)
}

@Test func readerHTMLParserExtractsPageTitle() async throws {
    let html = "<html><head><title>测试标题 - 轻小说/译文区 - 百合会</title></head><body></body></html>"
    #expect(YamiboHTMLPageInspector.pageTitle(from: html) == "测试标题 - 轻小说/译文区 - 百合会")
}

@Test func readerHTMLParserExtractsOnlyAuthorIDFromThreadLink() async throws {
    let html = #"""
    <html>
      <body>
        <a href="forum.php?mod=viewthread&tid=999999&page=1&authorid=1&mobile=2">别的帖子</a>
        <a class="nav-more-item" href="forum.php?mod=viewthread&tid=557752&page=1&authorid=595655&mobile=2">只看楼主</a>
      </body>
    </html>
    """#
    let request = NovelPageRequest(
        threadID: "557752",
        view: 1
    )

    #expect(YamiboThreadHTMLFacts.onlyAuthorID(from: html, threadID: request.threadID) == "595655")
}

@Test func readerHTMLParserHandlesMalformedHTML() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message"><div>序章<br>这段 HTML 没有正常闭合
      </body>
    </html>
    """#

    let parsed = novelReaderParsedContent(from: html, threadID: "557752")

    #expect(parsed.segments == [.text("序章\n这段 HTML 没有正常闭合", chapterTitle: "序章")])
}

@Test func parseProjectionCarriesChapterStats() async throws {
    let html = #"""
    <html>
      <body>
        <div class="message">第1话 恋爱的开始<br>正文</div>
        <div class="message">感谢翻译，收藏一波<br>评论</div>
      </body>
    </html>
    """#
    let request = NovelPageRequest(
        threadID: "11",
        view: 1
    )
    let document = try novelProjection(from: html, request: request)

    #expect(document.retainedChapterCount == 2)
    #expect(document.filteredChapterCandidateCount == 0)
    let chapterTitles = document.segments.compactMap { segment -> String? in
        switch segment {
        case let .text(_, chapterTitle), let .image(_, chapterTitle):
            chapterTitle
        }
    }
    #expect(chapterTitles == ["第1话 恋爱的开始", "感谢翻译，收藏一波"])
}

@Test func readerHTMLParserPreservesChapterBodiesInDirectoryStyleThread() async throws {
    let html = #"""
    <html>
      <head><title>测试书 - 百合会</title></head>
      <body>
        <div class="message">
          目录：<br>
          序章<br>
          1 如弃猫般的她<br>
          译者后记
        </div>
        <div class="message">
          <div class="chapter-shell">
            序章<br>
            我肯定没有不惜伤害他人也要以自己的恋情为优先的勇气。
            <blockquote>
              所以，不是什么道德伦理之类的原因，而是我认为自己绝对不会不忠。
            </blockquote>
          </div>
        </div>
        <div class="message">
          1 如弃猫般的她<br>
          「呐，雪，车站往哪边走？」<br>
          <div class="nested">在涩谷街上，被唤作雪的我指着东北方回答询问的声音。</div>
        </div>
        <div class="message">
          译者后记<br>
          首先感谢看到这的各位，加分及留言一直都给了我不少翻下去的动力。
        </div>
      </body>
    </html>
    """#

    let request = NovelPageRequest(
        threadID: "557752",
        view: 1
    )
    let document = try novelProjection(from: html, request: request)

    let chapterTitles = document.segments.compactMap { segment -> String? in
        switch segment {
        case let .text(_, chapterTitle), let .image(_, chapterTitle):
            chapterTitle
        }
    }

    #expect(chapterTitles == ["目录：", "序章", "1 如弃猫般的她", "译者后记"])
    #expect(document.segments.contains {
        guard case let .text(text, chapterTitle) = $0 else { return false }
        return chapterTitle == "序章" && text.contains("绝对不会不忠")
    })
    #expect(document.segments.contains {
        guard case let .text(text, chapterTitle) = $0 else { return false }
        return chapterTitle == "1 如弃猫般的她" && text.contains("在涩谷街上")
    })
    #expect(document.segments.contains {
        guard case let .text(text, chapterTitle) = $0 else { return false }
        return chapterTitle == "译者后记" && text.contains("翻下去的动力")
    })
}

private func novelProjection(
    from html: String,
    request: NovelPageRequest,
    authorID: String? = nil
) throws -> NovelReaderProjection {
    let page = try forumThreadPage(from: html, threadID: request.threadID)
    let resolvedAuthorID = authorID
        ?? request.authorID
        ?? YamiboThreadHTMLFacts.onlyAuthorID(from: html, threadID: request.threadID)
        ?? page.posts.first?.author.uid
        ?? "99"
    return try NovelReaderProjectionBuilder.build(
        from: page,
        request: request,
        authorID: resolvedAuthorID
    )
}

private func novelReaderParsedContent(from html: String, threadID: String) -> NovelReaderParsedContent {
    let request = NovelPageRequest(threadID: threadID, view: 1, authorID: "99")
    guard let document = try? novelProjection(from: html, request: request, authorID: "99") else {
        return NovelReaderParsedContent()
    }
    return NovelReaderParsedContent(
        segments: document.segments,
        segmentSources: document.segmentSources,
        segmentSemantics: document.segmentSemantics,
        retainedChapterCount: document.retainedChapterCount,
        filteredChapterCandidateCount: document.filteredChapterCandidateCount
    )
}

private func forumThreadPage(from html: String, threadID: String) throws -> ForumThreadPage {
    try ForumThreadPageHTMLParser.parsePage(
        from: htmlWithSyntheticPostIDs(html),
        thread: ThreadIdentity(tid: threadID),
        fallbackTitle: nil
    )
}

private func htmlWithSyntheticPostIDs(_ html: String) -> String {
    var nextPostID = 900_000
    let pattern = #"<div\s+class="message"(?![^>]*\bid=)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
    var result = ""
    var cursor = html.startIndex
    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
        guard let range = Range(match.range, in: html) else { continue }
        result += html[cursor ..< range.lowerBound]
        result += #"<div class="message" id="postmessage_\#(nextPostID)""#
        nextPostID += 1
        cursor = range.upperBound
    }
    result += html[cursor...]
    return result
}

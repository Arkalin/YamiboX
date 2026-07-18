import Foundation
@preconcurrency import GRDB
import Testing
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

#if canImport(UIKit)
import UIKit

private extension NovelTextViewportRuntimeOwner {
    convenience init() {
        self.init(adapter: DefaultNovelTextLayoutRuntimeAdapter())
    }
}

private func makeTestOfflineCacheStore(
    rootDirectory: URL? = nil,
    baseDirectory: URL? = nil,
    prefix: String = "grdb-novel-offline-cache"
) throws -> OfflineCacheStore {
    let rootDirectory = rootDirectory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return OfflineCacheStore(
        databasePool: try YamiboDatabase.openPool(rootDirectory: rootDirectory.appendingPathComponent("grdb", isDirectory: true)),
        baseDirectory: baseDirectory ?? rootDirectory.appendingPathComponent("offline-images", isDirectory: true)
    )
}
private typealias ReaderTestFont = UIFont

private func readerTestFontWeight(_ font: ReaderTestFont) -> CGFloat {
    let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
    if let value = traits?[.weight] as? CGFloat {
        return value
    }
    if let value = traits?[.weight] as? NSNumber {
        return CGFloat(truncating: value)
    }
    return 0
}
#endif

private struct StubURLProtocolResponse {
    let statusCode: Int
    let body: String
}

private enum StubURLProtocolOutput {
    case response(StubURLProtocolResponse)
    case error(URLError)
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> StubURLProtocolOutput)? = defaultHandler()
    nonisolated(unsafe) static var tid28UnfilteredCachePolicy: URLRequest.CachePolicy?

    static func threadPageHTML(postID: String, authorID: String = "42", body: String) -> String {
        """
        <html><body>
          <div class="plc cl" id="pid\(postID)">
            <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=\(authorID)&amp;mobile=2">楼主</a></li></ul>
            <div class="message">\(body)</div>
          </div>
        </body></html>
        """
    }

    static func defaultHandler() -> (URLRequest) -> StubURLProtocolOutput {
        { request in
        let absolute = request.url?.absoluteString ?? ""

        if absolute.contains("mod=space"),
           absolute.contains("do=favorite") {
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if cookie.contains("favorite-add-success=1") {
                return .response(
                    StubURLProtocolResponse(
                        statusCode: 200,
                        body: """
                        <html><body>
                          <ul class="sclist">
                            <li>
                              <a href="forum.php?mod=viewthread&tid=704&mobile=2">远端收藏</a>
                              <a class="mdel" href="home.php?mod=spacecp&ac=favorite&op=delete&favid=8801">删除</a>
                            </li>
                          </ul>
                        </body></html>
                        """
                    )
                )
            }
            if cookie.contains("favorite-target-page2=1") {
                if absolute.contains("page=2") {
                    return .response(
                        StubURLProtocolResponse(
                            statusCode: 200,
                            body: """
                            <html><body>
                              <ul class="sclist">
                                <li>
                                  <a href="forum.php?mod=viewthread&tid=805&mobile=2">第二页收藏</a>
                                  <a class="mdel" href="home.php?mod=spacecp&ac=favorite&op=delete&favid=9902">删除</a>
                                </li>
                              </ul>
                              <div class="pg"><a href="home.php?mod=space&do=favorite&type=thread&page=1">1</a><strong>2</strong></div>
                            </body></html>
                            """
                        )
                    )
                }
                return .response(
                    StubURLProtocolResponse(
                        statusCode: 200,
                        body: """
                        <html><body>
                          <ul class="sclist">
                            <li><a href="forum.php?mod=viewthread&tid=804&mobile=2">第一页收藏</a></li>
                          </ul>
                          <div class="pg"><strong>1</strong><a href="home.php?mod=space&do=favorite&type=thread&page=2">2</a></div>
                        </body></html>
                        """
                    )
                )
            }
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: """
                    <html>
                      <head><title>登录 - 百合会 - 手机版 - Powered by Discuz!</title></head>
                      <body class="pg_logging">
                        <form id="member_login" action="member.php?mod=logging&action=login"></form>
                      </body>
                    </html>
                    """
                )
            )
        }

        if absolute.contains("do=profile") {
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: #"<html><body><a href="home.php?mod=spacecp&formhash=profilehash">设置</a></body></html>"#
                )
            )
        }

        if absolute.contains("ac=favorite"),
           absolute.contains("type=thread"),
           absolute.contains("id=704") {
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: "<html><body>信息收藏成功</body></html>"
                )
            )
        }

        if absolute.contains("mod=faq") {
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if cookie.contains("missing-token=1") {
                return .response(
                    StubURLProtocolResponse(
                        statusCode: 200,
                        body: "<html><body>no token</body></html>"
                    )
                )
            }
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: #"<html><body><input name="formhash" value="abc12345" /></body></html>"#
                )
            )
        }

        if absolute.contains("ac=favorite"),
           absolute.contains("op=delete") {
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if cookie.contains("favorite-delete-success=1")
                || body.contains("favorite%5B%5D=55")
                || body.contains("favorite[]=55") {
                return .response(
                    StubURLProtocolResponse(
                        statusCode: 200,
                        body: "<html><body>操作成功</body></html>"
                    )
                )
            }
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: "<html><body>操作失败</body></html>"
                )
            )
        }

        if absolute.contains("tid=22") {
            return .error(URLError(.notConnectedToInternet))
        }

        if absolute.contains("tid=23") {
            let body: String
            if absolute.contains("authorid=42") {
                body = threadPageHTML(postID: "2301", body: "只看楼主新缓存")
            } else {
                body = threadPageHTML(postID: "2302", authorID: "77", body: "全部回复新缓存")
            }
            return .response(StubURLProtocolResponse(statusCode: 200, body: body))
        }

        if absolute.contains("tid=24") {
            if absolute.contains("page=2") {
                return .error(URLError(.networkConnectionLost))
            }
            let page = absolute.contains("page=3") ? "3" : "1"
            let body = threadPageHTML(postID: "240\(page)", body: "只看楼主缓存页\(page)")
            return .response(StubURLProtocolResponse(statusCode: 200, body: body))
        }

        if absolute.contains("tid=25") {
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: threadPageHTML(postID: "41257246", body: "新解析章节<br>新正文")
                )
            )
        }

        if absolute.contains("tid=34") {
            return .error(URLError(.notConnectedToInternet))
        }

        if absolute.contains("tid=35") {
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: """
                    <html><body>
                      <div class="plc cl" id="pid3501">
                        <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主</a></li></ul>
                        <div class="message"></div>
                      </div>
                    </body></html>
                    """
                )
            )
        }

        if absolute.contains("tid=36") {
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: threadPageHTML(postID: "3601", body: "在线章节<br>在线新正文")
                )
            )
        }

        if absolute.contains("tid=37") {
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: threadPageHTML(postID: "3701", body: "未缓存章节<br>未缓存在线正文")
                )
            )
        }

        if absolute.contains("action=viewratings"),
           absolute.contains("tid=26"),
           absolute.contains("pid=2601") {
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: """
                    <html><body>
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
                        <li class="flex-box mli"><div><span class="z">完整评分理由</span></div></li>
                      </ul>
                    </body></html>
                    """
                )
            )
        }

        if absolute.contains("tid=26") {
            let body = absolute.contains("authorid=42")
                ? """
                <html><body>
                  <div id="pid2601">
                    <div class="message">episode 16<br>正文</div>
                    <div id="ratelog_2601">
                      <ul class="post_box cl">
                        <li class="flex-box mli p0">
                          <div>参与人数</div><div>积分</div><div>理由</div>
                        </li>
                        <li class="flex-box mli p0">
                          <div><a>读者甲</a></div><div> + 2</div><div>有效评分理由</div>
                        </li>
                        <li class="flex-box mli p0">
                          <div><a href="forum.php?mod=misc&amp;action=viewratings&amp;tid=26&amp;pid=2601&amp;mobile=2" title="查看全部评分">查看全部评分</a></div>
                        </li>
                      </ul>
                    </div>
                  </div>
                </body></html>
                """
                : """
                <html><body>
                  <div id="pid9999"><div class="message">普通第 2 页没有目标楼层</div></div>
                </body></html>
                """
            return .response(StubURLProtocolResponse(statusCode: 200, body: body))
        }

        if absolute.contains("tid=27") {
            let body = absolute.contains("authorid=42")
                ? """
                <html><body>
                  <div class="plc cl" id="pid2701">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=42&mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                  <div class="plc cl" id="pid2703">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=42&mobile=2">楼主</a></li></ul>
                    <div class="message">第二章<br>正文</div>
                  </div>
                </body></html>
                """
                : """
                <html><body>
                  <div class="plc cl" id="pid2701">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=42&mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                  <div class="plc cl" id="pid2702">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=77&mobile=2">读者甲</a></li></ul>
                    <div class="message">楼间回复</div>
                  </div>
                  <div class="plc cl" id="pid2703">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=42&mobile=2">楼主</a></li></ul>
                    <div class="message">第二章<br>正文</div>
                  </div>
                </body></html>
                """
            return .response(StubURLProtocolResponse(statusCode: 200, body: body))
        }

        if absolute.contains("tid=28") || absolute.contains("ptid=28") {
            if !absolute.contains("authorid=42") {
                tid28UnfilteredCachePolicy = request.cachePolicy
            }
            let body = absolute.contains("authorid=42")
                ? """
                <html><body>
                  <div class="plc cl" id="pid2801">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=42&mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                </body></html>
                """
                : """
                <html><body>
                  <div class="plc cl" id="pid2801">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=42&mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                  <div class="plc cl" id="pid2802">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=77&mobile=2">读者甲</a></li></ul>
                    <div class="message">楼间回复</div>
                  </div>
                </body></html>
                """
            return .response(StubURLProtocolResponse(statusCode: 200, body: body))
        }

        if absolute.contains("tid=29") || absolute.contains("ptid=29") {
            let body: String
            if absolute.contains("authorid=42") {
                body = """
                <html><body>
                  <div class="plc cl" id="pid2901">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=42&mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                </body></html>
                """
            } else if absolute.contains("mod=redirect"), absolute.contains("pid=2901") {
                body = """
                <html><body>
                  <div class="plc cl" id="pid2901">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=42&mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                  <div class="plc cl" id="pid2902">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&uid=77&mobile=2">读者甲</a></li></ul>
                    <div class="message">真实全帖页回复</div>
                  </div>
                  <div class="pg"><strong>4</strong><a href="forum.php?mod=viewthread&amp;tid=29&amp;page=5&amp;mobile=2">5</a></div>
                </body></html>
                """
            } else {
                body = """
                <html><body>
                  <div class="plc cl" id="pid9999">
                    <div class="message">错误全帖页</div>
                  </div>
                </body></html>
                """
            }
            return .response(StubURLProtocolResponse(statusCode: 200, body: body))
        }

        if absolute.contains("tid=30") {
            return .response(
                StubURLProtocolResponse(
                    statusCode: 200,
                    body: threadPageHTML(postID: "3001", body: "新 schema 缓存刷新正文")
                )
            )
        }

        if absolute.contains("tid=31") {
            return .error(URLError(.notConnectedToInternet))
        }

        return .error(URLError(.badServerResponse))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let output = Self.handler?(request)
        guard let output else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch output {
        case let .response(response):
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Test func threadRoutePreservesAuthorIDFromExistingURL() async throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123&page=1&authorid=77&mobile=2"))
    let built = YamiboRoute.thread(url: url, page: 2, authorID: nil).url.absoluteString
    #expect(built.contains("authorid=77"))
    #expect(built.contains("page=2"))
}

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

@Test func chapterTitleNormalizerPreservesNonEmptyFirstLines() async throws {
    #expect(NovelChapterTitleNormalizer.normalize("第1话 恋爱的开始") == "第1话 恋爱的开始")
    #expect(NovelChapterTitleNormalizer.normalize("後記") == "後記")
    #expect(NovelChapterTitleNormalizer.normalize("感谢翻译，收藏一波") == "感谢翻译，收藏一波")
    #expect(NovelChapterTitleNormalizer.normalize("本帖最后由 xxx 于 2025-1-1 编辑") == "本帖最后由 xxx 于 2025-1-1 编辑")
}

@Test func readerTextTransformerConvertsTraditionalAndSimplified() async throws {
    #expect(NovelTextTransformer.transform("戀上朋友的妹妹了 後記", mode: .simplified) == "恋上朋友的妹妹了 后记")
    #expect(NovelTextTransformer.transform("恋上朋友的妹妹了 后记", mode: .traditional) == "戀上朋友的妹妹了 後記")
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

@Test func repositoryTreatsLoginFavoritesPageAsNotAuthenticated() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = FavoriteRepository(
        client: YamiboClient(session: session, cookie: "sid=1; favorite-delete-success=1", userAgent: "Test-UA")
    )

    await #expect(throws: YamiboError.notAuthenticated) {
        _ = try await repository.fetchFavorites()
    }
}

#if canImport(UIKit)
@Test func novelTextLayoutProducesChaptersForBothModes() async throws {
    let document = NovelReaderProjection(
        threadID: "1",
        view: 1,
        maxView: 2,
        segments: [
            .text(String(repeating: "第一章内容。", count: 80), chapterTitle: "第一章"),
            .text(String(repeating: "第二章内容。", count: 80), chapterTitle: "第二章")
        ]
    )

    let paged = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 320, height: 568)
    )
    #expect(paged.viewportIndex.surfaces.count >= 2)
    #expect(paged.viewportIndex.chapters.count == 2)
    #expect(paged.viewportIndex.chapters.first?.title == "第一章")
    #expect(paged.viewportIndex.chapters.last?.title == "第二章")
    #expect((paged.viewportIndex.chapters.last?.startSurfaceOrdinal ?? 0) > 0)

    let vertical = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: NovelReaderLayout(width: 320, height: 568)
    )
    #expect(vertical.viewportIndex.surfaces.count >= 2)
    #expect(vertical.viewportIndex.chapters.first?.title == "第一章")
    #expect(vertical.viewportIndex.chapters.last?.title == "第二章")
}

@Test func novelTextLayoutFiltersAuthorRepliesToOthersWhenSettingIsDisabled() throws {
    let document = NovelReaderProjection(
        threadID: "188",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "第一章 正文。", count: 40), chapterTitle: "第一章"),
            .text(String(repeating: "读者甲 发表于 2026-5-1\n楼主回复。", count: 12), chapterTitle: "读者甲 发表于 2026-5-1"),
            .text(String(repeating: "第二章 正文。", count: 40), chapterTitle: "第二章"),
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "301"),
            NovelReaderSegmentSource(ownerPostID: "302", isAuthorReplyToOther: true),
            NovelReaderSegmentSource(ownerPostID: "303"),
        ]
    )
    let layout = NovelReaderLayout(width: 320, height: 568)
    let visible = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: layout
    )
    let hidden = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false, readingMode: .vertical),
        layout: layout
    )

    let visibleSegmentIndexes = Set(visible.viewportIndex.surfaces.flatMap { $0.ranges.map(\.segmentIndex) })
    let hiddenSegmentIndexes = Set(hidden.viewportIndex.surfaces.flatMap { $0.ranges.map(\.segmentIndex) })

    #expect(visibleSegmentIndexes.contains(1))
    #expect(!hiddenSegmentIndexes.contains(1))
    #expect(hidden.viewportIndex.chapters.map(\.title) == ["第一章", "第二章"])
}

@Test func novelTextLayoutRendersImageOnlySurfaceWhenAllTextOnPageIsHiddenByAuthorReplyFilter() throws {
    let document = NovelReaderProjection(
        threadID: "189",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "读者回复正文。", count: 20), chapterTitle: "读者回复"),
            .image(URL(string: "https://example.com/only-image.jpg")!, chapterTitle: "读者回复"),
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "701", isAuthorReplyToOther: true),
            NovelReaderSegmentSource(ownerPostID: "702"),
        ]
    )

    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false, readingMode: .vertical),
        layout: NovelReaderLayout(width: 320, height: 568)
    )

    #expect(result.viewportIndex.surfaces.allSatisfy { $0.ranges.isEmpty })
    #expect(result.viewportIndex.surfaces.contains { !$0.externalBlocks.isEmpty })
}
#endif

@Test func novelChapterDirectoryExtractorMatchesReaderPreviewDirectoryRules() throws {
    let document = NovelReaderProjection(
        threadID: "99",
        view: 2,
        maxView: 3,
        resolvedAuthorID: "42",
        segments: [
            .text("第一章\n开头", chapterTitle: "第一章"),
            .text("第一章续文", chapterTitle: "第一章"),
            .image(try #require(URL(string: "https://example.com/1.jpg")), chapterTitle: "第一章"),
            .text("同名章\n正文", chapterTitle: "同名章"),
            .text("同名章\n另一处正文", chapterTitle: "同名章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "1001"),
            NovelReaderSegmentSource(ownerPostID: "1001"),
            NovelReaderSegmentSource(ownerPostID: "1001"),
            NovelReaderSegmentSource(ownerPostID: "1002"),
            NovelReaderSegmentSource(ownerPostID: "1003")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "post:1001#chapter:0", textID: "post:1001#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:1001#chapter:0", textID: "post:1001#chapter:0#text:1"),
            novelReaderImageSemantics(chapterID: "post:1001#chapter:0"),
            novelReaderTextSemantics(chapterID: "post:1002#chapter:0", textID: "post:1002#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:1003#chapter:0", textID: "post:1003#chapter:0#text:0")
        ]
    )

    let entries = NovelChapterDirectoryExtractor.entries(
        from: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical)
    )

    #expect(entries.map(\.chapter.title) == ["第一章", "同名章", "同名章"])
    #expect(entries.map(\.chapter.ordinal) == [0, 1, 2])
    #expect(entries.map(\.chapter.startIndex) == [0, 1, 2])
    #expect(entries.map(\.ownerPostID) == ["1001", "1002", "1003"])
    #expect(entries[0].anchor?.resumePoint.view == 2)
    #expect(entries[0].anchor?.resumePoint.authorID == "42")
    #expect(entries[0].anchor?.resumePoint.chapterIdentity?.rawValue == "post:1001#chapter:0")
    #expect(entries[0].anchor?.resumePoint.textSegmentIdentity?.rawValue == "post:1001#chapter:0#text:0")
    #expect(entries[0].anchor?.resumePoint.chapterTitle == "第一章")
    #expect(entries[0].anchor?.resumePoint.readingModeHint == .vertical)
}

@Test func novelChapterDirectoryExtractorUsesReaderAuthorReplyVisibilitySetting() throws {
    let document = NovelReaderProjection(
        threadID: "100",
        view: 1,
        maxView: 1,
        resolvedAuthorID: "42",
        segments: [
            .text("第一章\n正文", chapterTitle: "第一章"),
            .text("作者回复\n正文", chapterTitle: "作者回复"),
            .text("第二章\n正文", chapterTitle: "第二章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "1001"),
            NovelReaderSegmentSource(ownerPostID: "1002", isAuthorReplyToOther: true),
            NovelReaderSegmentSource(ownerPostID: "1003")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "post:1001#chapter:0", textID: "post:1001#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:1002#chapter:0", textID: "post:1002#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:1003#chapter:0", textID: "post:1003#chapter:0#text:0")
        ]
    )

    let visible = NovelChapterDirectoryExtractor.entries(
        from: document,
        settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: true)
    )
    let hidden = NovelChapterDirectoryExtractor.entries(
        from: document,
        settings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false)
    )

    #expect(visible.map(\.chapter.title) == ["第一章", "作者回复", "第二章"])
    #expect(hidden.map(\.chapter.title) == ["第一章", "第二章"])
}

@Test func readerContainerLayoutComputesReadableFrameFromSafeAreaAndChrome() async throws {
    let layout = NovelReaderLayout(
        containerSize: CGSize(width: 390, height: 844),
        safeAreaInsets: NovelReaderLayoutInsets(top: 59, bottom: 34),
        contentInsets: NovelReaderLayoutInsets(top: 0, leading: 20, bottom: 24, trailing: 20),
        chromeInsets: NovelReaderLayoutInsets(top: 72, bottom: 96),
        readingMode: .paged
    )

    #expect(layout.readableFrame.minX == 20)
    #expect(layout.readableFrame.minY == 131)
    #expect(layout.readableFrame.width == 350)
    #expect(layout.readableFrame.height == 559)
}

@Test func readerContainerLayoutProjectsLandscapeSpreadToSingleNovelTextBox() throws {
    let layout = NovelReaderLayout(
        containerSize: CGSize(width: 1024, height: 768),
        contentInsets: NovelReaderLayoutInsets(leading: 16, trailing: 16),
        readingMode: .paged
    )
    let settings = NovelReaderAppearanceSettings(
        showsTwoPagesInLandscapeOnPad: true,
        readingMode: .paged
    )

    let projected = layout.novelTextBoxLayout(
        settings: settings,
        usesPadPresentation: true
    )

    #expect(layout.readableFrame.width == 992)
    #expect(projected.width == 512)
    #expect(projected.readableFrame.width == 480)
    #expect(
        layout.novelTextBoxLayout(settings: settings, usesPadPresentation: false) == layout
    )
    #expect(
        layout.novelTextBoxLayout(
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            usesPadPresentation: true
        ) == layout
    )
}

#if canImport(UIKit)
@Test func novelTextLayoutProducesPagedAndVerticalPagesAtModuleSeam() throws {
    let text = String(repeating: "这是用于模块边界测试的正文。", count: 120)
    let document = NovelReaderProjection(
        threadID: "58",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    let paged = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 320, height: 568)
    )
    let vertical = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: NovelReaderLayout(width: 320, height: 568)
    )

    #expect(!paged.viewportIndex.surfaces.isEmpty)
    #expect(!vertical.viewportIndex.surfaces.isEmpty)
    #expect(paged.viewportIndex.surfaces.first?.ranges.first?.startOffset == 0)
    #expect(paged.viewportIndex.surfaces.last?.ranges.last?.endOffset == text.count)
    #expect(vertical.viewportIndex.surfaces.first?.ranges.first?.startOffset == 0)
    #expect(vertical.viewportIndex.surfaces.last?.ranges.last?.endOffset == text.count)
    #expect(paged.viewportIndex.chapters.first?.title == "第一章")
    #expect(vertical.viewportIndex.chapters.first?.title == "第一章")
    #expect(
        NovelTextPreviewLayout.textFits(
            String(text.prefix(80)),
            chapterTitle: "第一章",
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568)
        )
    )
}
#endif

@Test func novelTextLayoutAssemblesDocumentPagesChaptersImagesAndViewportIndex() async throws {
    let imageURL = try #require(URL(string: "https://example.com/image.jpg"))
    let document = NovelReaderProjection(
        threadID: "99",
        view: 1,
        maxView: 1,
        segments: [
            .text("开头", chapterTitle: "第一章"),
            .text("继续", chapterTitle: "第一章"),
            .image(imageURL, chapterTitle: "第一章"),
            .text("第二章正文", chapterTitle: "第二章")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-0"),
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-1"),
            novelReaderImageSemantics(chapterID: "chapter-1"),
            novelReaderTextSemantics(chapterID: "chapter-2", textID: "chapter-2-text-0")
        ]
    )

    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    #expect(pagination.viewportIndex.surfaces.count == 3)
    #expect(pagination.viewportIndex.chapters.map(\.title) == ["第一章", "第二章"])
    #expect(pagination.viewportIndex.chapters.map(\.startSurfaceOrdinal) == [0, 2])
    #expect(pagination.viewportIndex.surfaces[0].externalBlocks.isEmpty)
    #expect(pagination.viewportIndex.surfaces[0].ranges == [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 2),
        NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 2)
    ])
    #expect(pagination.viewportIndex.surfaces[1].externalBlocks.map(\.url) == [imageURL])
    #expect(pagination.viewportIndex.surfaces[1].externalBlocks.map(\.chapterTitle) == ["第一章"])
    #expect(pagination.viewportIndex.surfaces[2].ranges.first?.segmentIndex == 3)
    #expect(pagination.viewportIndex.surfaces[2].externalBlocks.isEmpty)
    #expect(pagination.viewportIndex.surfaces[2].ranges == [
        NovelRenderedTextRange(segmentIndex: 3, startOffset: 0, endOffset: 5)
    ])
}

@Test func novelTextLayoutGroupsSameTitleChaptersBySemanticIdentity() throws {
    let document = NovelReaderProjection(
        threadID: "100",
        view: 1,
        maxView: 1,
        segments: [
            .text("同名章\n第一处。", chapterTitle: "同名章"),
            .text("同名章\n第二处。", chapterTitle: "同名章")
        ],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-a"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-a"),
                chapterTitleRange: NovelCharacterRange(location: 0, length: "同名章".count)
            ),
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-b"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-b"),
                chapterTitleRange: NovelCharacterRange(location: 0, length: "同名章".count)
            )
        ]
    )

    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    #expect(pagination.viewportIndex.chapters.map(\.title) == ["同名章", "同名章"])
    #expect(pagination.viewportIndex.chapters.map(\.startSurfaceOrdinal) == [0, 1])
    #expect(pagination.viewportIndex.surfaces.map(\.chapterOrdinal) == [0, 1])
}

@Test func novelTextLayoutPublishesNovelTextViewportIndexForRenderedPages() async throws {
    let document = NovelReaderProjection(
        threadID: "100",
        view: 2,
        maxView: 3,
        segments: [
            .text("第一章前半", chapterTitle: "第一章"),
            .text("第一章后半", chapterTitle: "第一章"),
            .text("第二章正文", chapterTitle: "第二章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "post-1"),
            NovelReaderSegmentSource(ownerPostID: "post-1"),
            NovelReaderSegmentSource(ownerPostID: "post-2")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "post:post-1#chapter:0", textID: "post:post-1#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:post-1#chapter:0", textID: "post:post-1#chapter:0#text:1"),
            novelReaderTextSemantics(chapterID: "post:post-2#chapter:0", textID: "post:post-2#chapter:0#text:0")
        ]
    )

    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    let index = pagination.viewportIndex
    #expect(index.documentView == 2)
    #expect(index.readingMode == .paged)
    #expect(index.surfaces.map(\.surfaceOrdinal) == [0, 1])
    #expect(index.surfaces[0].ranges == [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 5),
        NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 5)
    ])
    #expect(index.surfaces[1].ranges == [
        NovelRenderedTextRange(segmentIndex: 2, startOffset: 0, endOffset: 5)
    ])
    #expect(index.chapters.map(\.title) == ["第一章", "第二章"])
    #expect(index.chapters.map(\.startSurfaceOrdinal) == [0, 1])
    let firstChapterSecondText = try #require(document.semantics(forSegmentIndex: 1)?.textSegmentIdentity)
    let secondChapterText = try #require(document.semantics(forSegmentIndex: 2)?.textSegmentIdentity)
    #expect(index.position(for: firstChapterSecondText, displayedTextOffset: 3, in: document)?.surfaceOrdinal == 0)
    #expect(index.position(for: secondChapterText, displayedTextOffset: 2, in: document)?.chapterCommentTarget?.ownerPostID == "post-2")
}

@Test func novelTextLayoutPublishesNovelTextViewportIndexForVerticalChunks() async throws {
    let document = NovelReaderProjection(
        threadID: "101",
        view: 1,
        maxView: 1,
        segments: [
            .text("纵向阅读第一段", chapterTitle: "第一章")
        ]
    )

    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: NovelReaderLayout(width: 390, height: 844, readingMode: .vertical),
        viewportSurfaceLayout: { _, _, _ in
            [
                NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: 4),
                NovelTextViewportDocumentSurfaceRange(startOffset: 4, endOffset: 7)
            ]
        }
    )

    let index = pagination.viewportIndex
    #expect(index.readingMode == .vertical)
    #expect(index.surfaces.map(\.ranges) == [
        [NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 4)],
        [NovelRenderedTextRange(segmentIndex: 0, startOffset: 4, endOffset: 7)]
    ])
    let textSegmentIdentity = try #require(document.semantics(forSegmentIndex: 0)?.textSegmentIdentity)
    #expect(index.position(for: textSegmentIdentity, displayedTextOffset: 5, in: document)?.surfaceOrdinal == 1)
}

@Test func novelTextLayoutBuildsCurrentWebpageViewportContextBeforePublishingReadablePages() async throws {
    let imageURL = try #require(URL(string: "https://example.com/inline.jpg"))
    let document = NovelReaderProjection(
        threadID: "146",
        view: 3,
        maxView: 4,
        segments: [
            .text("第一章正文", chapterTitle: "第一章"),
            .text("第二段正文", chapterTitle: "第一章"),
            .image(imageURL, chapterTitle: "第一章"),
            .text("第二章正文", chapterTitle: "第二章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "post-1"),
            NovelReaderSegmentSource(ownerPostID: "post-1"),
            NovelReaderSegmentSource(ownerPostID: "post-image"),
            NovelReaderSegmentSource(ownerPostID: "post-2")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "post:post-1#chapter:0", textID: "post:post-1#chapter:0#text:0"),
            novelReaderTextSemantics(chapterID: "post:post-1#chapter:0", textID: "post:post-1#chapter:0#text:1"),
            novelReaderImageSemantics(chapterID: "post:post-1#chapter:0"),
            novelReaderTextSemantics(chapterID: "post:post-2#chapter:0", textID: "post:post-2#chapter:0#text:0")
        ],
        fetchedAt: Date(timeIntervalSince1970: 146)
    )

    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    let context = pagination.viewportContext
    let index = pagination.viewportIndex

    #expect(context.identity.documentView == 3)
    #expect(context.identity.threadID == document.threadID)
    #expect(context.identity.fetchedAt == document.fetchedAt)
    #expect(context.document.text == "第一章正文\n\n第二段正文\n\n第二章正文")
    #expect(context.document.textRangesBySegment[0] == NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 5))
    #expect(context.document.textRangesBySegment[1] == NovelRenderedTextRange(segmentIndex: 1, startOffset: 7, endOffset: 12))
    #expect(context.document.textRangesBySegment[3] == NovelRenderedTextRange(segmentIndex: 3, startOffset: 14, endOffset: 19))
    #expect(context.document.insertedSeparatorRanges == [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 5, endOffset: 7),
        NovelRenderedTextRange(segmentIndex: 1, startOffset: 12, endOffset: 14)
    ])
    #expect(context.externalBlocks.map(\.chapterIdentity) == [
        NovelChapterIdentity(rawValue: "post:post-1#chapter:0")
    ])
    #expect(context.diagnostics.indexBuildCount == 1)
    #expect(context.diagnostics.visibleLayoutPassCount == 0)
    #expect(index.surfaces.flatMap(\.ranges).map(\.segmentIndex) == [0, 1, 3])
}

@Test func novelTextLayoutResultIsViewportFirstWithoutRenderedPageCompatibility() async throws {
    let document = NovelReaderProjection(
        threadID: "163",
        view: 1,
        maxView: 1,
        segments: [
            .text("第一段", chapterTitle: "第一章"),
            .text("第二段", chapterTitle: "第一章")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-0"),
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-1")
        ]
    )

    let layoutResult = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    #expect(layoutResult.viewportContext.document.text == "第一段\n\n第二段")
    #expect(layoutResult.viewportIndex.surfaces.map(\.ranges) == [
        [
            NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 3),
            NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 3)
        ]
    ])
    #expect(layoutResult.viewportIndex.surfaces.map(\.surfaceOrdinal) == [0])
    #expect(layoutResult.viewportIndex.surfaces.first?.externalBlocks.isEmpty == true)
}

@Test func novelTextLayoutCreatesAndUpdatesNovelTextViewportThroughHighLevelInterface() throws {
    let document = NovelReaderProjection(
        threadID: "62",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "High level Novel Text Viewport creation should publish exact ranges. ", count: 8), chapterTitle: "第一章")
        ]
    )
    let compactLayout = NovelReaderLayout(width: 320, height: 568)
    let expandedLayout = NovelReaderLayout(width: 414, height: 896)

    let created = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: compactLayout
    )
    let updated = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: expandedLayout
    )

    #expect(created.viewportContext.identity.layout == compactLayout)
    #expect(created.viewportIndex.readingMode == .paged)
    #expect(updated.viewportContext.identity.layout == expandedLayout)
    #expect(updated.viewportIndex.readingMode == .vertical)
    #expect(updated.viewportContext.document == created.viewportContext.document)
}

#if canImport(UIKit)
@Test func novelTextViewportUpdatePublishesPageLayoutMetrics() throws {
    let repetitionCount = 400
    let layout = NovelReaderLayout(width: 320, height: 568, readingMode: .vertical)
    let document = NovelReaderProjection(
        threadID: "63",
        view: 1,
        maxView: 1,
        segments: [
            .text(
                String(repeating: "Viewport update metrics should size native novel text. ", count: repetitionCount),
                chapterTitle: "第一章"
            )
        ]
    )

    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .vertical),
        layout: layout
    )

    #expect(result.viewportIndex.surfaces.count > 2)
    for page in result.viewportIndex.surfaces {
        let geometry = try #require(page.frozenGeometry)
        let textHeight = try #require(result.layoutMetrics.surfaceMetrics[page.surfaceOrdinal]?.textHeight)
        #expect(textHeight == geometry.clipHeight)
        #expect(textHeight > 0)
        #expect(textHeight <= layout.readableFrame.height)
    }
}
#endif

@Test func novelTextViewportFrozenGeometryUsesSurfaceClipHeight() {
    let clipRect = CGRect(x: 0, y: 2_400, width: 320, height: 780)

    #expect(
        NovelTextViewportFrozenGeometry.surfaceContentHeight(forDocumentClipRect: clipRect) == 780
    )
}

@Test func novelTextLayoutConvertsDisplayOffsetsUsingSwiftCharacterRanges() throws {
    let document = NovelReaderProjection(
        threadID: "412",
        view: 3,
        maxView: 3,
        segments: [
            .text("第一段文本", chapterTitle: "第一章"),
            .text("第二段文本", chapterTitle: "第一章"),
            .text("第三段文本", chapterTitle: "第一章")
        ]
    )
    let ranges = [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 10, endOffset: 12),
        NovelRenderedTextRange(segmentIndex: 2, startOffset: 40, endOffset: 43)
    ]

    let sample = try #require(
        NovelTextLayout.viewportSample(
            displayOffset: 5,
            ranges: ranges,
            document: document,
            surfaceOrdinal: 7
        )
    )
    let textSegmentIdentity = try #require(document.semantics(forSegmentIndex: 2)?.textSegmentIdentity)
    let displayOffset = try #require(
        NovelTextLayout.displayOffset(
            for: textSegmentIdentity,
            displayedTextOffset: 41,
            in: document,
            ranges: ranges
        )
    )

    #expect(sample.textSegmentIdentity == textSegmentIdentity)
    #expect(sample.displayedTextOffset == 41)
    #expect(displayOffset == 5)
}

@Test func novelTextViewportIndexPagePublishesImageExternalBlockPlacement() async throws {
    let imageURL = try #require(URL(string: "https://example.com/viewport-image.jpg"))
    let document = NovelReaderProjection(
        threadID: "164",
        view: 2,
        maxView: 2,
        segments: [
            .text("第一章正文", chapterTitle: "第一章"),
            .image(imageURL, chapterTitle: "第一章")
        ],
        segmentSources: [
            NovelReaderSegmentSource(ownerPostID: "text-post"),
            NovelReaderSegmentSource(ownerPostID: "image-post")
        ]
    )

    let layoutResult = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    let imagePage = try #require(layoutResult.viewportIndex.surfaces.first { !$0.externalBlocks.isEmpty })
    #expect(imagePage.ranges.isEmpty)
    #expect(imagePage.externalBlocks == [
        NovelTextViewportExternalBlock(
            chapterIdentity: document.semantics(forSegmentIndex: 1)?.chapterIdentity,
            url: imageURL,
            chapterOrdinal: 0,
            chapterTitle: "第一章",
            frozenFrame: NovelTextViewportExternalBlockFrame(
                x: 0,
                y: 0,
                width: 390,
                height: 253.5
            ),
            chapterCommentTarget: ReaderChapterCommentTarget(
                threadID: document.threadID,
                view: 2,
                ownerPostID: "image-post",
                title: "第一章"
            )
        )
    ])
    #expect(layoutResult.viewportIndex.surfaces[imagePage.surfaceOrdinal].externalBlocks.map(\.url) == [imageURL])
}

@Test func novelTextLayoutDerivesPageRangesFromComposedViewportDocument() async throws {
    let document = NovelReaderProjection(
        threadID: "165",
        view: 1,
        maxView: 1,
        segments: [
            .text("第一段", chapterTitle: "第一章"),
            .text("第二段", chapterTitle: "第一章")
        ],
        segmentSemantics: [
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-0"),
            novelReaderTextSemantics(chapterID: "chapter-1", textID: "chapter-1-text-1")
        ]
    )
    let layoutInputCount = LockedCounter()

    let layoutResult = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: { context, _, _ in
            layoutInputCount.increment()
            #expect(context.document.text == "第一段\n\n第二段")
            return [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        }
    )

    #expect(layoutInputCount.value == 1)
    #expect(layoutResult.viewportContext.document.insertedSeparatorRanges == [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 3, endOffset: 5)
    ])
    #expect(layoutResult.viewportIndex.surfaces.map(\.ranges) == [
        [
            NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 3),
            NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 3)
        ]
    ])
    let secondSegmentIdentity = try #require(document.semantics(forSegmentIndex: 1)?.textSegmentIdentity)
    #expect(layoutResult.viewportIndex.position(for: secondSegmentIdentity, displayedTextOffset: 1, in: document)?.surfaceOrdinal == 0)
}

@Test func novelTextLayoutPreservesViewportPageRangesWithoutDisplayValueMaterialization() async throws {
    let settings = NovelReaderAppearanceSettings(
        fontScale: 1.25,
        fontFamily: .systemSerif,
        lineHeightScale: 1.7,
        characterSpacingScale: 0.12,
        usesJustifiedText: true,
        indentsParagraphFirstLine: true,
        readingMode: .paged
    )
    let context = NovelTextViewportContext(
        identity: NovelTextViewportIdentity(
            threadID: "159",
            documentView: 2,
            maxView: 3,
            fetchedAt: Date(timeIntervalSince1970: 159),
            appearance: settings,
            layout: NovelReaderLayout(width: 390, height: 844)
        ),
        document: NovelTextViewportDocument(
            text: "第一段正文很长\n\n第二段正文继续",
            textRangesBySegment: [
                0: NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 7),
                1: NovelRenderedTextRange(segmentIndex: 1, startOffset: 9, endOffset: 16)
            ],
            insertedSeparatorRanges: [
                NovelRenderedTextRange(segmentIndex: 0, startOffset: 7, endOffset: 9)
            ]
        ),
        externalBlocks: [],
        diagnostics: NovelTextViewportDiagnostics(indexBuildCount: 1)
    )
    let ranges = [
        NovelRenderedTextRange(segmentIndex: 0, startOffset: 2, endOffset: 7),
        NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 4)
    ]
    let viewportPage = NovelTextViewportIndexSurface(
        surfaceOrdinal: 4,
        documentView: 2,
        chapterOrdinal: 0,
        chapterTitle: "第一章",
        ranges: ranges
    )

    let result = NovelTextLayoutResult(
        viewportContext: context,
        viewportIndex: NovelTextViewportIndex(
            documentView: 2,
            readingMode: .paged,
            surfaces: [viewportPage],
            chapters: []
        )
    )

    #expect(result.viewportIndex.surfaces.first?.ranges == ranges)
    #expect(result.viewportIndex.surfaces.first?.chapterTitle == "第一章")
    #expect(result.viewportContext.identity.appearance == settings)
}

@Test func novelTextLayoutDoesNotExposeDisplayValueForMissingViewportPageRange() async throws {
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let context = NovelTextViewportContext(
        identity: NovelTextViewportIdentity(
            threadID: "159-missing",
            documentView: 1,
            maxView: 1,
            fetchedAt: Date(timeIntervalSince1970: 159),
            appearance: settings,
            layout: NovelReaderLayout(width: 390, height: 844)
        ),
        document: NovelTextViewportDocument(
            text: "第一段正文",
            textRangesBySegment: [
                0: NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 5)
            ],
            insertedSeparatorRanges: []
        ),
        externalBlocks: [],
        diagnostics: NovelTextViewportDiagnostics(indexBuildCount: 1)
    )
    let viewportPage = NovelTextViewportIndexSurface(
        surfaceOrdinal: 0,
        documentView: 1,
        chapterOrdinal: nil,
        chapterTitle: nil,
        ranges: [NovelRenderedTextRange(segmentIndex: 9, startOffset: 0, endOffset: 2)]
    )

    let result = NovelTextLayoutResult(
        viewportContext: context,
        viewportIndex: NovelTextViewportIndex(
            documentView: 1,
            readingMode: .paged,
            surfaces: [viewportPage],
            chapters: []
        )
    )
    #expect(result.viewportIndex.surfaces.first?.ranges.first?.segmentIndex == 9)
}

@Test func novelTextLayoutDoesNotReuseCachedNovelTextViewportIndexForMatchingInputs() async throws {
    let document = NovelReaderProjection(
        threadID: "102",
        view: 1,
        maxView: 1,
        segments: [.text("重复打开时应该复用精确索引", chapterTitle: "第一章")],
        fetchedAt: Date(timeIntervalSince1970: 1)
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 390, height: 844)
    let layoutPassCount = LockedCounter()
    let viewportSurfaceLayout: NovelTextViewportSurfaceLayout = { context, _, _ in
        layoutPassCount.increment()
        return [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
    }

    let first = try NovelTextLayout.layout(
        document: document,
        settings: settings,
        layout: layout,
        viewportSurfaceLayout: viewportSurfaceLayout,
    )
    let second = try NovelTextLayout.layout(
        document: document,
        settings: settings,
        layout: layout,
        viewportSurfaceLayout: viewportSurfaceLayout,
    )

    #expect(layoutPassCount.value == 2)
    #expect(first.viewportIndex == second.viewportIndex)
    #expect(first.viewportIndex.surfaces == second.viewportIndex.surfaces)
}

@Test func novelTextLayoutInvalidatesCachedNovelTextViewportIndexForSettingsAndLayoutChanges() async throws {
    let document = NovelReaderProjection(
        threadID: "103",
        view: 1,
        maxView: 1,
        segments: [.text("设置和布局改变必须重建索引", chapterTitle: "第一章")],
        fetchedAt: Date(timeIntervalSince1970: 1)
    )
    let layoutPassCount = LockedCounter()
    let viewportSurfaceLayout: NovelTextViewportSurfaceLayout = { context, _, _ in
        layoutPassCount.increment()
        return [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
    }

    _ = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: viewportSurfaceLayout,
    )
    _ = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(fontScale: 1.2, readingMode: .paged),
        layout: NovelReaderLayout(width: 390, height: 844),
        viewportSurfaceLayout: viewportSurfaceLayout,
    )
    _ = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 320, height: 568),
        viewportSurfaceLayout: viewportSurfaceLayout,
    )

    #expect(layoutPassCount.value == 3)
}

@Test func novelTextLayoutDoesNotCacheFailedNovelTextViewportIndexBuilds() async throws {
    let document = NovelReaderProjection(
        threadID: "104",
        view: 1,
        maxView: 1,
        segments: [.text("失败的索引构建不能污染缓存", chapterTitle: "第一章")],
        fetchedAt: Date(timeIntervalSince1970: 1)
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 390, height: 844)

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            document: document,
            settings: settings,
            layout: layout,
            viewportSurfaceLayout: { _, _, _ in [] },
        )
    }

    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: settings,
        layout: layout,
        viewportSurfaceLayout: { context, _, _ in
            [NovelTextViewportDocumentSurfaceRange(startOffset: 0, endOffset: context.document.text.count)]
        },
    )

    #expect(pagination.viewportIndex.surfaces.count == 1)
}

#if canImport(UIKit)
@Test func novelTextLayoutPreservesSingleTextSegmentRanges() async throws {
    let text = String(repeating: "分页边界应来自 Novel Text Layout。", count: 100)
    let document = NovelReaderProjection(
        threadID: "58",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 320, height: 568)

    let pagination = try NovelTextLayout.layout(document: document, settings: settings, layout: layout)
    let ranges = pagination.viewportIndex.surfaces.flatMap(\.ranges)

    #expect(ranges.first?.startOffset == 0)
    #expect(ranges.last?.endOffset == text.count)
    for pair in zip(ranges, ranges.dropFirst()) {
        #expect(pair.0.endOffset <= pair.1.startOffset)
    }
    #expect(Set(ranges.map(\.segmentIndex)) == [0])
}

@Test func novelTextLayoutFreezesPagedSurfaceGeometryFromTextKitDocument() async throws {
    let text = String(repeating: "Frozen paged geometry must be committed with the surface. ", count: 160)
    let layout = NovelReaderLayout(width: 320, height: 568)
    let document = NovelReaderProjection(
        threadID: "189",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: layout
    )
    let textPages = result.viewportIndex.surfaces.filter { !$0.ranges.isEmpty }

    #expect(textPages.count > 1)
    for page in textPages {
        let geometry = try #require(page.frozenGeometry)
        #expect(geometry.documentStartOffset < geometry.documentEndOffset)
        #expect(geometry.clipHeight > 0)
        #expect(geometry.documentClipMinY.isFinite)
        #expect(geometry.documentClipMaxY.isFinite)
        #expect(geometry.contentHeight >= geometry.clipHeight)
    }

    for pair in zip(textPages, textPages.dropFirst()) {
        let previous = try #require(pair.0.frozenGeometry)
        let next = try #require(pair.1.frozenGeometry)
        #expect(previous.documentEndOffset <= next.documentStartOffset)
        #expect(previous.documentClipMaxY <= next.documentClipMinY)
    }
}
#endif

@Test func novelTextLayoutAcceptsRematerializedGeometryWhenPageStartsAfterTrimmedWhitespace() async throws {
#if canImport(UIKit)
    let paragraph = "    页首空白不应使 TextKit 重新物化后的片段几何校验失败。"
    let text = Array(repeating: paragraph, count: 180).joined(separator: "\n\n")
    let document = NovelReaderProjection(
        threadID: "190",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged),
        layout: NovelReaderLayout(width: 320, height: 568)
    )

    #expect(result.viewportIndex.surfaces.count > 1)
    #expect(result.viewportIndex.surfaces.allSatisfy { $0.frozenGeometry != nil })
#endif
}

@Test func novelTextSurfaceFragmentPartitionerMovesCrossingLineToNextSurface() throws {
    let surfaces = NovelTextSurfaceFragmentPartitioner.partition(
        [
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 0, length: 10),
                rect: CGRect(x: 0, y: 0, width: 200, height: 35)
            ),
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 10, length: 10),
                rect: CGRect(x: 0, y: 40, width: 200, height: 35)
            ),
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 20, length: 10),
                rect: CGRect(x: 0, y: 80, width: 200, height: 35)
            )
        ],
        surfaceHeight: 100
    )

    #expect(surfaces.count == 2)
    #expect(surfaces.allSatisfy { $0.clipRect.height <= 100 })
    let firstSurface = try #require(surfaces.first)
    let secondSurface = try #require(surfaces.dropFirst().first)
    #expect(firstSurface.characterRange == NSRange(location: 0, length: 20))
    #expect(secondSurface.characterRange == NSRange(location: 20, length: 10))
}

@Test func novelTextSurfaceFragmentPartitionerIgnoresAlreadyCoveredOverlappingFragments() throws {
    let surfaces = NovelTextSurfaceFragmentPartitioner.partition(
        [
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 0, length: 10),
                rect: CGRect(x: 0, y: 0, width: 200, height: 35)
            ),
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 10, length: 10),
                rect: CGRect(x: 0, y: 40, width: 200, height: 35)
            ),
            NovelTextSurfaceLayoutFragment(
                characterRange: NSRange(location: 15, length: 5),
                rect: CGRect(x: 0, y: 80, width: 200, height: 35)
            )
        ],
        surfaceHeight: 100
    )

    #expect(surfaces.count == 1)
    #expect(try #require(surfaces.first).characterRange == NSRange(location: 0, length: 20))
}

@Test func novelTextViewportDrawingClipsToFrozenPageGeometry() {
    let clipRect = NovelTextViewportDrawingGeometry.clipRect(
        bounds: CGRect(x: 0, y: 0, width: 361, height: 669),
        surfaceOriginY: 1_000,
        documentClipMaxY: 1_629.64
    )

    #expect(clipRect.origin == .zero)
    #expect(clipRect.width == 361)
    #expect(abs(clipRect.height - 629.64) < 0.001)
    #expect(
        NovelTextViewportDrawingGeometry.clipRect(
            bounds: CGRect(x: 0, y: 0, width: 361, height: 669),
            surfaceOriginY: 1_000,
            documentClipMaxY: nil
        ) == CGRect(x: 0, y: 0, width: 361, height: 669)
    )
}

@Test func novelTextViewportDrawingAssignsFragmentsToOneSurfaceByStartOffset() {
    let surfaceRange = 102 ..< 180

    #expect(!NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
        fragmentStart: 100,
        fragmentEnd: 150,
        documentRange: surfaceRange
    ))
    #expect(NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
        fragmentStart: 102,
        fragmentEnd: 150,
        documentRange: surfaceRange
    ))
    #expect(!NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
        fragmentStart: 50,
        fragmentEnd: 102,
        documentRange: surfaceRange
    ))
    #expect(!NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
        fragmentStart: 180,
        fragmentEnd: 220,
        documentRange: surfaceRange
    ))
}

@MainActor
@Test func novelTextViewportDrawsRestoredVerticalSurfaceAfterInitialFirstPageViewport() throws {
#if canImport(UIKit)
    let text = Array(
        repeating: "围绕着王位继承权的争夺，距离那场内战的落幕已过去半个月的时间，而今天，是女王陛下的王位继承仪式。",
        count: 260
    ).joined(separator: "\n\n")
    let document = NovelReaderProjection(
        threadID: "191",
        view: 1,
        maxView: 4,
        segments: [.text(text, chapterTitle: "第六章 贵穿之物")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .vertical)
    let layout = NovelReaderLayout(width: 390, height: 844, readingMode: .vertical)
    let runtime = NovelTextViewportRuntimeOwner()
    let transaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: settings,
            layout: layout
        )
    )
    let targetSurface = try #require(transaction.result.viewportIndex.surfaces.dropFirst(9).first)
    try runtime.prepareInitialViewport(for: transaction, around: 0)
    #expect(runtime.commit(transaction))
    runtime.updateVisibleSurfaceIdentities(
        transaction.result.viewportIndex.surfaces
            .filter { abs($0.surfaceOrdinal - targetSurface.surfaceOrdinal) <= 1 }
            .map {
                NovelReaderSurfaceIdentity(
                    generation: transaction.generation,
                    ordinal: $0.surfaceOrdinal
                )
            }
    )
    let displayReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: transaction.generation,
        ordinal: targetSurface.surfaceOrdinal
    )))
    let width = 390
    let height = 844
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))

    displayReference.draw(in: context, bounds: CGRect(x: 0, y: 0, width: width, height: height))

    let upperHalfAlphaPixelCount = stride(from: 0, to: (height / 2) * bytesPerRow, by: 4).reduce(0) { count, offset in
        count + (pixels[offset + 3] > 0 ? 1 : 0)
    }
    #expect(upperHalfAlphaPixelCount > 100)

    let inkRows = (0..<height).map { y -> Bool in
        let rowStart = y * bytesPerRow
        let alphaPixels = stride(from: rowStart, to: rowStart + bytesPerRow, by: 4).reduce(0) { count, offset in
            count + (pixels[offset + 3] > 0 ? 1 : 0)
        }
        return alphaPixels > 8
    }
    let firstInkRow = try #require(inkRows.firstIndex(of: true))
    let lastInkRow = try #require(inkRows.lastIndex(of: true))
    var longestBlankBand = 0
    var currentBlankBand = 0
    for hasInk in inkRows[firstInkRow...lastInkRow] {
        if hasInk {
            longestBlankBand = max(longestBlankBand, currentBlankBand)
            currentBlankBand = 0
        } else {
            currentBlankBand += 1
        }
    }
    longestBlankBand = max(longestBlankBand, currentBlankBand)
    #expect(longestBlankBand < 220)
#endif
}

@MainActor
@Test func novelTextViewportDrawsLaterSurfaceLinesWhenLayoutFragmentStartsBeforeSurface() throws {
#if canImport(UIKit)
    let text = String(
        repeating: "库莉茜耶把听到的话认真记在心里，然后继续望向远方闪闪发亮的雪原和村庄。 ",
        count: 220
    )
    let document = NovelReaderProjection(
        threadID: "192",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "长段落")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .vertical)
    let layout = NovelReaderLayout(width: 390, height: 844, readingMode: .vertical)
    let runtime = NovelTextViewportRuntimeOwner()
    let transaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: settings,
            layout: layout
        )
    )
    let targetSurface = try #require(transaction.result.viewportIndex.surfaces.first {
        ($0.frozenGeometry?.documentStartOffset ?? 0) > 0 && !$0.ranges.isEmpty
    })
    let geometry = try #require(targetSurface.frozenGeometry)
    try runtime.prepareInitialViewport(for: transaction, around: 0)
    #expect(runtime.commit(transaction))
    runtime.updateVisibleSurfaceIdentities([
        NovelReaderSurfaceIdentity(
            generation: transaction.generation,
            ordinal: targetSurface.surfaceOrdinal
        )
    ])
    let displayReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: transaction.generation,
        ordinal: targetSurface.surfaceOrdinal
    )))
    let width = 390
    let height = max(Int(ceil(geometry.contentHeight)), 1)
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let context = try #require(CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))

    displayReference.draw(in: context, bounds: CGRect(x: 0, y: 0, width: width, height: height))

    let inkRows = (0..<height).map { y -> Bool in
        let rowStart = y * bytesPerRow
        let alphaPixels = stride(from: rowStart, to: rowStart + bytesPerRow, by: 4).reduce(0) { count, offset in
            count + (pixels[offset + 3] > 0 ? 1 : 0)
        }
        return alphaPixels > 8
    }
    let firstInkRow = try #require(inkRows.firstIndex(of: true))
    let lastInkRow = try #require(inkRows.lastIndex(of: true))

    #expect(firstInkRow < 80)
    #expect(lastInkRow > height / 2)
    #expect(height - lastInkRow - 1 < 100)
#endif
}

@Test func novelTextLayoutPagedViewportSurfaceRangeFailureDoesNotUseEstimatedFallback() async throws {
    let text = String(repeating: "TextKit 2 failure should not fall back. ", count: 40)
    let document = NovelReaderProjection(
        threadID: "65",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            viewportSurfaceLayout: { _, _, _ in [] }
        )
    }
}

@Test func novelTextLayoutPagedFailureThrowsInsteadOfPublishingFallbackPage() async throws {
    let document = NovelReaderProjection(
        threadID: "59",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "TextKit 2 failure should stop pagination. ", count: 40), chapterTitle: "第一章")
        ]
    )

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            viewportSurfaceLayout: { _, _, _ in [] }
        )
    }
}

@Test func novelTextLayoutVerticalViewportPageRangeFailureDoesNotUseEstimatedFallback() async throws {
    let text = String(repeating: "Vertical TextKit 2 failure should not fall back. ", count: 40)
    let document = NovelReaderProjection(
        threadID: "66",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "第一章")]
    )

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568),
            viewportSurfaceLayout: { _, _, _ in [] }
        )
    }
}

@Test func novelTextLayoutVerticalFailureThrowsInsteadOfPublishingFallbackPage() async throws {
    let document = NovelReaderProjection(
        threadID: "60",
        view: 1,
        maxView: 1,
        segments: [
            .text(String(repeating: "Vertical TextKit 2 failure should stop pagination. ", count: 40), chapterTitle: "第一章")
        ]
    )

    #expect(throws: NovelTextLayoutFailure.textKitIndexing) {
        _ = try NovelTextLayout.layout(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568),
            viewportSurfaceLayout: { _, _, _ in [] }
        )
    }
}

@Test func readerParagraphIndentPlannerKeepsContinuationFirstParagraphUnindentedOnly() {
    let text = "续页正文。\n\n新段落正文。\n第三段正文。"
    let ranges = NovelParagraphIndentPlanner.indentedParagraphRangesAfterFirst(in: text)
    let substrings = ranges.map { String(text[$0]) }

    #expect(substrings == ["\n\n新段落正文。", "\n第三段正文。"])
}

#if canImport(UIKit)
@Test func readerAttributedTextFactoryUsesParagraphStyleForTitleAndBody() throws {
    let pointSize = 24.0
    let attributedText = NovelAttributedTextFactory.makeAttributedText(
        text: "第一章\n第一段正文。\n\n第二段正文。",
        chapterTitle: "第一章",
        settings: NovelReaderAppearanceSettings(lineHeightScale: 1.6),
        baseFontSize: pointSize
    )
    let titleStyle = try #require(
        attributedText.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
    )
    let bodyStyle = try #require(
        attributedText.attribute(
            .paragraphStyle,
            at: "第一章\n".count,
            effectiveRange: nil
        ) as? NSParagraphStyle
    )

    // Leading is proportional to the point size (6pt at the default 22pt
    // body), scaled by the user's lineHeightScale.
    let expectedLineSpacing = pointSize * NovelAttributedTextFactory.lineSpacingRatio * 1.6
    #expect(abs(titleStyle.lineSpacing - expectedLineSpacing) < 0.001)
    #expect(abs(bodyStyle.lineSpacing - expectedLineSpacing) < 0.001)
}

@Test func novelTextSettingsPreviewSurfaceUsesAttributedParagraphSemantics() throws {
    let surface = NovelTextSettingsPreviewSurface(
        text: "第一段正文。\n\n第二段正文。",
        settings: NovelReaderAppearanceSettings(
            usesJustifiedText: true,
            indentsParagraphFirstLine: true
        )
    )
    let style = try #require(surface.diagnosticParagraphStyle(at: 0))

    #expect(style.alignment == .justified)
    #expect(style.firstLineHeadIndent == 44)
}

@Test func readerAttributedTextFactoryIndentsBodyButNotTitleOrContinuationSlices() throws {
    let pointSize = 24.0
    let settings = NovelReaderAppearanceSettings(indentsParagraphFirstLine: true)
    let paragraphStart = NovelAttributedTextFactory.makeAttributedText(
        text: "第一章\n第一段正文。",
        chapterTitle: "第一章",
        startsAtParagraphBoundary: true,
        settings: settings,
        baseFontSize: pointSize
    )
    let continuation = NovelAttributedTextFactory.makeAttributedText(
        text: "续页正文。",
        chapterTitle: "第一章",
        startsAtParagraphBoundary: false,
        settings: settings,
        baseFontSize: pointSize
    )
    let titleStyle = try #require(
        paragraphStart.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )
    let bodyStyle = try #require(
        paragraphStart.attribute(.paragraphStyle, at: "第一章\n".count, effectiveRange: nil) as? NSParagraphStyle
    )
    let continuationStyle = try #require(
        continuation.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )

    #expect(titleStyle.firstLineHeadIndent == 0)
    #expect(bodyStyle.firstLineHeadIndent == 48)
    #expect(continuationStyle.firstLineHeadIndent == 0)
}

@Test func readerAttributedTextFactoryIndentsLaterParagraphsInContinuationSlices() throws {
    let pointSize = 24.0
    let attributedText = NovelAttributedTextFactory.makeAttributedText(
        text: "续页正文。\n\n新段落正文。",
        chapterTitle: "第一章",
        startsAtParagraphBoundary: false,
        settings: NovelReaderAppearanceSettings(indentsParagraphFirstLine: true),
        baseFontSize: pointSize
    )
    let continuationStyle = try #require(
        attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )
    let newParagraphStyle = try #require(
        attributedText.attribute(.paragraphStyle, at: "续页正文。\n\n".count, effectiveRange: nil) as? NSParagraphStyle
    )

    #expect(continuationStyle.firstLineHeadIndent == 0)
    #expect(newParagraphStyle.firstLineHeadIndent == 48)
}

@Test func novelAttributedDocumentUsesPreparedSemanticRunsAndMatchesViewportText() throws {
    let document = NovelReaderProjection(
        threadID: "301",
        view: 1,
        maxView: 1,
        segments: [
            .text("第一章\n第一段正文。", chapterTitle: "第一章"),
            .text("第二段正文。", chapterTitle: nil),
        ]
    )
    let preparedInput = try NovelTextLayout.prepareInput(
        document: document,
        settings: NovelReaderAppearanceSettings(indentsParagraphFirstLine: true),
        layout: NovelReaderLayout(width: 390, height: 844)
    )
    let attributedDocument = NovelAttributedTextFactory.makeAttributedDocument(
        from: preparedInput
    )
    let titleStyle = try #require(
        attributedDocument.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )
    let bodyStyle = try #require(
        attributedDocument.attribute(
            .paragraphStyle,
            at: "第一章\n".count,
            effectiveRange: nil
        ) as? NSParagraphStyle
    )

    #expect(attributedDocument.string == preparedInput.viewportContextSeed.document.text)
    #expect(titleStyle.firstLineHeadIndent == 0)
    #expect(bodyStyle.firstLineHeadIndent > 0)
}

@Test func novelAttributedDocumentStylesChapterTitleFromSemanticRangeOnly() throws {
    let document = NovelReaderProjection(
        threadID: "303",
        view: 1,
        maxView: 1,
        segments: [
            .text("真正标题\n正文。", chapterTitle: "旧标题不应参与主文档样式")
        ],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                chapterTitleRange: NovelCharacterRange(location: 0, length: "真正标题".count)
            )
        ]
    )
    let preparedInput = try NovelTextLayout.prepareInput(
        document: document,
        settings: NovelReaderAppearanceSettings(indentsParagraphFirstLine: true),
        layout: NovelReaderLayout(width: 390, height: 844)
    )
    let attributedDocument = NovelAttributedTextFactory.makeAttributedDocument(
        from: preparedInput
    )
    let titleStyle = try #require(
        attributedDocument.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )
    let bodyStyle = try #require(
        attributedDocument.attribute(
            .paragraphStyle,
            at: "真正标题\n".count,
            effectiveRange: nil
        ) as? NSParagraphStyle
    )

    #expect(attributedDocument.string == "真正标题\n正文。")
    #expect(titleStyle.firstLineHeadIndent == 0)
    #expect(bodyStyle.firstLineHeadIndent > 0)
}

@Test func novelTextLayoutTransformsInlineBoldRangesWithDisplayedText() throws {
    let document = NovelReaderProjection(
        threadID: "304",
        view: 1,
        maxView: 1,
        segments: [.text("繁體粗體結束", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                inlineTextStyles: [
                    NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 2, length: 2))
                ]
            )
        ]
    )

    let preparedInput = try NovelTextLayout.prepareInput(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged, translationMode: .simplified),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(preparedInput.viewportContextSeed.document.text == "繁体粗体结束")
    #expect(preparedInput.annotatedSegments.first?.semantics?.inlineTextStyles == [
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 2, length: 2))
    ])
    #expect(preparedInput.viewportContextSeed.document.inlineTextStylesBySegment[0] == [
        NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 2, length: 2))
    ])
}

@Test func novelTextLayoutTransformsQuoteRangesAndProjectsDocumentOffsets() throws {
    let document = NovelReaderProjection(
        threadID: "307",
        view: 1,
        maxView: 1,
        segments: [
            .text("前段", chapterTitle: nil),
            .text("繁體引用結束", chapterTitle: nil),
        ],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1")
            ),
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-2"),
                blockTextStyles: [
                    NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 2, length: 2))
                ]
            ),
        ]
    )

    let preparedInput = try NovelTextLayout.prepareInput(
        document: document,
        settings: NovelReaderAppearanceSettings(readingMode: .paged, translationMode: .simplified),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(preparedInput.viewportContextSeed.document.text == "前段\n\n繁体引用结束")
    #expect(preparedInput.annotatedSegments[1].semantics?.blockTextStyles == [
        NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 2, length: 2))
    ])
    #expect(preparedInput.viewportContextSeed.document.blockTextStyles == [
        NovelBlockTextStyleRange(
            style: .quote,
            range: NovelCharacterRange(location: "前段\n\n繁体".count, length: 2)
        )
    ])
}

@Test func readerAttributedTextFactoryAppliesInlineBoldWithoutChangingNormalBody() throws {
    let document = NovelReaderProjection(
        threadID: "305",
        view: 1,
        maxView: 1,
        segments: [.text("普通粗体普通", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                inlineTextStyles: [
                    NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 2, length: 2))
                ]
            )
        ]
    )
    let preparedInput = try NovelTextLayout.prepareInput(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    let attributedDocument = NovelAttributedTextFactory.makeAttributedDocument(from: preparedInput)
    let normalFont = try #require(attributedDocument.attribute(.font, at: 0, effectiveRange: nil) as? ReaderTestFont)
    let boldFont = try #require(attributedDocument.attribute(.font, at: 2, effectiveRange: nil) as? ReaderTestFont)

    #expect(readerTestFontWeight(boldFont) > readerTestFontWeight(normalFont))
}

@MainActor
@Test func novelTextRuntimeRebuildsSemanticDocumentWhenOnlyInlineStylesChange() throws {
    let runtime = NovelTextViewportRuntimeOwner()
    let plain = NovelReaderProjection(
        threadID: "306",
        view: 1,
        maxView: 1,
        segments: [.text("同一段正文", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1")
            )
        ]
    )
    let styled = NovelReaderProjection(
        threadID: "306",
        view: 1,
        maxView: 1,
        segments: [.text("同一段正文", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                inlineTextStyles: [
                    NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 3, length: 2))
                ]
            )
        ]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 390, height: 844)

    let first = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(document: plain, settings: settings, layout: layout)
    )
    #expect(runtime.commit(first))
    let second = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(document: styled, settings: settings, layout: layout)
    )
    #expect(runtime.commit(second))

    #expect(runtime.runtimeTransactionDiagnostics.semanticAttributedDocumentBuildCount == 2)
    #expect(runtime.runtimeTransactionDiagnostics.semanticAttributedDocumentReuseCount == 0)
}

@MainActor
@Test func novelTextRuntimeRebuildsSemanticDocumentWhenOnlyBlockStylesChange() throws {
    let runtime = NovelTextViewportRuntimeOwner()
    let plain = NovelReaderProjection(
        threadID: "308",
        view: 1,
        maxView: 1,
        segments: [.text("同一段正文", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1")
            )
        ]
    )
    let styled = NovelReaderProjection(
        threadID: "308",
        view: 1,
        maxView: 1,
        segments: [.text("同一段正文", chapterTitle: nil)],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                blockTextStyles: [
                    NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 3, length: 2))
                ]
            )
        ]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 390, height: 844)

    let first = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(document: plain, settings: settings, layout: layout)
    )
    #expect(runtime.commit(first))
    let second = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(document: styled, settings: settings, layout: layout)
    )
    #expect(runtime.commit(second))

    #expect(runtime.runtimeTransactionDiagnostics.semanticAttributedDocumentBuildCount == 2)
    #expect(runtime.runtimeTransactionDiagnostics.semanticAttributedDocumentReuseCount == 0)
}
#endif

@Test func novelTextLayoutRejectsEmptySemanticDocumentBeforeRuntimeAllocation() throws {
    let document = NovelReaderProjection(
        threadID: "302",
        view: 1,
        maxView: 1,
        segments: [.text(" \n ", chapterTitle: nil)]
    )

    #expect(throws: NovelTextLayoutFailure.semanticDocumentPreparation) {
        _ = try NovelTextLayout.prepareInput(
            document: document,
            settings: NovelReaderAppearanceSettings(),
            layout: NovelReaderLayout(width: 390, height: 844)
        )
    }
}

#if canImport(UIKit)
@Test func novelTextLayoutCommitsSemanticLayoutFontPlatformAndTextKitFingerprints() throws {
    let document = NovelReaderProjection(
        threadID: "303",
        view: 1,
        maxView: 1,
        segments: [.text("第一章\n指纹正文。", chapterTitle: "第一章")]
    )
    let result = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(!result.fingerprints.semantic.isEmpty)
    #expect(!result.fingerprints.text.isEmpty)
    #expect(!result.fingerprints.layout.isEmpty)
    #expect(!result.fingerprints.font.isEmpty)
    #expect(!result.fingerprints.platform.isEmpty)
    #expect(result.fingerprints.textKitImplementation == "NSTextLayoutManager-TextKit2-v1")
}
#endif

@Test func novelReaderCacheStorePersistsAndDeletesPages() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NovelReaderProjectionStore(baseDirectory: directory)
    let document = NovelReaderProjection(
        threadID: "10",
        view: 3,
        maxView: 5,
        resolvedAuthorID: "12",
        segments: [.text("正文", chapterTitle: "测试章")],
        fetchedAt: Date(timeIntervalSince1970: 100)
    )

    try await store.save(document)
    let loaded = await store.loadProjection(for: NovelPageRequest(threadID: "10", view: 3, authorID: "12"))
    #expect(loaded == document)
    #expect(await store.cachedViews(for: "10", authorID: "12") == [3])

    try await store.deleteViews([3], for: "10", authorID: "12")
    let deleted = await store.loadProjection(for: NovelPageRequest(threadID: "10", view: 3, authorID: "12"))
    #expect(deleted == nil)
}

@Test func novelReaderCacheStoreIndexUsesTidFirstIdentityWithoutThreadURL() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: directory.appendingPathComponent("grdb", isDirectory: true))
    let store = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let document = NovelReaderProjection(
        threadID: "18610",
        view: 4,
        maxView: 5,
        resolvedAuthorID: "12",
        segments: [.text("正文", chapterTitle: "测试章")]
    )

    try await store.save(document)

    let rows = try await novelReaderProjectionCacheRows(in: database)
    let metadata = try #require(rows.first)

    #expect(rows.count == 1)
    #expect(metadata.namespace == "novel-reader-projections")
    #expect(metadata.key == "tid_18610_author_12_view_4")
    #expect(!metadata.key.contains("https://"))
    #expect(FileManager.default.fileExists(
        atPath: novelReaderProjectionCacheFile(rootDirectory: directory, key: metadata.key).path
    ))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json", isDirectory: false).path))
}

@Test func novelReaderCacheStoreLegacyIndexAndFilesAreIgnoredAndPreserved() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try YamiboDatabase.openPool(rootDirectory: directory.appendingPathComponent("grdb", isDirectory: true))
    let legacyIndexURL = directory.appendingPathComponent("index.json", isDirectory: false)
    let legacyFileURL = directory.appendingPathComponent("legacy-reader-document.json", isDirectory: false)
    let legacyIndexData = Data(#"{"version":3,"threads":{"tid:18611":{"threadID":"18611","variants":{"source:fallbackUnfilteredPage":{"pages":{"1":{"fileName":"legacy-reader-document.json","fetchedAt":"2026-01-01T00:00:00Z"}}}}}}}"#.utf8)
    try legacyIndexData.write(to: legacyIndexURL, options: [.atomic])
    try Data(#"{"legacy":true}"#.utf8).write(to: legacyFileURL, options: [.atomic])

    let store = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let legacyLoaded = await store.loadProjection(
        for: NovelPageRequest(threadID: "18611", view: 1)
    )
    try await store.save(
        NovelReaderProjection(
            threadID: "18612",
            view: 1,
            maxView: 1,
            segments: [.text("新缓存正文", chapterTitle: "新章")]
        )
    )

    #expect(legacyLoaded == nil)
    #expect(try Data(contentsOf: legacyIndexURL) == legacyIndexData)
    #expect(FileManager.default.fileExists(atPath: legacyFileURL.path))
}

@Test func novelReaderCacheStoreWritesDocumentSchemaVersionAndSemanticIdentities() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NovelReaderProjectionStore(baseDirectory: directory)
    let document = NovelReaderProjection(
        threadID: "18601",
        view: 1,
        maxView: 1,
        segments: [.text("第一章\n正文", chapterTitle: "第一章")],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                chapterTitleRange: NovelCharacterRange(location: 0, length: "第一章".count),
                inlineTextStyles: [
                    NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 4, length: 2))
                ],
                blockTextStyles: [
                    NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 4, length: 2))
                ]
            )
        ]
    )

    try await store.save(document)

    let cacheFile = try #require(novelReaderProjectionCacheFiles(rootDirectory: directory).first)
    let object = try #require(
        JSONSerialization.jsonObject(with: try Data(contentsOf: cacheFile)) as? [String: Any]
    )
    let semantics = try #require(object["segmentSemantics"] as? [[String: Any]])
    let firstSemantics = try #require(semantics.first)
    let chapterIdentity = try #require(firstSemantics["chapterIdentity"] as? [String: Any])
    let textSegmentIdentity = try #require(firstSemantics["textSegmentIdentity"] as? [String: Any])
    let titleRange = try #require(firstSemantics["chapterTitleRange"] as? [String: Any])
    let inlineTextStyles = try #require(firstSemantics["inlineTextStyles"] as? [[String: Any]])
    let firstInlineStyle = try #require(inlineTextStyles.first)
    let firstInlineRange = try #require(firstInlineStyle["range"] as? [String: Any])
    let blockTextStyles = try #require(firstSemantics["blockTextStyles"] as? [[String: Any]])
    let firstBlockStyle = try #require(blockTextStyles.first)
    let firstBlockRange = try #require(firstBlockStyle["range"] as? [String: Any])

    #expect(object["schemaVersion"] as? Int == NovelReaderProjection.schemaVersion)
    #expect(object["threadID"] as? String == "18601")
    #expect(chapterIdentity["rawValue"] as? String != nil)
    #expect(textSegmentIdentity["rawValue"] as? String != nil)
    #expect(titleRange["location"] as? Int == 0)
    #expect(titleRange["length"] as? Int == "第一章".count)
    #expect(firstInlineStyle["style"] as? String == NovelInlineTextStyle.bold.rawValue)
    #expect(firstInlineRange["location"] as? Int == 4)
    #expect(firstInlineRange["length"] as? Int == 2)
    #expect(firstBlockStyle["style"] as? String == NovelBlockTextStyle.quote.rawValue)
    #expect(firstBlockRange["location"] as? Int == 4)
    #expect(firstBlockRange["length"] as? Int == 2)
}

@Test func readerPageDocumentRejectsOutdatedSchemaVersionOnDecode() async throws {
    let json = #"""
    {
      "schemaVersion": 3,
      "threadID": "18605",
      "view": 1,
      "maxView": 1,
      "contentSource": "fallbackUnfilteredPage",
      "retainedChapterCount": 1,
      "filteredChapterCandidateCount": 0,
      "segments": [
        {"kind": "text", "text": "第一章\n正文", "chapterTitle": "第一章"}
      ],
      "segmentSources": [null],
      "segmentSemantics": [
        {
          "chapterIdentity": {"rawValue": "post:1#chapter:0"},
          "textSegmentIdentity": {"rawValue": "post:1#chapter:0#text:0"},
          "chapterTitleRange": {"location": 0, "length": 3},
          "inlineTextStyles": [],
          "blockTextStyles": []
        }
      ],
      "fetchedAt": "2026-06-05T00:00:00Z"
    }
    """#.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(throws: (any Error).self) {
        _ = try decoder.decode(NovelReaderProjection.self, from: json)
    }
}

@Test func novelReaderCacheStoreInvalidatesDocumentWithCorruptExplicitTitleRange() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: directory.appendingPathComponent("grdb", isDirectory: true))
    let store = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let document = #"""
    {
      "schemaVersion": 6,
      "threadID": "18604",
      "view": 1,
      "maxView": 1,
      "contentSource": "fallbackUnfilteredPage",
      "retainedChapterCount": 1,
      "filteredChapterCandidateCount": 0,
      "segments": [
        {"kind": "text", "text": "短文", "chapterTitle": "短文"}
      ],
      "segmentSources": [null],
      "segmentSemantics": [
        {
          "chapterIdentity": {"rawValue": "post:1#chapter:0"},
          "textSegmentIdentity": {"rawValue": "post:1#chapter:0#text:0"},
          "chapterTitleRange": {"location": 0, "length": 20},
          "inlineTextStyles": [],
          "blockTextStyles": []
        }
      ],
      "fetchedAt": "2026-06-05T00:00:00Z"
    }
    """#
    try await store.save(
        NovelReaderProjection(
            threadID: "18604",
            view: 1,
            maxView: 1,
            segments: [.text("短文", chapterTitle: "短文")]
        )
    )
    let metadata = try #require(try await novelReaderProjectionCacheRows(in: database).first)
    let fileURL = novelReaderProjectionCacheFile(rootDirectory: directory, key: metadata.key)
    try Data(document.utf8).write(to: fileURL, options: [.atomic])

    let verifyingStore = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let loaded = await verifyingStore.loadProjection(
        for: NovelPageRequest(threadID: "18604", view: 1)
    )

    #expect(loaded == nil)
    #expect(try await novelReaderProjectionCacheRows(in: database).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func novelReaderCacheStoreInvalidatesDocumentWithCorruptInlineTextStyleRange() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: directory.appendingPathComponent("grdb", isDirectory: true))
    let store = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let document = #"""
    {
      "schemaVersion": 6,
      "threadID": "18606",
      "view": 1,
      "maxView": 1,
      "contentSource": "fallbackUnfilteredPage",
      "retainedChapterCount": 1,
      "filteredChapterCandidateCount": 0,
      "segments": [
        {"kind": "text", "text": "短文", "chapterTitle": "短文"}
      ],
      "segmentSources": [null],
      "segmentSemantics": [
        {
          "chapterIdentity": {"rawValue": "post:1#chapter:0"},
          "textSegmentIdentity": {"rawValue": "post:1#chapter:0#text:0"},
          "chapterTitleRange": {"location": 0, "length": 2},
          "inlineTextStyles": [
            {"style": "bold", "range": {"location": 1, "length": 20}}
          ],
          "blockTextStyles": []
        }
      ],
      "fetchedAt": "2026-06-05T00:00:00Z"
    }
    """#
    try await store.save(
        NovelReaderProjection(
            threadID: "18606",
            view: 1,
            maxView: 1,
            segments: [.text("短文", chapterTitle: "短文")]
        )
    )
    let metadata = try #require(try await novelReaderProjectionCacheRows(in: database).first)
    let fileURL = novelReaderProjectionCacheFile(rootDirectory: directory, key: metadata.key)
    try Data(document.utf8).write(to: fileURL, options: [.atomic])

    let verifyingStore = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let loaded = await verifyingStore.loadProjection(
        for: NovelPageRequest(threadID: "18606", view: 1)
    )

    #expect(loaded == nil)
    #expect(try await novelReaderProjectionCacheRows(in: database).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func novelReaderCacheStoreSeparatesVariantsByAuthorID() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NovelReaderProjectionStore(baseDirectory: directory)
    let unfiltered = NovelReaderProjection(
        threadID: "21",
        view: 1,
        maxView: 3,
        segments: [.text("全部回复正文", chapterTitle: "第一章")]
    )
    let authorFiltered = NovelReaderProjection(
        threadID: "21",
        view: 1,
        maxView: 3,
        resolvedAuthorID: "42",
        segments: [.text("只看楼主正文", chapterTitle: "第一章")]
    )

    try await store.save(unfiltered)
    try await store.save(authorFiltered)

    let loadedUnfiltered = await store.loadProjection(
        for: NovelPageRequest(threadID: "21", view: 1)
    )
    let loadedAuthorFiltered = await store.loadProjection(
        for: NovelPageRequest(threadID: "21", view: 1, authorID: "42")
    )

    #expect(loadedUnfiltered?.segments == unfiltered.segments)
    #expect(loadedAuthorFiltered?.segments == authorFiltered.segments)
    #expect(await store.cachedViews(for: "21", authorID: nil) == [1])
    #expect(await store.cachedViews(for: "21", authorID: "42") == [1])

    try await store.deleteViews([1], for: "21", authorID: "42")

    let deletedAuthorFiltered = await store.loadProjection(
        for: NovelPageRequest(threadID: "21", view: 1, authorID: "42")
    )
    let preservedUnfiltered = await store.loadProjection(
        for: NovelPageRequest(threadID: "21", view: 1)
    )

    #expect(deletedAuthorFiltered == nil)
    #expect(preservedUnfiltered?.segments == unfiltered.segments)
}

@Test func readerRepositoryDoesNotCrossHitFilteredCacheWhenOffline() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: cacheStore,
        forumCacheStore: forumCacheStore
    )
    let authorFiltered = NovelReaderProjection(
        threadID: "22",
        view: 1,
        maxView: 2,
        resolvedAuthorID: "42",
        segments: [.text("只看楼主缓存", chapterTitle: "第一章")]
    )
    try await cacheStore.save(authorFiltered)

    await #expect(throws: YamiboError.offline) {
        _ = try await repository.loadPage(NovelPageRequest(threadID: "22", view: 1))
    }

    await #expect(throws: YamiboError.offline) {
        _ = try await repository.loadPage(NovelPageRequest(threadID: "22", view: 1, authorID: "42"))
    }
}

@Test func readerRepositoryLoadsProjectionFromCachedAuthorScopedThreadPage() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "32")
    try await forumCacheStore.saveThreadPage(
        makeReaderRepositoryThreadPage(
            thread: thread,
            title: "缓存小说",
            postID: "3201",
            authorID: "42",
            contentHTML: "<strong>第一章</strong><br>缓存正文"
        ),
        thread: thread,
        pageNumber: 1,
        authorID: "42"
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore
    )

    let document = try await repository.loadPage(NovelPageRequest(threadID: "32", view: 1, authorID: "42"))

    #expect(document.resolvedAuthorID == "42")
    #expect(document.segments.contains(.text("第一章\n缓存正文", chapterTitle: "第一章")))
    #expect(document.projectionSourceFingerprint != nil)
    #expect(await repository.cachedViews(for: "32", authorID: "42") == [1])
}

@Test func readerRepositoryPersistsProjectionDerivedFromCachedAuthorScopedThreadPage() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let readerCacheDirectory = directory.appendingPathComponent("reader", isDirectory: true)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: readerCacheDirectory)
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "3201")
    try await forumCacheStore.saveThreadPage(
        makeReaderRepositoryThreadPage(
            thread: thread,
            title: "缓存小说",
            postID: "320101",
            authorID: "42",
            contentHTML: "<strong>第一章</strong><br>缓存正文"
        ),
        thread: thread,
        pageNumber: 1,
        authorID: "42"
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore
    )

    let document = try await repository.loadPage(NovelPageRequest(threadID: "3201", view: 1, authorID: "42"))
    let persisted = await NovelReaderProjectionStore(baseDirectory: readerCacheDirectory).loadProjection(
        for: NovelPageRequest(threadID: "3201", view: 1, authorID: "42")
    )

    #expect(persisted?.threadID == document.threadID)
    #expect(persisted?.view == document.view)
    #expect(persisted?.resolvedAuthorID == document.resolvedAuthorID)
    #expect(persisted?.segments == document.segments)
    #expect(persisted?.segmentSources == document.segmentSources)
    #expect(persisted?.segmentSemantics == document.segmentSemantics)
    #expect(persisted?.projectionSourceFingerprint == document.projectionSourceFingerprint)
    #expect(persisted?.projectionSchemaVersion == document.projectionSchemaVersion)
}

@Test func readerRepositoryRepairsProjectionCacheDirectoryDeletedDuringRuntime() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let readerCacheDirectory = directory.appendingPathComponent("reader", isDirectory: true)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: readerCacheDirectory)
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "3202")
    try await forumCacheStore.saveThreadPage(
        makeReaderRepositoryThreadPage(
            thread: thread,
            title: "运行中删缓存",
            postID: "320201",
            authorID: "42",
            contentHTML: "<strong>第一章</strong><br>缓存正文"
        ),
        thread: thread,
        pageNumber: 1,
        authorID: "42"
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore
    )

    _ = try await repository.loadPage(NovelPageRequest(threadID: "3202", view: 1, authorID: "42"))
    try FileManager.default.removeItem(
        at: YamiboDatabase.cacheDirectoryURL(rootDirectory: readerCacheDirectory)
            .appendingPathComponent(NovelReaderProjectionStore.projectionNamespace, isDirectory: true)
    )
    let document = try await repository.loadPage(NovelPageRequest(threadID: "3202", view: 1, authorID: "42"))
    let persisted = await NovelReaderProjectionStore(baseDirectory: readerCacheDirectory).loadProjection(
        for: NovelPageRequest(threadID: "3202", view: 1, authorID: "42")
    )

    #expect(persisted?.segments == document.segments)
    #expect(persisted?.projectionSourceFingerprint == document.projectionSourceFingerprint)
}

@Test func readerRepositoryDoesNotUseLegacyReaderProjectionWithoutThreadPage() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    try await novelReaderCacheStore.save(
        NovelReaderProjection(
            threadID: "33",
            view: 1,
            maxView: 1,
            resolvedAuthorID: "42",
            segments: [.text("旧 reader projection", chapterTitle: "旧章")]
        )
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore
    )

    await #expect(throws: (any Error).self) {
        _ = try await repository.loadPage(NovelPageRequest(threadID: "33", view: 1, authorID: "42"))
    }

    #expect(await repository.cachedViews(for: "33", authorID: "42").isEmpty)
}

private func makeReaderRepositoryThreadPage(
    thread: ThreadIdentity,
    title: String,
    postID: String,
    authorID: String,
    contentHTML: String,
    page: Int = 1,
    totalPages: Int = 1
) -> ForumThreadPage {
    ForumThreadPage(
        thread: thread,
        title: title,
        posts: [
            ForumThreadPost(
                postID: postID,
                author: BlogReaderUser(uid: authorID, name: "楼主"),
                contentHTML: contentHTML,
                contentText: "ignored"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: page, totalPages: totalPages)
    )
}

@Test func readerRepositoryRefreshesOnlyCurrentVariantCache() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: cacheStore,
        forumCacheStore: forumCacheStore
    )
    let unfiltered = NovelReaderProjection(
        threadID: "23",
        view: 1,
        maxView: 2,
        segments: [.text("全部回复旧缓存", chapterTitle: "第一章")]
    )
    let authorFiltered = NovelReaderProjection(
        threadID: "23",
        view: 1,
        maxView: 2,
        resolvedAuthorID: "42",
        segments: [.text("只看楼主旧缓存", chapterTitle: "第一章")]
    )
    try await cacheStore.save(unfiltered)
    try await cacheStore.save(authorFiltered)

    try await repository.refreshCachedViews(
        [1],
        for: "23",
        authorID: "42"
    )

    let refreshedAuthorFiltered = await cacheStore.loadProjection(
        for: NovelPageRequest(threadID: "23", view: 1, authorID: "42")
    )
    let preservedUnfiltered = await cacheStore.loadProjection(
        for: NovelPageRequest(threadID: "23", view: 1)
    )

    let refreshedText = refreshedAuthorFiltered?.segments.compactMap { segment -> String? in
        if case let .text(text, _) = segment { return text }
        return nil
    }.first
    let preservedText = preservedUnfiltered?.segments.compactMap { segment -> String? in
        if case let .text(text, _) = segment { return text }
        return nil
    }.first

    #expect(refreshedText == "只看楼主新缓存")
    #expect(preservedText == "全部回复旧缓存")
}

@Test func readerRepositoryRefreshesCachedDocumentsBeforeAuthorReplyMetadataSchema() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStoreDirectory = directory.appendingPathComponent("reader", isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: cacheStoreDirectory)
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    try await cacheStore.save(
        NovelReaderProjection(
            threadID: "30",
            view: 1,
            maxView: 1,
            resolvedAuthorID: "42",
            segments: [.text("旧 schema 缓存正文", chapterTitle: "第一章")]
        )
    )
    try rewriteCachedReaderDocumentSchemaVersion(in: cacheStoreDirectory, to: 3)
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: cacheStoreDirectory),
        forumCacheStore: forumCacheStore
    )

    let document = try await repository.loadPage(NovelPageRequest(threadID: "30", view: 1, authorID: "42"))
    let text = document.segments.compactMap { segment -> String? in
        if case let .text(text, _) = segment { return text }
        return nil
    }.first

    #expect(text == "新 schema 缓存刷新正文")
}

@Test func readerRepositoryDoesNotFallBackToOldSchemaProjectionWhenThreadPageRefreshIsOffline() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStoreDirectory = directory.appendingPathComponent("reader", isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: cacheStoreDirectory)
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    try await cacheStore.save(
        NovelReaderProjection(
            threadID: "31",
            view: 1,
            maxView: 1,
            resolvedAuthorID: "42",
            segments: [.text("旧 schema 离线缓存正文", chapterTitle: "第一章")]
        )
    )
    try rewriteCachedReaderDocumentSchemaVersion(in: cacheStoreDirectory, to: 3)
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: cacheStoreDirectory),
        forumCacheStore: forumCacheStore
    )

    await #expect(throws: YamiboError.offline) {
        _ = try await repository.loadPage(NovelPageRequest(threadID: "31", view: 1, authorID: "42"))
    }
}

@Test func readerRepositoryFallsBackToDurableNovelOfflineSourcePageWhenOnlineAcquisitionFails() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "34")
    let sourcePage = makeReaderRepositoryThreadPage(
        thread: thread,
        title: "离线小说",
        postID: "3401",
        authorID: "42",
        contentHTML: "<strong>离线章节</strong><br>离线正文"
    )
    let updatedAt = Date(timeIntervalSince1970: 34_000)
    try await offlineStore.saveNovelOfflineSourcePage(
        sourcePage,
        request: NovelOfflineCacheWorkRequest(
            ownerTitle: "离线小说",
            title: "第一页",
            threadID: "34",
            view: 1,
            authorID: "42"
        ),
        updatedAt: updatedAt
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore,
        offlineCacheStore: offlineStore
    )

    let load = try await repository.loadPageResult(NovelPageRequest(threadID: "34", view: 1, authorID: "42"))
    let prewarm = await novelReaderCacheStore.loadProjection(
        for: NovelPageRequest(threadID: "34", view: 1, authorID: "42")
    )

    #expect(load.source == .offlineFallback(updatedAt: updatedAt))
    #expect(load.projection.segments.contains(.text("离线章节\n离线正文", chapterTitle: "离线章节")))
    #expect(load.projection.projectionSourceFingerprint != nil)
    #expect(load.projection.projectionSchemaVersion == 1)
    #expect(prewarm?.segments == load.projection.segments)
}

@Test func readerRepositoryOfflineFallbackReusesValidTransparentProjectionCache() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "341")
    let sourcePage = makeReaderRepositoryThreadPage(
        thread: thread,
        title: "离线小说",
        postID: "34101",
        authorID: "42",
        contentHTML: "<strong>离线章节</strong><br>离线正文"
    )
    let updatedAt = Date(timeIntervalSince1970: 341_000)
    try await offlineStore.saveNovelOfflineSourcePage(
        sourcePage,
        request: NovelOfflineCacheWorkRequest(
            ownerTitle: "离线小说",
            title: "第一页",
            threadID: "341",
            view: 1,
            authorID: "42"
        ),
        updatedAt: updatedAt
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore,
        offlineCacheStore: offlineStore
    )
    let parsedLoad = try await repository.loadPageResult(NovelPageRequest(threadID: "341", view: 1, authorID: "42"))
    let fingerprint = try #require(parsedLoad.projection.projectionSourceFingerprint)
    let cachedProjection = NovelReaderProjection(
        threadID: parsedLoad.projection.threadID,
        view: 1,
        maxView: parsedLoad.projection.maxView,
        resolvedAuthorID: "42",
        segments: [.text("透明缓存正文", chapterTitle: "透明缓存章节")],
        projectionSourceFingerprint: fingerprint,
        projectionSchemaVersion: parsedLoad.projection.projectionSchemaVersion
    )
    try await novelReaderCacheStore.save(cachedProjection)

    let cachedLoad = try await repository.loadPageResult(NovelPageRequest(threadID: "341", view: 1, authorID: "42"))

    #expect(cachedLoad.source == .offlineFallback(updatedAt: updatedAt))
    #expect(cachedLoad.projection.segments == cachedProjection.segments)
}

@Test func readerRepositoryDoesNotUseOfflineFallbackForParserFailures() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let thread = ThreadIdentity(tid: "35")
    let sourcePage = makeReaderRepositoryThreadPage(
        thread: thread,
        title: "离线小说",
        postID: "3501",
        authorID: "42",
        contentHTML: "<strong>离线章节</strong><br>离线正文"
    )
    try await offlineStore.saveNovelOfflineSourcePage(
        sourcePage,
        request: NovelOfflineCacheWorkRequest(
            ownerTitle: "离线小说",
            title: "第一页",
            threadID: "35",
            view: 1,
            authorID: "42"
        ),
        updatedAt: Date(timeIntervalSince1970: 35_000)
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true)),
        forumCacheStore: ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true)),
        offlineCacheStore: offlineStore
    )

    await #expect(throws: (any Error).self) {
        _ = try await repository.loadPageResult(NovelPageRequest(threadID: "35", view: 1, authorID: "42"))
    }
}

@Test func readerRepositoryAutoRefreshesExistingNovelOfflineSourceAfterOnlineRead() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let thread = ThreadIdentity(tid: "36")
    let oldSource = makeReaderRepositoryThreadPage(
        thread: thread,
        title: "自动刷新小说",
        postID: "3600",
        authorID: "42",
        contentHTML: "<strong>旧章节</strong><br>旧正文"
    )
    let oldUpdatedAt = Date(timeIntervalSince1970: 36_000)
    try await offlineStore.saveNovelOfflineSourcePage(
        oldSource,
        request: NovelOfflineCacheWorkRequest(
            ownerTitle: "自动刷新小说",
            title: "第一页",
            threadID: "36",
            view: 1,
            authorID: "42"
        ),
        updatedAt: oldUpdatedAt
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true)),
        forumCacheStore: ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true)),
        offlineCacheStore: offlineStore,
        novelOfflineAutoRefreshEnabled: { true }
    )

    let load = try await repository.loadPageResult(NovelPageRequest(threadID: "36", view: 1, authorID: "42"))
    let refreshedSource = await offlineStore.novelOfflineSourcePage(
        ownerTitle: "自动刷新小说",
        threadID: "36",
        view: 1,
        authorID: "42"
    )
    let snapshot = await offlineStore.novelOfflineCacheViewsSnapshot(
        ownerTitle: "自动刷新小说",
        threadID: "36",
        authorID: "42"
    )

    #expect(load.source == .online)
    #expect(load.projection.segments.contains(.text("在线章节\n在线新正文", chapterTitle: "在线章节")))
    #expect(refreshedSource?.posts.first?.contentHTML.contains("在线新正文") == true)
    #expect((snapshot.updateTimesByView[1] ?? oldUpdatedAt) > oldUpdatedAt)
}

@Test func readerRepositoryDoesNotCreateNovelOfflineEntryForUncachedOnlineRead() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true)),
        forumCacheStore: ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true)),
        offlineCacheStore: offlineStore,
        novelOfflineAutoRefreshEnabled: { true }
    )

    _ = try await repository.loadPageResult(NovelPageRequest(threadID: "37", view: 1, authorID: "42"))
    let snapshot = await offlineStore.novelOfflineCacheViewsSnapshot(
        ownerTitle: "未缓存小说",
        threadID: "37",
        authorID: "42"
    )

    #expect(snapshot.cachedViews.isEmpty)
    #expect(await offlineStore.allNovelOfflineCacheEntries().isEmpty)
}

@Test func readerRepositoryCachesViewsSequentiallyAndSkipsFailures() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: cacheStore,
        forumCacheStore: forumCacheStore
    )
    let result = await repository.cacheViews(
        [1, 2, 3],
        for: "24",
        authorID: "42"
    )

    #expect(result.completedViews == [1, 3])
    #expect(result.failedViews == [2])
    #expect(!result.wasCancelled)
    #expect(await repository.cachedViews(for: "24", authorID: "42") == [1, 3])
    #expect(await cacheStore.cachedViews(for: "24", authorID: nil).isEmpty)
}

@Test func readerRepositoryRefreshesLegacyCacheMissingChapterCommentSources() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: cacheStore,
        forumCacheStore: forumCacheStore
    )
    let legacyDocument = NovelReaderProjection(
        threadID: "25",
        view: 1,
        maxView: 1,
        resolvedAuthorID: "42",
        retainedChapterCount: 1,
        segments: [.text("旧缓存章节\n旧正文", chapterTitle: "旧缓存章节")]
    )
    try await cacheStore.save(legacyDocument)

    let loaded = try await repository.loadPage(NovelPageRequest(threadID: "25", view: 1, authorID: "42"))

    #expect(loaded.segments == [.text("新解析章节\n新正文", chapterTitle: "新解析章节")])
    #expect(loaded.source(forSegmentIndex: 0)?.ownerPostID == "41257246")
}

@Test func readerChapterCommentsRepositoryLoadsChapterCommentsFromAuthorFilteredPageWhenTargetHasAuthorID() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = ReaderChapterCommentsRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
    )
    let target = ReaderChapterCommentTarget(
        threadID: "26",
        view: 2,
        ownerPostID: "2601",
        title: "episode 16",
        authorID: "42"
    )

    let page = try await repository.loadChapterComments(for: target)

    #expect(page.comments.map(\.body) == ["完整评分理由"])
}

@Test func readerChapterCommentsRepositoryLoadsSamePageRepliesFromUnfilteredPageForAuthorFilteredTarget() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = ReaderChapterCommentsRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
    )
    let target = ReaderChapterCommentTarget(
        threadID: "27",
        view: 2,
        ownerPostID: "2701",
        title: "第一章",
        authorID: "42"
    )

    let page = try await repository.loadChapterComments(for: target)

    #expect(page.comments.map(\.source) == [.reply])
    #expect(page.comments.map(\.authorName) == ["读者甲"])
    #expect(page.comments.map(\.body) == ["楼间回复"])
    #expect(page.isBoundaryClosed == true)
    #expect(page.nextView == nil)
}

@Test func readerChapterCommentsRepositoryReloadsUnfilteredRepliesIgnoringURLCache() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = ReaderChapterCommentsRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
    )
    let target = ReaderChapterCommentTarget(
        threadID: "28",
        view: 2,
        ownerPostID: "2801",
        title: "第一章",
        authorID: "42"
    )
    StubURLProtocol.tid28UnfilteredCachePolicy = nil

    let page = try await repository.loadChapterComments(for: target)

    #expect(page.comments.map(\.body) == ["楼间回复"])
    #expect(StubURLProtocol.tid28UnfilteredCachePolicy == .reloadIgnoringLocalCacheData)
}

@Test func readerChapterCommentsRepositoryFindsRealUnfilteredPageForAuthorFilteredChapterComments() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = ReaderChapterCommentsRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
    )
    let target = ReaderChapterCommentTarget(
        threadID: "29",
        view: 2,
        ownerPostID: "2901",
        title: "第一章",
        authorID: "42"
    )

    let page = try await repository.loadChapterComments(for: target)

    #expect(page.comments.map(\.body) == ["真实全帖页回复"])
    #expect(page.nextView == 5)
}

final class FavoriteRepositoryDeleteTests: XCTestCase {
    func testDeletesFavoriteUsingFormhashAndFavoriteID() async throws {
        let repository = makeFavoriteRepository(cookie: "sid=1; favorite-delete-success=1")
        try await repository.deleteFavorite(remoteFavoriteID: "55")
    }

    func testThrowsWhenDeleteFormhashIsMissing() async {
        let repository = makeFavoriteRepository(cookie: "sid=1; missing-token=1")

        do {
            try await repository.deleteFavorite(remoteFavoriteID: "55")
            XCTFail("Expected missingFavoriteDeleteToken")
        } catch let error as YamiboError {
            XCTAssertEqual(error, .missingFavoriteDeleteToken)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testThrowsWhenDeleteResponseIsFailure() async {
        let repository = makeFavoriteRepository(cookie: "sid=1")

        do {
            try await repository.deleteFavorite(remoteFavoriteID: "999")
            XCTFail("Expected favoriteDeleteFailed")
        } catch let error as YamiboError {
            XCTAssertEqual(error, .favoriteDeleteFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeFavoriteRepository(cookie: String) -> FavoriteRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return FavoriteRepository(
            client: YamiboClient(session: session, cookie: cookie, userAgent: "Test-UA")
        )
    }
}

final class FavoriteRepositoryThreadFavoriteTests: XCTestCase {
    func testAddsThreadFavoriteAndBackfillsRemoteFavoriteID() async throws {
        let repository = makeFavoriteRepository(cookie: "sid=1; favorite-add-success=1")

        let remoteFavorite = try await repository.addThreadFavorite(threadID: "704", formHash: "abc12345")

        XCTAssertEqual(remoteFavorite?.remoteFavoriteID, "8801")
        XCTAssertEqual(remoteFavorite?.threadID, "704")
    }

    func testFindsRemoteFavoriteIDAcrossFavoritePages() async throws {
        let repository = makeFavoriteRepository(cookie: "sid=1; favorite-target-page2=1")

        let remoteFavorite = try await repository.remoteFavorite(forThreadID: "805")

        XCTAssertEqual(remoteFavorite?.remoteFavoriteID, "9902")
    }

    func testFavoritePageParserReadsPagination() {
        let html = """
        <html><body>
          <ul class="sclist">
            <li><a href="forum.php?mod=viewthread&tid=900&mobile=2">收藏</a></li>
          </ul>
          <div class="pg"><a href="home.php?page=1">1</a><strong>2</strong><a href="home.php?page=3">3</a></div>
        </body></html>
        """

        let page = FavoriteHTMLParser.parseFavoritePage(from: html)

        XCTAssertEqual(page.currentPage, 2)
        XCTAssertEqual(page.totalPages, 3)
        XCTAssertEqual(page.favorites.count, 1)
    }

    func testFavoritePageParserDistinguishesUnparseableFromGenuinelyEmptyDocument() {
        let unparseable = FavoriteHTMLParser.parseFavoritePage(from: "")
        XCTAssertFalse(unparseable.documentParsed)
        XCTAssertTrue(unparseable.favorites.isEmpty)

        let wellFormedButEmpty = FavoriteHTMLParser.parseFavoritePage(from: "<html><body></body></html>")
        XCTAssertTrue(wellFormedButEmpty.documentParsed)
        XCTAssertTrue(wellFormedButEmpty.favorites.isEmpty)
    }

    private func makeFavoriteRepository(cookie: String) -> FavoriteRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return FavoriteRepository(
            client: YamiboClient(session: session, cookie: cookie, userAgent: "Test-UA")
        )
    }
}

@MainActor
@Test func novelTextSelectionCopiesDisplayedTextFromCommittedGeneration() throws {
    let document = NovelReaderProjection(
        threadID: "197",
        view: 1,
        maxView: 1,
        segments: [.text("Alpha beta gamma delta", chapterTitle: "Selection")]
    )
    let runtime = NovelTextViewportRuntimeOwner()
    let firstTransaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 480, readingMode: .paged)
        )
    )
    #expect(runtime.commit(firstTransaction))
    let range = try #require(NovelTextSelectionRange(
        generation: firstTransaction.generation,
        lowerBound: 6,
        upperBound: 10
    ))

    #expect(runtime.selectedText(for: range) == "beta")

    let staleTransaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: NovelReaderAppearanceSettings(fontScale: 1.1, readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 480, readingMode: .paged)
        )
    )
    #expect(runtime.commit(staleTransaction))

    #expect(runtime.selectedText(for: range) == nil)
}

@MainActor
@Test func novelTextSelectionCopiesDisplayedTextAcrossVerticalSurfaces() throws {
#if canImport(UIKit)
    let text = String(
        repeating: "Selection can cross a vertical TextKit chunk while staying in the current runtime generation. ",
        count: 80
    )
    let document = NovelReaderProjection(
        threadID: "198",
        view: 1,
        maxView: 1,
        segments: [.text(text, chapterTitle: "Selection")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .vertical)
    let layout = NovelReaderLayout(width: 320, height: 240, readingMode: .vertical)
    let runtime = NovelTextViewportRuntimeOwner()
    let transaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: settings,
            layout: layout
        )
    )
    let firstSurface = try #require(transaction.result.viewportIndex.surfaces.first)
    let secondSurface = try #require(transaction.result.viewportIndex.surfaces.dropFirst().first)
    try runtime.prepareInitialViewport(for: transaction, around: firstSurface.surfaceOrdinal)
    #expect(runtime.commit(transaction))

    let firstReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: transaction.generation,
        ordinal: firstSurface.surfaceOrdinal
    )))
    let secondReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: transaction.generation,
        ordinal: secondSurface.surfaceOrdinal
    )))
    let firstGeometry = try #require(firstSurface.frozenGeometry)
    let secondGeometry = try #require(secondSurface.frozenGeometry)
    let range = try #require(NovelTextSelectionRange(
        generation: transaction.generation,
        lowerBound: firstGeometry.documentEndOffset - 12,
        upperBound: secondGeometry.documentStartOffset + 12
    ))
    let copiedText = try #require(firstReference.selectedText(for: range))
    let documentText = transaction.result.viewportContext.document.text
    let expectedText = String(documentText[
        documentText.index(documentText.startIndex, offsetBy: range.lowerBound)..<documentText.index(
            documentText.startIndex,
            offsetBy: range.upperBound
        )
    ])

    #expect(copiedText == expectedText)
    #expect(!firstReference.selectionRects(for: range).isEmpty)
    #expect(!secondReference.selectionRects(for: range).isEmpty)
#endif
}

@MainActor
@Test func novelTextSelectionRejectsStaleGeneration() throws {
#if canImport(UIKit)
    let document = NovelReaderProjection(
        threadID: "199",
        view: 1,
        maxView: 1,
        segments: [.text(String(repeating: "Stale selection should not copy. ", count: 20), chapterTitle: "Selection")]
    )
    let settings = NovelReaderAppearanceSettings(readingMode: .paged)
    let layout = NovelReaderLayout(width: 320, height: 480, readingMode: .paged)
    let runtime = NovelTextViewportRuntimeOwner()
    let firstTransaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: settings,
            layout: layout
        )
    )
    try runtime.prepareInitialViewport(for: firstTransaction, around: 0)
    #expect(runtime.commit(firstTransaction))
    let oldReference = try #require(runtime.displayReference(for: NovelReaderSurfaceIdentity(
        generation: firstTransaction.generation,
        ordinal: 0
    )))
    let oldRange = try #require(NovelTextSelectionRange(
        generation: firstTransaction.generation,
        lowerBound: 0,
        upperBound: 5
    ))

    let secondTransaction = try runtime.prepareTransaction(
        preparedInput: NovelTextLayout.prepareInput(
            document: document,
            settings: NovelReaderAppearanceSettings(fontScale: 1.1, readingMode: .paged),
            layout: layout
        )
    )
    try runtime.prepareInitialViewport(for: secondTransaction, around: 0)
    #expect(runtime.commit(secondTransaction))

    #expect(oldReference.isStale)
    #expect(oldReference.selectedText(for: oldRange) == nil)
    #expect(oldReference.selectionRects(for: oldRange).isEmpty)
#endif
}

private func novelReaderTextSemantics(
    chapterID: String,
    textID: String,
    titleRangeLength: Int? = nil
) -> NovelReaderSegmentSemantics {
    NovelReaderSegmentSemantics(
        chapterIdentity: NovelChapterIdentity(rawValue: chapterID),
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: textID),
        chapterTitleRange: titleRangeLength.map { NovelCharacterRange(location: 0, length: $0) }
    )
}

private func novelReaderImageSemantics(chapterID: String) -> NovelReaderSegmentSemantics {
    NovelReaderSegmentSemantics(
        chapterIdentity: NovelChapterIdentity(rawValue: chapterID)
    )
}

private func rewriteCachedReaderDocumentSchemaVersion(in directory: URL, to version: Int) throws {
    let fileURL = try #require(novelReaderProjectionCacheFiles(rootDirectory: directory).first)
    let data = try Data(contentsOf: fileURL)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    object["schemaVersion"] = version
    let output = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try output.write(to: fileURL, options: [.atomic])
}

private struct NovelReaderProjectionCacheRow: Sendable, Equatable {
    var namespace: String
    var key: String
}

private func novelReaderProjectionCacheRows(in database: DatabasePool) async throws -> [NovelReaderProjectionCacheRow] {
    try await database.read { db in
        try Row.fetchAll(
            db,
            sql: """
            SELECT namespace, cache_key
            FROM cache_entries
            WHERE namespace = ?
            ORDER BY cache_key
            """,
            arguments: [NovelReaderProjectionStore.projectionNamespace]
        ).map { row in
            NovelReaderProjectionCacheRow(
                namespace: row["namespace"],
                key: row["cache_key"]
            )
        }
    }
}

private func novelReaderProjectionCacheFile(rootDirectory: URL, key: String) -> URL {
    YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
        .appendingPathComponent(NovelReaderProjectionStore.projectionNamespace, isDirectory: true)
        .appendingPathComponent("\(key).json", isDirectory: false)
}

private func novelReaderProjectionCacheFiles(rootDirectory: URL) throws -> [URL] {
    let directory = YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
        .appendingPathComponent(NovelReaderProjectionStore.projectionNamespace, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return []
    }
    return try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

@Suite("NovelReaderRepository by-id APIs", .serialized)
private struct NovelReaderRepositoryByIDTests {
    @Test func fetchThreadDisplayTitleUsesThreadIDRequest() async throws {
        defer { NovelReaderRepositoryByIDURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NovelReaderRepositoryByIDURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let repository = NovelReaderRepository(
            client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
        )

        NovelReaderRepositoryByIDURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let items = components?.queryItems ?? []
            let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in
                item.value.map { (item.name, $0) }
            })
            #expect(values["tid"] == "3210")
            #expect(values["page"] == "1")
            #expect(values["authorid"] == "42")
            #expect(request.url?.absoluteString.contains("thread-") == false)
            return (
                Data("<html><head><title>By ID Title</title></head><body></body></html>".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let title = try await repository.fetchThreadDisplayTitle(threadID: "3210", authorID: "42")

        #expect(title == "By ID Title")
    }
}

private final class NovelReaderRepositoryByIDURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Data, HTTPURLResponse)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
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

#if canImport(UIKit)
@Test func readerDocumentCarriesOwnerPostIDToRenderedPages() throws {
    let html = """
    <html><body>
      <div class="t_f" id="postmessage_100">第一章<br>正文</div>
    </body></html>
    """
    let request = NovelPageRequest(
        threadID: "42",
        view: 3,
        authorID: "7"
    )

    let document = try chapterCommentsNovelProjection(from: html, request: request)
    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.ownerPostID == "100")
    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.view == 3)
    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.title == "第一章")
}

@Test func readerDocumentCarriesNestedOwnerPostIDToRenderedPages() throws {
    let html = """
    <html><body>
      <div id="post_595655">
        <div class="message">
          <div class="t_f" id="postmessage_595655">第一章<br>正文</div>
        </div>
      </div>
    </body></html>
    """
    let request = NovelPageRequest(
        threadID: "557752",
        view: 1,
        authorID: "595655"
    )

    let document = try chapterCommentsNovelProjection(from: html, request: request)
    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(document.segments.count == 1)
    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.ownerPostID == "595655")
    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.view == 1)
}

@Test func readerDocumentCarriesAncestorOwnerPostIDToRenderedPages() throws {
    let html = """
    <html><body>
      <div id="pid41257246">
        <div class="message">作品名：测试<br>作者：测试</div>
      </div>
    </body></html>
    """
    let request = NovelPageRequest(
        threadID: "557752",
        view: 1,
        authorID: "595655"
    )

    let document = try chapterCommentsNovelProjection(from: html, request: request)
    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.ownerPostID == "41257246")
}

private func chapterCommentsNovelProjection(
    from html: String,
    request: NovelPageRequest
) throws -> NovelReaderProjection {
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: html,
        thread: ThreadIdentity(tid: request.threadID),
        fallbackTitle: nil
    )
    return try NovelReaderProjectionBuilder.build(
        from: page,
        request: request,
        authorID: request.authorID ?? "7"
    )
}
#endif

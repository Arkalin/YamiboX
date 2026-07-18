import Foundation
@testable import YamiboXCore
@testable import YamiboXUI

// 本文件收拢原 ReaderCoreTests.swift(已按被测对象拆分)里的共享测试基础设施:
// URLProtocol 桩、离线缓存 store 构造器、语义 fixture 与投影缓存文件定位器。
// 同一测试 target 内以 internal 可见,供 NovelReaderTests/ 各拆分文件以及
// LibraryTests/FavoriteRepositoryRemoteTests.swift 复用。

#if canImport(UIKit)
import UIKit

extension NovelTextViewportRuntimeOwner {
    convenience init() {
        self.init(adapter: DefaultNovelTextLayoutRuntimeAdapter())
    }
}
#endif

// 不依赖 UIKit,放在条件编译块外(原文件把它放在 #if canImport(UIKit) 内,
// 但其非 UIKit 调用方并未被条件编译包裹)。
func makeTestOfflineCacheStore(
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

struct StubURLProtocolResponse {
    let statusCode: Int
    let body: String
}

enum StubURLProtocolOutput {
    case response(StubURLProtocolResponse)
    case error(URLError)
}

/// 全局单 handler 的 URL 桩:默认路由 `defaultHandler()` 按 URL 内容分发,
/// 覆盖收藏、阅读器仓库与章评仓库各测试所需的 bbs.yamibo.com 表面。
///
/// 注意:`handler` 是跨测试共享的可变静态量。除“临时包装默认路由、结束后立即
/// 恢复 `defaultHandler()`(包装期间对其他请求原样委托)”这种对并行用例无行为
/// 影响的用法外,不要往 handler 或其他静态量里塞测试间传递的状态——原
/// `tid28UnfilteredCachePolicy` 静态信道已按此原则移除,改由相关测试局部记录
/// (见 ReaderChapterCommentsRepositoryTests)。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> StubURLProtocolOutput)? = defaultHandler()

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
                          <div class="findbox mt10 cl">
                            <ul>
                              <li class="sclist"><a href="home.php?mod=spacecp&amp;ac=favorite&amp;op=delete&amp;favid=8801" class="dialog mdel"><i class="dm-error"></i></a><a href="forum.php?mod=viewthread&amp;tid=704&amp;mobile=2">远端收藏</a></li>
                            </ul>
                          </div>
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
                              <div class="findbox mt10 cl">
                                <ul>
                                  <li class="sclist"><a href="home.php?mod=spacecp&amp;ac=favorite&amp;op=delete&amp;favid=9902" class="dialog mdel"><i class="dm-error"></i></a><a href="forum.php?mod=viewthread&amp;tid=805&amp;mobile=2">第二页收藏</a></li>
                                </ul>
                              </div>
                              <div class="pg"><a href="home.php?mod=space&amp;do=favorite&amp;type=thread&amp;page=1">1</a><strong>2</strong></div>
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
                          <div class="findbox mt10 cl">
                            <ul>
                              <li class="sclist"><a href="home.php?mod=spacecp&amp;ac=favorite&amp;op=delete&amp;favid=9901" class="dialog mdel"><i class="dm-error"></i></a><a href="forum.php?mod=viewthread&amp;tid=804&amp;mobile=2">第一页收藏</a></li>
                            </ul>
                          </div>
                          <div class="pg"><strong>1</strong><a href="home.php?mod=space&amp;do=favorite&amp;type=thread&amp;page=2">2</a></div>
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
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                  <div class="plc cl" id="pid2703">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主</a></li></ul>
                    <div class="message">第二章<br>正文</div>
                  </div>
                </body></html>
                """
                : """
                <html><body>
                  <div class="plc cl" id="pid2701">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                  <div class="plc cl" id="pid2702">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=77&amp;mobile=2">读者甲</a></li></ul>
                    <div class="message">楼间回复</div>
                  </div>
                  <div class="plc cl" id="pid2703">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主</a></li></ul>
                    <div class="message">第二章<br>正文</div>
                  </div>
                </body></html>
                """
            return .response(StubURLProtocolResponse(statusCode: 200, body: body))
        }

        if absolute.contains("tid=28") || absolute.contains("ptid=28") {
            let body = absolute.contains("authorid=42")
                ? """
                <html><body>
                  <div class="plc cl" id="pid2801">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                </body></html>
                """
                : """
                <html><body>
                  <div class="plc cl" id="pid2801">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                  <div class="plc cl" id="pid2802">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=77&amp;mobile=2">读者甲</a></li></ul>
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
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                </body></html>
                """
            } else if absolute.contains("mod=redirect"), absolute.contains("pid=2901") {
                body = """
                <html><body>
                  <div class="plc cl" id="pid2901">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主</a></li></ul>
                    <div class="message">第一章<br>正文</div>
                  </div>
                  <div class="plc cl" id="pid2902">
                    <ul class="authi"><li class="mtit"><a href="home.php?mod=space&amp;uid=77&amp;mobile=2">读者甲</a></li></ul>
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

func novelReaderTextSemantics(
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

func novelReaderImageSemantics(chapterID: String) -> NovelReaderSegmentSemantics {
    NovelReaderSegmentSemantics(
        chapterIdentity: NovelChapterIdentity(rawValue: chapterID)
    )
}

func novelReaderProjectionCacheFiles(rootDirectory: URL) throws -> [URL] {
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

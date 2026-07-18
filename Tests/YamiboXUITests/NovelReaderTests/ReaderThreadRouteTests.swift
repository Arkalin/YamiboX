import Foundation
import Testing
@testable import YamiboXCore

// 拆分自 ReaderCoreTests.swift:YamiboRoute 在阅读器场景下的帖子路由构造。

@Test func threadRoutePreservesAuthorIDFromExistingURL() async throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123&page=1&authorid=77&mobile=2"))
    let built = YamiboRoute.thread(url: url, page: 2, authorID: nil).url.absoluteString
    #expect(built.contains("authorid=77"))
    #expect(built.contains("page=2"))
}

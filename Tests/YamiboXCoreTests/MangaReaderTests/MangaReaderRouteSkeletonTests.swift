import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Route Contracts")
struct MangaReaderTestsRouteContracts {
    @Test func yamiboThreadRouteResolverCreatesMangaPayload() async throws {
        let resolver = YamiboThreadRouteResolver(
            client: YamiboClient(session: URLSession(configuration: .ephemeral), cookie: nil, userAgent: "Test-UA")
        )
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=700&mobile=2"))

        let target = try await resolver.resolve(YamiboThreadRouteRequest(
            threadURL: url,
            title: "测试漫画 第1话",
            knownThreadKind: .manga
        ))

        // A request without a fid can never come from a smart-enabled manga
        // board (one rule, no special cases), so the manga classification
        // routes to the direct single-thread reader payload.
        guard case let .mangaDirect(payload) = target else {
            Issue.record("Expected direct-to-reader manga payload")
            return
        }
        #expect(payload.thread.tid == "700")
        #expect(payload.title == "测试漫画 第1话")
    }
}

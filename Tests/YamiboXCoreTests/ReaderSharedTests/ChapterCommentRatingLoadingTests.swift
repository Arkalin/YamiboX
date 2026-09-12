import Foundation
import Testing
@testable import YamiboXCore

struct ChapterCommentRatingLoadingTests {
    private let target = ReaderChapterCommentTarget(threadID: "42", view: 1, ownerPostID: "100", authorID: "7")

    @Test(arguments: [false, true])
    func ratingsWithoutReasonsAreSuccessfulEmptyResults(ajax: Bool) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let repository = ReaderChapterCommentsRepository(client: YamiboClient(session: session))
        let request = try ratingRequest(ajax ? "empty-ajax" : "empty")

        let ratings = try await repository.loadRatingReasons(for: target, request: request)

        #expect(ratings.isEmpty)
    }

    @Test func ajaxPayloadKeepsReasonsAndTheirAuthors() throws {
        let html = "<root><![CDATA[\(RatingLoadingFixtures.ratings(reasons: ["", "Full reason"]))]]></root>"
        let ratings = try ChapterCommentsHTMLParser.parseFullRatingReasonsPage(html: html, target: target)

        #expect(ratings.map(\.body) == ["Full reason"])
        #expect(ratings.first?.authorName == "Reader 1")
        #expect(ratings.first?.authorUID == "7")
        #expect(ratings.first?.postID == "100")
    }

    @Test func emptyRatingTableIsRecognizedWithoutInventingAComment() throws {
        let ratings = try ChapterCommentsHTMLParser.parseFullRatingReasonsPage(
            html: RatingLoadingFixtures.ratings(reasons: []), target: target
        )
        #expect(ratings.isEmpty)
    }

    @Test(arguments: ["", "<html><body>Unavailable</body></html>", "<ul class='post_box'><li class='flex-box'>Unavailable</li></ul>"])
    func unrecognizedPagesAreNotSuccessfulEmptyResults(html: String) {
        #expect(throws: (any Error).self) {
            try ChapterCommentsHTMLParser.parseFullRatingReasonsPage(html: html, target: target)
        }
    }

    @Test func loginPageKeepsAuthenticationFailure() {
        #expect(throws: YamiboError.notAuthenticated) {
            try ChapterCommentsHTMLParser.parseFullRatingReasonsPage(
                html: "<root><![CDATA[<div id='messagetext'>请先登录</div>]]></root>", target: target
            )
        }
    }

    @Test func invalidRatingPageIncludesParsingDiagnostics() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let repository = ReaderChapterCommentsRepository(client: YamiboClient(session: session))
        do {
            _ = try await repository.loadRatingReasons(for: target, request: ratingRequest("invalid"))
            Issue.record("Expected an invalid rating page to fail")
        } catch {
            let details = LoadFailureDetails(error: error)
            #expect(details.isHTMLParsingFailure)
            #expect(details.requestContext == "ChapterCommentsHTMLParser.parseFullRatingReasonsPage")
            #expect(details.html?.contains("Unavailable") == true)
        }
    }

    @MainActor @Test func emptyReasonsDoNotBlockLaterRatingsOrRefresh() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let repository = ReaderChapterCommentsRepository(client: YamiboClient(session: session))
        let empty = try ratingRequest("empty")
        let nonempty = try ratingRequest("nonempty", postID: "101")
        let reply = ChapterComment(id: "101", source: .reply, authorName: "Reader", body: "Reply", postID: "101")
        let preview = ChapterComment(id: "preview", source: .ratingReason, authorName: "Reader 0", body: "Preview", postID: "101")
        let initial = ChapterCommentsPage(
            target: target, comments: [reply, preview], isBoundaryClosed: true,
            pendingRatings: [empty, nonempty]
        )
        let module = ReaderChapterCommentsModule(adapter: .init(
            loadInitial: { _ in initial },
            loadMore: { _, _ in throw URLError(.badURL) },
            loadRatings: { target, request in try await repository.loadRatingReasons(for: target, request: request) }
        ), onChange: nil)

        await module.loadAndContinue(target)
        let complete = try loadedPage(module)
        #expect(complete.isComplete)
        #expect(complete.comments.map(\.body) == ["Reply", "Full reason"])
        #expect(complete.comments.last?.postID == "101")
        #expect(complete.comments.last?.isThreadAuthor == true)
        #expect(module.loadMoreError == nil)

        await module.refreshAndContinue(target)
        #expect(try loadedPage(module) == complete)
        #expect(module.loadMoreError == nil)
    }

    @MainActor private func loadedPage(_ module: ReaderChapterCommentsModule) throws -> ChapterCommentsPage {
        guard case let .loaded(_, page) = module.state else {
            throw URLError(.badServerResponse)
        }
        return page
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RatingLoadingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func ratingRequest(_ path: String, postID: String = "100") throws -> ChapterCommentRatingRequest {
        .init(postID: postID, url: try #require(URL(string: "https://bbs.yamibo.com/\(path)")))
    }
}

private enum RatingLoadingFixtures {
    static func ratings(reasons: [String]) -> String {
        let rows = reasons.enumerated().map { index, reason in
            """
            <li class='flex-box mli'><span class='z'>积分 +5 点</span><span class='z'><a href='home.php?mod=space&amp;uid=7'>Reader \(index)</a></span><span class='y'>2024-7-16 18:45</span></li>
            <li class='flex-box mli'><span class='z'>\(reason)</span></li>
            """
        }.joined()
        return """
        <ul class='post_box'>
        <li class='flex-box mli'><span class='z'>积分</span><span class='z'>用户名</span><span class='y'>时间</span></li>
        \(rows)
        </ul>
        """
    }
}

private final class RatingLoadingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let html: String
        switch url.lastPathComponent {
        case "empty", "empty-ajax":
            // The reported chapter has nine ratings, all with blank reasons.
            let ratings = RatingLoadingFixtures.ratings(reasons: Array(repeating: "", count: 9))
            html = url.lastPathComponent == "empty-ajax" ? "<root><![CDATA[\(ratings)]]></root>" : ratings
        case "nonempty":
            html = RatingLoadingFixtures.ratings(reasons: ["Full reason"])
        default:
            html = "<html><body>Unavailable</body></html>"
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

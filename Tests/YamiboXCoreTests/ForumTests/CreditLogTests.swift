import Foundation
import Testing
@testable import YamiboXCore

@Suite(.serialized)
struct CreditLogTests {
    @Test(arguments: CreditLogFilter.allCases)
    func routesUseServerSideFilters(_ filter: CreditLogFilter) throws {
        let url = YamiboRoute.creditLog(filter: filter, page: 3).url
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "bbs.yamibo.com")
        #expect(url.path == "/home.php")
        #expect(query["mod"] == "spacecp")
        #expect(query["ac"] == "credit")
        #expect(query["op"] == "log")
        #expect(query["mobile"] == "2")
        #expect(query["page"] == "3")
        #expect(query["income"] == [CreditLogFilter.income: "1", .expense: "-1"][filter])
        #expect(query["exttype"] == nil)
        #expect(query["uid"] == nil)
        #expect(YamiboRoute.creditLog(filter: filter, page: -2).url.queryItemValue("page") == "1")
    }

    @Test func parsesCheckInAndRatingWithoutTurningOperationFiltersIntoLinks() throws {
        let page = try UserSpaceHTMLParser.parseCreditLog(from: creditHTML(rows: [
            creditRow(),
            creditRow(
                operation: #"<a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log&amp;optype=PRC">帖子被评分</a>"#,
                credit: #"积分 <span class="xi1">+10</span>"#,
                description: #"<a href="forum.php?mod=redirect&amp;goto=findpost&amp;ptid=123&amp;pid=456">Yamibo X &amp; iOS</a>，来自<a href="home.php?mod=space&amp;uid=42">读者</a>"#
            )
        ]))

        #expect(page.entries.map(\.operation) == ["天天打卡", "帖子被评分"])
        #expect(page.entries[0].changes == [CreditLogChange(name: "对象", valueText: "+1", amount: 1)])
        #expect(page.entries[0].description.text == "天天打卡")
        #expect(page.entries[0].description.links.isEmpty)
        #expect(page.entries[0].timeText == "2026-09-10 00:22")
        let description = page.entries[1].description
        #expect(description.text == "Yamibo X & iOS，来自读者")
        #expect(description.links.count == 2)
        #expect(description.links[0].url.queryItemValue("pid") == "456")
        #expect(description.links[1].url.queryItemValue("uid") == "42")
        let characters = Array(description.text)
        let link = description.links[1]
        #expect(String(characters[link.start ..< link.start + link.length]) == "读者")
        #expect(page.pageNavigation == nil)
    }

    @Test func preservesMultipleDeltasUnitsAndNonNumericResets() throws {
        let page = try UserSpaceHTMLParser.parseCreditLog(from: creditHTML(rows: [
            creditRow(credit: #"积分 <span class="xg1">- 1,000</span> 点<br/>对象 <span class="xi1">+2</span> 个"#),
            creditRow(credit: "积分清零")
        ]))
        #expect(page.entries[0].changes == [
            CreditLogChange(name: "积分", valueText: "-1,000 点", amount: -1000),
            CreditLogChange(name: "对象", valueText: "+2 个", amount: 2)
        ])
        #expect(page.entries[1].changes == [CreditLogChange(name: "积分清零", valueText: "")])
    }

    @Test func preservesDuplicateTransactionsWithStableDistinctIDs() throws {
        let html = creditHTML(rows: [creditRow(), creditRow(), creditRow()])
        let first = try UserSpaceHTMLParser.parseCreditLog(from: html)
        let second = try UserSpaceHTMLParser.parseCreditLog(from: html)
        #expect(first.entries.count == 3)
        #expect(Set(first.entries.map(\.id)).count == 3)
        #expect(first.entries.map(\.id) == second.entries.map(\.id))
    }

    @Test func descriptionKeepsParagraphLinkOffsetsAndRejectsUnsafeSchemes() throws {
        let html = creditHTML(rows: [creditRow(description: #"第一行<br/><a href="https://example.com/info">说明</a><a href="javascript:alert(1)">无效链接</a>"#)])
        let description = try #require(UserSpaceHTMLParser.parseCreditLog(from: html).entries.first?.description)
        #expect(description.text == "第一行\n说明无效链接")
        #expect(description.links.map(\.url.absoluteString) == ["https://example.com/info"])
        #expect(description.links.first?.start == 4)
    }

    @Test(arguments: [1, 2, 3])
    func parsesFirstMiddleAndLastPage(_ current: Int) throws {
        let links = (1...3).filter { $0 != current }.map {
            #"<a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log&amp;income=-1&amp;page=\#($0)">\#($0)</a>"#
        }.joined()
        let pager = #"<div class="pg"><strong>\#(current)</strong>\#(links)</div>"#
        let page = try UserSpaceHTMLParser.parseCreditLog(from: creditHTML(rows: [creditRow()], pager: pager))
        #expect(page.pageNavigation == ForumPageNavigation(currentPage: current, totalPages: 3))
    }

    @Test func acceptsOnlyExplicitCreditEmptyPages() throws {
        let empty = #"<div class="empty-box mt10 cl"><h4>现在还没有记录</h4></div>"#
        #expect(try UserSpaceHTMLParser.parseCreditLog(from: creditNavigation + empty).entries.isEmpty)
        #expect(throws: YamiboError.self) { try UserSpaceHTMLParser.parseCreditLog(from: empty) }
        #expect(throws: YamiboError.self) { try UserSpaceHTMLParser.parseCreditLog(from: creditHTML(rows: [])) }
        #expect(throws: YamiboError.self) {
            try UserSpaceHTMLParser.parseCreditLog(from: creditNavigation + #"<div class="empty-box"><h4>没有权限</h4></div>"#)
        }
    }

    @Test func rejectsLoginPermissionWAFAndMalformedPages() throws {
        #expect(throws: YamiboError.notAuthenticated) {
            try UserSpaceHTMLParser.parseCreditLog(from: #"<form id="loginform">请先登录</form>"#)
        }
        #expect(throws: YamiboError.underlying("权限不足")) {
            try UserSpaceHTMLParser.parseCreditLog(from: #"<div class="jump_c">权限不足</div>"#)
        }
        #expect(throws: YamiboError.self) {
            try UserSpaceHTMLParser.parseCreditLog(from: #"<script>window.__noxExpire=30</script><body></body>"#)
        }
        #expect(throws: YamiboError.self) {
            try UserSpaceHTMLParser.parseCreditLog(from: creditHTML(rows: [creditRow(), "<li>broken</li>"]))
        }
    }

    @Test(arguments: CreditLogFilter.allCases)
    func repositoryLoadsWithExistingCredentials(_ filter: CreditLogFilter) async throws {
        let html = creditHTML(rows: [creditRow()])
        CreditLogURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url == YamiboRoute.creditLog(filter: filter, page: 2).url)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "EeqY_2132_auth=fixture")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CreditLog-Test")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { CreditLogURLProtocol.handler = nil }
        let repository = makeCreditRepository()
        #expect(try await repository.fetchCreditLog(filter: filter, page: 2).entries.count == 1)
    }

    @Test func repositoryPropagatesLoginErrors() async throws {
        CreditLogURLProtocol.handler = { request in
            (Data(#"<form id="loginform">请先登录</form>"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { CreditLogURLProtocol.handler = nil }
        do {
            _ = try await makeCreditRepository().fetchCreditLog(filter: .all, page: 1)
            Issue.record("Expected authentication failure")
        } catch {
            #expect(LoadDiagnosticError.classificationError(error) as? YamiboError == .notAuthenticated)
            #expect(!LoadFailureDetails(error: error).isHTMLParsingFailure)
        }
    }

    @Test func repositoryIncludesMalformedPageDiagnostics() async throws {
        CreditLogURLProtocol.handler = { request in
            (Data("<html><body>Unexpected page</body></html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { CreditLogURLProtocol.handler = nil }
        do {
            _ = try await makeCreditRepository().fetchCreditLog(filter: .all, page: 1)
            Issue.record("Expected parsing failure")
        } catch {
            #expect(LoadFailureDetails(error: error).isHTMLParsingFailure)
        }
    }

    @Test func repositoryDoesNotTreatWAFAsEmptyRecords() async throws {
        CreditLogURLProtocol.handler = { request in
            (Data("window.__noxExpire=30; gangplank".utf8), HTTPURLResponse(url: request.url!, statusCode: 405, httpVersion: nil, headerFields: ["Server": "Baidu_WAF"])!)
        }
        defer { CreditLogURLProtocol.handler = nil }
        await #expect(throws: (any Error).self) {
            try await makeCreditRepository().fetchCreditLog(filter: .all, page: 1)
        }
    }
}

private let creditNavigation = #"<div id="dhnavs"><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log">全部</a></div>"#

private func creditHTML(rows: [String], pager: String = "") -> String {
    creditNavigation + #"<div class="home_credit_log mt10 mb10 cl"><ul>\#(rows.joined())</ul>\#(pager)</div>"#
}

private func creditRow(
    operation: String = "天天打卡",
    credit: String = #"对象 <span class="xi1">+1</span>"#,
    description: String = "天天打卡"
) -> String {
    #"""
    <li class="cl">
      <p class="flex-box align-items-center justify-content-between"><span>\#(operation)</span><span>\#(credit)</span></p>
      <p class="flex-box align-items-center justify-content-between mt5"><span class="txt">\#(description)</span><span class="mtime">2026-09-10 00:22</span></p>
    </li>
    """#
}

private func makeCreditRepository() -> UserSpaceRepository {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CreditLogURLProtocol.self]
    return UserSpaceRepository(client: YamiboClient(
        session: URLSession(configuration: configuration),
        cookie: "EeqY_2132_auth=fixture",
        userAgent: "CreditLog-Test"
    ))
}

private final class CreditLogURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
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

import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Directory Repository", .serialized)
struct MangaReaderTestsDirectoryRepository {
    @Test func directorySeedReturnsCurrentChapterAndRemoteIngredients() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }

        harness.setHandler { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=1")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1")
            #expect(request.url?.absoluteString.contains("page=1") == true)
            return MangaReaderDataTestResponse(html: """
            <html>
              <head><title>【作者】作品 第12话 - 中文百合漫画区 - 百合会</title></head>
              <body>
                <a href="misc.php?mod=tag&id=12">tag</a>
                <a href="misc.php?mod=tag&id=34">tag</a>
                <div id="postmessage_9001">
                  <div class="message">
                    <a href="thread-701-1-1.html">第13话</a>
                    <a href="forum.php?mod=viewthread&tid=701&mobile=2">第13话 duplicate</a>
                    <a href="forum.php?mod=viewthread&tid=700&mobile=2">current</a>
                  </div>
                </div>
              </body>
            </html>
            """)
        }

        let repository = YamiboMangaDirectoryRepository(client: testClient(session: harness.session))

        let seed = try await repository.loadDirectorySeed(for: "700")
        let requestURL = try #require(harness.requests.first?.url?.absoluteString)

        #expect(seed.currentChapter.tid == "700")
        #expect(seed.currentChapter.rawTitle == "【作者】作品 第12话")
        #expect(seed.currentChapter.chapterNumber == 12)
        #expect(requestURL.contains("tid=700"))
        #expect(requestURL.contains("page=1"))
        #expect(requestURL.contains("authorid=42") == false)
        #expect(seed.currentChapter.view == 1)
        #expect(seed.cleanBookName == "作品")
        #expect(seed.tagIDs == ["12", "34"])
        #expect(seed.firstPostID == "9001")
        #expect(seed.samePageChapters.map(\.tid) == ["701"])
    }

    @Test func directorySeedAllowsCurrentOnlyPage() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }

        harness.setHandler { _ in
            MangaReaderDataTestResponse(html: """
            <html>
              <head><title>作品 第1话</title></head>
              <body><div class="message">no directory ingredients</div></body>
            </html>
            """)
        }

        let repository = YamiboMangaDirectoryRepository(client: YamiboClient(session: harness.session))

        let seed = try await repository.loadDirectorySeed(for: "702")

        #expect(seed.currentChapter.tid == "702")
        #expect(seed.tagIDs.isEmpty)
        #expect(seed.samePageChapters.isEmpty)
    }

    @Test func directorySeedErrorsWinBeforeParsing() async throws {
        try await expectSeedError(
            html: #"<html><body class="pg_logging"><form id="member_login"></form></body></html>"#,
            expected: YamiboError.notAuthenticated
        )
        try await expectSeedError(
            html: "<html><body>只能进行一次搜索</body></html>",
            expected: YamiboError.floodControl
        )
    }

    @Test func tagDirectoryFetchesPagesSequentiallyAndPreservesGroupIndexes() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }

        harness.setHandler { request in
            let absolute = request.url?.absoluteString ?? ""
            #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=1")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == YamiboNetworkConfiguration.desktopTagUserAgent)
            if absolute.contains("id=12"), absolute.contains("page=1") {
                return MangaReaderDataTestResponse(html: listHTML(tid: "1201", title: "第1话", totalPages: 2))
            }
            if absolute.contains("id=12"), absolute.contains("page=2") {
                return MangaReaderDataTestResponse(html: "<html><body>empty follow-up page</body></html>")
            }
            if absolute.contains("id=34"), absolute.contains("page=1") {
                return MangaReaderDataTestResponse(html: listHTML(tid: "3401", title: "第2话", totalPages: 1))
            }
            return MangaReaderDataTestResponse(statusCode: 404, html: "missing")
        }

        let repository = YamiboMangaDirectoryRepository(client: testClient(session: harness.session))
        let chapters = try await repository.loadTagDirectory(tagIDs: [" 12 ", "", "12", "34"], allowedForumID: "30")

        #expect(chapters.map(\.tid) == ["1201", "3401"])
        #expect(chapters.map(\.groupIndex) == [0, 1])
        #expect(harness.requests.map { $0.url?.absoluteString ?? "" }.count == 3)
    }

    @Test func tagDirectoryKeepsOnlyRowsFromAllowedForum() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }

        harness.setHandler { _ in
            MangaReaderDataTestResponse(html: """
            <html><body>
              <table>
                \(listRowHTML(tid: "571415", title: "【提灯喵汉化组】因为今天女友不在 38", forumID: "30", forumName: "中文百合漫画区"))
                \(listRowHTML(tid: "570528", title: "香询问大家因为今天女友不在的漫画价格", forumID: "33", forumName: "海域區"))
              </table>
            </body></html>
            """)
        }

        // The explicitly passed board fid governs the row filter — rows from
        // any other board are dropped, including fid 30 (the old hardcoded
        // value), proving the filter is no longer pinned to board 30.
        let repository = YamiboMangaDirectoryRepository(client: YamiboClient(session: harness.session))
        let chapters = try await repository.loadTagDirectory(tagIDs: ["20013"], allowedForumID: "33")

        #expect(chapters.map(\.tid) == ["570528"])
    }

    @Test func tagDirectoryThrowsFloodControlInsteadOfReturningPartialResults() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }

        harness.setHandler { request in
            let absolute = request.url?.absoluteString ?? ""
            if absolute.contains("page=1") {
                return MangaReaderDataTestResponse(html: listHTML(tid: "1201", title: "第1话", totalPages: 2))
            }
            return MangaReaderDataTestResponse(html: "<html><body>防灌水</body></html>")
        }

        let repository = YamiboMangaDirectoryRepository(client: YamiboClient(session: harness.session))

        await #expect(throws: YamiboError.floodControl) {
            _ = try await repository.loadTagDirectory(tagIDs: ["12"], allowedForumID: "30")
        }
    }

    @Test func searchDirectoryFollowsPaginationAndDefaultsBlankForumID() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }

        harness.setHandler { request in
            let absolute = request.url?.absoluteString ?? ""
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1")
            if absolute.contains("srchtxt=%E4%BD%9C%E5%93%81") {
                #expect(absolute.contains("srchfid%5B%5D=30"))
                return MangaReaderDataTestResponse(html: """
                <html><body>
                  <a href="search.php?mod=forum&searchid=555&page=2">2</a>
                  <option value="1">1</option><option value="2">2</option>
                  \(listHTML(tid: "8001", title: "第1话", totalPages: 1))
                </body></html>
                """)
            }
            if absolute.contains("searchid=555"), absolute.contains("page=2") {
                return MangaReaderDataTestResponse(html: listHTML(tid: "8002", title: "第2话", totalPages: 1))
            }
            return MangaReaderDataTestResponse(statusCode: 404, html: "missing")
        }

        let repository = YamiboMangaDirectoryRepository(client: testClient(session: harness.session))
        let chapters = try await repository.searchDirectory(keyword: " 作品 ", forumID: " ")

        #expect(chapters.map(\.tid) == ["8001", "8002"])
    }

    @Test func searchDirectoryReturnsEmptyForBlankKeywordAndNoResultPage() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }

        let repository = YamiboMangaDirectoryRepository(client: YamiboClient(session: harness.session))
        let blank = try await repository.searchDirectory(keyword: "   ", forumID: "30")
        #expect(blank.isEmpty)
        #expect(harness.requests.isEmpty)

        harness.setHandler { _ in
            MangaReaderDataTestResponse(html: "<html><body>没有找到匹配结果</body></html>")
        }
        let none = try await repository.searchDirectory(keyword: "missing", forumID: "30")
        #expect(none.isEmpty)
    }

    private func expectSeedError(html: String, expected: YamiboError) async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }

        harness.setHandler { _ in
            MangaReaderDataTestResponse(html: html)
        }
        let repository = YamiboMangaDirectoryRepository(client: YamiboClient(session: harness.session))

        await #expect(throws: expected) {
            _ = try await repository.loadDirectorySeed(for: "702")
        }
    }

    private func testClient(session: URLSession) -> YamiboClient {
        YamiboClient(
            session: session,
            cookie: "auth=1",
            userAgent: "TestAgent/1"
        )
    }
}

private func listHTML(tid: String, title: String, totalPages: Int) -> String {
    let options = (1 ... max(1, totalPages))
        .map { #"<option value="\#($0)">\#($0)</option>"# }
        .joined()
    return """
    <table>
      \(options)
      \(listRowHTML(tid: tid, title: title, forumID: "30", forumName: "中文百合漫画区"))
    </table>
    """
}

private func listRowHTML(
    tid: String,
    title: String,
    forumID: String,
    forumName: String
) -> String {
    """
    <tr>
      <th><a href="forum.php?mod=viewthread&tid=\(tid)&mobile=2">\(title)</a></th>
      <td class="by"><a href="forum-\(forumID)-1.html">\(forumName)</a></td>
      <td class="by"><cite><a href="space-uid-77.html">作者甲</a></cite><em><span>2026-01-02</span></em></td>
    </tr>
    """
}

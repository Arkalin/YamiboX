import Foundation
import Testing
@testable import YamiboXCore

@Suite("Message unread HTML")
struct MessageUnreadHTMLParserTests {
    @Test(arguments: [(0, 0), (5, 0), (0, 7), (5, 7), (99, 1)])
    func parsesBothCounters(counts: (Int, Int)) throws {
        let html = fixture(privateMessages: badge(counts.0), notices: badge(counts.1))
        let summary = try MessageUnreadHTMLParser.parse(html)
        #expect(summary.privateMessageCount == counts.0)
        #expect(summary.noticeCount == counts.1)
        #expect(summary.totalCount == counts.0 + counts.1)
    }

    @Test func followsURLsRatherThanSelectedTabOrderOrLanguage() throws {
        let html = """
        <div class="dhnv">
          <a class="mon" href="https://bbs.yamibo.com/home.php?do=notice&amp;mobile=2&amp;mod=space">我的提醒<strong>（ 7 ）</strong></a>
          <a href="home.php?mobile=2&amp;do=pm&amp;mod=space">我的訊息</a>
        </div>
        <div class="dhnv"><a href="https://example.com/home.php?mod=space&amp;do=pm"><strong>(99)</strong></a></div>
        <div id="pmlist"><li><span class="mnum">123</span>未读 456</li></div>
        """
        let summary = try MessageUnreadHTMLParser.parse(html)
        #expect(summary == MessageUnreadSummary(privateMessageCount: 0, noticeCount: 7))
        let list = try UserSpaceHTMLParser.parsePrivateMessageList(from: html)
        #expect(list.unreadCount == 0)
    }

    @Test(arguments: ["<strong></strong>", "<strong>(-1)</strong>", "<strong>(1x)</strong>",
                      "<strong>(99+)</strong>", "<strong>(1)</strong><strong>(2)</strong>",
                      "<span>(8)</span>", "<strong>999999999999999999999999</strong>"])
    func rejectsDamagedBadges(_ badge: String) {
        #expect(throws: (any Error).self) {
            try MessageUnreadHTMLParser.parse(fixture(privateMessages: badge, notices: ""))
        }
    }

    @Test(arguments: ["", "<html>unrelated page</html>",
                      "<script>window.__noxExpire=1; var token='nox_jst_v1'</script>",
                      "<div class='dhnv'><a href='home.php?mod=space&amp;do=pm'>PM</a></div>"])
    func rejectsUnrecognizedPages(_ html: String) {
        #expect(throws: (any Error).self) { try MessageUnreadHTMLParser.parse(html) }
    }

    @Test func rejectsLoginEvenWithNavigationPresent() {
        let html = "<body class='pg_logging'>" + fixture(privateMessages: "", notices: "") + "</body>"
        #expect(throws: YamiboError.notAuthenticated) { try MessageUnreadHTMLParser.parse(html) }
    }

    @Test func rejectsConflictingCountersAndTotalOverflow() {
        let duplicate = fixture(privateMessages: badge(1), notices: "")
            + "<div class='dhnv'><a href='home.php?mod=space&amp;do=pm'><strong>(2)</strong></a></div>"
        #expect(throws: (any Error).self) { try MessageUnreadHTMLParser.parse(duplicate) }
        #expect(throws: (any Error).self) {
            try MessageUnreadHTMLParser.parse(fixture(privateMessages: badge(Int.max), notices: badge(1)))
        }
    }

    private func badge(_ count: Int) -> String { count == 0 ? "" : "<strong>(\(count))</strong>" }

    private func fixture(privateMessages: String, notices: String) -> String {
        """
        <div class="dhnv">
          <a class="mon" href="home.php?mod=space&amp;do=pm">我的消息\(privateMessages)</a>
          <a href="home.php?mod=space&amp;do=notice">我的提醒\(notices)</a>
        </div>
        """
    }
}

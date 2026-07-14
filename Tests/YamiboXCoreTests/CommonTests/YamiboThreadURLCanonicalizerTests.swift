import Foundation
import Testing
@testable import YamiboXCore

@Suite("YamiboThreadURLCanonicalizer")
struct YamiboThreadURLCanonicalizerTests {
    @Test func canonicalThreadURLRemovesRequestOnlyQueryItemsAndExtra() throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mobile=2&page=25&authorid=406769&tid=521519&mod=viewthread&extra=page%3D1"))

        let canonical = YamiboThreadURLCanonicalizer.canonicalThreadURL(from: url)

        #expect(canonical.absoluteString == "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=521519")
    }

    @Test func canonicalThreadURLIsStableForDifferentQueryOrder() throws {
        let first = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=521519&extra=page%3D1&mobile=2"))
        let second = try #require(URL(string: "https://bbs.yamibo.com/forum.php?authorid=406769&mobile=2&extra=page%3D1&tid=521519&page=25&mod=viewthread"))

        #expect(YamiboThreadURLCanonicalizer.canonicalThreadURL(from: first) == YamiboThreadURLCanonicalizer.canonicalThreadURL(from: second))
    }

    @Test func canonicalThreadURLMatchesURLsWithAndWithoutExtra() throws {
        let forumListURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?extra=page%3D1&mod=viewthread&tid=521519"))
        let readerURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=521519"))

        #expect(YamiboThreadURLCanonicalizer.canonicalThreadURL(from: forumListURL) == YamiboThreadURLCanonicalizer.canonicalThreadURL(from: readerURL))
        #expect(YamiboThreadURLCanonicalizer.canonicalThreadURL(from: forumListURL).absoluteString == "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=521519")
    }

    @Test func canonicalThreadURLResolvesRelativeForumURLs() throws {
        let url = try #require(URL(string: "forum.php?mod=viewthread&tid=123&page=3&mobile=2"))

        let canonical = YamiboThreadURLCanonicalizer.canonicalThreadURL(from: url)

        #expect(canonical.absoluteString == "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")
    }

    @Test func canonicalThreadURLUsesPTIDForFindPostURLs() throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?goto=findpost&mobile=2&mod=redirect&pid=987&ptid=54321"))

        let canonical = YamiboThreadURLCanonicalizer.canonicalThreadURL(from: url)

        #expect(canonical.absoluteString == "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=54321")
    }

    @Test func canonicalThreadURLSupportsRewriteThreadURLs() throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/thread-123-4-1.html"))

        let canonical = YamiboThreadURLCanonicalizer.canonicalThreadURL(from: url)

        #expect(canonical.absoluteString == "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")
    }

    @Test func readerCacheIdentityUsesThreadIDAsCacheKey() throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=521519&extra=page%3D1&mobile=2&page=25&authorid=406769"))
        let identity = NovelReaderCacheIdentity(threadID: "521519", view: 25, authorID: "406769")

        #expect(YamiboThreadURLCanonicalizer.canonicalThreadURL(from: url).absoluteString == "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=521519")
        #expect(identity.threadID == "521519")
        #expect(identity.threadKey == "tid:521519")
        #expect(!identity.cacheKey.contains("https://"))
    }
}

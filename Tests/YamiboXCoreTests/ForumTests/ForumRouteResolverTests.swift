import Foundation
import Testing
@testable import YamiboXCore

@Test func forumRouteResolverResolvesBoardURLs() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=forumdisplay&fid=5&page=3&mobile=2"))

    #expect(ForumRouteResolver.resolve(url: url) == .board(fid: "5", title: nil, page: 3))
}

@Test func forumRouteResolverResolvesRewriteBoardURLs() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum-370-2.html"))

    #expect(ForumRouteResolver.resolve(url: url) == .board(fid: "370", title: nil, page: 2))
}

@Test func forumRouteResolverResolvesThreadURLs() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/thread-570956-1-1.html"))

    #expect(ForumRouteResolver.resolve(url: url) == .thread(url))
}

@Test func forumRouteResolverResolvesFindPostURLsAsThreadTargets() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=redirect&goto=findpost&ptid=570956&pid=99&mobile=2"))

    #expect(ForumRouteResolver.resolve(url: url) == .thread(url))
}

@Test func forumRouteResolverKeepsThreadReplyActionInWebFallback() throws {
    let url = YamiboRoute.threadReply(tid: "570956", page: 2).url

    #expect(ForumRouteResolver.resolve(url: url) == .web(url))
}

@Test func forumRouteResolverResolvesUserSpaceURLs() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/home.php?mod=space&uid=705216&mobile=2"))

    #expect(ForumRouteResolver.resolve(url: url) == .userSpace(uid: "705216", name: nil))
}

@Test func forumRouteResolverResolvesRewriteUserSpaceURLs() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/space-uid-705216.html"))

    #expect(ForumRouteResolver.resolve(url: url) == .userSpace(uid: "705216", name: nil))
}

@Test func forumRouteResolverResolvesBlogURLs() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/home.php?mod=space&do=blog&id=88&uid=705216&mobile=2"))

    #expect(ForumRouteResolver.resolve(url: url) == .blog(blogID: "88", uid: "705216", title: nil))
}

@Test func forumRouteResolverResolvesPrivateMessageURLs() throws {
    // Touch-template conversation links (`space_pm.htm`).
    let touchURL = try #require(URL(string: "https://bbs.yamibo.com/home.php?mod=space&do=pm&subop=view&touid=800001&mobile=2"))
    // Legacy desktop conversation links.
    let legacyURL = try #require(URL(string: "https://bbs.yamibo.com/home.php?mod=spacecp&ac=pm&op=showmsg&touid=800001&mobile=2"))

    #expect(ForumRouteResolver.resolve(url: touchURL) == .privateMessage(uid: "800001", name: nil))
    #expect(ForumRouteResolver.resolve(url: legacyURL) == .privateMessage(uid: "800001", name: nil))
}

@Test func forumRouteResolverResolvesMessageCenterURLs() throws {
    let privateMessagesURL = YamiboRoute.userSpacePrivateMessages(page: 2).url
    let noticesURL = YamiboRoute.userSpaceNotices(page: 3).url

    #expect(ForumRouteResolver.resolve(url: privateMessagesURL) == .messageCenter(tab: .privateMessages))
    #expect(ForumRouteResolver.resolve(url: noticesURL) == .messageCenter(tab: .notices))
}

@Test func forumRouteResolverResolvesRewriteBlogURLs() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/blog-705216-88.html"))

    #expect(ForumRouteResolver.resolve(url: url) == .blog(blogID: "88", uid: "705216", title: nil))
}

@Test func forumRouteResolverResolvesReaderOriginThreadURLs() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=570956&page=2#pid99"))

    #expect(ForumRouteResolver.resolve(url: url, source: .readerOrigin) == .thread(url))
}

@Test func forumRouteResolverResolvesReaderOriginFindPostURLsAsThreadTargets() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=redirect&goto=findpost&ptid=570956&pid=99&mobile=2"))

    #expect(ForumRouteResolver.resolve(url: url, source: .readerOrigin) == .thread(url))
}

@Test func forumRouteResolverResolvesHomeURL() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mobile=2"))

    #expect(ForumRouteResolver.resolve(url: url) == .home)
}

@Test func forumRouteResolverKeepsUnsupportedForumURLsInWebFallback() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=announcement&id=17&mobile=2"))

    #expect(ForumRouteResolver.resolve(url: url) == .web(url))
}

@Test func forumBoardRouteIncludesFilterAndOrderQueryItems() throws {
    let url = YamiboRoute.forumBoard(
        fid: "5",
        page: 2,
        filterID: "400",
        orderFilter: "lastpost",
        orderBy: "lastpost"
    ).url
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

    #expect(items.value(named: "fid") == "5")
    #expect(items.value(named: "page") == "2")
    #expect(items.values(named: "filter") == ["typeid", "lastpost"])
    #expect(items.value(named: "typeid") == "400")
    #expect(items.value(named: "orderby") == "lastpost")
}

@Test func forumBoardFavoriteRouteIncludesFormHash() throws {
    let url = YamiboRoute.forumBoardFavorite(fid: "5", formHash: "f47bb54f").url
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

    #expect(url.path == "/home.php")
    #expect(items.value(named: "mod") == "spacecp")
    #expect(items.value(named: "ac") == "favorite")
    #expect(items.value(named: "type") == "forum")
    #expect(items.value(named: "id") == "5")
    #expect(items.value(named: "formhash") == "f47bb54f")
}

@Test func forumSearchRouteIncludesTitleSearchFormHashAndOptionalForumScope() throws {
    let url = YamiboRoute.forumSearch(keyword: "百合 搜索", forumID: "5", formHash: "f47bb54f").url
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)

    #expect(components.path == "/search.php")
    #expect(items.value(named: "mod") == "forum")
    #expect(items.value(named: "searchsubmit") == "yes")
    #expect(items.value(named: "formhash") == "f47bb54f")
    #expect(items.value(named: "srchtype") == "title")
    #expect(items.value(named: "srchtxt") == "百合 搜索")
    #expect(items.value(named: "srchfid[]") == "5")
}

@Test func forumSearchPageRouteIncludesSearchID() throws {
    let url = YamiboRoute.forumSearchPage(searchID: "99", page: 3).url
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

    #expect(items.value(named: "mod") == "forum")
    #expect(items.value(named: "searchid") == "99")
    #expect(items.value(named: "page") == "3")
}

@Test func threadPostReplyRouteTargetsReplyAction() throws {
    let url = YamiboRoute.threadPostReply(tid: "704", pid: "4001", page: 2).url
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

    #expect(url.path == "/forum.php")
    #expect(items.value(named: "mod") == "post")
    #expect(items.value(named: "action") == "reply")
    #expect(items.value(named: "tid") == "704")
    #expect(items.value(named: "repquote") == "4001")
    #expect(items.value(named: "extra") == "")
    #expect(items.value(named: "page") == "2")
    #expect(items.value(named: "mobile") == "2")
}

@Test func threadReplyRouteTargetsWholeThreadReplyAction() throws {
    let url = YamiboRoute.threadReply(tid: "704", page: 3).url
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

    #expect(url.path == "/forum.php")
    #expect(items.value(named: "mod") == "post")
    #expect(items.value(named: "action") == "reply")
    #expect(items.value(named: "tid") == "704")
    #expect(items.value(named: "reppost") == "0")
    #expect(items.value(named: "page") == "3")
    #expect(items.value(named: "mobile") == "2")
}

@Test func userSpaceRoutesIncludeUidDoAndPage() throws {
    let profileURL = YamiboRoute.userSpaceProfile(uid: "705216").url
    let threadURL = YamiboRoute.userSpaceThreads(uid: "705216", page: 2).url
    let replyURL = YamiboRoute.userSpaceReplies(uid: "705216", page: 3).url
    let blogURL = YamiboRoute.userSpaceBlogs(uid: "705216", page: 4).url
    let friendURL = YamiboRoute.userSpaceFriends(uid: "705216", page: 5).url
    let friendBlogsURL = YamiboRoute.userSpaceFriendBlogs(page: 6).url
    let viewAllBlogsURL = YamiboRoute.userSpaceViewAllBlogs(filter: .hot, page: 7).url
    let onlineURL = YamiboRoute.userSpaceFriendPage(type: .onlineMember, page: 8).url
    let visitorsURL = YamiboRoute.userSpaceFriendPage(type: .myVisitor, page: 9).url
    let tracesURL = YamiboRoute.userSpaceFriendPage(type: .myTrace, page: 10).url
    let addFriendURL = YamiboRoute.userSpaceAddFriendForm(uid: "705216").url
    let privateMessageURL = YamiboRoute.privateMessage(uid: "800001", page: 2).url
    let privateMessageSendURL = YamiboRoute.privateMessageSend(privateMessageID: "900", uid: "800001").url
    let readerURL = YamiboRoute.blog(blogID: "88", uid: "705216", page: 2).url
    let blogCommentURL = YamiboRoute.blogComment(blogID: "88", uid: "705216").url
    let blogEditorURL = YamiboRoute.userSpaceBlogEditor.url

    #expect(try #require(URLComponents(url: profileURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "do") == "profile")
    #expect(try #require(URLComponents(url: threadURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "do") == "thread")
    #expect(try #require(URLComponents(url: threadURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "page") == "2")
    #expect(try #require(URLComponents(url: replyURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "view") == "reply")
    #expect(try #require(URLComponents(url: blogURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "do") == "blog")
    #expect(try #require(URLComponents(url: friendURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "do") == "friend")
    #expect(try #require(URLComponents(url: friendBlogsURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "view") == "we")
    #expect(try #require(URLComponents(url: viewAllBlogsURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "order") == "hot")
    #expect(try #require(URLComponents(url: onlineURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "view") == "online")
    #expect(try #require(URLComponents(url: onlineURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "type") == "member")
    #expect(try #require(URLComponents(url: visitorsURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "view") == "visitor")
    #expect(try #require(URLComponents(url: tracesURL, resolvingAgainstBaseURL: false)?.queryItems).value(named: "view") == "trace")
    let addFriendItems = try #require(URLComponents(url: addFriendURL, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(addFriendItems.value(named: "mod") == "spacecp")
    #expect(addFriendItems.value(named: "ac") == "friend")
    #expect(addFriendItems.value(named: "op") == "add")
    #expect(addFriendItems.value(named: "uid") == "705216")
    #expect(addFriendItems.value(named: "handlekey") == "addfriendhk_705216")
    #expect(addFriendItems.value(named: "inajax") == "1")
    let privateMessageItems = try #require(URLComponents(url: privateMessageURL, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(privateMessageItems.value(named: "mod") == "space")
    #expect(privateMessageItems.value(named: "do") == "pm")
    #expect(privateMessageItems.value(named: "subop") == "view")
    #expect(privateMessageItems.value(named: "touid") == "800001")
    #expect(privateMessageItems.value(named: "page") == "2")
    let privateMessageSendItems = try #require(URLComponents(url: privateMessageSendURL, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(privateMessageSendItems.value(named: "mod") == "spacecp")
    #expect(privateMessageSendItems.value(named: "ac") == "pm")
    #expect(privateMessageSendItems.value(named: "op") == "send")
    #expect(privateMessageSendItems.value(named: "pmid") == "900")
    #expect(privateMessageSendItems.value(named: "touid") == "800001")
    let readerItems = try #require(URLComponents(url: readerURL, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(readerItems.value(named: "do") == "blog")
    #expect(readerItems.value(named: "id") == "88")
    #expect(readerItems.value(named: "uid") == "705216")
    #expect(readerItems.value(named: "page") == "2")
    let blogCommentItems = try #require(URLComponents(url: blogCommentURL, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(blogCommentItems.value(named: "mod") == "spacecp")
    #expect(blogCommentItems.value(named: "ac") == "comment")
    #expect(blogCommentItems.value(named: "op") == "add")
    #expect(blogCommentItems.value(named: "id") == "88")
    #expect(blogCommentItems.value(named: "idtype") == "blogid")
    #expect(blogCommentItems.value(named: "uid") == "705216")
    let blogEditorItems = try #require(URLComponents(url: blogEditorURL, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(blogEditorItems.value(named: "mod") == "spacecp")
    #expect(blogEditorItems.value(named: "ac") == "blog")
    #expect(blogEditorItems.value(named: "mobile") == "2")
}

private extension Array where Element == URLQueryItem {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }

    func values(named name: String) -> [String] {
        filter { $0.name == name }.compactMap(\.value)
    }
}

import Foundation
import Testing
@testable import YamiboXCore

@Suite("YamiboRoute")
struct YamiboRouteTests {
    @Test func threadRouteNormalizesDuplicateQueryKeysWithoutTrapping() throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?tid=123&page=9&page=8&mobile=no&mobile=1&authorid=77"))

        let routed = YamiboRoute.thread(url: url, page: 1, authorID: nil).url
        let components = try #require(URLComponents(url: routed, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.path == "/forum.php")
        #expect(items["tid"] == "123")
        #expect(items["page"] == "1")
        #expect(items["mobile"] == "2")
        #expect(items["mod"] == "viewthread")
        #expect(items["authorid"] == "77")
    }

    @Test func threadRouteOverridesAuthorIDWhenProvided() throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123&authorid=77"))

        let routed = YamiboRoute.thread(url: url, page: 2, authorID: "88").url
        let components = try #require(URLComponents(url: routed, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(items["page"] == "2")
        #expect(items["authorid"] == "88")
    }

    @Test func threadRouteDecodesHTMLEntitiesBeforeNormalizingQueryItems() throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&amp;tid=501595&amp;extra=&amp;mobile=2"))

        let routed = YamiboRoute.thread(url: url, page: 1, authorID: nil).url
        let components = try #require(URLComponents(url: routed, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.path == "/forum.php")
        #expect(items["tid"] == "501595")
        #expect(items["amp;tid"] == nil)
        #expect(items["mobile"] == "2")
        #expect(items["mod"] == "viewthread")
    }

    @Test func boardFavoritesRouteRequestsForumTypeFavoriteList() throws {
        let routed = YamiboRoute.boardFavorites(page: 2).url
        let components = try #require(URLComponents(url: routed, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.path == "/home.php")
        #expect(items["mod"] == "space")
        #expect(items["do"] == "favorite")
        #expect(items["view"] == "me")
        #expect(items["type"] == "forum")
        #expect(items["mobile"] == "2")
        #expect(items["page"] == "2")
    }

    @Test func threadByIDRouteBuildsRequestURLWithoutSourceThreadURL() throws {
        let routed = YamiboRoute.threadByID(tid: " 521519 ", page: 25, authorID: "406769", reverse: true).url
        let components = try #require(URLComponents(url: routed, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "bbs.yamibo.com")
        #expect(components.path == "/forum.php")
        #expect(items["tid"] == "521519")
        #expect(items["page"] == "25")
        #expect(items["authorid"] == "406769")
        #expect(items["ordertype"] == "1")
        #expect(items["mobile"] == "2")
        #expect(items["mod"] == "viewthread")
    }
}

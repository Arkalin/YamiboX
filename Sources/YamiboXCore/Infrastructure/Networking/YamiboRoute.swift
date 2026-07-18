import Foundation

public enum YamiboRoute: Sendable {
    case favorites(page: Int)
    case boardFavorites(page: Int)
    case favoriteDeleteForm
    case favoriteDelete
    case threadFavorite(tid: String, formHash: String)
    case login
    case currentProfile
    case logout(formHash: String)
    case tag(id: String, page: Int)
    case search(keyword: String, forumID: String)
    case searchPage(searchID: String, page: Int)
    case forumSearch(keyword: String, forumID: String?, formHash: String)
    case forumSearchPage(searchID: String, page: Int)
    case thread(url: URL, page: Int, authorID: String?)
    case threadByID(tid: String, page: Int, authorID: String?, reverse: Bool)
    case forumHome
    case forumBoard(fid: String, page: Int, filterID: String?, orderFilter: String?, orderBy: String?)
    case forumBoardFavorite(fid: String, formHash: String)
    case userSpaceProfile(uid: String?)
    case userSpaceThreads(uid: String?, page: Int)
    case userSpaceReplies(uid: String?, page: Int)
    case userSpaceBlogs(uid: String?, page: Int)
    case userSpaceMyBlogs(uid: String?, page: Int)
    case userSpaceFriendBlogs(page: Int)
    case userSpaceViewAllBlogs(filter: UserSpaceViewAllBlogFilter, page: Int)
    case userSpaceFriends(uid: String?, page: Int)
    case userSpaceFriendPage(type: UserSpaceFriendType, page: Int)
    case userSpaceAddFriendForm(uid: String)
    case userSpaceAddFriendSubmit(uid: String)
    case userSpaceBlogEditor
    case userSpacePrivateMessages(page: Int)
    case userSpaceNotices(page: Int)
    case userSpaceSendPrivateMessage
    case privateMessage(uid: String, page: Int?)
    case privateMessageSend(privateMessageID: String, uid: String)
    case blog(blogID: String, uid: String?, page: Int)
    case blogComment(blogID: String, uid: String)
    case threadRateOptions(tid: String, pid: String)
    case threadRatingResults(tid: String, pid: String)
    case threadRateSubmit
    case threadPostComment(tid: String, pid: String, page: Int)
    case threadPollVoters(tid: String, pollOptionID: String?, page: Int)
    case threadPollVote(fid: String, tid: String)
    case threadReply(tid: String, page: Int)
    case threadPostReply(tid: String, pid: String, page: Int)

    public static func findPostURL(threadURL: URL, postID: String?) -> URL? {
        let normalizedPostID = postID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedPostID.isEmpty else { return nil }

        let resolvedURL = URL(string: threadURL.absoluteString, relativeTo: YamiboDomain.baseURL)?.absoluteURL ?? threadURL.absoluteURL
        let queryThreadID = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "tid" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = (queryThreadID?.isEmpty == false ? queryThreadID : nil)
            ?? MangaTitleCleaner.extractTid(from: resolvedURL.absoluteString)

        guard let threadID, !threadID.isEmpty else { return nil }

        var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)
            ?? URLComponents(url: YamiboDomain.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme ?? YamiboDomain.baseURL.scheme
        components.host = components.host ?? YamiboDomain.baseURL.host
        components.path = "/forum.php"
        components.queryItems = [
            .init(name: "goto", value: "findpost"),
            .init(name: "mobile", value: "2"),
            .init(name: "mod", value: "redirect"),
            .init(name: "pid", value: normalizedPostID),
            .init(name: "ptid", value: threadID)
        ]
        return components.url
    }

    public static func findPostURL(threadID: String, postID: String?) -> URL? {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return nil }
        return findPostURL(
            threadURL: Self.threadByID(tid: normalizedThreadID, page: 1, authorID: nil, reverse: false).url,
            postID: postID
        )
    }

    public var url: URL {
        switch self {
        case let .favorites(page):
            return Self.makeURL(path: "/home.php", queryItems: [
                .init(name: "mod", value: "space"),
                .init(name: "do", value: "favorite"),
                .init(name: "view", value: "me"),
                .init(name: "type", value: "thread"),
                .init(name: "mobile", value: "2"),
                .init(name: "page", value: String(page))
            ])
        case let .boardFavorites(page):
            return Self.makeURL(path: "/home.php", queryItems: [
                .init(name: "mod", value: "space"),
                .init(name: "do", value: "favorite"),
                .init(name: "view", value: "me"),
                .init(name: "type", value: "forum"),
                .init(name: "mobile", value: "2"),
                .init(name: "page", value: String(max(1, page)))
            ])
        case .favoriteDeleteForm:
            return Self.makeURL(path: "/misc.php", queryItems: [
                .init(name: "mod", value: "faq")
            ])
        case .favoriteDelete:
            return Self.makeURL(path: "/home.php", queryItems: [
                .init(name: "mod", value: "spacecp"),
                .init(name: "ac", value: "favorite"),
                .init(name: "op", value: "delete"),
                .init(name: "type", value: "all"),
                .init(name: "checkall", value: "1")
            ])
        case let .threadFavorite(tid, formHash):
            return Self.makeURL(path: "/home.php", queryItems: [
                .init(name: "mod", value: "spacecp"),
                .init(name: "ac", value: "favorite"),
                .init(name: "type", value: "thread"),
                .init(name: "id", value: tid),
                .init(name: "handlekey", value: "favoritethread"),
                .init(name: "formhash", value: formHash),
                .init(name: "mobile", value: "2")
            ])
        case .login:
            return Self.makeURL(path: "/member.php", queryItems: [
                .init(name: "mod", value: "logging"),
                .init(name: "action", value: "login"),
                .init(name: "mobile", value: "2")
            ])
        case .currentProfile:
            return Self.makeURL(path: "/home.php", queryItems: [
                .init(name: "mod", value: "space"),
                .init(name: "do", value: "profile"),
                .init(name: "mycenter", value: "1"),
                .init(name: "mobile", value: "2")
            ])
        case let .logout(formHash):
            return Self.makeURL(path: "/member.php", queryItems: [
                .init(name: "mod", value: "logging"),
                .init(name: "action", value: "logout"),
                .init(name: "formhash", value: formHash),
                .init(name: "mobile", value: "2")
            ])
        case let .tag(id, page):
            return Self.makeURL(path: "/misc.php", queryItems: [
                .init(name: "mod", value: "tag"),
                .init(name: "type", value: "thread"),
                .init(name: "mobile", value: "no"),
                .init(name: "id", value: id),
                .init(name: "page", value: String(page))
            ])
        case let .search(keyword, forumID):
            return Self.makeURL(path: "/search.php", percentEncodedQuery: [
                "mod=forum",
                "searchsubmit=yes",
                "mobile=2",
                "srchfid%5B%5D=\(forumID)",
                "srchtxt=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)",
                "srchtype=title"
            ].joined(separator: "&"))
        case let .searchPage(searchID, page):
            return Self.makeURL(path: "/search.php", queryItems: [
                .init(name: "mod", value: "forum"),
                .init(name: "orderby", value: "dateline"),
                .init(name: "ascdesc", value: "desc"),
                .init(name: "searchsubmit", value: "yes"),
                .init(name: "mobile", value: "2"),
                .init(name: "searchid", value: searchID),
                .init(name: "page", value: String(page))
            ])
        case let .forumSearch(keyword, forumID, formHash):
            var items: [URLQueryItem] = [
                .init(name: "mod", value: "forum"),
                .init(name: "searchsubmit", value: "yes"),
                .init(name: "mobile", value: "2"),
                .init(name: "formhash", value: formHash),
                .init(name: "srchtxt", value: keyword),
                .init(name: "srchtype", value: "title")
            ]
            if let forumID, !forumID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(.init(name: "srchfid[]", value: forumID))
            }
            return Self.makeURL(path: "/search.php", queryItems: items)
        case let .forumSearchPage(searchID, page):
            return Self.makeURL(path: "/search.php", queryItems: [
                .init(name: "mod", value: "forum"),
                .init(name: "orderby", value: "dateline"),
                .init(name: "ascdesc", value: "desc"),
                .init(name: "searchsubmit", value: "yes"),
                .init(name: "mobile", value: "2"),
                .init(name: "searchid", value: searchID),
                .init(name: "page", value: String(max(1, page)))
            ])
        case let .thread(url, page, authorID):
            // Unlike every constant route below, this one re-anchors a URL we
            // were handed (possibly host-relative, possibly HTML-escaped), so
            // it cannot go through `makeURL`.
            let decodedURLString = HTMLTextExtractor.decodeHTMLEntities(url.absoluteString)
            var components = URLComponents(
                url: URL(string: decodedURLString, relativeTo: YamiboDomain.baseURL)?.absoluteURL ?? url.absoluteURL,
                resolvingAgainstBaseURL: false
            ) ?? URLComponents(url: YamiboDomain.baseURL, resolvingAgainstBaseURL: false)!
            if components.host == nil {
                components.scheme = YamiboDomain.baseURL.scheme
                components.host = YamiboDomain.baseURL.host
            }
            if components.path.isEmpty {
                components.path = "/forum.php"
            }

            var items: [String: String?] = [:]
            for item in components.queryItems ?? [] {
                guard let value = item.value, !value.isEmpty else { continue }
                items[item.name] = value
            }
            items["mod"] = "viewthread"
            items["page"] = String(max(1, page))
            items["mobile"] = "2"
            if let authorID, !authorID.isEmpty {
                items["authorid"] = authorID
            }
            components.queryItems = items
                .map { URLQueryItem(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
            return components.url!
        case let .threadByID(tid, page, authorID, reverse):
            var items: [URLQueryItem] = [
                .init(name: "mobile", value: "2"),
                .init(name: "mod", value: "viewthread"),
                .init(name: "page", value: String(max(1, page))),
                .init(name: "tid", value: tid.trimmingCharacters(in: .whitespacesAndNewlines))
            ]
            if let authorID = authorID?.trimmingCharacters(in: .whitespacesAndNewlines), !authorID.isEmpty {
                items.append(.init(name: "authorid", value: authorID))
            }
            if reverse {
                items.append(.init(name: "ordertype", value: "1"))
            }
            return Self.makeURL(path: "/forum.php", queryItems: items.sorted { $0.name < $1.name })
        case .forumHome:
            return Self.makeURL(path: "/forum.php", queryItems: [
                .init(name: "mobile", value: "2")
            ])
        case let .forumBoard(fid, page, filterID, orderFilter, orderBy):
            var items: [URLQueryItem] = [
                .init(name: "mod", value: "forumdisplay"),
                .init(name: "fid", value: fid),
                .init(name: "mobile", value: "2"),
                .init(name: "page", value: String(max(1, page)))
            ]
            if let filterID, !filterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(.init(name: "filter", value: "typeid"))
                items.append(.init(name: "typeid", value: filterID))
            }
            if let orderFilter, !orderFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(.init(name: "filter", value: orderFilter))
            }
            if let orderBy, !orderBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(.init(name: "orderby", value: orderBy))
            }
            return Self.makeURL(path: "/forum.php", queryItems: items)
        case let .forumBoardFavorite(fid, formHash):
            return Self.makeURL(path: "/home.php", queryItems: [
                .init(name: "mod", value: "spacecp"),
                .init(name: "ac", value: "favorite"),
                .init(name: "type", value: "forum"),
                .init(name: "id", value: fid),
                .init(name: "handlekey", value: "favoriteforum"),
                .init(name: "formhash", value: formHash),
                .init(name: "mobile", value: "2")
            ])
        case let .userSpaceProfile(uid):
            return userSpaceURL(uid: uid, doValue: "profile", page: nil)
        case let .userSpaceThreads(uid, page):
            return userSpaceURL(uid: uid, doValue: "thread", page: page)
        case let .userSpaceReplies(uid, page):
            // The reply tab is selected by `type=reply` (with `view=me`);
            // `view=reply` is not a Discuz view and falls back to the thread list.
            return userSpaceURL(
                uid: uid,
                doValue: "thread",
                page: page,
                view: "me",
                extraItems: [.init(name: "type", value: "reply")]
            )
        case let .userSpaceBlogs(uid, page):
            return userSpaceURL(uid: uid, doValue: "blog", page: page, view: "me")
        case let .userSpaceMyBlogs(uid, page):
            return userSpaceURL(uid: uid, doValue: "blog", page: page)
        case let .userSpaceFriendBlogs(page):
            return userSpaceURL(uid: nil, doValue: "blog", page: page, view: "we")
        case let .userSpaceViewAllBlogs(filter, page):
            return userSpaceURL(
                uid: nil,
                doValue: "blog",
                page: page,
                view: "all",
                extraItems: [.init(name: "order", value: filter.routeOrderValue)]
            )
        case let .userSpaceFriends(uid, page):
            return userSpaceURL(uid: uid, doValue: "friend", page: page, view: "me")
        case let .userSpaceFriendPage(type, page):
            return userSpaceURL(
                uid: nil,
                doValue: "friend",
                page: page,
                view: type.routeViewValue,
                extraItems: type.routeExtraItems
            )
        case let .userSpaceAddFriendForm(uid), let .userSpaceAddFriendSubmit(uid):
            return userSpaceAddFriendURL(uid: uid)
        case .userSpaceBlogEditor:
            return Self.makeURL(path: "/home.php", queryItems: [
                .init(name: "mod", value: "spacecp"),
                .init(name: "ac", value: "blog"),
                .init(name: "mobile", value: "2")
            ])
        case let .userSpacePrivateMessages(page):
            return userSpaceURL(uid: nil, doValue: "pm", page: page)
        case let .userSpaceNotices(page):
            return userSpaceURL(uid: nil, doValue: "notice", page: page)
        case .userSpaceSendPrivateMessage:
            // Compose entry used by the touch template itself (no `op`).
            return Self.makeURL(path: "/home.php", queryItems: [
                .init(name: "mod", value: "spacecp"),
                .init(name: "ac", value: "pm"),
                .init(name: "mobile", value: "2")
            ])
        case let .privateMessage(uid, page):
            return privateMessageURL(uid: uid, page: page)
        case let .privateMessageSend(privateMessageID, uid):
            return privateMessageSendURL(privateMessageID: privateMessageID, uid: uid)
        case let .blog(blogID, uid, page):
            var items: [URLQueryItem] = [
                .init(name: "mod", value: "space"),
                .init(name: "do", value: "blog"),
                .init(name: "id", value: blogID),
                .init(name: "mobile", value: "2"),
                .init(name: "page", value: String(max(1, page)))
            ]
            if let uid, !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(.init(name: "uid", value: uid))
            }
            return Self.makeURL(path: "/home.php", queryItems: items)
        case let .blogComment(blogID, uid):
            return Self.makeURL(path: "/home.php", queryItems: [
                .init(name: "mod", value: "spacecp"),
                .init(name: "ac", value: "comment"),
                .init(name: "op", value: "add"),
                .init(name: "id", value: blogID),
                .init(name: "idtype", value: "blogid"),
                .init(name: "uid", value: uid),
                .init(name: "mobile", value: "2")
            ])
        case let .threadRateOptions(tid, pid):
            return Self.makeURL(path: "/forum.php", queryItems: [
                .init(name: "mod", value: "misc"),
                .init(name: "action", value: "rate"),
                .init(name: "tid", value: tid),
                .init(name: "pid", value: pid),
                .init(name: "mobile", value: "2"),
                .init(name: "infloat", value: "yes"),
                .init(name: "handlekey", value: "rate"),
                .init(name: "inajax", value: "1")
            ])
        case let .threadRatingResults(tid, pid):
            return Self.makeURL(path: "/forum.php", queryItems: [
                .init(name: "mod", value: "misc"),
                .init(name: "action", value: "viewratings"),
                .init(name: "tid", value: tid),
                .init(name: "pid", value: pid),
                .init(name: "mobile", value: "2"),
                .init(name: "inajax", value: "1")
            ])
        case .threadRateSubmit:
            return Self.makeURL(path: "/forum.php", queryItems: [
                .init(name: "mod", value: "misc"),
                .init(name: "action", value: "rate"),
                .init(name: "ratesubmit", value: "yes"),
                .init(name: "infloat", value: "yes"),
                .init(name: "inajax", value: "1"),
                .init(name: "handlekey", value: "rateform"),
                .init(name: "inajax", value: "1")
            ])
        case let .threadPostComment(tid, pid, page):
            return Self.makeURL(path: "/forum.php", queryItems: [
                .init(name: "mod", value: "post"),
                .init(name: "action", value: "reply"),
                .init(name: "comment", value: "yes"),
                .init(name: "tid", value: tid),
                .init(name: "pid", value: pid),
                .init(name: "extra", value: ""),
                .init(name: "page", value: String(max(1, page))),
                .init(name: "commentsubmit", value: "yes"),
                .init(name: "infloat", value: "yes"),
                .init(name: "inajax", value: "1"),
                .init(name: "handlekey", value: "commentform"),
                .init(name: "inajax", value: "1")
            ])
        case let .threadPollVoters(tid, pollOptionID, page):
            var items: [URLQueryItem] = [
                .init(name: "mod", value: "misc"),
                .init(name: "action", value: "viewvote"),
                .init(name: "tid", value: tid),
                .init(name: "mobile", value: "2"),
                .init(name: "inajax", value: "1")
            ]
            if page != 1 {
                items.append(.init(name: "page", value: String(max(1, page))))
            }
            if let pollOptionID = pollOptionID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pollOptionID.isEmpty {
                items.append(.init(name: "polloptionid", value: pollOptionID))
            }
            return Self.makeURL(path: "/forum.php", queryItems: items)
        case let .threadPollVote(fid, tid):
            return Self.makeURL(path: "/forum.php", queryItems: [
                .init(name: "mod", value: "misc"),
                .init(name: "action", value: "votepoll"),
                .init(name: "fid", value: fid),
                .init(name: "tid", value: tid),
                .init(name: "mobile", value: "2")
            ])
        case let .threadReply(tid, page):
            return Self.makeURL(path: "/forum.php", queryItems: [
                .init(name: "mod", value: "post"),
                .init(name: "action", value: "reply"),
                .init(name: "tid", value: tid),
                .init(name: "reppost", value: "0"),
                .init(name: "page", value: String(max(1, page))),
                .init(name: "mobile", value: "2")
            ])
        case let .threadPostReply(tid, pid, page):
            return Self.makeURL(path: "/forum.php", queryItems: [
                .init(name: "mod", value: "post"),
                .init(name: "action", value: "reply"),
                .init(name: "tid", value: tid),
                .init(name: "repquote", value: pid),
                .init(name: "extra", value: ""),
                .init(name: "page", value: String(max(1, page))),
                .init(name: "mobile", value: "2")
            ])
        }
    }

    private func userSpaceURL(
        uid: String?,
        doValue: String,
        page: Int?,
        view: String? = nil,
        extraItems: [URLQueryItem] = []
    ) -> URL {
        var items: [URLQueryItem] = [
            .init(name: "mod", value: "space"),
            .init(name: "do", value: doValue),
            .init(name: "mobile", value: "2")
        ]
        if let uid, !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(.init(name: "uid", value: uid))
        } else if doValue == "profile" {
            items.append(.init(name: "mycenter", value: "1"))
        }
        if let view {
            items.append(.init(name: "view", value: view))
        }
        if let page {
            items.append(.init(name: "page", value: String(max(1, page))))
        }
        items.append(contentsOf: extraItems)
        return Self.makeURL(path: "/home.php", queryItems: items)
    }

    private func userSpaceAddFriendURL(uid: String) -> URL {
        Self.makeURL(path: "/home.php", queryItems: [
            .init(name: "mod", value: "spacecp"),
            .init(name: "ac", value: "friend"),
            .init(name: "op", value: "add"),
            .init(name: "uid", value: uid),
            .init(name: "handlekey", value: "addfriendhk_\(uid)"),
            .init(name: "inajax", value: "1"),
            .init(name: "mobile", value: "2")
        ])
    }

    private func privateMessageURL(uid: String, page: Int?) -> URL {
        // Touch conversation view (`space_pm.htm` subop=view branch). The
        // desktop `spacecp&ac=pm&op=showmsg` form has no touch template.
        var items: [URLQueryItem] = [
            .init(name: "mod", value: "space"),
            .init(name: "do", value: "pm"),
            .init(name: "subop", value: "view"),
            .init(name: "touid", value: uid),
            .init(name: "mobile", value: "2")
        ]
        if let page {
            items.append(.init(name: "page", value: String(max(1, page))))
        }
        return Self.makeURL(path: "/home.php", queryItems: items)
    }

    private func privateMessageSendURL(privateMessageID: String, uid: String) -> URL {
        Self.makeURL(path: "/home.php", queryItems: [
            .init(name: "mod", value: "spacecp"),
            .init(name: "ac", value: "pm"),
            .init(name: "op", value: "send"),
            .init(name: "pmid", value: privateMessageID),
            .init(name: "touid", value: uid),
            .init(name: "mobile", value: "2")
        ])
    }

    /// Every constant route hangs off `YamiboDomain.baseURL` with just a path
    /// and query, so this factory is the single home for that boilerplate.
    /// The force unwraps are deliberate: `baseURL` is a compile-time constant
    /// known to parse, and `path`/`queryItems` are code-constructed values —
    /// a nil from either call can only mean a malformed route definition,
    /// i.e. a programmer error that should trap in development rather than
    /// limp along with a wrong URL.
    private static func makeURL(path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: YamiboDomain.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = queryItems
        return components.url!
    }

    /// Variant for `search`, whose Discuz endpoint needs hand-percent-encoded
    /// pairs (`srchfid%5B%5D=...`) that `queryItems` would encode differently.
    /// Same force-unwrap rationale as above.
    private static func makeURL(path: String, percentEncodedQuery: String) -> URL {
        var components = URLComponents(url: YamiboDomain.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.percentEncodedQuery = percentEncodedQuery
        return components.url!
    }
}

private extension UserSpaceViewAllBlogFilter {
    var routeOrderValue: String {
        switch self {
        case .latest:
            "dateline"
        case .hot:
            "hot"
        }
    }
}

private extension UserSpaceFriendType {
    var routeViewValue: String {
        switch self {
        case .myFriend:
            "me"
        case .onlineMember:
            "online"
        case .myVisitor:
            "visitor"
        case .myTrace:
            "trace"
        }
    }

    var routeExtraItems: [URLQueryItem] {
        switch self {
        case .onlineMember:
            [.init(name: "type", value: "member")]
        case .myFriend, .myVisitor, .myTrace:
            []
        }
    }
}

import Foundation

enum UserSpaceHTMLParser {
    static func parseProfile(from html: String, uidHint: String? = nil, titleHint: String? = nil) throws -> UserSpaceProfile {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let bodyText = document.body()?.normalizedText() ?? ""

        let uid = uidHint?.nilIfBlank
            ?? firstMatch(#"UID\s*[:：]?\s*(\d+)"#, in: bodyText)
            ?? firstUserID(in: document)
            ?? ""
        let username = firstNonBlank([
            document.firstText(".username, .mtit, h2, h1"),
            titleHint,
            try? document.title().replacingOccurrences(of: "-  百合会", with: "")
        ]) ?? L10n.string("user_space.unknown_user")
        let infoRows = parseInfoRows(in: document)

        return UserSpaceProfile(
            uid: uid,
            username: username,
            userGroup: infoRows.first(where: { $0.label.contains("用户组") || $0.label.contains("用戶組") })?.value,
            avatarURL: document.firstURL(
                anyOf: [
                    ".avatar img[src]",
                    ".mimg img[src]",
                    "img[src*='avatar']"
                ],
                attribute: "src"
            ),
            avatarBackgroundURL: document.firstURL(
                anyOf: [
                    ".space_bg img[src]",
                    ".profile_bg img[src]",
                    "img[src*='avatar_big']"
                ],
                attribute: "src"
            ),
            signature: document.firstText(".signature, .sign, .pf_l"),
            totalPoints: intAfterAny(labels: ["总积分", "總積分"], in: bodyText),
            points: plainPoints(in: bodyText),
            partner: intAfterAny(labels: ["对象", "對象"], in: bodyText),
            infoRows: infoRows
        )
    }

    static func parseThreads(from html: String) throws -> UserSpaceThreadPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        return UserSpaceThreadPage(
            threads: parseThreadSummaries(in: document),
            pageNavigation: parsePageNavigation(in: document)
        )
    }

    static func parseReplies(from html: String) throws -> UserSpaceReplyPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var replies: [UserSpaceReplyGroup] = []
        var seen = Set<String>()

        for link in document.selectAll("a[href*='viewthread'][href*='tid='], a[href*='thread-']") {
            guard let url = link.attrURL("href"),
                  let tid = threadID(from: url),
                  seen.insert(tid).inserted else {
                continue
            }
            let title = link.normalizedText()
            guard !title.isEmpty else { continue }
            let container = nearestListContainer(for: link)
            replies.append(
                UserSpaceReplyGroup(
                    threadID: tid,
                    threadTitle: title,
                    threadURL: url,
                    excerpt: container?.normalizedText().nilIfBlank,
                    lastActivityText: firstDateText(in: container)
                )
            )
        }

        return UserSpaceReplyPage(replies: replies, pageNavigation: parsePageNavigation(in: document))
    }

    static func parseBlogs(from html: String) throws -> UserSpaceBlogPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var blogs: [UserSpaceBlogSummary] = []
        var seen = Set<String>()

        for link in document.selectAll("a[href*='do=blog'][href*='id='], a[href*='blog-']") {
            guard let url = link.attrURL("href"),
                  let blogID = blogID(from: url),
                  seen.insert(blogID).inserted else {
                continue
            }
            let title = link.normalizedText()
            guard !title.isEmpty else { continue }
            let container = nearestListContainer(for: link)
            let text = container?.normalizedText() ?? ""
            blogs.append(
                UserSpaceBlogSummary(
                    blogID: blogID,
                    title: title,
                    url: url,
                    authorName: firstAuthorName(in: container),
                    authorID: firstUserID(in: container),
                    excerpt: text.nilIfBlank,
                    lastActivityText: firstDateText(in: container),
                    replyCount: intAfterAny(labels: ["回复", "回復"], in: text),
                    viewCount: intAfterAny(labels: ["查看", "浏览", "瀏覽"], in: text)
                )
            )
        }

        return UserSpaceBlogPage(blogs: blogs, pageNavigation: parsePageNavigation(in: document))
    }

    static func parseFriends(from html: String) throws -> UserSpaceFriendPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let containers = friendListContainers(in: document)
        let links = containers.flatMap { $0.selectAll("a[href*='mod=space'][href*='uid='], a[href*='space-uid-']") }
        var friends: [UserSpaceFriendSummary] = []
        var seen = Set<String>()

        for link in links {
            guard let url = link.attrURL("href"),
                  let uid = userID(from: url),
                  seen.insert(uid).inserted else {
                continue
            }
            let name = link.normalizedText()
            guard !name.isEmpty else { continue }
            let container = nearestListContainer(for: link)
            friends.append(
                UserSpaceFriendSummary(
                    uid: uid,
                    name: name,
                    avatarURL: container?.firstURL("img[src]", attribute: "src"),
                    detail: container?.normalizedText().nilIfBlank,
                    privateMessageURL: firstActionURL(in: container, patterns: ["ac=pm", "op=showmsg", "sendpm"]),
                    deleteURL: firstActionURL(in: container, patterns: ["op=ignore", "op=delete", "ac=friend&op=delete"])
                )
            )
        }

        return UserSpaceFriendPage(friends: friends, pageNavigation: parsePageNavigation(in: document))
    }

    static func parsePrivateMessageList(from html: String) throws -> UserSpacePrivateMessagePage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var messages: [UserSpacePrivateMessageSummary] = []
        var seen = Set<String>()

        for link in document.selectAll("a[href*='op=showmsg'][href*='touid='], a[href*='ac=pm'][href*='touid=']") {
            guard let url = link.attrURL("href"),
                  let uid = url.queryItemValue("touid") ?? url.queryItemValue("uid"),
                  seen.insert(uid).inserted else {
                continue
            }

            let container = nearestListContainer(for: link)
            let text = container?.normalizedText() ?? link.normalizedText()
            let name = firstNonBlank([
                firstUserName(uid: uid, in: container),
                link.normalizedText()
            ]) ?? L10n.string("user_space.unknown_user")
            let title = firstNonBlank([
                container?.firstText(".title, .subject, h3, h4"),
                link.normalizedText()
            ]) ?? name

            messages.append(
                UserSpacePrivateMessageSummary(
                    uid: uid,
                    name: name,
                    avatarURL: avatarImageURL(in: container),
                    title: title,
                    message: privateMessageListPreview(text: text, title: title, name: name),
                    timeText: firstDateText(in: container),
                    unreadCount: firstUnreadCount(in: container)
                )
            )
        }

        return UserSpacePrivateMessagePage(
            messages: messages,
            unreadCount: unreadCount(in: document),
            pageNavigation: parsePageNavigation(in: document)
        )
    }

    static func parseNotices(from html: String) throws -> UserSpaceNoticePage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var notices: [UserSpaceNoticeSummary] = []
        var seen = Set<String>()

        for container in noticeContainers(in: document) {
            let content = noticeContentElement(in: container) ?? container
            let contentHTML = ((try? content.html()) ?? "").nilIfBlank ?? ((try? container.html()) ?? "")
            let contentText = content.normalizedText()
            guard !contentText.isEmpty else { continue }

            let noticeID = noticeID(in: container) ?? [firstDateText(in: container), contentText].compactMap { $0 }.joined(separator: "|")
            guard !noticeID.isEmpty, seen.insert(noticeID).inserted else { continue }
            let avatarURL = avatarImageURL(in: container)

            notices.append(
                UserSpaceNoticeSummary(
                    noticeID: noticeID,
                    avatarURL: avatarURL,
                    userID: firstUserID(in: container) ?? avatarURL.flatMap(userIDFromAvatarURL),
                    contentHTML: contentHTML,
                    contentText: contentText,
                    quote: container.firstText("blockquote, .quote, .notice_quote"),
                    timeText: firstDateText(in: container)
                )
            )
        }

        return UserSpaceNoticePage(notices: notices, pageNavigation: parsePageNavigation(in: document))
    }

    static func parseAddFriendForm(from html: String, uid: String, nameHint: String? = nil) throws -> UserSpaceAddFriendForm {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        guard let formHash = parseFormHash(in: document, html: html) else {
            throw YamiboError.parsingFailed(context: L10n.string("context.user_space_add_friend"))
        }

        return UserSpaceAddFriendForm(
            uid: uid,
            name: firstNonBlank([
                document.firstText(".username, .mtit, h3, h2, a[href*='uid=\(uid)']"),
                nameHint
            ]),
            avatarURL: document.firstURL(
                anyOf: [
                    ".avatar img[src]",
                    ".mimg img[src]",
                    "img[src*='avatar']"
                ],
                attribute: "src"
            ),
            formHash: formHash,
            options: parseAddFriendOptions(in: document)
        )
    }

    static func parseAddFriendResult(from html: String) throws -> String {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let message = document.selectFirst(".jump_c, .alert_info, .messagetext, .showmessage, .wp, body")?.normalizedText() ?? ""

        if message.contains("请先登录") || message.contains("請先登錄") || message.contains("请登录") {
            throw YamiboError.notAuthenticated
        }
        if message.contains("失败") || message.contains("失敗") || message.contains("错误") || message.contains("錯誤") {
            throw YamiboError.underlying(message)
        }
        if message.isEmpty {
            throw YamiboError.parsingFailed(context: L10n.string("context.user_space_add_friend"))
        }
        return message
    }

    static func parsePrivateMessagePage(from html: String, toUID: String, titleHint: String? = nil) throws -> PrivateMessagePage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let normalizedToUID = toUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let toName = firstNonBlank([
            titleHint,
            firstUserName(uid: normalizedToUID, in: document),
            document.firstText(".username, .mtit, h2, h1")
        ])
        let title = firstNonBlank([
            document.firstText(".header h2, .mtit, h1, h2"),
            toName.map { L10n.string("private_message.chat_with", $0) },
            try? document.title().replacingOccurrences(of: "-  百合会", with: "")
        ]) ?? L10n.string("private_message.title")
        let formHash = parseFormHash(in: document, html: html)
        let privateMessageID = parsePrivateMessageID(in: document, html: html) ?? "0"

        return PrivateMessagePage(
            title: title,
            privateMessageID: privateMessageID,
            toUID: normalizedToUID,
            toName: toName,
            formHash: formHash,
            messages: parsePrivateMessages(in: document, toUID: normalizedToUID, toName: toName),
            pageNavigation: parsePageNavigation(in: document)
        )
    }

    static func parsePrivateMessageSendResult(from html: String) throws -> String {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let message = document.selectFirst(".jump_c, .alert_info, .messagetext, .showmessage, .wp, body")?.normalizedText() ?? ""

        if message.contains("请先登录") || message.contains("請先登錄") || message.contains("请登录") {
            throw YamiboError.notAuthenticated
        }
        if message.contains("失败") || message.contains("失敗") || message.contains("错误") || message.contains("錯誤") {
            throw YamiboError.underlying(message)
        }
        if message.isEmpty {
            throw YamiboError.parsingFailed(context: L10n.string("context.private_message"))
        }
        return message
    }

    private static func parseThreadSummaries(in document: Document) -> [ForumThreadSummary] {
        var threads: [ForumThreadSummary] = []
        var seen = Set<String>()

        for link in document.selectAll("a[href*='viewthread'][href*='tid='], a[href*='thread-']") {
            guard let url = link.attrURL("href"),
                  let tid = threadID(from: url),
                  seen.insert(tid).inserted else {
                continue
            }
            let title = link.normalizedText()
            guard !title.isEmpty else { continue }
            let container = nearestListContainer(for: link)
            let text = container?.normalizedText() ?? ""
            threads.append(
                ForumThreadSummary(
                    tid: tid,
                    title: title,
                    url: url,
                    authorName: firstAuthorName(in: container),
                    authorID: firstUserID(in: container),
                    authorAvatarURL: container?.firstURL(anyOf: ["img[src*='avatar']", "img[src]"], attribute: "src"),
                    description: text.nilIfBlank,
                    replyCount: intAfterAny(labels: ["回复", "回復"], in: text),
                    viewCount: intAfterAny(labels: ["查看", "浏览", "瀏覽"], in: text),
                    lastActivityText: firstDateText(in: container)
                )
            )
        }

        return threads
    }

    private static func parseInfoRows(in document: Document) -> [UserSpaceInfoRow] {
        var info: [UserSpaceInfoRow] = []
        var seen = Set<String>()

        for row in document.selectAll("li, tr, .pbm, .pf_l li, .profile_info li") {
            let text = row.normalizedText()
            guard let separator = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let label = String(text[..<separator]).htmlNormalized
            let value = String(text[text.index(after: separator)...]).htmlNormalized
            guard !label.isEmpty, !value.isEmpty else { continue }
            let url = row.firstURL("a[href]")
            let item = UserSpaceInfoRow(label: label, value: value, url: url)
            guard seen.insert(item.id).inserted else { continue }
            info.append(item)
        }

        return info
    }

    private static func parseAddFriendOptions(in document: Document) -> [UserSpaceAddFriendOption] {
        var result: [UserSpaceAddFriendOption] = []
        var seen = Set<Int>()

        for option in document.selectAll("select[name=gid] option, select[name=groupid] option, select[name=group] option") {
            guard let id = option.attrText("value").flatMap(Int.init), seen.insert(id).inserted else { continue }
            let name = option.normalizedText()
            guard !name.isEmpty else { continue }
            result.append(UserSpaceAddFriendOption(id: id, name: name))
        }

        return result
    }

    private static func parseFormHash(in document: Document, html: String) -> String? {
        if let value = document.selectFirst("input[name=formhash]")?.attrText("value") {
            return value
        }
        return HTMLTextExtractor.firstMatch(pattern: #"formhash=([A-Za-z0-9]+)"#, in: html)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func parsePrivateMessages(in document: Document, toUID: String, toName: String?) -> [PrivateMessage] {
        var messages: [PrivateMessage] = []
        var seen = Set<String>()

        for container in privateMessageContainers(in: document) {
            let content = privateMessageContentElement(in: container) ?? container
            let contentHTML = ((try? content.html()) ?? "").nilIfBlank ?? ((try? container.html()) ?? "")
            let contentText = content.normalizedText()
            guard !contentText.isEmpty else { continue }

            let user = privateMessageUser(in: container, toUID: toUID, toName: toName)
            let className = ((try? container.className()) ?? "").lowercased()
            let kind: PrivateMessageKind = if user.uid == toUID {
                .other
            } else if className.contains("self") || className.contains("right") || className.contains("me") || className.contains("mine") {
                .me
            } else {
                .other
            }
            let message = PrivateMessage(
                messageID: privateMessageItemID(in: container),
                kind: kind,
                author: user,
                postedAtText: firstDateText(in: container),
                contentHTML: contentHTML,
                contentText: contentText
            )
            guard seen.insert(message.id).inserted else { continue }
            messages.append(message)
        }

        return messages
    }

    private static func privateMessageContainers(in document: Document) -> [Element] {
        let scoped = document.selectAll(
            [
                ".pm_msg",
                ".pmb",
                ".pmlist li",
                ".pm_list li",
                ".messageitem",
                ".message_item",
                "li[id^=pm_]",
                "div[id^=pm_]",
                ".bbda"
            ].joined(separator: ",")
        )
        if !scoped.isEmpty {
            return scoped
        }
        YamiboLog.forum.warning("privateMessageContainers: no scoped private-message selectors matched, falling back to broad 'li, .cl' scan")
        return document.selectAll("li, .cl")
    }

    private static func privateMessageContentElement(in container: Element) -> Element? {
        for selector in [".pmcontent", ".message", ".content", ".t_f", ".txt", "blockquote"] {
            if let element = container.selectAll(selector).last {
                return element
            }
        }
        return nil
    }

    private static func privateMessageUser(in container: Element, toUID: String, toName: String?) -> PrivateMessageUser {
        let link = firstUserLink(in: container)
        let uid = link?.attrURL("href").flatMap(userID(from:))
        let name = firstNonBlank([
            link?.normalizedText(),
            uid == toUID ? toName : nil,
            uid == nil ? toName : nil
        ]) ?? L10n.string("private_message.me")
        return PrivateMessageUser(
            uid: uid,
            name: name,
            avatarURL: avatarImageURL(in: container)
        )
    }

    private static func firstUserLink(in element: Element) -> Element? {
        element.selectFirst("a[href*='uid='], a[href*='space-uid-']")
    }

    private static func firstUserName(uid: String, in element: Element?) -> String? {
        guard let element else { return nil }
        for link in element.selectAll("a[href*='uid=\(uid)'], a[href*='space-uid-\(uid)']") {
            if let name = link.normalizedText().nilIfBlank {
                return name
            }
        }
        return nil
    }

    private static func privateMessageItemID(in container: Element) -> String? {
        for attribute in ["data-id", "data-pmid", "id"] {
            if let value = container.attrText(attribute) {
                return HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: value)?.first ?? value
            }
        }
        return nil
    }

    private static func parsePrivateMessageID(in document: Document, html: String) -> String? {
        if let value = document.selectFirst("input[name=pmid]")?.attrText("value") {
            return value
        }
        for link in document.selectAll("form[action*='pmid='], a[href*='pmid=']") {
            let rawURL = ((try? link.attr("action")) ?? "").nilIfBlank ?? ((try? link.attr("href")) ?? "")
            guard let url = HTMLTextExtractor.absoluteURL(from: rawURL),
                  let pmid = url.queryItemValue("pmid") else {
                continue
            }
            return pmid
        }
        return HTMLTextExtractor.firstMatch(pattern: #"pmid=([A-Za-z0-9]+)"#, in: html)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func friendListContainers(in document: Document) -> [Element] {
        let scoped = document.selectAll(".friendlist, .buddy, .ulist, .ml, .buddylist, #friend_ul")
        if !scoped.isEmpty {
            return scoped
        }
        YamiboLog.forum.warning("friendListContainers: no scoped friend-list selectors matched, falling back to scanning entire document body")
        return document.selectAll("body")
    }

    private static func noticeContainers(in document: Document) -> [Element] {
        let scoped = document.selectAll(
            [
                "li[id^=notice_]",
                "div[id^=notice_]",
                ".notice li",
                ".nts li",
                ".ntc li",
                ".xld li",
                ".bbda"
            ].joined(separator: ",")
        )
        if !scoped.isEmpty {
            return scoped
        }
        YamiboLog.forum.warning("noticeContainers: no scoped notice-container selectors matched, falling back to broad 'li, .cl' scan")
        return document.selectAll("li, .cl")
    }

    private static func noticeContentElement(in container: Element) -> Element? {
        container.selectFirst(anyOf: [".ntc_body", ".notice_body", ".content", ".detail", ".xw0", ".txt"])
    }

    private static func noticeID(in container: Element) -> String? {
        for attribute in ["data-id", "data-notice-id", "id"] {
            if let value = container.attrText(attribute) {
                return HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: value)?.first ?? value
            }
        }
        if let url = container.firstURL("a[href*='noticeid=']"),
           let noticeID = url.queryItemValue("noticeid") {
            return noticeID
        }
        return nil
    }

    private static func privateMessageListPreview(text: String, title: String, name: String) -> String {
        var preview = text
        for prefix in [title, name] where !prefix.isEmpty {
            if preview.hasPrefix(prefix) {
                preview = String(preview.dropFirst(prefix.count)).htmlNormalized
            }
        }
        return preview.nilIfBlank ?? title
    }

    private static func unreadCount(in document: Document) -> Int? {
        let text = document.body()?.normalizedText() ?? ""
        return HTMLTextExtractor.firstMatch(pattern: #"(?:未读|未讀)\s*[:：]?\s*(\d+)"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }

    private static func firstUnreadCount(in element: Element?) -> Int? {
        guard let element else { return nil }
        let text = element.normalizedText()
        if let value = HTMLTextExtractor.firstMatch(pattern: #"(?:未读|未讀|新消息)\s*[:：]?\s*(\d+)"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Int.init) {
            return value
        }
        for selector in [".unread", ".badge", ".num"] {
            if let value = element.firstText(selector),
               let number = HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: value)?.first.flatMap(Int.init) {
                return number
            }
        }
        return nil
    }

    private static func userIDFromAvatarURL(_ url: URL) -> String? {
        let normalized = url.absoluteString.replacingOccurrences(of: "\\", with: "/")
        guard let match = HTMLTextExtractor.firstMatch(pattern: #"/avatar/(\d{3})/(\d{2})/(\d{2})/(\d{2})_avatar"#, in: normalized) else {
            return nil
        }
        let rawUID = match.dropFirst().joined()
        return Int(rawUID).map(String.init)
    }

    private static func parsePageNavigation(in document: Document) -> ForumPageNavigation? {
        guard let pager = document.selectFirst(".pg") else { return nil }
        let currentPage = pager.firstText("strong").flatMap(Int.init) ?? 1
        let pagerText = pager.normalizedText()
        let totalPages = HTMLTextExtractor.firstMatch(pattern: #"共\s*(\d+)\s*页"#, in: pagerText)?
            .dropFirst()
            .first
            .flatMap(Int.init)
            ?? HTMLTextExtractor.matches(pattern: #"page=(\d+)"#, in: (try? pager.html()) ?? "")
            .compactMap { $0.dropFirst().first.flatMap(Int.init) }
            .max()
        return ForumPageNavigation(currentPage: currentPage, totalPages: totalPages)
    }

    private static func nearestListContainer(for element: Element) -> Element? {
        var node: Element? = element
        while let current = node {
            if ["li", "tr", "dd", "div"].contains(current.tagName()) {
                return current
            }
            node = current.parent()
        }
        return element
    }

    private static func avatarImageURL(in element: Element?) -> URL? {
        element?.firstURL(
            anyOf: ["img[src*='avatar']", ".avatar img[src]", ".mimg img[src]", "img[src]"],
            attribute: "src"
        )
    }

    private static func firstActionURL(in element: Element?, patterns: [String]) -> URL? {
        guard let element else { return nil }
        for link in element.selectAll("a[href]") {
            let href = ((try? link.attr("href")) ?? "")
                .replacingOccurrences(of: "&amp;", with: "&")
            let text = link.normalizedText()
            if patterns.contains(where: { href.contains($0) || text.contains($0) }),
               let url = HTMLTextExtractor.absoluteURL(from: href) {
                return url
            }
            if patterns.contains("ac=pm"), text.contains("发消息") || text.contains("發消息") || text.contains("短消息"),
               let url = HTMLTextExtractor.absoluteURL(from: href) {
                return url
            }
            if patterns.contains("op=delete"), text.contains("删除") || text.contains("刪除") || text.contains("解除"),
               let url = HTMLTextExtractor.absoluteURL(from: href) {
                return url
            }
        }
        return nil
    }

    private static func firstAuthorName(in element: Element?) -> String? {
        element?.firstText(".mmc, a[href*='uid=']")
    }

    private static func firstUserID(in element: Element?) -> String? {
        guard let element else { return nil }
        for link in element.selectAll("a[href*='uid='], a[href*='space-uid-']") {
            guard let url = link.attrURL("href"),
                  let uid = userID(from: url) else {
                continue
            }
            return uid
        }
        return nil
    }

    private static func firstDateText(in element: Element?) -> String? {
        let text = element?.normalizedText() ?? ""
        return HTMLTextExtractor.firstMatch(pattern: #"\d{4}[-/]\d{1,2}[-/]\d{1,2}(?:\s+\d{1,2}:\d{2})?"#, in: text)?
            .first?
            .nilIfBlank
    }

    private static func threadID(from url: URL) -> String? {
        url.queryItemValue("tid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"thread-(\d+)-"#, in: url.absoluteString)?.dropFirst().first
    }

    private static func userID(from url: URL) -> String? {
        url.queryItemValue("uid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"space-uid-(\d+)"#, in: url.absoluteString)?.dropFirst().first
    }

    private static func blogID(from url: URL) -> String? {
        url.queryItemValue("id")
            ?? HTMLTextExtractor.firstMatch(pattern: #"blog-(\d+)-"#, in: url.absoluteString)?.dropFirst().first
    }

    private static func intAfterAny(labels: [String], in text: String) -> Int? {
        for label in labels {
            if let value = HTMLTextExtractor.firstMatch(pattern: #"\#(label)\s*[:：]?\s*(\d+)"#, in: text)?
                .dropFirst()
                .last
                .flatMap(Int.init) {
                return value
            }
        }
        return nil
    }

    private static func plainPoints(in text: String) -> Int? {
        for pattern in [#"(?:^|\s)积分\s*[:：]?\s*(\d+)"#, #"(?:^|\s)積分\s*[:：]?\s*(\d+)"#] {
            if let value = HTMLTextExtractor.firstMatch(pattern: pattern, in: text)?
                .dropFirst()
                .first
                .flatMap(Int.init) {
                return value
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: pattern, in: text)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func firstNonBlank(_ values: [String?]) -> String? {
        values.compactMap { $0?.htmlNormalized.nilIfBlank }.first
    }
}

import Foundation

private enum Labels {
    static let sendMessage = ["发消息", "發消息", "短消息"]
    static let deleteFriend = ["删除", "刪除", "解除"]
}

extension UserSpaceHTMLParser {
    static func parseFriends(from html: String) throws -> UserSpaceFriendPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var friends: [UserSpaceFriendSummary] = []
        var seen = Set<String>()

        for row in friendRows(in: document) {
            let profileLinks = row.selectAll("a[href*='mod=space'][href*='uid='], a[href*='space-uid-']")
                .filter { !$0.attr("href").contains("spacecp") }
            guard let uid = profileLinks.lazy.compactMap({ link in
                link.attrURL("href").flatMap(YamiboForumURLIdentity.userID(from:))
            }).first else {
                continue
            }
            let name = profileLinks.compactMap { $0.normalizedText().nilIfBlank }.last
            guard let name, seen.insert(uid).inserted else { continue }
            friends.append(
                UserSpaceFriendSummary(
                    uid: uid,
                    name: name,
                    avatarURL: row.firstURL(anyOf: [".mimg img[src]", "img[src]"], attribute: "src"),
                    detail: firstNonBlank([
                        row.firstText(".mtxt"),
                        row.normalizedText().nilIfBlank
                    ]),
                    privateMessageURL: firstActionURL(in: row, patterns: ["do=pm", "ac=pm", "op=showmsg", "sendpm"]),
                    deleteURL: firstActionURL(in: row, patterns: ["op=ignore", "op=delete", "ac=friend&op=delete"])
                )
            )
        }

        return UserSpaceFriendPage(friends: friends, pageNavigation: parsePageNavigation(in: document))
    }

    static func parseAddFriendForm(from html: String, uid: String, nameHint: String? = nil) throws -> UserSpaceAddFriendForm {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let body = HTMLTextExtractor.discuzAjaxPayload(from: html) ?? html
        let document = try KannaSoup.parse(body, baseURL: YamiboDomain.baseURL.absoluteString)
        guard let formHash = DiscuzFormHashParser.formHash(in: document, html: html) else {
            throw YamiboError.parsingFailed(context: L10n.string("context.user_space_add_friend"))
        }

        return UserSpaceAddFriendForm(
            uid: uid,
            name: firstNonBlank([
                document.firstText("form td strong, td strong"),
                nameHint,
                document.firstText("a[href*='uid=\(uid)']")
            ]),
            avatarURL: document.firstURL(
                anyOf: SharedSelectors.avatarImage,
                attribute: "src"
            ),
            formHash: formHash,
            options: parseAddFriendOptions(in: document)
        )
    }

    static func parseAddFriendResult(from html: String) throws -> String {
        try DiscuzActionResultParser.successMessage(
            from: html,
            emptyPageContext: L10n.string("context.user_space_add_friend")
        )
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

    private static func friendRows(in document: Document) -> [Element] {
        for selector in ["#friend_ul li", ".friendlist li, .buddy li, .ulist li, .buddylist li"] {
            let rows = document.selectAll(selector)
            if !rows.isEmpty {
                return rows
            }
        }
        var rows: [Element] = []
        for link in document.selectAll("a[href*='mod=space'][href*='uid='], a[href*='space-uid-']") {
            guard let container = nearestListContainer(for: link) else { continue }
            rows.append(container)
        }
        return rows.deduplicatedByDOMIdentity()
    }

    private static func firstActionURL(in element: Element?, patterns: [String]) -> URL? {
        guard let element else { return nil }
        for link in element.selectAll("a[href]") {
            let href = link.attr("href")
                .replacingOccurrences(of: "&amp;", with: "&")
            let text = link.normalizedText()
            if patterns.contains(where: { href.contains($0) || text.contains($0) }),
               let url = HTMLTextExtractor.absoluteURL(from: href) {
                return url
            }
            if patterns.contains("ac=pm"), Labels.sendMessage.contains(where: text.contains),
               let url = HTMLTextExtractor.absoluteURL(from: href) {
                return url
            }
            if patterns.contains("op=delete"), Labels.deleteFriend.contains(where: text.contains),
               let url = HTMLTextExtractor.absoluteURL(from: href) {
                return url
            }
        }
        return nil
    }
}

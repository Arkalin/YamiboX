import Foundation

/// Simplified/traditional label sets for friend-row action links. Top-level
/// `private` so the same-named groups in the sibling `UserSpaceHTMLParser+…`
/// files stay strictly file-scoped.
private enum Labels {
    static let sendMessage = ["发消息", "發消息", "短消息"]
    static let deleteFriend = ["删除", "刪除", "解除"]
}

/// User-space friend pages: friend list plus the add-friend form and its result.
extension UserSpaceHTMLParser {
    static func parseFriends(from html: String) throws -> UserSpaceFriendPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let containers = friendListContainers(in: document)
        let links = containers.flatMap { $0.selectAll("a[href*='mod=space'][href*='uid='], a[href*='space-uid-']") }
        var friends: [UserSpaceFriendSummary] = []
        var seen = Set<String>()

        for link in links {
            guard let url = link.attrURL("href"),
                  let uid = YamiboForumURLIdentity.userID(from: url),
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

    static func parseAddFriendForm(from html: String, uid: String, nameHint: String? = nil) throws -> UserSpaceAddFriendForm {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        guard let formHash = DiscuzFormHashParser.formHash(in: document, html: html) else {
            throw YamiboError.parsingFailed(context: L10n.string("context.user_space_add_friend"))
        }

        return UserSpaceAddFriendForm(
            uid: uid,
            name: firstNonBlank([
                document.firstText(".username, .mtit, h3, h2, a[href*='uid=\(uid)']"),
                nameHint
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

    private static func friendListContainers(in document: Document) -> [Element] {
        let scoped = document.selectAll(".friendlist, .buddy, .ulist, .ml, .buddylist, #friend_ul")
        if !scoped.isEmpty {
            return scoped
        }
        YamiboLog.forum.warning("friendListContainers: no scoped friend-list selectors matched, falling back to scanning entire document body")
        return document.selectAll("body")
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

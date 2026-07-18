import Foundation

/// User-space private-message pages: conversation list, single conversation,
/// and the send-result page.
extension UserSpaceHTMLParser {
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

    static func parsePrivateMessagePage(from html: String, toUID: String, titleHint: String? = nil) throws -> PrivateMessagePage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let normalizedToUID = toUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let toName = firstNonBlank([
            titleHint,
            firstUserName(uid: normalizedToUID, in: document),
            document.firstText(SharedSelectors.userDisplayName)
        ])
        let title = firstNonBlank([
            document.firstText(".header h2, .mtit, h1, h2"),
            toName.map { L10n.string("private_message.chat_with", $0) },
            document.title().replacingOccurrences(of: SharedLabels.titleSuffix, with: "")
        ]) ?? L10n.string("private_message.title")
        let formHash = DiscuzFormHashParser.formHash(in: document, html: html)
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
        try DiscuzActionResultParser.successMessage(
            from: html,
            emptyPageContext: L10n.string("context.private_message")
        )
    }

    private static func parsePrivateMessages(in document: Document, toUID: String, toName: String?) -> [PrivateMessage] {
        var messages: [PrivateMessage] = []
        var seen = Set<String>()

        for container in privateMessageContainers(in: document) {
            let content = privateMessageContentElement(in: container) ?? container
            let contentHTML = content.html().nilIfBlank ?? container.html()
            let contentText = content.normalizedText()
            guard !contentText.isEmpty else { continue }

            let user = privateMessageUser(in: container, toUID: toUID, toName: toName)
            let className = container.className().lowercased()
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
        let uid = link?.attrURL("href").flatMap(YamiboForumURLIdentity.userID(from:))
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
        element.selectFirst(SharedSelectors.userLink)
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
            let rawURL = link.attr("action").nilIfBlank ?? link.attr("href")
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
}

import Foundation

/// User-space private-message pages, touch template `space_pm.htm`:
/// conversation list, single conversation, and the send-result page.
///
/// Verified against the live template markup. Conversation list:
///
/// ```html
/// <div class="dhnv …"><a … class="flex mon">我的消息<strong>(5)</strong></a>…</div>
/// <div id="pmlist" …><ul>
///   <li>
///     <span class="mimg"><a href="home.php?mod=space&do=pm&subop=view&touid=UID"><img …></a></span>
///     <a href="home.php?mod=space&do=pm&subop=view&touid=UID">
///       <p class="mtit"><span class="mtime">TIME</span><span class="mnum">N</span> NAME 对我说:</p>
///       <p class="mtxt">MESSAGE</p>
///     </a>
///   </li>
/// </ul></div>
/// ```
///
/// Single conversation (`subop=view`, rows via `space_pm_node.htm`):
///
/// ```html
/// <div class="msgbox b_m">
///   <div class="friend_msg cl"><div class="avat z"><img …></div>
///     <div class="dialog_green z"><div class="dialog_c">MESSAGE</div><div class="date">TIME</div></div></div>
///   <div class="self_msg cl">…<div class="dialog_white y"><div class="dialog_c">MESSAGE</div>…</div></div>
/// </div>
/// <form id="pmform" … action="home.php?mod=spacecp&ac=pm&op=send&pmid=PMID&…">
/// ```
extension UserSpaceHTMLParser {
    static func parsePrivateMessageList(from html: String) throws -> UserSpacePrivateMessagePage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var messages: [UserSpacePrivateMessageSummary] = []
        var seen = Set<String>()

        for container in privateMessageListItems(in: document) {
            // Group conversations link via `plid=` instead and are skipped,
            // matching the conversation screen which only supports `touid`.
            guard let link = container.selectFirst("a[href*='touid=']"),
                  let url = link.attrURL("href"),
                  let uid = url.queryItemValue("touid")?.nilIfBlank,
                  seen.insert(uid).inserted else {
                continue
            }

            let titleLine = conversationTitleLine(in: container)
            let name = firstNonBlank([
                titleLine.flatMap(conversationPartnerName(fromTitleLine:)),
                firstUserName(uid: uid, in: container)
            ]) ?? L10n.string("user_space.unknown_user")
            let preview = firstNonBlank([
                container.firstText(".mtxt"),
                titleLine
            ]) ?? name

            messages.append(
                UserSpacePrivateMessageSummary(
                    uid: uid,
                    name: name,
                    avatarURL: avatarImageURL(in: container),
                    title: titleLine ?? name,
                    message: preview,
                    timeText: firstNonBlank([
                        container.firstText(".mtime"),
                        firstDateText(in: container)
                    ]),
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
            firstUserName(uid: normalizedToUID, in: document)
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

    // MARK: Conversation list

    private static func privateMessageListItems(in document: Document) -> [Element] {
        for selector in ["#pmlist li", ".pmlist li", ".pm_list li"] {
            let matches = document.selectAll(selector)
            if !matches.isEmpty {
                return matches
            }
        }
        // Older markup variants: derive rows from the conversation links.
        var containers: [Element] = []
        var seen = Set<String>()
        for link in document.selectAll("a[href*='touid=']") {
            guard let url = link.attrURL("href"),
                  let uid = url.queryItemValue("touid"),
                  seen.insert(uid).inserted,
                  let container = nearestListContainer(for: link) else {
                continue
            }
            containers.append(container)
        }
        return containers
    }

    /// The `.mtit` line with the `.mtime`/`.mnum` spans excluded — its direct
    /// text nodes are exactly "NAME 对我说:" / "我对 NAME 说:".
    private static func conversationTitleLine(in container: Element) -> String? {
        guard let titleElement = container.selectFirst(".mtit") else {
            return container.firstText(".title, .subject, h3, h4")
        }
        return titleElement.ownText().htmlNormalized.nilIfBlank
            ?? titleElement.normalizedText().nilIfBlank
    }

    /// Extracts the conversation partner's name from the list-row title line
    /// ("NAME 对我说:" or "我对 NAME 说:", plus the traditional variants).
    private static func conversationPartnerName(fromTitleLine titleLine: String) -> String? {
        var line = titleLine
        for suffix in ["说:", "說:", "说：", "說：", "说", "說"] where line.hasSuffix(suffix) {
            line = String(line.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        for prefix in ["我对", "我對"] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank
        }
        for marker in ["对我", "對我"] {
            if let range = line.range(of: marker) {
                return String(line[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfBlank
            }
        }
        return line.nilIfBlank
    }

    // MARK: Conversation page

    private static func parsePrivateMessages(in document: Document, toUID: String, toName: String?) -> [PrivateMessage] {
        var messages: [PrivateMessage] = []
        var seen = Set<String>()

        for container in privateMessageContainers(in: document) {
            let content = privateMessageContentElement(in: container)
            let contentHTML = content?.html().nilIfBlank ?? container.html()
            let contentText = (content ?? container).normalizedText()
            guard !contentText.isEmpty else { continue }

            let kind = privateMessageKind(of: container, toUID: toUID)
            let message = PrivateMessage(
                messageID: privateMessageItemID(in: container),
                kind: kind,
                author: privateMessageUser(in: container, kind: kind, toUID: toUID, toName: toName),
                postedAtText: firstNonBlank([
                    container.firstText(".date"),
                    firstDateText(in: container)
                ]),
                contentHTML: contentHTML,
                contentText: contentText
            )
            guard seen.insert(message.id).inserted else { continue }
            messages.append(message)
        }

        return messages
    }

    private static func privateMessageContainers(in document: Document) -> [Element] {
        for selector in [
            ".msgbox .friend_msg, .msgbox .self_msg",
            ".friend_msg, .self_msg",
            ".pm_msg, .pmb, .messageitem, .message_item, li[id^=pm_], div[id^=pm_]"
        ] {
            let matches = document.selectAll(selector)
            if !matches.isEmpty {
                return matches
            }
        }
        YamiboLog.forum.warning("privateMessageContainers: no private-message selectors matched")
        return []
    }

    private static func privateMessageContentElement(in container: Element) -> Element? {
        for selector in [".dialog_c", ".pmcontent", ".message", ".content", ".t_f", ".txt", "blockquote"] {
            if let element = container.selectAll(selector).last {
                return element
            }
        }
        return nil
    }

    private static func privateMessageKind(of container: Element, toUID: String) -> PrivateMessageKind {
        if container.hasClass("self_msg") {
            return .me
        }
        if container.hasClass("friend_msg") {
            return .other
        }
        if let uid = firstUserLink(in: container)?.attrURL("href").flatMap(YamiboForumURLIdentity.userID(from:)) {
            return uid == toUID ? .other : .me
        }
        let className = container.className().lowercased()
        if className.contains("self") || className.contains("right") || className.contains("me") || className.contains("mine") {
            return .me
        }
        return .other
    }

    private static func privateMessageUser(in container: Element, kind: PrivateMessageKind, toUID: String, toName: String?) -> PrivateMessageUser {
        let link = firstUserLink(in: container)
        let uid = link?.attrURL("href").flatMap(YamiboForumURLIdentity.userID(from:))
            ?? (kind == .other ? toUID.nilIfBlank : nil)
        let name: String
        switch kind {
        case .me:
            name = firstNonBlank([link?.normalizedText()]) ?? L10n.string("private_message.me")
        case .other:
            name = firstNonBlank([link?.normalizedText(), toName]) ?? L10n.string("user_space.unknown_user")
        }
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

    // MARK: Unread counts

    private static func unreadCount(in document: Document) -> Int? {
        if let badge = document.firstText(".dhnv a.mon strong, .dhnv strong"),
           let value = HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: badge)?.first.flatMap(Int.init) {
            return value
        }
        let text = document.body()?.normalizedText() ?? ""
        return HTMLTextExtractor.firstMatch(pattern: #"(?:未读|未讀)\s*[:：]?\s*(\d+)"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }

    private static func firstUnreadCount(in element: Element?) -> Int? {
        guard let element else { return nil }
        for selector in [".mnum", ".unread", ".badge", ".num"] {
            if let value = element.firstText(selector),
               let number = HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: value)?.first.flatMap(Int.init) {
                return number
            }
        }
        let text = element.normalizedText()
        return HTMLTextExtractor.firstMatch(pattern: #"(?:未读|未讀|新消息)\s*[:：]?\s*(\d+)"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }
}

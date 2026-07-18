import Foundation

/// User-space notification ("提醒/通知") list page.
extension UserSpaceHTMLParser {
    static func parseNotices(from html: String) throws -> UserSpaceNoticePage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var notices: [UserSpaceNoticeSummary] = []
        var seen = Set<String>()

        for container in noticeContainers(in: document) {
            let content = noticeContentElement(in: container) ?? container
            let contentHTML = content.html().nilIfBlank ?? container.html()
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

    /// Recovers a UID from the deterministic Discuz avatar path
    /// (`/avatar/001/23/45/67_avatar…` → uid 1234567).
    private static func userIDFromAvatarURL(_ url: URL) -> String? {
        let normalized = url.absoluteString.replacingOccurrences(of: "\\", with: "/")
        guard let match = HTMLTextExtractor.firstMatch(pattern: #"/avatar/(\d{3})/(\d{2})/(\d{2})/(\d{2})_avatar"#, in: normalized) else {
            return nil
        }
        let rawUID = match.dropFirst().joined()
        return Int(rawUID).map(String.init)
    }
}

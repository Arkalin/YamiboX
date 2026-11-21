import Foundation

extension UserSpaceHTMLParser {
    static func parseNotices(from html: String) throws -> UserSpaceNoticePage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var notices: [UserSpaceNoticeSummary] = []
        var seen = Set<String>()

        for container in noticeContainers(in: document) {
            let content = noticeContentElement(in: container)
            let contentHTML = content?.html().nilIfBlank ?? container.html()
            let contentWithoutQuoteHTML = try contentHTMLWithoutQuote(from: contentHTML)
            let contentWithoutQuoteDocument = try KannaSoup.parseBodyFragment(
                contentWithoutQuoteHTML,
                baseURL: YamiboDomain.baseURL.absoluteString
            )
            let contentText = contentWithoutQuoteDocument.body()?.normalizedText().nilIfBlank
                ?? (content ?? container).normalizedText()
            guard !contentText.isEmpty else { continue }

            let timeText = firstNonBlank([
                container.firstText(".mtit span"),
                firstDateText(in: container)
            ])
            let noticeID = noticeID(in: container) ?? [timeText, contentText].compactMap { $0 }.joined(separator: "|")
            guard !noticeID.isEmpty, seen.insert(noticeID).inserted else { continue }
            let avatarURL = avatarImageURL(in: container)

            notices.append(
                UserSpaceNoticeSummary(
                    noticeID: noticeID,
                    avatarURL: avatarURL,
                    userID: firstUserID(in: container) ?? avatarURL.flatMap(userIDFromAvatarURL),
                    contentHTML: contentHTML,
                    contentText: contentText,
                    contentBlocks: try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: contentWithoutQuoteHTML),
                    quote: container.firstText("blockquote, .quote, .notice_quote"),
                    timeText: timeText
                )
            )
        }

        return UserSpaceNoticePage(notices: notices, pageNavigation: parsePageNavigation(in: document))
    }

    private static func noticeContainers(in document: Document) -> [Element] {
        for selector in [
            "#notice_ul li[notice]",
            "li[notice]",
            "li[id^=notice_], div[id^=notice_]",
            ".notice li, .nts li, .ntc li"
        ] {
            let matches = document.selectAll(selector)
            if !matches.isEmpty {
                return matches
            }
        }
        YamiboLog.forum.warning("noticeContainers: no notice-container selectors matched")
        return []
    }

    private static func noticeContentElement(in container: Element) -> Element? {
        container.selectFirst(anyOf: [".mbody", ".ntc_body", ".notice_body", ".content", ".detail"])
    }

    private static func contentHTMLWithoutQuote(from html: String) throws -> String {
        let document = try KannaSoup.parseBodyFragment(html, baseURL: YamiboDomain.baseURL.absoluteString)
        guard let body = document.body() else { return html }
        body.select("blockquote, .quote, .notice_quote").remove()
        return body.html()
    }

    private static func noticeID(in container: Element) -> String? {
        for attribute in ["notice", "data-id", "data-notice-id", "id"] {
            if let value = container.attrText(attribute) {
                return HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: value)?.first ?? value
            }
        }
        if let ignoreLink = container.selectFirst("a[id^=a_note_]"),
           let noticeID = HTMLTextExtractor.firstMatch(pattern: #"a_note_(\d+)"#, in: ignoreLink.id())?.dropFirst().first {
            return noticeID
        }
        if let url = container.firstURL("a[href*='noticeid=']"),
           let noticeID = url.queryItemValue("noticeid") {
            return noticeID
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
}

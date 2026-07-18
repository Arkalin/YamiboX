import Foundation

/// User-space notification ("提醒/通知") list page, touch template
/// `space_notice.htm`. Verified against the live template markup:
///
/// ```html
/// <div id="notice_ul" class="imglist …"><ul>
///   <li class="cl" notice="ID">
///     <span class="mimg"><a href="home.php?mod=space&uid=AUTHOR"><img …></a></span>
///     <p class="mtit"><a id="a_note_ID" …>屏蔽</a><span>TIME</span></p>
///     <p class="mbody">CONTENT</p>
///   </li>
/// </ul></div>
/// ```
///
/// The notice id lives in the `notice` attribute, the content in `.mbody`
/// (never the whole row — that would drag in the 屏蔽 link and timestamp),
/// and the timestamp in `.mtit span`, which for recent items is a relative
/// phrase ("半小时前"), not a date.
extension UserSpaceHTMLParser {
    static func parseNotices(from html: String) throws -> UserSpaceNoticePage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var notices: [UserSpaceNoticeSummary] = []
        var seen = Set<String>()

        for container in noticeContainers(in: document) {
            let content = noticeContentElement(in: container)
            let contentHTML = content?.html().nilIfBlank ?? container.html()
            let contentText = (content ?? container).normalizedText()
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
                    quote: container.firstText("blockquote, .quote, .notice_quote"),
                    timeText: timeText
                )
            )
        }

        return UserSpaceNoticePage(notices: notices, pageNavigation: parsePageNavigation(in: document))
    }

    private static func noticeContainers(in document: Document) -> [Element] {
        // Most-specific first; the trailing candidates cover older markup
        // variants. No broad `li` fallback — on this page it would turn the
        // header, tab bar, and pager into "notices".
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

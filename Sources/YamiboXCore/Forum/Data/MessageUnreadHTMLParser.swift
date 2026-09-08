import Foundation

enum MessageUnreadHTMLParser {
    static func parse(_ html: String) throws -> MessageUnreadSummary {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let privateMessages = try count(for: "pm", in: document)
        let notices = try count(for: "notice", in: document)
        guard privateMessages <= Int.max - notices else { throw parsingError }
        return MessageUnreadSummary(privateMessageCount: privateMessages, noticeCount: notices)
    }

    static func count(for section: String, in document: Document) throws -> Int {
        var result: Int?
        for link in document.selectAll(".dhnv a[href]") {
            guard let url = link.attrURL("href"),
                  url.host == YamiboDomain.forumHost,
                  url.queryItemValue("mod") == "space",
                  url.queryItemValue("do") == section,
                  url.queryItemValue("subop") == nil else { continue }

            let badges = link.selectAll("strong")
            let value: Int
            if badges.isEmpty {
                // A recognized tab without a badge means zero. A changed
                // badge container with digits must not silently clear it.
                guard !link.normalizedText().contains(where: { $0.isNumber }) else { throw parsingError }
                value = 0
            } else {
                guard badges.count == 1 else { throw parsingError }
                var text = badges[0].normalizedText().trimmingCharacters(in: .whitespacesAndNewlines)
                if (text.hasPrefix("(") && text.hasSuffix(")"))
                    || (text.hasPrefix("（") && text.hasSuffix("）")) {
                    text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(text) else { throw parsingError }
                value = number
            }
            if let result, result != value { throw parsingError }
            result = value
        }
        guard let result else { throw parsingError }
        return result
    }

    private static var parsingError: YamiboError {
        .parsingFailed(context: L10n.string("message_center.unread_count"))
    }
}

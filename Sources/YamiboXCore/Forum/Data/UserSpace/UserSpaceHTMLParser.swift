import Foundation

enum UserSpaceHTMLParser {

    enum SharedSelectors {
        static let userLink = "a[href*='uid='], a[href*='space-uid-']"
        static let userDisplayName = ".username, .mtit, h2, h1"
        static let avatarImage = [".avatar img[src]", ".mimg img[src]", "img[src*='avatar']"]
    }

    enum SharedLabels {
        static let titleSuffix = "-  百合会"
    }


    static func parsePageNavigation(in document: Document) -> ForumPageNavigation? {
        ForumPageNavigationParser.parse(in: document, template: .userSpace)
    }

    static func nearestListContainer(for element: Element) -> Element? {
        var node: Element? = element
        while let current = node {
            if ["li", "tr", "dd", "div"].contains(current.tagName()) {
                return current
            }
            node = current.parent()
        }
        return element
    }

    static func avatarImageURL(in element: Element?) -> URL? {
        element?.firstURL(
            anyOf: ["img[src*='avatar']", ".avatar img[src]", ".mimg img[src]", "img[src]"],
            attribute: "src"
        )
    }

    static func firstUserID(in element: Element?) -> String? {
        guard let element else { return nil }
        for link in element.selectAll(SharedSelectors.userLink) {
            guard let url = link.attrURL("href"),
                  let uid = YamiboForumURLIdentity.userID(from: url) else {
                continue
            }
            return uid
        }
        return nil
    }

    static func firstDateText(in element: Element?) -> String? {
        let text = element?.normalizedText() ?? ""
        return HTMLTextExtractor.firstMatch(pattern: #"\d{4}[-/]\d{1,2}[-/]\d{1,2}(?:\s+\d{1,2}:\d{2})?"#, in: text)?
            .first?
            .nilIfBlank
    }

    static func intAfterAny(labels: [String], in text: String) -> Int? {
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

    static func firstNonBlank(_ values: [String?]) -> String? {
        values.compactMap { $0?.htmlNormalized.nilIfBlank }.first
    }
}

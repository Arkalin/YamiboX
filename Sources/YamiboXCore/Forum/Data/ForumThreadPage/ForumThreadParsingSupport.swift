import Foundation

enum ForumUserIDParser {
    static func userID(fromHref href: String) -> String? {
        guard let url = HTMLTextExtractor.absoluteURL(from: href) else { return nil }
        return YamiboForumURLIdentity.userID(from: url)
    }
}

extension [Element] {
    func deduplicatedByDOMIdentity() -> [Element] {
        var result: [Element] = []
        var seen: Set<String> = []
        for (index, element) in enumerated() {
            let key = element.cssSelector().nilIfBlank ?? "\(element.tagName())-\(element.id())-\(index)"
            if seen.insert(key).inserted {
                result.append(element)
            }
        }
        return result
    }
}

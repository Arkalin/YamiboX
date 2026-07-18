import Foundation

/// Shared primitives for the thread-page parser family
/// (`ForumThreadPostsParser`, `ForumThreadPollParser`, `ForumThreadRatingParser`, ...).
enum ForumUserIDParser {
    /// Discuz user ID extracted from a profile link — an href convenience over
    /// `YamiboForumURLIdentity`, which owns the actual URL rules.
    static func userID(fromHref href: String) -> String? {
        guard let url = HTMLTextExtractor.absoluteURL(from: href) else { return nil }
        return YamiboForumURLIdentity.userID(from: url)
    }
}

extension [Element] {
    /// Elements deduplicated by DOM identity (CSS selector path), preserving order.
    ///
    /// Part parsers collect candidates from several overlapping selector families
    /// (for example `#ratelog_<pid>` plus the generic `[id^=ratelog_]`); this collapses
    /// elements that resolve to the same node.
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

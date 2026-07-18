import Foundation

/// Parses the Discuz "home.php" user-space pages (mobile template).
///
/// The implementation is split by page domain into sibling extension files —
/// one file per family of pages so each stays reviewable:
/// - `UserSpaceHTMLParser+Profile.swift`       profile page
/// - `UserSpaceHTMLParser+Threads.swift`       own threads / replies / blog lists
/// - `UserSpaceHTMLParser+Friends.swift`       friend list, add-friend form/result
/// - `UserSpaceHTMLParser+Messages.swift`      private-message list/page/send result
/// - `UserSpaceHTMLParser+Notifications.swift` notice list
///
/// This file keeps only what several page domains share: the selector/label
/// vocabulary and the generic extraction helpers. Because the type's
/// implementation spans files, the shared members below are `internal`
/// (`private` would confine them to this file) — they are still implementation
/// detail, not API.
enum UserSpaceHTMLParser {
    // MARK: Shared selector/label vocabulary

    /// Selectors used by more than one page domain. Named `Shared…` (not plain
    /// `Selectors`) so the per-file `private enum Selectors` groups in the
    /// extension files never collide with it during unqualified lookup.
    enum SharedSelectors {
        /// Links that identify a forum user (query-param and SEO-rewrite URL forms).
        static let userLink = "a[href*='uid='], a[href*='space-uid-']"
        /// Display-name candidates on page headers, most specific first.
        static let userDisplayName = ".username, .mtit, h2, h1"
        /// Avatar `<img>` candidates, most specific first.
        static let avatarImage = [".avatar img[src]", ".mimg img[src]", "img[src*='avatar']"]
    }

    enum SharedLabels {
        /// Site suffix Discuz appends to every `<title>`.
        static let titleSuffix = "-  百合会"
    }

    // MARK: Shared extraction helpers

    static func parsePageNavigation(in document: Document) -> ForumPageNavigation? {
        guard let pager = document.selectFirst(".pg") else { return nil }
        let currentPage = pager.firstText("strong").flatMap(Int.init) ?? 1
        let pagerText = pager.normalizedText()
        let totalPages = HTMLTextExtractor.firstMatch(pattern: #"共\s*(\d+)\s*页"#, in: pagerText)?
            .dropFirst()
            .first
            .flatMap(Int.init)
            ?? HTMLTextExtractor.matches(pattern: #"page=(\d+)"#, in: pager.html())
            .compactMap { $0.dropFirst().first.flatMap(Int.init) }
            .max()
        return ForumPageNavigation(currentPage: currentPage, totalPages: totalPages)
    }

    /// Nearest ancestor that acts as a list row (`li`/`tr`/`dd`/`div`), or the
    /// element itself when nothing above qualifies.
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

    /// First integer following any of the given labels (used for the
    /// simplified/traditional label pairs like 回复/回復).
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

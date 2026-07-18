import Foundation

/// Parses page-level metadata of a thread page: pagination, view/reply counters,
/// and the owning forum (breadcrumb). The Discuz form hash needed for POST
/// actions comes from the shared `DiscuzFormHashParser`.
enum ForumThreadPageMetadataParser {
    static func pageNavigation(in document: Document) -> ForumPageNavigation? {
        guard let pager = document.selectFirst(".pg") else { return nil }
        let currentPage = pager.firstText("strong").flatMap(Int.init) ?? 1
        let pagerText = pager.normalizedText()
        let totalPages = HTMLTextExtractor.firstMatch(pattern: #"/\s*(\d+)\s*页"#, in: pagerText)?
            .dropFirst()
            .first
            .flatMap(Int.init)
            ?? HTMLTextExtractor.firstMatch(pattern: #"\.\.\s*(\d+)"#, in: pagerText)?
            .dropFirst()
            .first
            .flatMap(Int.init)

        return ForumPageNavigation(currentPage: currentPage, totalPages: totalPages)
    }

    static func threadStats(in document: Document) -> (totalViews: Int?, totalReplies: Int?) {
        let candidateText = [
            ".thread-meta",
            ".thread_stats",
            ".threadstats",
            ".thread_info",
            ".thread-info",
            ".threadlist_foot",
            ".vwthd",
            ".ts",
            ".hm",
            "#thread_subject"
        ]
            .compactMap { selector in
                document.select(selector).text().nilIfBlank
            }
            .joined(separator: " ")

        let fallbackText = candidateText.nilIfBlank
            ?? (document.body()?.text() ?? "")
        return (
            totalViews: intAfterAny(labels: ["查看", "浏览", "瀏覽", "阅读", "閱讀", "views", "view"], in: fallbackText),
            totalReplies: intAfterAny(labels: ["回复", "回復", "回覆", "评论", "評論", "replies", "reply", "comments", "comment"], in: fallbackText)
        )
    }

    static func forumName(in document: Document) -> String? {
        let selectors = [
            "#pt a[href*='forum.php?mod=forumdisplay']",
            "#pt a[href*='fid=']",
            ".bm_h a[href*='forum.php?mod=forumdisplay']",
            ".bm_h a[href*='fid=']",
            "a[href*='forum.php?mod=forumdisplay']"
        ]
        for selector in selectors {
            let values = document.selectAll(selector)
                .compactMap { $0.normalizedText().nilIfBlank }
                .filter { value in
                    value != L10n.string("forum.default_title")
                }
            if let value = values.last {
                return value
            }
        }
        return nil
    }

    static func forumID(in document: Document) -> String? {
        let selectors = [
            "#pt a[href*='fid=']",
            ".bm_h a[href*='fid=']",
            "a[href*='forum.php?mod=forumdisplay']",
            "a[href*='fid=']"
        ]
        for selector in selectors {
            for link in document.selectAll(selector) {
                guard let value = link.attrURL("href")?.queryItemValue("fid") else {
                    continue
                }
                return value
            }
        }
        return nil
    }

    private static func intAfterAny(labels: [String], in text: String) -> Int? {
        let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        for label in labels {
            if let value = HTMLTextExtractor.firstMatch(
                pattern: #"\#(label)\s*[:：]?\s*(\d+)"#,
                in: normalized
            )?
                .dropFirst()
                .last
                .flatMap(Int.init) {
                return value
            }
        }
        return nil
    }
}

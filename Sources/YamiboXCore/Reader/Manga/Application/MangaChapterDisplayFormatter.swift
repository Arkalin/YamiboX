import Foundation

public enum MangaChapterDisplayFormatter {
    public static func displayNumber(for chapter: MangaChapter) -> String {
        displayNumber(rawTitle: chapter.rawTitle, chapterNumber: chapter.chapterNumber)
    }

    public static func readerHeaderTitle(rawTitle: String, cleanBookName: String) -> String {
        let source = readerHeaderEpisodeSource(rawTitle: rawTitle, cleanBookName: cleanBookName)
        let chapterNumber = MangaTitleCleaner.extractChapterNumber(source)
        let displayNumber = displayNumber(rawTitle: source, chapterNumber: chapterNumber)

        if displayNumber != "-" {
            let prefix = readerHeaderEpisodePrefix(displayNumber)
            let subtitle = readerHeaderSubtitle(from: source, displayNumber: displayNumber)
            return [prefix, subtitle]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        if let source = normalizedHeaderComponent(source) {
            return source
        }

        let fallback = MangaTitleCleaner.cleanThreadTitle(rawTitle)
        return normalizedHeaderComponent(fallback) ?? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func displayNumber(rawTitle: String, chapterNumber: Double) -> String {
        let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTitle.contains("最终") || normalizedTitle.localizedCaseInsensitiveContains("final") {
            return "终"
        }
        if normalizedTitle.contains("番外") || normalizedTitle.localizedCaseInsensitiveContains("special") {
            return "SP"
        }
        if normalizedTitle.contains("特别") || normalizedTitle.localizedCaseInsensitiveContains("extra") {
            return "Ex"
        }

        guard chapterNumber > 0 else { return "-" }
        if chapterNumber == floor(chapterNumber) {
            return String(Int(chapterNumber))
        }
        let formatted = String(format: "%.2f", chapterNumber)
        let parts = formatted.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return formatted }

        var suffix = parts[1]
        while suffix.last == "0" {
            suffix.removeLast()
        }
        while suffix.first == "0" {
            suffix.removeFirst()
        }
        guard !suffix.isEmpty else { return parts[0] }
        return "\(parts[0])-\(suffix)"
    }

    public static func latestChapter(in chapters: [MangaChapter]) -> MangaChapter? {
        chapters.max {
            ($0.chapterNumber, Int64($0.tid) ?? 0) < ($1.chapterNumber, Int64($1.tid) ?? 0)
        }
    }

    private static func readerHeaderEpisodeSource(rawTitle: String, cleanBookName: String) -> String {
        var source = MangaTitleCleaner.cleanThreadTitle(rawTitle)
        let replacements = [
            #"【[^】]*】|\[[^\]]*\]|\([^)]*\)|（[^）]*）"#,
            #"\S*汉化组"#
        ]

        for pattern in replacements {
            source = source.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        if let bookName = normalizedHeaderComponent(cleanBookName) {
            source = source.replacingOccurrences(
                of: NSRegularExpression.escapedPattern(for: bookName),
                with: " ",
                options: .regularExpression
            )
        }

        return normalizedHeaderComponent(source) ?? ""
    }

    private static func readerHeaderEpisodePrefix(_ displayNumber: String) -> String {
        switch displayNumber {
        case "终", "SP", "Ex":
            return displayNumber
        default:
            return L10n.string("favorites.manga_chapter", displayNumber)
        }
    }

    private static func readerHeaderSubtitle(from source: String, displayNumber: String) -> String {
        let patterns: [String]
        switch displayNumber {
        case "终":
            patterns = [
                #"^(?:最终话|最終話|最终回|最終回|大结局)(?:\s*[\-—–_、，,|｜:/：#·.。!！?？]+\s*|\s+|$)"#,
                #"(?i)^final(?:\s*[\-—–_、，,|｜:/：#·.。!！?？]+\s*|\s+|$)"#
            ]
        case "SP":
            patterns = [
                #"^(?:番外|特典|附录|SP|卷后附|卷彩页|小剧场|小漫画)(?:篇|章|话|話|回)?(?:\s*[\-—–_、，,|｜:/：#·.。!！?？]+\s*|\s+|$)"#,
                #"(?i)^special(?:\s*[\-—–_、，,|｜:/：#·.。!！?？]+\s*|\s+|$)"#
            ]
        case "Ex":
            patterns = [
                #"^(?:特别|EX|Extra)(?:篇|章|话|話|回)?(?:\s*[\-—–_、，,|｜:/：#·.。!！?？]+\s*|\s+|$)"#,
                #"(?i)^extra(?:\s*[\-—–_、，,|｜:/：#·.。!！?？]+\s*|\s+|$)"#
            ]
        default:
            patterns = [
                #"最终话|最終話|最终回|最終回|大结局"#,
                #"(?i)\bfinal\b"#,
                #"番外|特典|附录|SP|卷后附|卷彩页|小剧场|小漫画"#,
                #"(?i)\bspecial\b"#,
                #"特别"#,
                #"(?i)\bextra\b"#,
                #"第\s*\d+(?:\.\d+)?\s*[-—]\s*\d+(?:\.\d+)?"#,
                #"(?:第)?\s*\d+(?:\.\d+)?\s*[话話织回章节幕折更]\s*[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳⓪]*"#,
                #"\d+(?:\.\d+)?\s*[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳⓪]*"#
            ]
        }

        for pattern in patterns {
            if let range = source.range(of: pattern, options: .regularExpression) {
                var subtitle = source
                subtitle.replaceSubrange(range, with: " ")
                return normalizedHeaderComponent(subtitle) ?? ""
            }
        }

        return normalizedHeaderComponent(source) ?? ""
    }

    private static func normalizedHeaderComponent(_ value: String) -> String? {
        let normalized = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"^[\s\-—–_、，,|｜:/：#·.。!！?？]+|[\s\-—–_、，,|｜:/：#·.。!！?？]+$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

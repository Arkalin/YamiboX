import Foundation

public enum MangaTitleCleaner {
    public static func cleanThreadTitle(_ rawTitle: String) -> String {
        HTMLTextExtractor.regexReplacing(
            rawTitle,
            pattern: #"(?i)\s+[-—–_]+\s+(.*?[区板]\s+[-—–_]+\s+)?(百合会|论坛|手机版|Powered by).*$"#,
            with: ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func cleanBookName(_ rawTitle: String) -> String {
        var clean = cleanThreadTitle(rawTitle)
        let hasLeadingMetadata = HTMLTextExtractor.regexContainsMatch(
            clean,
            pattern: #"^\s*(?:【.*?】|\[.*?\])+"#
        )
        let replacements = [
            #"【.*?】|\[.*?\]"#,
            #"(?i)[\(（]?c\d+[\)）]?"#,
            #"\s*(?:第\s*\d+(?:\.\d+)?\s*[-—]\s*\d+(?:\.\d+)?|(?:第)?\s*\d+(?:\.\d+)?\s*[话話织回章节幕折更]|最终话|最終話|最终回|最終回|大结局).*$"#,
            #"(?i)\s+(?:第\s*)?(?:\d+(?:\.\d+)?|[零〇一二两三四五六七八九十百千]+)\s*[卷册冊部]\s*(?:番外|特典|附录|附錄|特别|特別|SP|卷后附|卷後附|卷彩页|卷彩頁|小剧场|小劇場|小漫画|小漫畫).*$"#,
            #"\s*[|｜].*$"#,
            #"\s+-\s+.*?(中文百合漫画区|百合会|论坛).*$"#
        ]
        for pattern in replacements {
            clean = HTMLTextExtractor.regexReplacing(clean, pattern: pattern, with: "")
        }
        if hasLeadingMetadata {
            clean = HTMLTextExtractor.regexReplacing(
                clean,
                pattern: #"\s+(?:第\s*)?\d{1,3}(?:\.\d+)?(?:\s*[-—]\s*\d{1,3}(?:\.\d+)?)?$"#,
                with: ""
            )
        }
        clean = HTMLTextExtractor.regexReplacing(clean, pattern: #"[！？\?！!~。，、\.]+$"#, with: "")
        clean = HTMLTextExtractor.regexReplacing(clean, pattern: #"^[\s\-/\)#]+|[\s\-/\(#:]+$"#, with: "")
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func extractTid(from url: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: #"tid=(\d+)"#, in: url)?.dropFirst().first
            ?? HTMLTextExtractor.firstMatch(pattern: #"thread-(\d+)-"#, in: url)?.dropFirst().first
    }

    public static func extractAuthorPrefix(_ rawTitle: String) -> String {
        if let direct = HTMLTextExtractor.firstMatch(pattern: #"^\s*【(.*?)】"#, in: rawTitle)?.dropFirst().first,
           !direct.isEmpty {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let direct = HTMLTextExtractor.firstMatch(pattern: #"^\s*\[(.*?)\]"#, in: rawTitle)?.dropFirst().first,
           !direct.isEmpty {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let prefix = HTMLTextExtractor.firstMatch(
            pattern: #"^(?:【.*?】|\[.*?\]|[\s\u{00A0}\u{3000}])+"#,
            in: rawTitle
        )?.first else {
            return ""
        }

        let bracketMatches = HTMLTextExtractor.matches(pattern: #"【(.*?)】|\[(.*?)\]"#, in: prefix)
        guard let last = bracketMatches.last else { return "" }
        return last.dropFirst().first(where: { !$0.isEmpty })?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public static func searchKeyword(_ rawTitle: String) -> String {
        let author = extractAuthorPrefix(rawTitle)
        let cleanName = cleanBookName(rawTitle)
        let combined = [author, cleanName].filter { !$0.isEmpty }.joined(separator: " ")
        return String(combined.prefix(18)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func extractChapterNumber(_ rawTitle: String) -> Double {
        let cleaned = HTMLTextExtractor.regexReplacing(
            rawTitle,
            pattern: #"【.*?】|\[.*?\]|\(.*?\)|（.*?）|「.*?」|《.*?》"#,
            with: ""
        )

        if HTMLTextExtractor.regexContainsMatch(cleaned, pattern: #"番外|特典|附录|SP|卷后附|卷彩页|小剧场|小漫画"#) {
            return 0
        }
        if HTMLTextExtractor.regexContainsMatch(cleaned, pattern: #"最终话|最終話|最终回|最終回|大结局"#) {
            return 999
        }

        if let circledSuffix = HTMLTextExtractor.firstMatch(
            pattern: #"(?:第)?\s*(\d+(?:\.\d+)?)\s*[话話织回章节幕折更]\s*([①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳⓪]+)"#,
            in: cleaned
        ),
           let base = circledSuffix.dropFirst().first.flatMap(Double.init),
           let suffix = circledSuffix.dropFirst().dropFirst().first.flatMap(circledDigitsValue) {
            return base + (suffix / 100)
        }

        if let circledSuffix = HTMLTextExtractor.firstMatch(
            pattern: #"(?:^|[^\d.])(\d+(?:\.\d+)?)\s*([①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳⓪]+)(?!.*\d)"#,
            in: cleaned
        ),
           let base = circledSuffix.dropFirst().first.flatMap(Double.init),
           let suffix = circledSuffix.dropFirst().dropFirst().first.flatMap(circledDigitsValue) {
            return base + (suffix / 100)
        }

        let patterns = [
            #"第\s*(\d+(?:\.\d+)?)\s*[-—]\s*(\d+(?:\.\d+)?)"#,
            #"(?:第)?\s*(\d+(?:\.\d+)?)\s*[话話织回章节幕折更]"#,
            #"第\s*(\d+(?:\.\d+)?)"#,
            #"[-—|｜]\s*(\d+(?:\.\d+)?)"#,
            #"(\d+(?:\.\d+)?)(?!.*\d)"#
        ]

        for pattern in patterns {
            guard let match = HTMLTextExtractor.firstMatch(pattern: pattern, in: cleaned) else { continue }
            let numbers = match.dropFirst().compactMap(Double.init)
            if numbers.count == 2 {
                return numbers[0] + (numbers[1] / 100)
            }
            if let number = numbers.first {
                return number
            }
        }

        return 0
    }

    private static func circledDigitsValue(_ raw: String) -> Double? {
        let mapped = raw.compactMap { character -> String? in
            switch character {
            case "⓪": return "0"
            case "①": return "1"
            case "②": return "2"
            case "③": return "3"
            case "④": return "4"
            case "⑤": return "5"
            case "⑥": return "6"
            case "⑦": return "7"
            case "⑧": return "8"
            case "⑨": return "9"
            case "⑩": return "10"
            case "⑪": return "11"
            case "⑫": return "12"
            case "⑬": return "13"
            case "⑭": return "14"
            case "⑮": return "15"
            case "⑯": return "16"
            case "⑰": return "17"
            case "⑱": return "18"
            case "⑲": return "19"
            case "⑳": return "20"
            default: return nil
            }
        }.joined()
        return mapped.isEmpty ? nil : Double(mapped)
    }

    public static func extractAllPossibleNumbers(from rawTitle: String) -> [Double] {
        let patterns = [
            #"\d+(?:\.\d+)?"#,
            #"第\s*(\d+(?:\.\d+)?)"#,
        ]
        var values: [Double] = []
        for pattern in patterns {
            for match in HTMLTextExtractor.matches(pattern: pattern, in: rawTitle) {
                values.append(contentsOf: match.compactMap(Double.init))
            }
        }
        return Array(Set(values)).sorted()
    }
}

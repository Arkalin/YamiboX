import Foundation

/// The single decoder of Discuz "last edited" notes ("本帖最后由 X 于 <日期> 编辑"
/// and its variants) plus the site's date formats. Two drifted copies used to
/// exist — the favorites content-update resolver and the thread-page post
/// parser — with different simplified/traditional pairings; this is their
/// union: each token alternates 简/繁 independently, so mixed-variant pages
/// match too. Pure text in, text/Date out — deliberately free of any DOM
/// dependency so both HTML parsers and domain code can share it.
enum DiscuzEditedDateParser {
    // Group 1 captures the timestamp; the whole match is the sentence. One
    // pattern list serves both note location and timestamp extraction so the
    // two capabilities cannot fork again.
    private static let notePatterns = [
        #"(?:本帖最后由|本帖最後由)\s+.+?\s+(?:于|於)\s+(.+?)\s+(?:编辑|編輯)"#,
        #"(?:最后编辑于|最後編輯於)\s*(.+)"#
    ]

    /// The full edit-note sentence located inside free text, or nil. Used by
    /// the post parser when no dedicated `.pstatus`-style node carries it.
    static func firstEditedNote(in text: String) -> String? {
        for pattern in notePatterns {
            guard let regex = HTMLTextExtractor.cachedRegex(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let matchRange = Range(match.range, in: text) else {
                continue
            }
            return String(text[matchRange]).nilIfBlank
        }
        return nil
    }

    /// The moment the content last changed: the edit note's timestamp when one
    /// is present, otherwise whatever date the posted-at text yields.
    static func date(lastEditedText: String?, postedAtText: String?, relativeTo: Date? = nil) -> Date? {
        [date(from: extractedEditTime(from: lastEditedText), relativeTo: relativeTo),
         date(from: postedAtText, relativeTo: relativeTo)].compactMap { $0 }.max()
    }

    static func date(from text: String?, relativeTo: Date? = nil) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let normalized = text.replacingOccurrences(of: "/", with: "-")
        let datePatterns = [
            #"(\d{4}-\d{1,2}-\d{1,2}\s+\d{1,2}:\d{2}(?::\d{2})?)"#,
            #"(\d{4}-\d{1,2}-\d{1,2})"#
        ]
        // Locale/calendar/timeZone never vary across patterns or formats, so
        // one DateFormatter is built per call and reused for every attempt
        // instead of re-constructing it (expensive: loads ICU data) on each
        // loop iteration. Kept local to this call rather than a shared
        // `static let` because DateFormatter is not thread-safe and this
        // parser has no guarantee against concurrent callers (e.g. parallel
        // Swift Testing test functions).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for pattern in datePatterns {
            guard let regex = HTMLTextExtractor.cachedRegex(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex ..< normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range),
                  let matchRange = Range(match.range(at: 1), in: normalized) else {
                continue
            }
            let value = String(normalized[matchRange])
            for format in formats(for: value) {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) {
                    return date
                }
            }
        }
        guard let relativeTo else { return nil }
        return relativeDate(from: normalized, relativeTo: relativeTo)
    }

    /// Only call with the page's capture time. Reinterpreting cached relative
    /// text against today's clock would make unchanged content appear newer.
    private static func relativeDate(from text: String, relativeTo: Date) -> Date? {
        if text == "刚刚" || text == "剛剛" { return relativeTo }
        if let match = HTMLTextExtractor.firstMatch(
            pattern: #"^(\d+)\s*(秒|分钟|分鐘|小时|小時|天)前$"#, in: text
        ), let count = Double(match[1]) {
            let seconds: Double = switch match[2] {
            case "秒": 1
            case "分钟", "分鐘": 60
            case "小时", "小時": 3600
            default: 86400
            }
            return relativeTo.addingTimeInterval(-count * seconds)
        }
        guard let match = HTMLTextExtractor.firstMatch(
            pattern: #"^(今天|昨天|前天)\s*(\d{1,2}):(\d{2})(?::(\d{2}))?$"#, in: text
        ), let hour = Int(match[2]), let minute = Int(match[3]),
              hour < 24, minute < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let offset = match[1] == "今天" ? 0 : (match[1] == "昨天" ? -1 : -2)
        guard let day = calendar.date(byAdding: .day, value: offset, to: relativeTo) else { return nil }
        let second = match.count > 4 ? (Int(match[4]) ?? 0) : 0
        guard second < 60 else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: second, of: day)
    }

    private static func extractedEditTime(from text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        for pattern in notePatterns {
            guard let regex = HTMLTextExtractor.cachedRegex(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[matchRange]).nilIfBlank
        }
        // Callers pass bare timestamps here too, not just edit notes; text
        // that matches no note shape still deserves a date-parse attempt.
        return text
    }

    private static func formats(for value: String) -> [String] {
        if value.contains(":") {
            return value.split(separator: ":").count == 3
                ? ["yyyy-M-d H:mm:ss", "yyyy-MM-dd HH:mm:ss"]
                : ["yyyy-M-d H:mm", "yyyy-MM-dd HH:mm"]
        }
        return ["yyyy-M-d", "yyyy-MM-dd"]
    }
}

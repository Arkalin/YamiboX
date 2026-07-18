import Foundation

enum HTMLTextExtractor {
    static func matches(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
    ) -> [[String]] {
        guard let regex = cachedRegex(pattern: pattern, options: options) else {
            YamiboLog.app.warning("HTMLTextExtractor: malformed regex pattern \(pattern, privacy: .public), returning no matches")
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).map { result in
            (0 ..< result.numberOfRanges).compactMap { index in
                let range = result.range(at: index)
                guard let swiftRange = Range(range, in: text) else { return nil }
                return String(text[swiftRange])
            }
        }
    }

    static func firstMatch(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
    ) -> [String]? {
        matches(pattern: pattern, in: text, options: options).first
    }

    static func stripTags(_ text: String) -> String {
        let withoutTags = regexReplacing(text, pattern: "<[^>]+>", with: " ")
        let decoded = decodeHTMLEntities(withoutTags)
        return regexReplacing(decoded, pattern: "\\s+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        var value = text
        let replacements = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'"
        ]
        for (source, target) in replacements {
            value = value.replacingOccurrences(of: source, with: target)
        }
        return value
    }

    static func absoluteURL(from href: String, baseURL: URL = YamiboDomain.baseURL) -> URL? {
        URL(string: decodeHTMLEntities(href), relativeTo: baseURL)?.absoluteURL
    }

    /// Payload of the `<root><![CDATA[…]]></root>` envelope Discuz wraps AJAX
    /// responses in, or nil when the input is not such an envelope. Feeding the
    /// raw envelope to the HTML parser destroys the first tag of the payload
    /// and leaks a literal "]]>" text node into the body.
    static func discuzAjaxPayload(from html: String) -> String? {
        guard let startRange = html.range(of: "<![CDATA["),
              let endRange = html.range(of: "]]>", range: startRange.upperBound ..< html.endIndex) else {
            return nil
        }
        return String(html[startRange.upperBound ..< endRange.lowerBound])
    }

    static func cachedRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        regexCache.regex(pattern: pattern, options: options)
    }

    // Equivalent to `String.replacingOccurrences(of:with:options:.regularExpression)` but backed
    // by cachedRegex, so repeated calls with the same pattern skip NSRegularExpression compilation.
    static func regexReplacing(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = cachedRegex(pattern: pattern) else {
            YamiboLog.app.warning("HTMLTextExtractor: malformed regex pattern \(pattern, privacy: .public), leaving text unchanged")
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    // Equivalent to `String.range(of:options:.regularExpression) != nil` but backed by cachedRegex.
    static func regexContainsMatch(_ text: String, pattern: String) -> Bool {
        guard let regex = cachedRegex(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static let regexCache = RegexCache()
}

// Some callers interpolate variable content (e.g. a thread ID) into patterns, so cache keys
// aren't a small fixed set. NSCache is thread-safe without manual locking and evicts under
// memory pressure, unlike a plain Dictionary; countLimit bounds the interpolated-key growth
// over a long session without waiting for memory pressure.
private final class RegexCache: @unchecked Sendable {
    private let storage = NSCache<NSString, NSRegularExpression>()

    init() {
        storage.countLimit = 512
    }

    func regex(pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue):\(pattern)" as NSString
        if let cached = storage.object(forKey: key) {
            return cached
        }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        storage.setObject(compiled, forKey: key)
        return compiled
    }
}

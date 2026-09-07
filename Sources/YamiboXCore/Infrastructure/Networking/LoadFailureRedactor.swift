import Foundation

enum LoadFailureRedactor {
    private static let marker = "[REDACTED]"
    private static let secretKey = #"(?:[\w-]*(?:password|passwd|pwd|cookie|authorization|formhash|token|secret|sessionid|authkey|seccode|nox_jst)[\w-]*)"#

    static func redact(_ text: String) -> String {
        var result = text
        // Use the HTML parser to identify credential fields, but replace in the
        // source spans rather than serializing the DOM (malformed markup matters).
        result = replacing(#"(?is)<(?:input|meta)\b(?:[^"'<>]|"[^"]*"|'[^']*')*>?"#, in: result) { tag in
            let node = (try? KannaSoup.parse(tag))?.selectFirst("input, meta")
            let field = node?.attr("name") ?? ""
            let id = node?.attr("id") ?? ""
            let isSecret = node == nil || node?.attr("type").lowercased() == "password"
                || matches(secretKey, in: field) || matches(secretKey, in: id)
            guard isSecret else { return tag }
            return replacing(#"(?is)\b(value|content)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, in: tag) { attribute in
                let name = attribute.prefix { $0 != "=" && !$0.isWhitespace }
                return "\(name)=\"\(marker)\""
            }
        }
        result = replacing(#"(?is)<textarea\b(?:[^"'<>]|"[^"]*"|'[^']*')*>.*?</textarea\s*>"#, in: result) { tag in
            guard let node = (try? KannaSoup.parse(tag))?.selectFirst("textarea"),
                  matches(secretKey, in: node.attr("name") + " " + node.attr("id")) else { return tag }
            return replacing(#"(?is)(?<=\>).*?(?=</textarea)"#, in: tag) { _ in marker }
        }
        // Header values and script/JSON/form assignments can occur in plain text
        // as well as HTML. Never enumerate arbitrary NSError userInfo contents.
        result = replacing(#"(?im)\b(?:authorization|(?:set-)?cookie)\s*:\s*[^\r\n<]+"#, in: result) { value in
            String(value.prefix { $0 != ":" }) + ": " + marker
        }
        let assignment = #"(?i)(?<![\w-])["']?"# + secretKey + #"["']?\s*[:=]\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^&\s;<>"'}]+)"#
        result = replacing(assignment, in: result) { value in
            guard let separator = value.firstIndex(where: { $0 == ":" || $0 == "=" }) else { return marker }
            return String(value[...separator]) + "\"\(marker)\""
        }
        result = replacing(#"(?i)https?://[^\s<>"']+"#, in: result) { raw in
            guard var url = URLComponents(string: raw) else { return raw }
            if url.user != nil { url.user = marker }
            if url.password != nil { url.password = marker }
            url.queryItems = url.queryItems?.map { item in
                URLQueryItem(name: item.name, value: matches(secretKey, in: item.name) ? marker : item.value)
            }
            if let fragment = url.fragment, matches(secretKey, in: fragment) { url.fragment = marker }
            return url.string ?? raw
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func replacing(_ pattern: String, in text: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let originalRange = Range(match.range, in: text),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(text[originalRange])))
        }
        return result
    }
}

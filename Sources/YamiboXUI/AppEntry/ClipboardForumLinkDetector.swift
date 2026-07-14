import Foundation
import YamiboXCore

public struct ClipboardForumLinkDetector: Sendable {
    private var lastPromptedURLString: String?

    public init() {}

    public mutating func promptURL(from clipboardText: String?) -> URL? {
        guard let url = Self.firstForumURL(in: clipboardText) else {
            resetConsecutivePrompt()
            return nil
        }

        let urlString = url.absoluteString
        guard urlString != lastPromptedURLString else { return nil }
        lastPromptedURLString = urlString
        return url
    }

    public static func firstForumURL(in text: String?) -> URL? {
        guard let text, !text.isEmpty else { return nil }

        let prefixes = [
            "https://\(YamiboDomain.forumHost)",
            "http://\(YamiboDomain.forumHost)",
            YamiboDomain.forumHost
        ]
        let matches = prefixes.flatMap { prefix -> [(range: Range<String.Index>, prefix: String)] in
            var ranges: [(range: Range<String.Index>, prefix: String)] = []
            var searchStart = text.startIndex

            while searchStart < text.endIndex {
                let searchRange = searchStart..<text.endIndex
                guard let range = text.range(
                    of: prefix,
                    options: [.caseInsensitive],
                    range: searchRange
                ) else {
                    break
                }
                ranges.append((range, prefix))
                searchStart = range.upperBound
            }

            return ranges
        }
        .sorted { $0.range.lowerBound < $1.range.lowerBound }

        for match in matches where hasValidLeadingBoundary(before: match.range.lowerBound, in: text) {
            let rawCandidate = candidateURLString(
                from: match.range.lowerBound,
                in: text,
                hasScheme: match.prefix.hasPrefix("http")
            )
            guard let url = URL(string: rawCandidate),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  YamiboDomain.isForumHost(url) else {
                continue
            }
            return mobileForumURL(from: url)
        }

        return nil
    }

    public mutating func resetConsecutivePrompt() {
        lastPromptedURLString = nil
    }

    private static func candidateURLString(
        from start: String.Index,
        in text: String,
        hasScheme: Bool
    ) -> String {
        let end = text[start...].firstIndex(where: isURLTerminator) ?? text.endIndex
        let candidate = String(text[start..<end]).trimmingTrailingURLPunctuation()
        return hasScheme ? candidate : "https://\(candidate)"
    }

    private static func hasValidLeadingBoundary(before start: String.Index, in text: String) -> Bool {
        guard start > text.startIndex else { return true }
        let previous = text[text.index(before: start)]
        return !previous.isLetter && !previous.isNumber && previous != "." && previous != "-" && previous != "_"
    }

    private static func isURLTerminator(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline {
            return true
        }
        return #""'<>[]{}()（）［］【】「」『』“”‘’"#.contains(character)
    }

    private static func mobileForumURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        let queryItems = components.queryItems ?? []
        guard !queryItems.contains(where: { $0.name == "mobile" && $0.value == "2" }) else {
            return url
        }

        components.queryItems = queryItems + [URLQueryItem(name: "mobile", value: "2")]
        return components.url ?? url
    }
}

private extension String {
    func trimmingTrailingURLPunctuation() -> String {
        trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?，。！？；：、"))
    }
}

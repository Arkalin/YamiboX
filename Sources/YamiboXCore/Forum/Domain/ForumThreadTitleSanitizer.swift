import Foundation

public enum ForumThreadTitleSanitizer {
    public static func sanitize(_ title: String?) -> String? {
        var value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }

        var removedSiteSuffix = false
        while true {
            let current = value
            value = removingSuffix(pattern: #"\s*-\s*powered\s*by\s*discuz!?\s*$"#, from: value)
            value = removingSuffix(pattern: #"\s*-\s*(手机版|手機版|mobile)\s*$"#, from: value)
            value = removingSuffix(pattern: #"\s*-\s*(百合会|百合會)\s*$"#, from: value)
            removedSiteSuffix = removedSiteSuffix || value != current
            if value == current { break }
        }

        if removedSiteSuffix {
            value = removingSuffix(pattern: #"\s*-\s*[^-]{1,24}(区|區|版|论坛|論壇)\s*$"#, from: value)
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func removingSuffix(pattern: String, from value: String) -> String {
        value.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}

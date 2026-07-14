import Foundation

enum NovelChapterTitleNormalizer {
    static func normalize(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let normalized = candidate
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized.isEmpty ? nil : normalized
    }
}

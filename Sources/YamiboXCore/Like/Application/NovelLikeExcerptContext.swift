import Foundation

package enum NovelLikeExcerptContext {
    private static let clauseDelimiters = Set("。！？…；：，、\n.!?;:,")

    private static let sentenceDelimiters = Set("。！？…\n")

    private static let prefixCharacterLimit = 16

    private static let suffixCharacterLimit = 40

    package static func make(
        textBefore: String,
        textAfter: String
    ) -> (prefix: String?, suffix: String?) {
        (prefix: prefix(from: textBefore), suffix: suffix(from: textAfter))
    }

    private static func prefix(from textBefore: String) -> String? {
        let clauseHead: Substring
        if let boundary = textBefore.lastIndex(where: { clauseDelimiters.contains($0) }) {
            clauseHead = textBefore[textBefore.index(after: boundary)...]
        } else {
            clauseHead = textBefore[...]
        }
        let trimmed = clauseHead.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(prefixCharacterLimit))
    }

    private static func suffix(from textAfter: String) -> String? {
        var tail = textAfter[...]
        if let boundary = tail.firstIndex(where: { sentenceDelimiters.contains($0) }) {
            let end = tail[boundary].isNewline ? boundary : tail.index(after: boundary)
            tail = tail[..<end]
        }
        let trimmed = String(tail.prefix(suffixCharacterLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

import Foundation

public enum NovelChapterTextComponents {
    public static func split(text: String, chapterTitle: String?) -> (title: String?, body: String?) {
        guard let chapterTitle else {
            return (nil, nil)
        }

        let trimmedTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return (nil, nil)
        }

        if text == trimmedTitle {
            return (trimmedTitle, nil)
        }

        let lineBreakCandidates = ["\r\n", "\n", "\r"]
        for separator in lineBreakCandidates {
            let prefixedTitle = trimmedTitle + separator
            if text.hasPrefix(prefixedTitle) {
                let body = String(text.dropFirst(prefixedTitle.count))
                return (trimmedTitle, separator + body)
            }
        }

        return (nil, nil)
    }
}

package enum NovelParagraphIndentPlanner {
    package static func indentedParagraphRangesAfterFirst(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        var isFirstParagraph = true

        while index < text.endIndex {
            let paragraphStart = index
            while index < text.endIndex, text[index].isReaderParagraphSeparator {
                index = text.index(after: index)
            }

            var paragraphEnd = index
            while paragraphEnd < text.endIndex, !text[paragraphEnd].isReaderParagraphSeparator {
                paragraphEnd = text.index(after: paragraphEnd)
            }

            let styleRange = paragraphStart ..< paragraphEnd
            if !isFirstParagraph, !styleRange.isEmpty {
                ranges.append(styleRange)
            }

            isFirstParagraph = false
            index = paragraphEnd
        }

        return ranges
    }
}

private extension Character {
    var isReaderParagraphSeparator: Bool {
        self == "\n" || self == "\r"
    }
}

import Foundation

/// Whitespace/newline normalization for committed text runs.
///
/// Alongside the normalized text it produces a boundary map so that character-indexed
/// attributes (links, style runs, rubies) recorded against the raw text can be projected
/// onto the normalized text via `NormalizedText.range(start:length:)`.
enum ForumThreadTextNormalizer {
    struct NormalizedText {
        let text: String
        /// `boundaryMap[i]` is the position in `text` that source boundary `i` maps to.
        private let boundaryMap: [Int]
        private let characterCount: Int

        init(text: String, boundaryMap: [Int]) {
            self.text = text
            self.boundaryMap = boundaryMap
            characterCount = text.count
        }

        /// Projects a character range of the source text onto the normalized text,
        /// or nil when the range collapses to nothing.
        func range(start: Int, length: Int) -> (start: Int, length: Int)? {
            guard length > 0, start >= 0, start < boundaryMap.count else { return nil }
            let sourceEnd = min(start + length, boundaryMap.count - 1)
            let normalizedStart = min(max(boundaryMap[start], 0), characterCount)
            let normalizedEnd = min(max(boundaryMap[sourceEnd], 0), characterCount)
            guard normalizedEnd > normalizedStart else { return nil }
            return (normalizedStart, normalizedEnd - normalizedStart)
        }
    }

    static func normalize(_ value: String) -> NormalizedText {
        var characters = Array(value)
        var boundaryMap = Array(0 ... characters.count)

        func apply(_ transform: ([Character]) -> (characters: [Character], boundaryMap: [Int])) {
            let result = transform(characters)
            characters = result.characters
            boundaryMap = boundaryMap.map { boundary in
                result.boundaryMap[min(boundary, result.boundaryMap.count - 1)]
            }
        }

        apply(collapseCollapsibleSpaces)
        apply(removeSpacesAdjacentToNewlines)
        apply(collapseExcessNewlines)
        apply(trimWhitespaceAndNewlines)

        return NormalizedText(text: String(characters), boundaryMap: boundaryMap)
    }

    private static func collapseCollapsibleSpaces(_ characters: [Character])
        -> (characters: [Character], boundaryMap: [Int]) {
        var output: [Character] = []
        var boundaryMap = Array(repeating: 0, count: characters.count + 1)
        var index = 0

        while index < characters.count {
            let outputStart = output.count
            if isCollapsibleSpace(characters[index]) {
                var end = index + 1
                while end < characters.count, isCollapsibleSpace(characters[end]) {
                    end += 1
                }
                output.append(" ")
                boundaryMap[index] = outputStart
                for boundary in (index + 1) ... end {
                    boundaryMap[boundary] = outputStart + 1
                }
                index = end
            } else {
                output.append(characters[index])
                boundaryMap[index] = outputStart
                boundaryMap[index + 1] = outputStart + 1
                index += 1
            }
        }

        return (output, boundaryMap)
    }

    private static func removeSpacesAdjacentToNewlines(_ characters: [Character])
        -> (characters: [Character], boundaryMap: [Int]) {
        var output: [Character] = []
        var boundaryMap = Array(repeating: 0, count: characters.count + 1)

        for index in characters.indices {
            let isSpaceBesideNewline = characters[index] == " "
                && ((index > 0 && characters[index - 1] == "\n")
                    || (index + 1 < characters.count && characters[index + 1] == "\n"))
            boundaryMap[index] = output.count
            if isSpaceBesideNewline {
                boundaryMap[index + 1] = output.count
            } else {
                output.append(characters[index])
                boundaryMap[index + 1] = output.count
            }
        }

        return (output, boundaryMap)
    }

    private static func collapseExcessNewlines(_ characters: [Character])
        -> (characters: [Character], boundaryMap: [Int]) {
        var output: [Character] = []
        var boundaryMap = Array(repeating: 0, count: characters.count + 1)
        var index = 0

        while index < characters.count {
            let outputStart = output.count
            if characters[index] == "\n" {
                var end = index + 1
                while end < characters.count, characters[end] == "\n" {
                    end += 1
                }
                let keptCount = min(2, end - index)
                output.append(contentsOf: Array(repeating: Character("\n"), count: keptCount))
                boundaryMap[index] = outputStart
                for offset in 1 ... (end - index) {
                    boundaryMap[index + offset] = outputStart + min(offset, keptCount)
                }
                index = end
            } else {
                output.append(characters[index])
                boundaryMap[index] = outputStart
                boundaryMap[index + 1] = outputStart + 1
                index += 1
            }
        }

        return (output, boundaryMap)
    }

    private static func trimWhitespaceAndNewlines(_ characters: [Character])
        -> (characters: [Character], boundaryMap: [Int]) {
        let start = characters.firstIndex(where: { !isTrimmedWhitespace($0) }) ?? characters.count
        let end = characters.lastIndex(where: { !isTrimmedWhitespace($0) }).map { $0 + 1 } ?? start
        let output = start < end ? Array(characters[start ..< end]) : []
        let boundaryMap = (0 ... characters.count).map { boundary in
            if boundary <= start {
                return 0
            }
            if boundary >= end {
                return output.count
            }
            return boundary - start
        }
        return (output, boundaryMap)
    }

    private static func isCollapsibleSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{00A0}"
    }

    private static func isTrimmedWhitespace(_ character: Character) -> Bool {
        String(character).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

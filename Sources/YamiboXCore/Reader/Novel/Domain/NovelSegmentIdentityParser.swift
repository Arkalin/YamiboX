import Foundation

/// Decodes the shared "<chapterIdentity>#text:N" / "#image:N" identity
/// format without depending on bookmarks or Like Items.
enum NovelSegmentIdentityParser {
    private static let occurrenceSuffixRegex = try! NSRegularExpression(pattern: #"#(?:text|image):(\d+)$"#)

    static func occurrence(of segmentIdentity: String) -> Int? {
        guard let match = firstMatch(in: segmentIdentity),
              let numberRange = Range(match.range(at: 1), in: segmentIdentity) else {
            return nil
        }
        return Int(segmentIdentity[numberRange])
    }

    static func chapterScope(of segmentIdentity: String) -> String? {
        guard let match = firstMatch(in: segmentIdentity),
              let matchRange = Range(match.range, in: segmentIdentity) else {
            return nil
        }
        return String(segmentIdentity[segmentIdentity.startIndex ..< matchRange.lowerBound])
    }

    private static func firstMatch(in segmentIdentity: String) -> NSTextCheckingResult? {
        let range = NSRange(segmentIdentity.startIndex ..< segmentIdentity.endIndex, in: segmentIdentity)
        return occurrenceSuffixRegex.firstMatch(in: segmentIdentity, range: range)
    }
}

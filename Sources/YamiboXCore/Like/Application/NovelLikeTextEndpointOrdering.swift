import Foundation

/// Orders `NovelLikeTextEndpoint`s within a chapter's linear reading flow and
/// decides whether two text Like ranges overlap or touch, so adding a range
/// that overlaps or touches existing text Like Items can merge them.
///
/// Segment identities are shaped "<chapterIdentity>#text:N" or
/// "<chapterIdentity>#image:N" (see `NovelReaderProjectionBuilder`), so
/// stripping the trailing occurrence suffix recovers the owning chapter, and
/// the occurrence number gives document order across different segments.
enum NovelLikeTextEndpointOrdering {
    private static let occurrenceSuffixRegex = try! NSRegularExpression(pattern: #"#(?:text|image):(\d+)$"#)

    /// The document-order occurrence number embedded in a segment identity's
    /// trailing "#text:N" / "#image:N" suffix, or nil if the identity doesn't
    /// carry one.
    static func occurrence(of segmentIdentity: String) -> Int? {
        guard let match = firstMatch(in: segmentIdentity),
              let numberRange = Range(match.range(at: 1), in: segmentIdentity) else {
            return nil
        }
        return Int(segmentIdentity[numberRange])
    }

    /// Orders two endpoints in document reading order. Returns nil when the
    /// endpoints can't be placed in the same chapter, since cross-chapter
    /// position has no defined order here.
    static func compare(_ lhs: NovelLikeTextEndpoint, _ rhs: NovelLikeTextEndpoint) -> ComparisonResult? {
        if lhs.segmentIdentity == rhs.segmentIdentity {
            if lhs.offset == rhs.offset { return .orderedSame }
            return lhs.offset < rhs.offset ? .orderedAscending : .orderedDescending
        }
        guard let lhsScope = chapterScope(of: lhs.segmentIdentity),
              let rhsScope = chapterScope(of: rhs.segmentIdentity),
              lhsScope == rhsScope,
              let lhsOccurrence = occurrence(of: lhs.segmentIdentity),
              let rhsOccurrence = occurrence(of: rhs.segmentIdentity) else {
            return nil
        }
        if lhsOccurrence == rhsOccurrence { return .orderedSame }
        return lhsOccurrence < rhsOccurrence ? .orderedAscending : .orderedDescending
    }

    /// True when the two anchors' ranges overlap or are contiguous (no
    /// character gap between them) within the same chapter. Different
    /// segments never touch under this model: a Like range is confined to
    /// one text segment, so only same-segment ranges can merge.
    static func overlapsOrTouches(_ lhs: NovelTextLikeAnchor, _ rhs: NovelTextLikeAnchor) -> Bool {
        guard lhs.chapterIdentity == rhs.chapterIdentity else { return false }
        guard let forward = compare(lhs.endEndpoint, rhs.startEndpoint),
              let backward = compare(rhs.endEndpoint, lhs.startEndpoint) else {
            return false
        }
        return forward != .orderedAscending && backward != .orderedAscending
    }

    private static func chapterScope(of segmentIdentity: String) -> String? {
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

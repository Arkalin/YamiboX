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
    /// Orders two endpoints in document reading order. Returns nil when the
    /// endpoints can't be placed in the same chapter, since cross-chapter
    /// position has no defined order here.
    static func compare(_ lhs: NovelLikeTextEndpoint, _ rhs: NovelLikeTextEndpoint) -> ComparisonResult? {
        if lhs.segmentIdentity == rhs.segmentIdentity {
            if lhs.offset == rhs.offset { return .orderedSame }
            return lhs.offset < rhs.offset ? .orderedAscending : .orderedDescending
        }
        guard let lhsScope = NovelSegmentIdentityParser.chapterScope(of: lhs.segmentIdentity),
              let rhsScope = NovelSegmentIdentityParser.chapterScope(of: rhs.segmentIdentity),
              lhsScope == rhsScope,
              let lhsOccurrence = NovelSegmentIdentityParser.occurrence(of: lhs.segmentIdentity),
              let rhsOccurrence = NovelSegmentIdentityParser.occurrence(of: rhs.segmentIdentity) else {
            return nil
        }
        if lhsOccurrence == rhsOccurrence { return .orderedSame }
        return lhsOccurrence < rhsOccurrence ? .orderedAscending : .orderedDescending
    }

    /// True when the two anchors' ranges overlap or are contiguous (no
    /// character gap between them) within the same chapter.
    ///
    /// Works across segments as well as within one: `compare` already orders
    /// endpoints in different segments of the same chapter by their occurrence
    /// number, and an anchor may now span segments. Two annotations on either
    /// side of an illustration therefore *do* touch, and merge, which is the
    /// point — the illustration is a layout break, not a semantic one.
    static func overlapsOrTouches(_ lhs: NovelTextLikeAnchor, _ rhs: NovelTextLikeAnchor) -> Bool {
        guard lhs.chapterIdentity == rhs.chapterIdentity else { return false }
        guard let forward = compare(lhs.endEndpoint, rhs.startEndpoint),
              let backward = compare(rhs.endEndpoint, lhs.startEndpoint) else {
            return false
        }
        return forward != .orderedAscending && backward != .orderedAscending
    }
}

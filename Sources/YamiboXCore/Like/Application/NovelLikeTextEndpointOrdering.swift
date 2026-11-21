import Foundation

enum NovelLikeTextEndpointOrdering {
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

    static func overlapsOrTouches(_ lhs: NovelTextLikeAnchor, _ rhs: NovelTextLikeAnchor) -> Bool {
        guard lhs.chapterIdentity == rhs.chapterIdentity else { return false }
        guard let forward = compare(lhs.endEndpoint, rhs.startEndpoint),
              let backward = compare(rhs.endEndpoint, lhs.startEndpoint) else {
            return false
        }
        return forward != .orderedAscending && backward != .orderedAscending
    }
}

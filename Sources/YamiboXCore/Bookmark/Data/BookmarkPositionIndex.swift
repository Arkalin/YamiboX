import Foundation

/// Positions only: full bookmark display data is fetched for the winning ID.
/// Entries arrive in the store's original book order, so duplicates and nearby
/// novel positions still choose the same first row as the uncached query.
struct BookmarkPositionIndex: Sendable {
    let workKey: ReadingWorkKey
    let revision: String

    private struct NovelSegment: Hashable, Sendable {
        let chapter: NovelChapterIdentity?
        let segment: NovelTextSegmentIdentity?
    }

    private struct MangaPage: Hashable, Sendable {
        let chapter: String
        let localIndex: Int
    }

    private struct Candidate: Sendable {
        let id: String
        let order: Int
    }

    private let novel: [NovelSegment: [Int: Candidate]]
    private let manga: [MangaPage: String]

    init(workKey: ReadingWorkKey, revision: String,
         entries: [(id: String, anchor: BookmarkAnchorPayload)]) {
        self.workKey = workKey
        self.revision = revision
        var novel: [NovelSegment: [Int: Candidate]] = [:]
        var manga: [MangaPage: String] = [:]
        for (order, entry) in entries.enumerated() {
            switch entry.anchor {
            case let .novel(anchor):
                let key = NovelSegment(chapter: anchor.chapterIdentity, segment: anchor.textSegmentIdentity)
                if novel[key]?[anchor.displayedTextOffset] == nil {
                    novel[key, default: [:]][anchor.displayedTextOffset] = Candidate(id: entry.id, order: order)
                }
            case let .manga(anchor):
                let key = MangaPage(chapter: anchor.chapterTID, localIndex: anchor.pageLocalIndex)
                if manga[key] == nil { manga[key] = entry.id }
            }
        }
        self.novel = novel
        self.manga = manga
    }

    func firstID(marking payload: BookmarkAnchorPayload) -> String? {
        switch payload {
        case let .manga(anchor):
            return manga[MangaPage(chapter: anchor.chapterTID, localIndex: anchor.pageLocalIndex)]
        case let .novel(anchor):
            let key = NovelSegment(chapter: anchor.chapterIdentity, segment: anchor.textSegmentIdentity)
            guard let positions = novel[key] else { return nil }
            let radius = NovelBookmarkAnchor.neighborhoodCharacterRadius
            let lower = anchor.displayedTextOffset.subtractingReportingOverflow(radius)
            let upper = anchor.displayedTextOffset.addingReportingOverflow(radius)
            let upperBound = upper.overflow ? Int.max : upper.partialValue
            var offset = lower.overflow ? Int.min : lower.partialValue
            var first: Candidate?
            // At most 81 integer offsets, regardless of the work's bookmark
            // count. Hashable preserves Swift's Unicode string equality and
            // optional-identity equality used by marksSamePlace.
            while offset <= upperBound {
                if let candidate = positions[offset], first == nil || candidate.order < first!.order {
                    first = candidate
                }
                if offset == upperBound { break }
                offset += 1
            }
            return first?.id
        }
    }
}

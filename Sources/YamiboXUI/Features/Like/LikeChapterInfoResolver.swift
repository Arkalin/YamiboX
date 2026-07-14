import Foundation
import YamiboXCore

/// Best-effort chapter-title lookup for Like item cards. Like anchors never
/// persist a chapter title (see implementation-design.md §11's "resolve
/// live, don't persist a value that can drift" philosophy, already applied
/// to manga chapter order) — novel titles are read back from the disk-cached
/// `NovelReaderProjection` instead. A cache miss (page never opened as a
/// reader view, or since evicted) simply yields no chapter info; the card
/// falls back to showing just the excerpt/image with no chapter caption.
enum LikeChapterInfoResolver {
    /// A `NovelReaderProjection` cache lookup is keyed by more than just the
    /// forum page: `NovelReaderProjectionStore` also keys on `authorID`, and
    /// every real projection is cached under a real, non-empty author id
    /// (see `NovelReaderProjectionBuilder.build`) — a lookup that omits it
    /// resolves to the unfiltered/"all" namespace, which never has a real
    /// entry, and is not merely a "cache miss": the underlying projection was
    /// never written under that key. `NovelTextLikeAnchor`/
    /// `NovelImageLikeAnchor` capture both dimensions at Like time so this
    /// can round-trip the exact key rather than guessing either of them.
    private struct NovelCacheContext: Hashable {
        var view: Int
        var resolvedAuthorID: String?
    }

    private static func cacheContext(for anchor: LikeAnchorPayload) -> NovelCacheContext? {
        switch anchor {
        case let .novelText(textAnchor):
            return NovelCacheContext(
                view: textAnchor.view,
                resolvedAuthorID: textAnchor.resolvedAuthorID
            )
        case let .novelImage(imageAnchor):
            return NovelCacheContext(
                view: imageAnchor.view,
                resolvedAuthorID: imageAnchor.resolvedAuthorID
            )
        case .mangaImage:
            return nil
        }
    }

    /// Matches the anchor's segment identity against `projection.segmentSemantics`
    /// and reads the corresponding `NovelReaderSegment.chapterTitle`.
    static func novelChapterTitle(
        for anchor: LikeAnchorPayload,
        in projection: NovelReaderProjection?
    ) -> String? {
        guard let projection else { return nil }
        let segmentIdentity: String
        switch anchor {
        case let .novelText(textAnchor):
            segmentIdentity = textAnchor.textSegmentIdentity.rawValue
        case let .novelImage(imageAnchor):
            segmentIdentity = imageAnchor.imageSegmentIdentity
        case .mangaImage:
            return nil
        }
        guard let index = projection.segmentSemantics.firstIndex(where: {
            $0?.textSegmentIdentity?.rawValue == segmentIdentity
        }) else {
            return nil
        }
        return trimmedOrNil(projection.segments[index].chapterTitle)
    }

    /// Resolves chapter titles for a batch of novel Like items, caching one
    /// projection load per distinct `(view, authorID)` so a list of many
    /// items on the same forum page/filter context doesn't re-read the disk
    /// cache per item.
    static func novelChapterInfo(
        for items: [LikeItem],
        threadID: String,
        cacheStore: NovelReaderProjectionStore
    ) async -> [String: String] {
        var projectionsByContext: [NovelCacheContext: NovelReaderProjection] = [:]
        var attemptedContexts: Set<NovelCacheContext> = []
        var result: [String: String] = [:]

        for item in items {
            guard let context = cacheContext(for: item.anchor) else { continue }
            if !attemptedContexts.contains(context) {
                attemptedContexts.insert(context)
                if let projection = await cacheStore.loadProjection(
                    for: NovelPageRequest(threadID: threadID, view: context.view, authorID: context.resolvedAuthorID)
                ) {
                    projectionsByContext[context] = projection
                }
            }
            if let title = novelChapterTitle(for: item.anchor, in: projectionsByContext[context]) {
                result[item.id] = title
            }
        }
        return result
    }

    /// Resolves chapter titles for a batch of manga Like items from the
    /// (already-loaded) manga directory's chapter list, matched by `tid`.
    static func mangaChapterInfo(for items: [LikeItem], directory: MangaDirectory?) -> [String: String] {
        guard let directory else { return [:] }
        var titleByTID: [String: String] = [:]
        for chapter in directory.chapters where titleByTID[chapter.tid] == nil {
            if let title = trimmedOrNil(chapter.rawTitle) {
                titleByTID[chapter.tid] = title
            }
        }
        var result: [String: String] = [:]
        for item in items {
            guard case let .mangaImage(anchor) = item.anchor, let title = titleByTID[anchor.chapterTID] else { continue }
            result[item.id] = title
        }
        return result
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

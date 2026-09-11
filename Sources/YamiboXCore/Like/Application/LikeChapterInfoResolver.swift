import Foundation

/// Saved chapter titles win; local reading data only fills missing snapshots.
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
            segmentIdentity = textAnchor.start.segmentIdentity
        case let .novelImage(imageAnchor):
            segmentIdentity = imageAnchor.imageSegmentIdentity
        case .mangaImage:
            return nil
        }
        return novelChapterTitle(forSegmentIdentity: segmentIdentity, in: projection)
    }

    static func novelChapterTitle(forSegmentIdentity identity: String, in projection: NovelReaderProjection) -> String? {
        for (segment, semantics) in zip(projection.segments, projection.segmentSemantics) {
            if semantics?.textSegmentIdentity?.rawValue == identity {
                return LikeItem.normalizedChapterTitle(segment.chapterTitle)
            }
        }
        return nil
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
            guard item.workKey == .novel(threadID: threadID) else { continue }
            if let title = LikeItem.normalizedChapterTitle(item.chapterTitle) {
                result[item.id] = title
                continue
            }
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
        var titleByTID: [String: String] = [:]
        for chapter in directory?.chapters ?? [] where titleByTID[chapter.tid] == nil {
            if let title = trimmedOrNil(chapter.rawTitle) {
                titleByTID[chapter.tid] = title
            }
        }
        var result: [String: String] = [:]
        for item in items {
            if let title = LikeItem.normalizedChapterTitle(item.chapterTitle) {
                result[item.id] = title
                continue
            }
            guard case let .mangaImage(anchor) = item.anchor, let title = titleByTID[anchor.chapterTID] else { continue }
            result[item.id] = title
        }
        return result
    }

    static func backfillNovelChapterTitles(in projection: NovelReaderProjection, store: LikeStore) async {
        let work = LikeWorkKey.novel(threadID: projection.threadID)
        let items = await store.likes(for: work)
        let snapshots = items.compactMap { item -> LikeItem? in
            guard item.chapterTitle == nil,
                  let context = cacheContext(for: item.anchor),
                  context.view == projection.view,
                  context.resolvedAuthorID == projection.resolvedAuthorID,
                  let title = novelChapterTitle(for: item.anchor, in: projection) else { return nil }
            var snapshot = item
            snapshot.chapterTitle = title
            return snapshot
        }
        _ = try? await store.resolveChapterTitles(snapshots)
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

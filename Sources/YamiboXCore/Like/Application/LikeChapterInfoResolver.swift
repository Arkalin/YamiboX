import Foundation

enum LikeChapterInfoResolver {
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
        return projection.chapterTitle(forSegmentIdentity: segmentIdentity)
    }

    static func novelChapterInfo(
        for items: [LikeItem],
        threadID: String,
        cacheStore: any NovelReaderProjectionReading
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

    static func mangaChapterInfo(for items: [LikeItem], directory: MangaDirectory?) -> [String: String] {
        var titleByTID: [String: String] = [:]
        for chapter in directory?.chapters ?? [] where titleByTID[chapter.tid] == nil {
            if let title = LikeItem.normalizedChapterTitle(chapter.rawTitle) {
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
        let work = ReadingWorkKey.novel(threadID: projection.threadID)
        let items: [LikeItem]
        do { items = try await store.likes(for: work) }
        catch {
            YamiboLog.persistence.warning("Failed to read likes for chapter-title backfill: \(error)")
            return
        }
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
}

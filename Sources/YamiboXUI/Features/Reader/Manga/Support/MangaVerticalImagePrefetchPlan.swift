import YamiboXCore

enum MangaVerticalImagePrefetchPlan {
    static func pagesToPrefetch(
        pages: [MangaReaderPageProjection],
        visiblePageIndexes: [Int],
        fallbackPageIndex: Int?
    ) -> [MangaReaderPageProjection] {
        guard !pages.isEmpty else { return [] }
        var visible = visiblePageIndexes.filter { pages.indices.contains($0) }
        if visible.isEmpty, let fallbackPageIndex {
            visible = [min(max(fallbackPageIndex, 0), pages.count - 1)]
        }
        guard let first = visible.min(), let last = visible.max() else { return [] }

        var seenURLs = Set(visible.map { pages[$0].imageURL })
        return [last + 1, first - 1, last + 2].compactMap { index in
            guard pages.indices.contains(index),
                  seenURLs.insert(pages[index].imageURL).inserted else { return nil }
            return pages[index]
        }
    }
}

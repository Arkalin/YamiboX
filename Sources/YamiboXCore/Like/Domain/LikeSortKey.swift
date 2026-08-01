import Foundation

/// Derives a Like Item's book-order key from its anchor.
///
/// Local derived state, never synced: every device can recompute it from the
/// anchor, and the `chapterOrdinal` half is only knowable on a device that has
/// actually laid the page out.
enum LikeSortKey {
    static func of(_ anchor: LikeAnchorPayload, chapterOrdinal: Int?) -> Int64 {
        switch anchor {
        case let .novelText(textAnchor):
            ReaderAnnotationSortKey.novel(
                view: textAnchor.view,
                chapterOrdinal: chapterOrdinal ?? 0,
                textSegmentIdentity: textAnchor.startSegmentIdentity,
                displayedTextOffset: textAnchor.start.offset
            )
        case let .novelImage(imageAnchor):
            ReaderAnnotationSortKey.novel(
                view: imageAnchor.view,
                chapterOrdinal: chapterOrdinal ?? 0,
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: imageAnchor.imageSegmentIdentity),
                displayedTextOffset: 0
            )
        case let .mangaImage(mangaAnchor):
            // Manga Like Items have no global page index in their anchor (it
            // predates one), so the chapter ordinal a reader session resolves
            // is what separates chapters; page index orders within one.
            ReaderAnnotationSortKey.manga(globalPageIndex: mangaAnchor.pageLocalIndex)
                + Int64(max(0, chapterOrdinal ?? 0)) * ReaderAnnotationSortKey.chapterOrdinalWeight
        }
    }

    /// The chapter identity whose ordinal would sharpen this item's key, or nil
    /// for anchors that don't have one.
    static func chapterIdentity(of anchor: LikeAnchorPayload) -> NovelChapterIdentity? {
        switch anchor {
        case let .novelText(textAnchor): textAnchor.chapterIdentity
        case let .novelImage(imageAnchor): imageAnchor.chapterIdentity
        case .mangaImage: nil
        }
    }
}

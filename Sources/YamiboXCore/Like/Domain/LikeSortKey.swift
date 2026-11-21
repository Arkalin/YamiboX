import Foundation

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
            ReaderAnnotationSortKey.manga(globalPageIndex: mangaAnchor.pageLocalIndex)
                + Int64(max(0, chapterOrdinal ?? 0)) * ReaderAnnotationSortKey.chapterOrdinalWeight
        }
    }

    static func chapterIdentity(of anchor: LikeAnchorPayload) -> NovelChapterIdentity? {
        switch anchor {
        case let .novelText(textAnchor): textAnchor.chapterIdentity
        case let .novelImage(imageAnchor): imageAnchor.chapterIdentity
        case .mangaImage: nil
        }
    }
}

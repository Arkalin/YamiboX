extension ReaderAnnotationSortKey {
    public static func of(_ anchor: BookmarkAnchorPayload) -> Int64 {
        switch anchor {
        case let .novel(novelAnchor):
            novel(
                view: novelAnchor.view,
                chapterOrdinal: novelAnchor.chapterOrdinal,
                textSegmentIdentity: novelAnchor.textSegmentIdentity,
                displayedTextOffset: novelAnchor.displayedTextOffset
            )
        case let .manga(mangaAnchor):
            manga(globalPageIndex: mangaAnchor.globalPageIndex)
        }
    }
}

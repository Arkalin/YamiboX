import Foundation

package struct NovelChapterAnchor: Hashable, Sendable {
    package let resumePoint: NovelResumePoint

    package init(resumePoint: NovelResumePoint) {
        self.resumePoint = resumePoint
    }
}

package struct NovelChapterDirectoryEntry: Hashable, Sendable {
    package let chapter: NovelReaderChapter
    package let anchor: NovelChapterAnchor?
    package let ownerPostID: String?

    package init(
        chapter: NovelReaderChapter,
        anchor: NovelChapterAnchor?,
        ownerPostID: String?
    ) {
        self.chapter = chapter
        self.anchor = anchor
        self.ownerPostID = ownerPostID
    }
}

package enum NovelChapterDirectoryExtractor {
    package static func entries(
        from projection: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings
    ) -> [NovelChapterDirectoryEntry] {
        var seenIdentities: Set<NovelChapterIdentity> = []
        return projection.segments.indices.compactMap { index in
            let segment = projection.segments[index]
            let semantics = projection.semantics(forSegmentIndex: index)
            let source = projection.source(forSegmentIndex: index)
            if source?.isAuthorReplyToOther == true, !settings.showsAuthorRepliesToOthers {
                return nil
            }
            guard let semantics,
                  let chapterIdentity = semantics.chapterIdentity,
                  seenIdentities.insert(chapterIdentity).inserted else {
                return nil
            }
            let ordinal = seenIdentities.count - 1
            let title = segment.chapterTitle ?? ""
            let anchor = semantics.textSegmentIdentity.map {
                NovelChapterAnchor(
                    resumePoint: NovelResumePoint(
                        view: projection.view,
                        chapterIdentity: chapterIdentity,
                        textSegmentIdentity: $0,
                        displayedTextOffset: 0,
                        chapterOrdinal: ordinal,
                        chapterTitle: title,
                        segmentProgress: 0,
                        authorID: projection.resolvedAuthorID,
                        readingModeHint: settings.readingMode
                    )
                )
            }
            return NovelChapterDirectoryEntry(
                chapter: NovelReaderChapter(
                    ordinal: ordinal,
                    title: title,
                    startIndex: ordinal
                ),
                anchor: anchor,
                ownerPostID: source?.ownerPostID
            )
        }
    }
}

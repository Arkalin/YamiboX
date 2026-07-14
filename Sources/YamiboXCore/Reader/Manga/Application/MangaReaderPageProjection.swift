import Foundation

public struct MangaReaderPageProjection: Hashable, Identifiable, Sendable {
    public var tid: String
    public var ownerPostID: String
    public var chapterTitle: String
    public var imageURL: URL
    public var sourceIdentity: MangaReaderProjectionSourceIdentity
    public var globalIndex: Int
    public var localIndex: Int
    public var chapterPageCount: Int

    public var id: String {
        "\(tid)#\(localIndex)"
    }

    public init(
        tid: String,
        ownerPostID: String,
        chapterTitle: String,
        imageURL: URL,
        sourceIdentity: MangaReaderProjectionSourceIdentity,
        globalIndex: Int,
        localIndex: Int,
        chapterPageCount: Int
    ) {
        self.tid = tid
        self.ownerPostID = ownerPostID
        self.chapterTitle = chapterTitle
        self.imageURL = imageURL
        self.sourceIdentity = sourceIdentity
        self.globalIndex = max(0, globalIndex)
        self.localIndex = max(0, localIndex)
        self.chapterPageCount = max(0, chapterPageCount)
    }

    public static func projections(from window: MangaChapterWindow) -> [MangaReaderPageProjection] {
        var pages: [MangaReaderPageProjection] = []
        pages.reserveCapacity(window.documents.reduce(0) { $0 + $1.imageURLs.count })

        for document in window.documents {
            for (localIndex, imageURL) in document.imageURLs.enumerated() {
                pages.append(
                    MangaReaderPageProjection(
                        tid: document.tid,
                        ownerPostID: document.ownerPostID,
                        chapterTitle: document.chapterTitle,
                        imageURL: imageURL,
                        sourceIdentity: document.sourceIdentity,
                        globalIndex: pages.count,
                        localIndex: localIndex,
                        chapterPageCount: document.imageURLs.count
                    )
                )
            }
        }

        return pages
    }

    public static func resolvedPageIndex(
        for position: MangaReadingPosition?,
        in pages: [MangaReaderPageProjection]
    ) -> Int? {
        guard let position else { return nil }
        return pages.firstIndex { page in
            page.tid == position.tid && page.localIndex == position.localIndex
        }
    }

    public static func resolvedPageIndex(for window: MangaChapterWindow) -> Int? {
        resolvedPageIndex(
            for: window.resolvedPosition,
            in: projections(from: window)
        )
    }
}

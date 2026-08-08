import Foundation

/// Shared display values for reader entry surfaces. Persistence models stay
/// free of localized presentation strings while Favorites, History, and Home
/// present the same reading state consistently.
package enum ReadingProgressPresentation {
    package static func percent(for record: ReadingProgressRecord) -> Int? {
        switch record.kind {
        case .novel:
            return record.novel?.novelDocumentSurfaceProgressPercent
        case .manga:
            guard let manga = record.manga,
                  let pageCount = manga.mangaPageCount,
                  pageCount > 0 else {
                return nil
            }
            return min(
                max(Int(((Double(manga.mangaPageIndex) + 1) / Double(pageCount) * 100).rounded()), 0),
                100
            )
        case .thread:
            guard let thread = record.thread,
                  let pageCount = thread.pageCount,
                  pageCount > 0 else {
                return nil
            }
            return min(max(Int((Double(thread.lastPage) / Double(pageCount) * 100).rounded()), 0), 100)
        }
    }

    package static func positionText(for record: ReadingProgressRecord) -> String? {
        switch record.kind {
        case .novel:
            return record.novel?.lastChapter
        case .manga:
            guard let manga = record.manga else { return nil }
            if let pageCount = manga.mangaPageCount {
                return L10n.string(
                    "favorites.progress.manga_page_total",
                    manga.lastChapter,
                    manga.mangaPageIndex + 1,
                    pageCount
                )
            }
            return L10n.string(
                "favorites.progress.manga_page",
                manga.lastChapter,
                manga.mangaPageIndex + 1
            )
        case .thread:
            guard let thread = record.thread else { return nil }
            if let pageCount = thread.pageCount {
                return L10n.string(
                    "history.progress.page_of_total",
                    String(thread.lastPage),
                    String(pageCount)
                )
            }
            return L10n.string("history.progress.page", String(thread.lastPage))
        }
    }
}

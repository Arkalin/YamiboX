import Foundation
import YamiboXCore

/// A presentation of existing history, not a separate reading library.
struct ReadingHomeShelf: Equatable {
    let readingEntries: [BrowsingHistoryEntry]
    let continuing: [BrowsingHistoryEntry]
    let previous: [BrowsingHistoryEntry]

    init(
        entries: [BrowsingHistoryEntry],
        boardReader: BoardReaderSettings,
        favoritedThreadIDs: Set<String>? = nil
    ) {
        let readingEntries = entries.filter { entry in
            guard entry.category(boardReader: boardReader) != .normal else { return false }
            guard let favoritedThreadIDs else { return true }
            // Match the history page's favorite action: smart manga uses its current chapter.
            guard let threadID = entry.target.threadID ?? entry.chapterThreadID else { return false }
            return favoritedThreadIDs.contains(threadID)
        }
            .sorted {
                if $0.lastVisitTime != $1.lastVisitTime { return $0.lastVisitTime > $1.lastVisitTime }
                return $0.id < $1.id
            }
        var categories: Set<BrowsingHistoryCategory> = []
        var continuing: [BrowsingHistoryEntry] = []
        var previous: [BrowsingHistoryEntry] = []
        for entry in readingEntries {
            if categories.insert(entry.category(boardReader: boardReader)).inserted {
                continuing.append(entry)
            } else {
                previous.append(entry)
            }
        }
        self.readingEntries = readingEntries
        self.continuing = continuing
        self.previous = previous
    }
}

struct ReadingHomeBook: Identifiable {
    let entry: BrowsingHistoryEntry
    let category: BrowsingHistoryCategory
    let isSmartManga: Bool
    let coverURL: URL?

    var id: String { entry.id }

    var kindTitle: String {
        if category == .novel { return L10n.string("history.filter.novel") }
        return L10n.string(isSmartManga ? "home.kind.smart_manga" : "history.filter.manga")
    }

    var positionText: String? {
        if category == .novel { return entry.chapterTitle }
        if let pageIndex = entry.pageIndex {
            if let pageCount = entry.pageCount {
                return L10n.string("history.progress.page_of_total", String(min(pageIndex + 1, pageCount)), String(pageCount))
            }
            return L10n.string("history.progress.page", String(pageIndex + 1))
        }
        return entry.chapterTitle
    }
}

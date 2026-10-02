import Foundation
import YamiboXCore

/// A presentation of existing history, not a separate reading library.
struct BookshelfShelf: Equatable {
    let readingEntries: [BrowsingHistoryEntry]
    let continuing: [BrowsingHistoryEntry]
    let previous: [BrowsingHistoryEntry]

    init(
        entries: [BrowsingHistoryEntry],
        boardReader: BoardReaderSettings,
        favorites: FavoriteMembershipSnapshot? = nil,
        continueSettings: BookshelfContinueSettings = .init()
    ) {
        let readingEntries = entries.filter { entry in
            guard entry.category(boardReader: boardReader) != .normal else { return false }
            return favorites?.membership(for: entry).isFavorited ?? true
        }
            .sorted {
                if $0.lastVisitTime != $1.lastVisitTime { return $0.lastVisitTime > $1.lastVisitTime }
                return $0.id < $1.id
            }
        var novelCount = 0
        var mangaCount = 0
        var continuing: [BrowsingHistoryEntry] = []
        var previous: [BrowsingHistoryEntry] = []
        for entry in readingEntries {
            let category = entry.category(boardReader: boardReader)
            let canContinue = switch continueSettings.mode {
            case .mixed:
                continuing.count < continueSettings.mixedCount
            case .separate:
                category == .novel
                    ? novelCount < continueSettings.novelCount
                    : mangaCount < continueSettings.mangaCount
            }
            if canContinue {
                continuing.append(entry)
                if category == .novel { novelCount += 1 } else { mangaCount += 1 }
            } else {
                previous.append(entry)
            }
        }
        self.readingEntries = readingEntries
        self.continuing = continuing
        self.previous = previous
    }
}

struct BookshelfBook: Identifiable {
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

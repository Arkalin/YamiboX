import Foundation

/// Stable visit data, independent of the device's reader mode and progress projection.
struct BrowsingHistorySyncRecord: Codable, Equatable, Sendable {
    var target: FavoriteContentTarget
    var threadID: String?
    var title: String
    var forumID: String?
    var authorID: String?
    var lastVisitTime: Date
    var id: String { threadID.map { "source:\($0)" } ?? target.id }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Target equality intentionally compares identity only. A persisted sync
        // record must also compare the display name: otherwise a rename-only
        // merge is exported but skipped by the store's unchanged-snapshot guard,
        // leaving its local fingerprint permanently different from the upload.
        lhs.target == rhs.target
            && lhs.target.mangaCleanBookName == rhs.target.mangaCleanBookName
            && lhs.threadID == rhs.threadID
            && lhs.title == rhs.title
            && lhs.forumID == rhs.forumID
            && lhs.authorID == rhs.authorID
            && lhs.lastVisitTime == rhs.lastVisitTime
    }

    init(_ entry: BrowsingHistoryEntry) {
        target = entry.target
        threadID = entry.lastVisitedThreadID ?? entry.target.threadID
        title = entry.lastVisitedThreadTitle ?? entry.title
        forumID = entry.forumID
        authorID = entry.authorID
        lastVisitTime = entry.lastVisitTime
    }

    var entry: BrowsingHistoryEntry {
        BrowsingHistoryEntry(target: target, title: target.mangaCleanBookName ?? title,
            forumID: forumID, authorID: authorID, chapterThreadID: target.kind == .mangaTitle ? threadID : nil,
            lastVisitTime: lastVisitTime, lastVisitedThreadID: threadID, lastVisitedThreadTitle: title)
    }
}

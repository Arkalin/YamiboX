import Foundation

/// An activity's source is not the reader identity stored in the timeline.
public struct BrowsingHistoryVisit: Sendable {
    public var threadID: String
    public var title: String
    public var forumID: String?
    public var reader: BrowsingHistoryCategory
    public var authorID: String?
    public var date: Date
    public var directory: MangaDirectory?

    public init(
        threadID: String, title: String, forumID: String? = nil,
        reader: BrowsingHistoryCategory, authorID: String? = nil,
        date: Date = .now, directory: MangaDirectory? = nil
    ) {
        self.threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title
        self.forumID = forumID?.browsingHistoryTrimmedNonEmpty
        self.reader = reader
        self.authorID = authorID
        self.date = date
        self.directory = directory
    }
}

public struct BrowsingHistorySnapshot: Sendable {
    public let entries: [BrowsingHistoryEntry]
    public let boardReader: BoardReaderSettings

    public init(entries: [BrowsingHistoryEntry], boardReader: BoardReaderSettings) {
        self.entries = entries
        self.boardReader = boardReader
    }
}

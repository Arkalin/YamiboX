import Foundation

public struct MangaChapter: Codable, Hashable, Identifiable, Sendable {
    public let tid: String
    public var rawTitle: String
    public var chapterNumber: Double
    public var view: Int
    public var authorUID: String?
    public var authorName: String?
    public var groupIndex: Int
    public var publishTime: Date?

    public var id: String { tid }

    public init(
        tid: String,
        rawTitle: String,
        chapterNumber: Double,
        view: Int = 1,
        authorUID: String? = nil,
        authorName: String? = nil,
        groupIndex: Int = 0,
        publishTime: Date? = nil
    ) {
        self.tid = tid
        self.rawTitle = rawTitle
        self.chapterNumber = chapterNumber
        self.view = max(1, view)
        self.authorUID = authorUID
        self.authorName = authorName
        self.groupIndex = groupIndex
        self.publishTime = publishTime
    }
}

import Foundation

public struct ReaderChapterCommentTarget: Codable, Hashable, Sendable {
    public var threadID: String
    public var view: Int
    public var ownerPostID: String
    public var title: String?
    public var authorID: String?

    public init(threadID: String, view: Int, ownerPostID: String, title: String? = nil, authorID: String? = nil) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "ReaderChapterCommentTarget requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.view = max(1, view)
        self.ownerPostID = ownerPostID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title
        self.authorID = authorID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.authorID?.isEmpty == true {
            self.authorID = nil
        }
    }
}

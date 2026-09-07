import Foundation

public struct NovelDetailLaunchContext: Codable, Hashable, Sendable {
    public var thread: ThreadIdentity
    public var title: String
    public var authorID: String?

    public init(thread: ThreadIdentity, title: String, authorID: String? = nil) {
        self.thread = thread
        self.title = title.nilIfBlank ?? L10n.string("reader.title")
        self.authorID = authorID?.nilIfBlank
    }
}

public struct MangaDetailLaunchContext: Codable, Hashable, Sendable {
    public var thread: ThreadIdentity
    public var title: String
    public var focusedChapterTID: String?
    public var directoryNameHint: String?

    public init(
        thread: ThreadIdentity,
        title: String,
        focusedChapterTID: String? = nil,
        directoryNameHint: String? = nil
    ) {
        self.thread = thread
        self.title = title.nilIfBlank ?? L10n.string("manga.reader.title")
        self.focusedChapterTID = focusedChapterTID?.nilIfBlank
        self.directoryNameHint = directoryNameHint?.nilIfBlank
    }
}

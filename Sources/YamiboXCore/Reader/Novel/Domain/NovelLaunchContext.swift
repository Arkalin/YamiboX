import Foundation

public enum NovelLaunchSource: String, Codable, Hashable, Sendable {
    case forum
    case favorites
    case resume
    case like
    case history
}

public struct NovelLaunchContext: Codable, Hashable, Identifiable, Sendable {
    public var threadID: String
    public var threadTitle: String
    public var source: NovelLaunchSource
    public var initialView: Int?
    public var authorID: String?
    public var initialResumePoint: NovelResumePoint?
    /// When true, this reader session must not persist reading progress,
    /// resume route, or Favorite Library recency. See Reader Preview Mode in
    /// docs/contexts/reader-navigation/CONTEXT.md.
    public var isPreview: Bool

    public var id: String { threadID }

    public init(
        threadID: String,
        threadTitle: String,
        source: NovelLaunchSource,
        initialView: Int? = nil,
        authorID: String? = nil,
        initialResumePoint: NovelResumePoint? = nil,
        isPreview: Bool = false
    ) {
        self.threadID = Self.normalizedThreadID(threadID)
        self.threadTitle = threadTitle
        self.source = source
        self.initialView = initialView
        self.authorID = authorID
        self.initialResumePoint = initialResumePoint
        self.isPreview = isPreview
    }

    private static func normalizedThreadID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "NovelLaunchContext requires a Yamibo thread tid")
        return trimmed
    }
}

public struct NovelPageRequest: Codable, Hashable, Sendable {
    public var threadID: String
    public var view: Int
    public var authorID: String?

    public init(threadID: String, view: Int, authorID: String? = nil) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "NovelPageRequest requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.view = max(1, view)
        self.authorID = authorID
    }
}

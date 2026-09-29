import Foundation

public struct ForumAnnouncementPage: Equatable, Sendable {
    public let items: [ForumAnnouncement]
    public let filters: [ForumComposerLink]
    public let selectedID: String?
}

public struct ForumAnnouncement: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    public let authorURL: URL?
    public let date: String
    public let blocks: [ForumThreadContentBlock]
}

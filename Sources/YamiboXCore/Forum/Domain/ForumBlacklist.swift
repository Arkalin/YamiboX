import Foundation

public struct ForumBlacklistEntry: Codable, Equatable, Identifiable, Sendable {
    public let uid: String
    public let username: String
    public let avatarURL: URL?
    public let deleteURL: URL

    public var id: String { uid }

    public init(uid: String, username: String, avatarURL: URL?, deleteURL: URL) {
        self.uid = uid
        self.username = username
        self.avatarURL = avatarURL
        self.deleteURL = deleteURL
    }
}

public struct ForumBlacklistPage: Sendable {
    public let entries: [ForumBlacklistEntry]
    public let navigation: ForumPageNavigation?
    public let formHash: String

    public init(entries: [ForumBlacklistEntry], navigation: ForumPageNavigation?, formHash: String) {
        self.entries = entries
        self.navigation = navigation
        self.formHash = formHash
    }
}

public enum ForumBlockedReplyDisplay: String, Codable, CaseIterable, Sendable {
    case placeholder
    case hidden
}

public protocol ForumBlacklistRemoteOperating: Sendable {
    func fetchPage(page: Int) async throws -> ForumBlacklistPage
    func fetchUser(uid: String?) async throws -> UserSpaceProfile
    func add(username: String, formHash: String) async throws
    func remove(_ entry: ForumBlacklistEntry) async throws
}

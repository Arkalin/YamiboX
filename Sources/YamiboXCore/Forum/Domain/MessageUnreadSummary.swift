import Foundation

public struct MessageUnreadSummary: Equatable, Sendable {
    public let privateMessageCount: Int
    public let noticeCount: Int

    public var totalCount: Int { privateMessageCount + noticeCount }

    public init(privateMessageCount: Int, noticeCount: Int) {
        precondition(privateMessageCount >= 0 && noticeCount >= 0)
        precondition(privateMessageCount <= Int.max - noticeCount)
        self.privateMessageCount = privateMessageCount
        self.noticeCount = noticeCount
    }
}

public protocol MessageUnreadLoading: Sendable {
    func fetchUnreadSummary() async throws -> MessageUnreadSummary
}

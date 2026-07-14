import Foundation

public struct NovelReaderCacheBatchProgress: Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case running
        case completed
        case cancelled
    }

    public var totalCount: Int
    public var completedCount: Int
    public var currentView: Int?
    public var completedViews: [Int]
    public var failedViews: [Int]
    public var status: Status

    public init(
        totalCount: Int,
        completedCount: Int,
        currentView: Int?,
        completedViews: [Int],
        failedViews: [Int],
        status: Status
    ) {
        self.totalCount = totalCount
        self.completedCount = completedCount
        self.currentView = currentView
        self.completedViews = completedViews
        self.failedViews = failedViews
        self.status = status
    }
}

public struct NovelReaderCacheBatchResult: Hashable, Sendable {
    public var totalCount: Int
    public var completedViews: [Int]
    public var failedViews: [Int]
    public var wasCancelled: Bool

    public init(
        totalCount: Int,
        completedViews: [Int],
        failedViews: [Int],
        wasCancelled: Bool
    ) {
        self.totalCount = totalCount
        self.completedViews = completedViews
        self.failedViews = failedViews
        self.wasCancelled = wasCancelled
    }
}
